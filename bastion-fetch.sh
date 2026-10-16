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
GO_VER=1.26.0
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

# <local-name>|<hf-repo>|<file-glob>
# Qwen's own GGUF repo 401s; unsloth's is the usable mirror.
MODELS=(
  "qwen3-coder-30b-a3b|unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF|*Q4_K_M*.gguf"
# "deepseek-coder-v2-lite|bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF|*Q4_K_M*.gguf"
# "gpt-oss-20b|ggml-org/gpt-oss-20b-GGUF|*mxfp4*.gguf"
)

# ------------------------------------------------------------- helpers ------
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

# Prefer wheels tagged for the TARGET (cp311/manylinux), not this host.
pipdl() { # pipdl <destdir> <pkgs...>
  local dest="$1"; shift
  python3 -m pip download -q -d "$dest" \
      --only-binary=:all: --platform manylinux2014_x86_64 \
      --python-version 3.11 --implementation cp --abi cp311 "$@" 2>/dev/null \
    && { echo "   ok (cp311/manylinux wheels)"; return 0; }
  warn "strict cp311 download failed for: $*  - retrying natively"
  warn "  (if this bastion is not py3.11/x86_64 linux, those may not install)"
  python3 -m pip download -q -d "$dest" "$@"
}

# ------------------------------------------------------------- emacs --------
fetch_emacs() {
  local D="$OUT/emacs"

  say "emacs $EMACS_VER source"
  get "https://ftp.gnu.org/gnu/emacs/emacs-$EMACS_VER.tar.xz" "$D/emacs-$EMACS_VER.tar.xz"
  to_targz "$D/emacs-$EMACS_VER.tar.xz" "$D/emacs-$EMACS_VER.tar.gz" \
    && rm -f "$D/emacs-$EMACS_VER.tar.xz"

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

  say "gopls + dlv (static linux/amd64 - built here, nothing to build there)"
  if [ -x "$D/bin/gopls" ] && [ -x "$D/bin/dlv" ]; then
    echo "   have gopls/dlv"
  else
    local GR="$OUT/.goroot"
    [ -x "$GR/go/bin/go" ] || { mkdir -p "$GR"; tar -C "$GR" -xzf "$D/go$GO_VER.linux-amd64.tar.gz"; }
    mkdir -p "$D/bin"
    env GOROOT="$GR/go" PATH="$GR/go/bin:$PATH" GOBIN="$D/bin" \
        GOFLAGS=-trimpath GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
        "$GR/go/bin/go" install \
          golang.org/x/tools/gopls@latest \
          github.com/go-delve/delve/cmd/dlv@latest
    echo "   built: $(ls "$D/bin")"
  fi

  say "clangd $CLANGD_VER (C/C++/CUDA LSP; runs on glibc 2.28, no RPM needed)"
  get "https://github.com/clangd/clangd/releases/download/$CLANGD_VER/clangd-linux-$CLANGD_VER.zip" \
      "$D/clangd-linux-$CLANGD_VER.zip"
  to_targz "$D/clangd-linux-$CLANGD_VER.zip" "$D/clangd-$CLANGD_VER.tar.gz" \
    && rm -f "$D/clangd-linux-$CLANGD_VER.zip"

  say "shellcheck $SHELLCHECK_VER (static; backs flymake in bash buffers)"
  get "https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VER/shellcheck-$SHELLCHECK_VER.linux.x86_64.tar.gz" \
      "$D/shellcheck-$SHELLCHECK_VER.tar.gz"

  say "python language server wheels"
  mkdir -p "$D/wheels-lsp"
  pipdl "$D/wheels-lsp" python-lsp-server ruff || warn "python LSP wheels incomplete"

  # Carry the editor config across if it's sitting next to this script.
  if [ -d "$(dirname "$0")/dotfiles" ]; then
    say "bundling dotfiles/"
    cp -R "$(dirname "$0")/dotfiles" "$D/dotfiles"
  fi

  # The target-side installer travels inside the bundle.
  for s in install-target.sh build-grammars.sh; do
    [ -f "$(dirname "$0")/$s" ] && cp "$(dirname "$0")/$s" "$D/$s"
  done
}

# -------------------------------------------------------------- model -------
fetch_model() {
  local D="$OUT/model"

  say "ollama $OLLAMA_VER (prebuilt, CUDA bundled, runs on glibc 2.28)"
  get "https://github.com/ollama/ollama/releases/download/$OLLAMA_VER/ollama-linux-amd64.tar.zst" \
      "$D/ollama-linux-amd64.tar.zst"
  to_targz "$D/ollama-linux-amd64.tar.zst" "$D/ollama-linux-amd64.tar.gz" \
    && rm -f "$D/ollama-linux-amd64.tar.zst"

  say "aider wheels"
  mkdir -p "$D/wheels-aider"
  pipdl "$D/wheels-aider" aider-chat || warn "aider wheels incomplete"

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

  # The target-side installer rides along inside the bundle it installs.
  [ -f "$(dirname "$0")/install-model.sh" ] && cp "$(dirname "$0")/install-model.sh" "$D/"
  true
}

# --------------------------------------------------------------- pack -------
case "$STAGE" in
  emacs) fetch_emacs ;;
  model) fetch_model ;;
  all)   fetch_emacs; fetch_model ;;
  *)     echo "usage: $0 [all|emacs|model]" >&2; exit 2 ;;
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
