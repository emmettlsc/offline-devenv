#!/usr/bin/env bash
# Runs ON THE AIR-GAPPED TARGET, from inside the transferred model/ directory
# (the one rsync'd to e.g. /data1/ai).
#
#   ./install-model.sh              # ollama + import weights + aider + verify
#   ./install-model.sh serve        # (re)start the server in the background
#   ./install-model.sh stop
#
# Nothing here reaches the network: ollama is a prebuilt tarball, the weights
# are plain GGUF imported via a Modelfile (no registry pull), and aider comes
# from a local wheelhouse.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/opt}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# The blob store is a COPY of each GGUF, so it must live on the big disk --
# not under $HOME, which is where ollama would put it by default.
OLLAMA_MODELS="${OLLAMA_MODELS:-$HERE/ollama-models}"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
LOG="$HERE/ollama.log"
PIDFILE="$HERE/ollama.pid"

export OLLAMA_MODELS OLLAMA_HOST
# Flash attention is a prerequisite for KV-cache quantization in ollama, and
# q8_0 KV roughly halves cache VRAM -- the difference between a comfortable
# 32k context and OOM at ~19GB of weights on a 24GB card.
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
# Keep the model resident between aider calls; reloading 19GB per prompt is
# the single biggest source of "why is this so slow".
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"

OLLAMA="$PREFIX/bin/ollama"

# Append a guarded source line to an rc file. Additive and idempotent; never
# replaces one.
add_rc() { # add_rc <rcfile> <needle> <line>
  if [ ! -e "$1" ]; then echo "   $(basename "$1") does not exist - skipped"; return 0; fi
  if grep -qF "$2" "$1" 2>/dev/null; then
    echo "   $(basename "$1") already sources $(basename "$2")"
  else
    printf '\n# ollama/aider env (added by install-model.sh)\n%s\n' "$3" >> "$1"
    echo "   appended to $1"
  fi
}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------- preflight ------
preflight() {
  say "preflight"
  command -v nvidia-smi >/dev/null \
    && nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap \
                  --format=csv,noheader | sed 's/^/   /' \
    || warn "no nvidia-smi - ollama will fall back to CPU (unusably slow here)"
  echo "   glibc   $(ldd --version | head -1 | awk '{print $NF}')"
  echo "   store   $OLLAMA_MODELS"
  local avail; avail="$(df -BG --output=avail "$HERE" 2>/dev/null | tail -1 | tr -dc '0-9')" || avail=""
  local need=0
  local sz
  for f in "$HERE"/gguf/*/*.gguf; do
    [ -f "$f" ] || continue
    sz="$(du -BG "$f" 2>/dev/null | cut -f1 | tr -dc '0-9')" || sz=""
    need=$(( need + ${sz:-0} ))
  done
  echo "   weights ${need}G to import, ${avail:-?}G free on this filesystem"
  # `ollama create` copies the GGUF into the blob store rather than linking it.
  [ -n "$avail" ] && [ "$need" -gt 0 ] && [ "$avail" -lt "$need" ] \
    && warn "not enough space: the import COPIES each GGUF into the store"
  true
}

# -------------------------------------------------------------- ollama ------
# bin/ollama is the FIRST entry in the archive and lib/ollama/llama-quantize
# is among the LAST, after ~685MB of CUDA libraries. A truncated transfer or a
# full disk therefore leaves a server that starts fine and an import path that
# fails much later with "llama-quantize unavailable binary not found".
ollama_tree_ok() { # ollama_tree_ok [quiet]
  local f rc=0
  for f in bin/ollama lib/ollama/llama-quantize lib/ollama/libllama-quantize-impl.so \
           lib/ollama/libllama-common.so.0; do
    if [ ! -e "$PREFIX/$f" ]; then
      [ "${1:-}" = quiet ] || warn "missing from the ollama install: $f"
      rc=1
    fi
  done
  return $rc
}

install_ollama() {
  say "ollama"
  local tgz="$HERE/ollama-linux-amd64.tar.gz" zst="$HERE/ollama-linux-amd64.tar.zst"

  # Validate the whole gzip stream before trusting it. This is the cheap,
  # decisive test for the truncation described above.
  if [ -s "$tgz" ]; then
    if ! gzip -t "$tgz" 2>/dev/null; then
      die "archive is truncated or corrupt: $tgz
   On the fetch host:
     rm -f airgap/model/ollama-linux-amd64.tar.gz && ./bastion-fetch.sh model
   then re-sync it here."
    fi
    echo "   archive integrity OK ($(du -h "$tgz" | cut -f1))"
  fi

  if ollama_tree_ok quiet; then
    echo "   already installed: $("$OLLAMA" --version 2>&1 | tail -1)"
    return 0
  fi

  echo "   extracting into $PREFIX"
  mkdir -p "$PREFIX"
  if [ -s "$tgz" ]; then
    tar -C "$PREFIX" -xzf "$tgz" || die "extraction failed (disk full?)"
  elif [ -s "$zst" ]; then
    command -v zstd >/dev/null \
      || die "only .tar.zst present and no zstd here (RHEL 8 tar 1.30 cannot read it).
   Re-run the fetch on a host with zstd, or install the zstd RPM."
    zstd -dc "$zst" | tar -C "$PREFIX" -x || die "extraction failed (disk full?)"
  else
    die "no ollama archive in $HERE"
  fi
  # tar preserves modes, but a hand-copied tree may not.
  chmod +x "$PREFIX"/bin/ollama "$PREFIX"/lib/ollama/llama-* 2>/dev/null || true

  ollama_tree_ok || die "ollama install still incomplete after extraction (see above).
   Check free space on $PREFIX and re-run."
  echo "   installed: $("$OLLAMA" --version 2>&1 | tail -1)"
}

write_env() {
  say "env"
  cat > "$PREFIX/ollama-env.sh" <<ENV
# source this from ~/.bashrc (after opt/env.sh)
export PATH="$PREFIX/bin:\$PATH"
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="$OLLAMA_HOST"
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_KEEP_ALIVE=30m
# aider talks to ollama over this; it is NOT the same var as OLLAMA_HOST.
export OLLAMA_API_BASE="http://$OLLAMA_HOST"
export TIKTOKEN_CACHE_DIR="$PREFIX/tiktoken-cache"
export LITELLM_LOCAL_MODEL_COST_MAP=True
ENV
  # Seed tiktoken's cache so aider can count tokens without reaching the
  # network, and force litellm to use its bundled model-cost map instead of
  # fetching one (it otherwise retries in a background thread before falling
  # back, so this costs startup time too).
  if [ -d "$HERE/tiktoken-cache" ]; then
    rm -rf "$PREFIX/tiktoken-cache"
    cp -R "$HERE/tiktoken-cache" "$PREFIX/tiktoken-cache"
    echo "   tiktoken cache -> $PREFIX/tiktoken-cache ($(ls "$PREFIX/tiktoken-cache" | wc -l | tr -d ' ') encodings)"
  else
    warn "no tiktoken-cache/ in the bundle: aider will try to download BPE vocab"
    warn "  re-run './bastion-fetch.sh model' on the fetch host"
  fi
  cat > "$PREFIX/ollama-env.csh" <<ENV
# source this from ~/.cshrc (after env.csh)
setenv PATH "$PREFIX/bin:\${PATH}"
setenv OLLAMA_MODELS "$OLLAMA_MODELS"
setenv OLLAMA_HOST "$OLLAMA_HOST"
setenv OLLAMA_FLASH_ATTENTION 1
setenv OLLAMA_KV_CACHE_TYPE q8_0
setenv OLLAMA_KEEP_ALIVE 30m
setenv OLLAMA_API_BASE "http://$OLLAMA_HOST"
setenv TIKTOKEN_CACHE_DIR "$PREFIX/tiktoken-cache"
setenv LITELLM_LOCAL_MODEL_COST_MAP True
ENV
  echo "   wrote $PREFIX/ollama-env.sh and $PREFIX/ollama-env.csh"
  if [ "${NO_SHELL_RC:-0}" != 1 ]; then
    add_rc "$HOME/.cshrc"  "$PREFIX/ollama-env.csh" \
           "if (-f $PREFIX/ollama-env.csh) source $PREFIX/ollama-env.csh"
    add_rc "$HOME/.bashrc" "$PREFIX/ollama-env.sh" \
           "[ -f $PREFIX/ollama-env.sh ] && . $PREFIX/ollama-env.sh"
  fi

  # Optional user-level unit, for when you'd rather not babysit nohup.
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/ollama.service" <<UNIT
[Unit]
Description=ollama (local model server)
After=network.target

[Service]
ExecStart=$PREFIX/bin/ollama serve
Environment=OLLAMA_MODELS=$OLLAMA_MODELS
Environment=OLLAMA_HOST=$OLLAMA_HOST
Environment=OLLAMA_FLASH_ATTENTION=1
Environment=OLLAMA_KV_CACHE_TYPE=q8_0
Environment=OLLAMA_KEEP_ALIVE=30m
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
  echo "   wrote ~/.config/systemd/user/ollama.service"
  echo "   (to use it: loginctl enable-linger \$USER && systemctl --user enable --now ollama)"
}

# --------------------------------------------------------------- serve ------
serve() {
  say "serve"
  if curl -sf --max-time 3 "http://$OLLAMA_HOST/api/version" >/dev/null 2>&1; then
    echo "   already up: $(curl -s "http://$OLLAMA_HOST/api/version")"; return 0
  fi
  mkdir -p "$OLLAMA_MODELS"
  nohup "$OLLAMA" serve >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  local i
  for i in $(seq 1 40); do
    if curl -sf --max-time 2 "http://$OLLAMA_HOST/api/version" >/dev/null 2>&1; then
      echo "   up after ${i}s: $(curl -s "http://$OLLAMA_HOST/api/version")"
      # Confirm it found the GPU rather than silently going CPU-only.
      grep -iE 'inference compute|library=cuda|no compatible GPUs' "$LOG" | tail -2 | sed 's/^/   /'
      return 0
    fi
    sleep 1
  done
  tail -20 "$LOG"; die "server did not come up (log: $LOG)"
}

stop() {
  say "stop"
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && echo "   stopped" || echo "   not running"
  rm -f "$PIDFILE"
}

# -------------------------------------------------------------- models ------
import_models() {
  say "models"
  shopt -s nullglob
  # A blob store rsync'd from a host that ran `ollama pull' is already in its
  # final form: nothing to import, no llama-quantize, no second copy.
  local existing
  existing="$("$OLLAMA" list 2>/dev/null | tail -n +2 | grep -c . || true)"
  if [ "${existing:-0}" -gt 0 ]; then
    echo "   $existing model(s) already in the store - no import needed"
    "$OLLAMA" list 2>/dev/null | sed 's/^/   /'
  fi
  # Refuse the import up front rather than letting ollama fail deep inside it.
  if [ -d "$HERE/modelfiles" ] && [ ! -x "$PREFIX/lib/ollama/llama-quantize" ]; then
    warn "GGUF import needs $PREFIX/lib/ollama/llama-quantize, which is absent."
    warn "  Either re-extract a complete ollama archive (install-model.sh ollama),"
    warn "  or skip the import entirely by pulling upstream on the fetch host:"
    warn "      ./bastion-fetch.sh model"
    warn "      rsync -aP airgap/model/ollama-models/ this-host:$OLLAMA_MODELS/"
    return 0
  fi
  local mf found=0
  for mf in "$HERE"/modelfiles/*.Modelfile; do
    found=1
    local name; name="$(basename "$mf" .Modelfile)"
    if "$OLLAMA" list 2>/dev/null | awk '{print $1}' | grep -qx "$name:latest"; then
      echo "   have $name"; continue
    fi
    # Rewrite FROM as an absolute path: ollama resolves a relative FROM against
    # the client's cwd, not the Modelfile's directory, so a relative path here
    # is a trap waiting for whoever runs this from somewhere else.
    local src abs tmp
    src="$(awk '/^[Ff][Rr][Oo][Mm][ \t]/ {print $2; exit}' "$mf")"
    case "$src" in
      /*) abs="$src" ;;
      *)  abs="$HERE/${src#./}" ;;
    esac
    [ -f "$abs" ] || { warn "$name: GGUF not found at $abs - skipping"; continue; }
    tmp="$(mktemp)"; sed "s|^[Ff][Rr][Oo][Mm][ \t].*|FROM $abs|" "$mf" > "$tmp"
    echo "   creating $name from $(basename "$abs") ($(du -h "$abs" | cut -f1))"
    "$OLLAMA" create "$name" -f "$tmp" || warn "create failed for $name"
    rm -f "$tmp"
  done
  if [ "$found" = 1 ]; then
    "$OLLAMA" list 2>/dev/null | sed 's/^/   /'
    echo
    echo "   NOTE: the import copied each GGUF into $OLLAMA_MODELS."
    echo "   Once 'ollama run' works, delete $HERE/gguf to reclaim that space."
  elif [ "${existing:-0}" -eq 0 ]; then
    warn "no models in the store and no modelfiles/ to import."
    warn "  on the bastion:  ./bastion-fetch.sh model   (pulls upstream)"
    warn "  then:            rsync -aP airgap/model/ollama-models/ this-host:$OLLAMA_MODELS/"
  fi
}

# --------------------------------------------------------------- aider ------
install_aider() {
  say "aider"
  local venv="$PREFIX/venv-aider"
  [ -d "$HERE/wheels-aider" ] || { warn "no wheels-aider/ - skipping"; return 0; }
  command -v python3.11 >/dev/null || die "no python3.11"
  [ -d "$venv" ] || python3.11 -m venv "$venv" \
    || die "venv failed (python3.11 may lack ensurepip)"
  # Install the WHEEL FILE, not the bare name: that pins the version, so pip
  # cannot walk backwards through 0.86.1, 0.86.0 ... when one dependency is
  # missing and then report it as a version conflict.
  local whl
  whl="$(ls "$HERE"/wheels-aider/aider_chat-*.whl 2>/dev/null | sort -V | tail -1)"
  if [ -z "$whl" ]; then
    warn "no aider wheel in $HERE/wheels-aider - re-run './bastion-fetch.sh model'"
    return 0
  fi
  echo "   installing $(basename "$whl")"
  "$venv/bin/pip" install -q --no-index --find-links "$HERE/wheels-aider" "$whl" \
    || { warn "aider install failed. The wheelhouse is probably incomplete:
     on the fetch host, rm -rf airgap/model/wheels-aider and re-run
     ./bastion-fetch.sh model  (it now clears the dir itself)"; return 0; }
  ln -sfn "$venv/bin/aider" "$PREFIX/bin/aider"
  echo "   $("$PREFIX/bin/aider" --version 2>/dev/null || echo installed)"

  # Name the model as ollama actually reports it (e.g. "qwen3-coder:30b"),
  # which is what aider needs after the ollama_chat/ prefix. A Modelfile
  # basename only matches on the GGUF-import path.
  local default
  default="$("$OLLAMA" list 2>/dev/null | awk 'NR==2{print $1}')"
  if [ -z "$default" ]; then
    default="$(basename "$(ls "$HERE"/modelfiles/*.Modelfile 2>/dev/null | head -1)" .Modelfile 2>/dev/null || true)"
  fi
  [ -n "$default" ] || { warn "no model loaded yet - skipping aider config"; return 0; }
  echo "   default model: $default"

  # num_ctx has to be asserted on the aider side too. The Modelfile sets it for
  # the stored model, but litellm sends its own default per request, and the
  # smaller of the two wins -- which is how you end up silently running at 2k
  # context with a 32k model.
  if [ ! -f "$HOME/.aider.model.settings.yml" ]; then
    cat > "$HOME/.aider.model.settings.yml" <<YML
- name: ollama_chat/$default
  edit_format: diff
  use_repo_map: true
  extra_params:
    num_ctx: 32768
YML
    echo "   wrote ~/.aider.model.settings.yml"
  else
    echo "   kept existing ~/.aider.model.settings.yml"
  fi

  if [ ! -f "$HOME/.aider.conf.yml" ]; then
    cat > "$HOME/.aider.conf.yml" <<YML
model: ollama_chat/$default
# Air-gapped: both of these otherwise block on network calls at startup.
check-update: false
analytics-disable: true
YML
    echo "   wrote ~/.aider.conf.yml"
  else
    echo "   kept existing ~/.aider.conf.yml"
  fi
}

# -------------------------------------------------------------- verify ------
verify() {
  say "verify"
  local name; name="$("$OLLAMA" list 2>/dev/null | awk 'NR==2{print $1}')"
  [ -n "$name" ] || { warn "no models imported"; return 0; }
  echo "   generating with $name ..."
  local t0 t1
  t0=$(date +%s)
  curl -sf "http://$OLLAMA_HOST/api/generate" -d "{
      \"model\": \"$name\",
      \"prompt\": \"Write a Go function that reverses a string. Code only.\",
      \"stream\": false,
      \"options\": {\"num_predict\": 128}
    }" | python3 -c "
import json,sys
r = json.load(sys.stdin)
print('   --- response ---')
print('\n'.join('   '+l for l in r.get('response','').strip().splitlines()[:12]))
ec, ed = r.get('eval_count',0), r.get('eval_duration',1)
print('   --- %d tokens, %.1f tok/s ---' % (ec, ec/(ed/1e9)))" \
    || warn "generate failed - check $LOG"
  t1=$(date +%s); echo "   wall: $((t1-t0))s"
  echo
  # Residency and split: anything less than 100% GPU means layers spilled to
  # CPU, which costs far more than the VRAM it saved.
  "$OLLAMA" ps 2>/dev/null | sed 's/^/   /'
  command -v nvidia-smi >/dev/null && \
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | sed 's/^/   VRAM /'
  echo
  echo "   next:  source $PREFIX/ollama-env.csh   (tcsh)"
  echo "          cd <your repo> && aider"
}

case "${1:-all}" in
  all)     preflight; install_ollama; write_env; serve; import_models; install_aider; verify ;;
  ollama)  install_ollama; write_env; serve ;;
  models)  serve; import_models ;;
  aider)   install_aider ;;
  serve)   serve ;;
  stop)    stop ;;
  verify)  verify ;;
  *) echo "usage: $0 [all|ollama|models|aider|serve|stop|verify]" >&2; exit 2 ;;
esac
