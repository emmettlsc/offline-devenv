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
install_ollama() {
  say "ollama"
  if [ -x "$OLLAMA" ]; then
    echo "   already installed: $("$OLLAMA" --version 2>&1 | tail -1)"; return 0
  fi
  local tgz
  tgz="$(ls "$HERE"/ollama-linux-amd64.tar.gz 2>/dev/null || true)"
  if [ -z "$tgz" ]; then
    # Bastion had no zstd, so the raw upstream archive came across instead.
    local zst="$HERE/ollama-linux-amd64.tar.zst"
    [ -f "$zst" ] || die "no ollama archive in $HERE"
    command -v zstd >/dev/null \
      || die "only .tar.zst present and no zstd here (RHEL 8 tar 1.30 cannot read it).
   Re-run the bastion fetch on a host with zstd, or install the zstd RPM."
    say "decompressing .tar.zst"
    mkdir -p "$PREFIX"; zstd -dc "$zst" | tar -C "$PREFIX" -x
  else
    mkdir -p "$PREFIX"; tar -C "$PREFIX" -xzf "$tgz"
  fi
  [ -x "$OLLAMA" ] || die "ollama binary not where expected ($OLLAMA)"
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
ENV
  cat > "$PREFIX/ollama-env.csh" <<ENV
# source this from ~/.cshrc (after env.csh)
setenv PATH "$PREFIX/bin:\${PATH}"
setenv OLLAMA_MODELS "$OLLAMA_MODELS"
setenv OLLAMA_HOST "$OLLAMA_HOST"
setenv OLLAMA_FLASH_ATTENTION 1
setenv OLLAMA_KV_CACHE_TYPE q8_0
setenv OLLAMA_KEEP_ALIVE 30m
setenv OLLAMA_API_BASE "http://$OLLAMA_HOST"
ENV
  echo "   wrote $PREFIX/ollama-env.sh and $PREFIX/ollama-env.csh"

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
  say "import weights"
  shopt -s nullglob
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
  [ "$found" = 1 ] || warn "no modelfiles/ found - did the model bundle transfer?"
  "$OLLAMA" list 2>/dev/null | sed 's/^/   /'
  echo
  echo "   NOTE: the import copied each GGUF into $OLLAMA_MODELS."
  echo "   Once 'ollama run' works you can delete $HERE/gguf to reclaim that space."
}

# --------------------------------------------------------------- aider ------
install_aider() {
  say "aider"
  local venv="$PREFIX/venv-aider"
  [ -d "$HERE/wheels-aider" ] || { warn "no wheels-aider/ - skipping"; return 0; }
  command -v python3.11 >/dev/null || die "no python3.11"
  [ -d "$venv" ] || python3.11 -m venv "$venv" \
    || die "venv failed (python3.11 may lack ensurepip)"
  "$venv/bin/pip" install -q --no-index --find-links "$HERE/wheels-aider" aider-chat \
    || { warn "aider install failed - wheel set may be incomplete for this platform"; return 0; }
  ln -sfn "$venv/bin/aider" "$PREFIX/bin/aider"
  echo "   $("$PREFIX/bin/aider" --version 2>/dev/null || echo installed)"

  # Pick the first imported model as the default.
  local default; default="$(basename "$(ls "$HERE"/modelfiles/*.Modelfile 2>/dev/null | head -1)" .Modelfile 2>/dev/null || true)"
  [ -n "$default" ] || return 0

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
