#!/usr/bin/env bash
# Runs on a host that has internet access (i.e. not the air-gapped target).
# Fetches everything needed to stand up the dev env + local coding model on the
# air-gapped RHEL 8.10 target.
#
#   ./bastion-fetch.sh            # everything
#   ./bastion-fetch.sh emacs      # editor + toolchain only
#   ./bastion-fetch.sh model      # ollama + weights + aider only
#
# Design constraints this encodes:
#   * The target has NO dnf repos, so nothing here is an RPM. Every binary is
#     either built from source there or is a prebuilt that runs on glibc 2.28.
#   * Everything is normalized to .tar.gz. RHEL 8.10 ships tar 1.30, which
#     predates --zstd (tar 1.31), and xz presence is not guaranteed.
#   * Only pure-Go binaries are built here (static, glibc-independent).
set -euo pipefail

STAGE="${1:-all}"
OUT="${OUT:-$PWD/airgap}"
mkdir -p "$OUT"/{emacs,model}

# ---------------------------------------------------------------- pins ------
# Bump if a URL 404s. All of these were verified live; the script prints a
# manifest of what it actually got at the end.
EMACS_VER=30.1                 # match the Mac exactly -> identical behavior
TREE_SITTER_VER=0.25.3         # any 0.25.x is fine (Emacs 30 takes ABI 13-15)
GO_VER=1.27.2                  # gopls@latest needs >= 1.27 to build; keep
                               # the shipped toolchain >= that
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/emmettlsc/dotfiles.git}"
AIDER_MIN=0.86                 # floor: a resolver dead-end must error,
                               # never quietly downgrade
OLLAMA_VER=v0.40.5             # asset NAMES and FORMAT change between releases
CLANGD_VER=23.1.0              # needs only GLIBC_2.18; static libstdc++
SHELLCHECK_VER=v0.11.0         # fully static

# <lang>|<repo>|<ref>   -> emacs loads libtree-sitter-<lang>.so
# Every tag below was compiled and load-tested against Emacs 30.1.
GRAMMARS=(
  "go|tree-sitter/tree-sitter-go|v0.23.4"
  "gomod|camdencheek/tree-sitter-go-mod|v1.1.0"
  "c|tree-sitter/tree-sitter-c|v0.23.4"
  "cpp|tree-sitter/tree-sitter-cpp|v0.23.4"
  "python|tree-sitter/tree-sitter-python|v0.23.6"
  "bash|tree-sitter/tree-sitter-bash|v0.23.3"
  "yaml|ikatyang/tree-sitter-yaml|v0.5.0"
  "dockerfile|camdencheek/tree-sitter-dockerfile|v0.2.0"
  "cmake|uyha/tree-sitter-cmake|v0.5.0"
  "json|tree-sitter/tree-sitter-json|v0.24.8"
)

# Models pulled from the ollama registry on THIS host, so the target receives
# a finished blob store and never runs the GGUF import path. Preferred: that
# path needs llama-quantize and can need "compatibility patches" on the
# target, and it copies every GGUF a second time into the blob store.
# aider counts tokens with tiktoken, which downloads its BPE vocab from
# openaipublic.blob.core.windows.net on first use -- fatal on an air-gapped
# box. tiktoken keys each cached file by sha1(url), verified against tiktoken
# itself, so the cache can be seeded with curl and needs no python here.
TIKTOKEN_BASE_URL="https://openaipublic.blob.core.windows.net/encodings"
TIKTOKEN_ENCODINGS=(cl100k_base o200k_base p50k_base r50k_base)

REGISTRY_MODELS=(
  "qwen3-coder:30b"
# "deepseek-coder-v2:16b"
# "gpt-oss:20b"
)

# Used only by the `model-gguf' stage.
# <local-name>|<hf-repo>|<file-glob>
# Qwen's own GGUF repo 401s; unsloth's is the usable mirror.
MODELS=(
  "qwen3-coder-30b-a3b|unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF|*Q4_K_M*.gguf"
# "deepseek-coder-v2-lite|bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|*Q4_K_M*.gguf"
# "gpt-oss-20b|ggml-org/gpt-oss-20b-GGUF|*mxfp4*.gguf"
)

# ------------------------------------------------------------- helpers ------
# Stamp the bundle with the commit it was built from. The installers print
# this, so "is the target running the current script?" is answerable without
# diffing files across an air gap.
stamp_rev() { # stamp_rev <dir>
  local d="$(dirname "$0")" rev
  rev="$(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '%s %s\n' "$rev" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/BUNDLE_REV"
  echo "   bundle rev: $rev"
}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }

get() { # get <url> <dest>
  if [ -s "$2" ]; then echo "   have $(basename "$2")"; return 0; fi
  echo "   fetch $(basename "$2")"
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$2.part" "$1"
  mv "$2.part" "$2"
}

# Recompress to .tar.gz so the target needs nothing but tar+gzip.
to_targz() { # to_targz <archive> <out.tar.gz>
  local src="$1" dst="$2"
  [ -s "$dst" ] && { echo "   have $(basename "$dst")"; return 0; }
  local dec
  case "$src" in
    *.tar.zst) dec="zstd -dc" ;;
    *.tar.xz)  dec="xz -dc"   ;;
    *.tar.gz)  cp "$src" "$dst"; return 0 ;;
    *.zip)
      command -v unzip >/dev/null || { warn "no unzip; shipping $(basename "$src") as-is"; return 1; }
      local t; t="$(mktemp -d)"
      unzip -q "$src" -d "$t"
      tar -C "$t" -czf "$dst.part" . && mv "$dst.part" "$dst"
      rm -rf "$t"; echo "   repacked -> $(basename "$dst")"; return 0 ;;
    *) warn "unknown archive type: $src"; return 1 ;;
  esac
  local tool="${dec%% *}"
  command -v "$tool" >/dev/null || { warn "no $tool here; shipping $(basename "$src") as-is"; return 1; }
  echo "   repacking $(basename "$src") -> $(basename "$dst")"
  $dec "$src" | gzip -1 > "$dst.part" && mv "$dst.part" "$dst"
}

# Fetch then normalize, skipping the download entirely when the normalized
# artifact is already present. Without this a re-run re-downloads the original
# every time, because the first run deletes it after repacking -- 52MB for
# emacs, 1.4GB for ollama.
# Delete artifacts left over from a previous pin. The target side discovers
# archives by glob, and an old version can win it (go1.26.0 sorts before
# go1.27.2), which would quietly ship the wrong toolchain.
prune_stale() { # prune_stale <dir> <glob> <keep-basename>
  local f
  for f in "$1"/$2; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "$3" ] && continue
    echo "   pruned $(basename "$f")"; rm -f "$f"
  done
}

fetch_norm() { # fetch_norm <url> <download-path> <final.tar.gz>
  if [ -s "$3" ]; then echo "   have $(basename "$3")"; return 0; fi
  get "$1" "$2"
  if to_targz "$2" "$3"; then rm -f "$2"; fi
}

# Wheel downloading is the most failure-prone step here. The rule, established
# by testing every combination inside a real RHEL 8.10 x86_64 container:
#
#   The fetch host's python must BE 3.11, the same as the target.
#
# Retargeting with --python-version does NOT work for aider's dependency set
# at ANY pip version -- 21.3.1, 22.3.1 and 24.2 all fail identically with
# "Cannot install aider-chat==0.86.0 and aider-chat==0.86.1 ...
# ResolutionImpossible", because markers are evaluated against the running
# interpreter. With python 3.11 running, no retargeting is needed and it
# resolves cleanly.
#
# --platform is then needed only when the host OS/arch differs from the
# target. On linux x86_64 with glibc <= 2.28 the host's own tags are already
# right (they include manylinux_2_28 and everything below). On a foreign host
# BOTH manylinux tags must be named -- 2014 alone backtracks to a 2024 aider,
# 2_28 alone fails since pip does not expand tags downward -- and repeating
# --platform needs pip >= 22 (pip 21 honours only the last, silently).
TARGET_GLIBC=2.28
TARGET_PY=3.11

# A self-contained CPython 3.11 for when the fetch host has none and you have
# no root. Extracts and runs as a plain user, bundles pip and OpenSSL, and
# needs only glibc >= 2.17 (the target has 2.28).
PY311_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.11.17%2B20261013-x86_64-unknown-linux-gnu-install_only.tar.gz"

PY_BIN="${PY_BIN:-}"
pick_python() {
  local c v
  for c in python3.11 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    v="$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    [ "$v" = "$TARGET_PY" ] && { PY_BIN="$c"; return 0; }
  done
  # No system 3.11. Rather than failing -- or worse, retargeting from an older
  # interpreter, which yields ResolutionImpossible at every pip version --
  # fetch a self-contained one. Needs no root.
  bootstrap_python
}

bootstrap_python() {
  local root="$OUT/.python311" py="$OUT/.python311/python/bin/python3.11"
  if [ -x "$py" ]; then PY_BIN="$py"; return 0; fi
  say "no system python $TARGET_PY: fetching a self-contained one (no root needed)"
  mkdir -p "$root"
  get "$PY311_URL" "$root/cpython311.tar.gz" || { warn "could not download CPython $TARGET_PY"; return 1; }
  tar -C "$root" -xzf "$root/cpython311.tar.gz" || { warn "could not unpack CPython"; return 1; }
  if [ ! -x "$py" ]; then warn "unexpected layout in the CPython tarball"; return 1; fi
  PY_BIN="$py"
  echo "   $("$PY_BIN" -V 2>&1)  pip $("$PY_BIN" -m pip --version 2>/dev/null | awk '{print $2}')"
  echo "   (local to $root -- nothing installed system-wide)"
}

ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
host_glibc() { ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1; }

host_tags_ok_for_target() {
  [ "$(uname -s)" = Linux ] || return 1
  [ "$(uname -m)" = x86_64 ] || return 1
  local g; g="$(host_glibc)"; [ -n "$g" ] || return 1
  ver_le "$g" "$TARGET_GLIBC"
}

pip_major() { "$PY_BIN" -m pip --version 2>/dev/null | awk '{print $2}' | cut -d. -f1; }

pipdl() { # pipdl <destdir> <pkgs...>
  local dest="$1"; shift
  [ -n "$PY_BIN" ] || pick_python || return 1
  # Start clean: a dir left by a failed resolution holds several candidate
  # versions and a partial dependency set.
  rm -rf "$dest"; mkdir -p "$dest"

  if host_tags_ok_for_target; then
    echo "   native mode (py $TARGET_PY, linux x86_64, glibc $(host_glibc))"
    "$PY_BIN" -m pip download -q -d "$dest" --only-binary=:all: "$@" && return 0
    warn "wheel download failed for: $*"
    return 1
  fi

  echo "   cross mode (host is not linux/x86_64/glibc<=$TARGET_GLIBC)"
  local pm; pm="$(pip_major)"
  if [ -z "$pm" ] || [ "$pm" -lt 22 ]; then
    warn "pip $("$PY_BIN" -m pip --version 2>/dev/null | awk '{print $2}') cannot be trusted with repeated"
    warn "  --platform (needs >= 22; pip 21 honours only the last, silently)."
    warn "  Run:  $PY_BIN -m pip install --user --upgrade pip"
    return 1
  fi
  "$PY_BIN" -m pip download -q -d "$dest" --only-binary=:all: \
      --platform manylinux_2_28_x86_64 --platform manylinux2014_x86_64 "$@" \
    && return 0
  warn "wheel download failed for: $*"
  return 1
}

# ------------------------------------------------------------- emacs --------
fetch_emacs() {
  local D="$OUT/emacs"

  say "emacs $EMACS_VER source"
  fetch_norm "https://ftp.gnu.org/gnu/emacs/emacs-$EMACS_VER.tar.xz" \
             "$D/emacs-$EMACS_VER.tar.xz" "$D/emacs-$EMACS_VER.tar.gz"
  prune_stale "$D" 'emacs-*.tar.*' "emacs-$EMACS_VER.tar.gz"

  say "libtree-sitter $TREE_SITTER_VER source (C library; no Rust needed)"
  get "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v$TREE_SITTER_VER.tar.gz" \
      "$D/libtree-sitter-$TREE_SITTER_VER.tar.gz"

  say "tree-sitter grammars (source; compiled on target)"
  mkdir -p "$D/grammars"
  for g in "${GRAMMARS[@]}"; do
    IFS='|' read -r lang repo ref <<<"$g"
    get "https://github.com/$repo/archive/refs/tags/$ref.tar.gz" "$D/grammars/$lang-$ref.tar.gz"
  done

  say "go toolchain $GO_VER (gopls shells out to 'go list' - required on target)"
  get "https://go.dev/dl/go$GO_VER.linux-amd64.tar.gz" "$D/go$GO_VER.linux-amd64.tar.gz"
  prune_stale "$D" 'go*.linux-amd64.tar.gz' "go$GO_VER.linux-amd64.tar.gz"

  say "gopls + dlv (static linux/amd64 - built here, nothing to build there)"
  if [ -x "$D/bin/gopls" ] && [ -x "$D/bin/dlv" ]; then
    echo "   have gopls/dlv"
  else
    local GR="$OUT/.goroot" GP="$OUT/.gopath"
    [ -x "$GR/go/bin/go" ] || { mkdir -p "$GR"; tar -C "$GR" -xzf "$D/go$GO_VER.linux-amd64.tar.gz"; }
    mkdir -p "$D/bin" "$GP"
    # ONE package per invocation: `go install pkg@version' requires every
    # argument to come from the same module, so gopls and dlv cannot share a
    # command line ("All packages must be provided by the same module").
    #
    # GOBIN is deliberately unset: go refuses it outright when the build is a
    # cross-compile ("cannot install cross-compiled binaries when GOBIN is
    # set"), which is exactly what happens if this is ever run from a mac
    # instead of a linux host. Collect from GOPATH/bin afterwards instead --
    # a cross-build lands in a <goos>_<goarch>/ subdirectory there, a native
    # one directly in bin/.
    #
    # GOROOT stays unset too: when a tool wants a newer toolchain (gopls now
    # needs >= 1.27) go re-execs into it, and a GOROOT pinned at the bundled
    # version contradicts that. GOTOOLCHAIN=auto is explicit so a host with
    # GOTOOLCHAIN=local in its environment still works.
    local pkg b src
    for pkg in golang.org/x/tools/gopls@latest \
               github.com/go-delve/delve/cmd/dlv@latest; do
      echo "   building ${pkg%@*}"
      env PATH="$GR/go/bin:$PATH" GOPATH="$GP" GOTOOLCHAIN=auto \
          GOFLAGS=-trimpath GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
          "$GR/go/bin/go" install "$pkg" \
        || warn "failed to build ${pkg%@*}"
    done
    for b in gopls dlv; do
      src="$(find "$GP/bin" -type f -name "$b" 2>/dev/null | head -1)"
      if [ -n "$src" ]; then install -m755 "$src" "$D/bin/$b"; echo "   ok $b"
      else warn "$b was not produced"; fi
    done
  fi

  say "clangd $CLANGD_VER (C/C++/CUDA LSP; runs on glibc 2.28, no RPM needed)"
  fetch_norm "https://github.com/clangd/clangd/releases/download/$CLANGD_VER/clangd-linux-$CLANGD_VER.zip" \
             "$D/clangd-linux-$CLANGD_VER.zip" "$D/clangd-$CLANGD_VER.tar.gz"
  prune_stale "$D" 'clangd-*' "clangd-$CLANGD_VER.tar.gz"

  say "shellcheck $SHELLCHECK_VER (static; backs flymake in bash buffers)"
  get "https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VER/shellcheck-$SHELLCHECK_VER.linux.x86_64.tar.gz" \
      "$D/shellcheck-$SHELLCHECK_VER.tar.gz"

  say "python language server wheels"
  mkdir -p "$D/wheels-lsp"
  # compiledb turns a make build (or its dry run) into the
  # compile_commands.json clangd needs. Pure python, so it bundles trivially.
  pipdl "$D/wheels-lsp" python-lsp-server ruff compiledb \
    || warn "python LSP wheels incomplete"

  # Sync the editor config rather than trusting whatever clone is lying
  # around: a stale dotfiles/ here is invisible until the target is already
  # running the old init.el, which is a slow and confusing way to find out.
  say "dotfiles"
  local dd="$(dirname "$0")/dotfiles"
  if [ -d "$dd/.git" ]; then
    ( cd "$dd" && git pull --ff-only -q ) \
      && echo "   pulled: $(cd "$dd" && git log --oneline -1)" \
      || warn "git pull failed in $dd - bundling it as-is"
  elif [ -n "${DOTFILES_REPO:-}" ]; then
    git clone -q "$DOTFILES_REPO" "$dd" && echo "   cloned $DOTFILES_REPO"
  fi
  if [ -d "$dd" ]; then
    rm -rf "$D/dotfiles"; cp -R "$dd" "$D/dotfiles"; rm -rf "$D/dotfiles/.git"
    echo "   bundled $(ls "$D/dotfiles" | tr '\n' ' ')"
  else
    warn "no dotfiles/ next to this script and DOTFILES_REPO unset:"
    warn "  the target will get no init.el"
  fi

  # The target-side installer travels inside the bundle.
  stamp_rev "$D"
  for s in install-target.sh build-grammars.sh; do
    [ -f "$(dirname "$0")/$s" ] && cp "$(dirname "$0")/$s" "$D/$s"
  done
}

# -------------------------------------------------------------- model -------
sha1_of() { # sha1_of <string>  (no trailing newline: matches hashlib.sha1)
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | awk '{print $1}'
  else printf '%s' "$1" | shasum | awk '{print $1}'; fi
}

fetch_tiktoken() {
  local cache="$OUT/model/tiktoken-cache" e url key
  say "tiktoken BPE cache"
  mkdir -p "$cache"
  for e in "${TIKTOKEN_ENCODINGS[@]}"; do
    url="$TIKTOKEN_BASE_URL/$e.tiktoken"
    key="$(sha1_of "$url")"
    if [ -s "$cache/$key" ]; then echo "   have $e"; continue; fi
    get "$url" "$cache/$key" && echo "   $e -> $key"
  done
}

fetch_model_common() {
  local D="$OUT/model"

  say "ollama $OLLAMA_VER (prebuilt, CUDA bundled, runs on glibc 2.28)"
  fetch_norm "https://github.com/ollama/ollama/releases/download/$OLLAMA_VER/ollama-linux-amd64.tar.zst" \
             "$D/ollama-linux-amd64.tar.zst" "$D/ollama-linux-amd64.tar.gz"

  say "aider wheels"
  mkdir -p "$D/wheels-aider"
  # The floor is load-bearing: without it a resolver dead-end downgrades
  # instead of failing, and you only notice from a stale UI much later.
  pipdl "$D/wheels-aider" "aider-chat>=$AIDER_MIN" || warn "aider wheels incomplete"
  local got; got="$(ls "$D/wheels-aider"/aider_chat-*.whl 2>/dev/null | head -1)"
  if [ -n "$got" ]; then echo "   resolved: $(basename "$got")"
  else warn "NO aider wheel resolved - check the pip output above"; fi

  fetch_tiktoken
  stamp_rev "$D"

  # The target-side installer rides along inside the bundle it installs.
  [ -f "$(dirname "$0")/install-model.sh" ] && cp "$(dirname "$0")/install-model.sh" "$D/"
  true
}

# ---------------------------------------------------- registry pull ---------
# Run a real ollama here and pull upstream, leaving a ready blob store in the
# bundle. The target then only has to serve it.
pull_models() {
  local D="$OUT/model" HOSTDIR="$OUT/.ollama-host" store="$OUT/model/ollama-models"
  local arc="$D/ollama-linux-amd64.tar.gz"
  [ -s "$arc" ] || { warn "no ollama archive yet - run the model stage first"; return 1; }

  say "unpacking ollama here (to do the pulling)"
  if [ ! -x "$HOSTDIR/bin/ollama" ]; then
    mkdir -p "$HOSTDIR"; tar -C "$HOSTDIR" -xzf "$arc"
  fi
  [ -x "$HOSTDIR/bin/ollama" ] || { warn "no bin/ollama inside $arc"; return 1; }

  say "pulling into $store"
  mkdir -p "$store"
  # Port 11435, not the default 11434: this must not collide with (or steal
  # models from) an ollama already running on this host.
  local hostport="127.0.0.1:11435" log="$OUT/.ollama-host.log" pid i m
  OLLAMA_MODELS="$store" OLLAMA_HOST="$hostport" "$HOSTDIR/bin/ollama" serve >>"$log" 2>&1 &
  pid=$!
  for i in $(seq 1 60); do
    curl -sf --max-time 2 "http://$hostport/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! curl -sf --max-time 2 "http://$hostport/api/version" >/dev/null 2>&1; then
    kill "$pid" 2>/dev/null || true
    tail -15 "$log" >&2; warn "local ollama did not start (log: $log)"; return 1
  fi
  for m in "${REGISTRY_MODELS[@]}"; do
    echo "   pull $m"
    OLLAMA_HOST="$hostport" "$HOSTDIR/bin/ollama" pull "$m" || warn "pull failed: $m"
  done
  OLLAMA_HOST="$hostport" "$HOSTDIR/bin/ollama" list 2>/dev/null | sed 's/^/   /'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  du -sh "$store" 2>/dev/null | sed 's/^/   store: /'
}

# ---------------------------------------------------- gguf (fallback) -------
fetch_gguf() {
  local D="$OUT/model"
  say "GGUF weights"
  command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1 || \
    python3 -m pip install -q --user huggingface_hub || warn "could not install huggingface_hub"
  local HF; HF="$(command -v hf || command -v huggingface-cli || true)"
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name repo glob <<<"$m"
    if [ -n "$HF" ]; then
      echo "   $name <- $repo ($glob)"
      "$HF" download "$repo" --include "$glob" --local-dir "$D/gguf/$name" || warn "failed: $repo"
    else
      warn "no hf CLI; fetch $repo manually into $D/gguf/$name"
    fi
  done

  # Modelfiles let ollama import a bare GGUF with no registry access.
  # num_ctx MUST be set here: ollama defaults to 2048, which silently guts
  # aider's repo map and file context.
  mkdir -p "$D/modelfiles"
  for m in "${MODELS[@]}"; do
    IFS='|' read -r name _r _g <<<"$m"
    local f
    f="$(find "$D/gguf/$name" -name '*-00001-of-*.gguf' 2>/dev/null | head -1)"
    [ -n "$f" ] || f="$(find "$D/gguf/$name" -name '*.gguf' 2>/dev/null | head -1)"
    [ -n "$f" ] || { warn "no .gguf for $name - skipping Modelfile"; continue; }
    cat > "$D/modelfiles/$name.Modelfile" <<MF
FROM ./${f#"$D/"}
PARAMETER num_ctx 32768
PARAMETER temperature 0.2
MF
    echo "   modelfile $name -> ${f#"$D/"}"
  done
}

# --------------------------------------------------------------- pack -------
case "$STAGE" in
  emacs)      fetch_emacs ;;
  model)      fetch_model_common; pull_models ;;
  model-gguf) fetch_model_common; fetch_gguf ;;
  all)        fetch_emacs; fetch_model_common; pull_models ;;
  *) echo "usage: $0 [all|emacs|model|model-gguf]" >&2
     echo "  model       ollama + aider + registry pull (recommended)" >&2
     echo "  model-gguf  ollama + aider + HuggingFace GGUF + Modelfiles" >&2
     exit 2 ;;
esac

if [ "$STAGE" = emacs ] || [ "$STAGE" = all ]; then
  say "packing emacs bundle"
  ( cd "$OUT" && tar -czf emacs-bundle.tar.gz emacs )
  ls -lh "$OUT/emacs-bundle.tar.gz"
fi

say "manifest"
du -sh "$OUT"/emacs "$OUT"/model 2>/dev/null || true
find "$OUT" -maxdepth 3 -type f \( -name '*.tar.gz' -o -name '*.whl' -o -name '*.gguf' \
  -o -name 'gopls' -o -name 'dlv' \) -exec du -h {} + 2>/dev/null | sort -k2

say "transfer"
echo "  emacs:  scp $OUT/emacs-bundle.tar.gz target:/tmp/"
echo "  model:  rsync -aP --inplace $OUT/model/ target:/data1/ai/"
echo "          (left untarred on purpose - GGUFs are incompressible and"
echo "           re-taring 19GB just doubles bastion disk for nothing)"
