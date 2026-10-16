#!/usr/bin/env bash
# Runs ON THE AIR-GAPPED TARGET, inside the unpacked emacs bundle.
#
#   tar -xzf emacs-bundle.tar.gz && cd emacs && ./install-target.sh
#
# Builds Emacs 30.x + libtree-sitter from source and drops in the prebuilt
# language servers. Touches nothing outside $PREFIX and ~/.emacs.d.
# No root, no dnf, no RPMs.
#
# Versions are discovered from the filenames in the bundle rather than pinned
# here: the bastion script owns the pins, and duplicating them would mean a
# bumped pin there silently breaks this script after the transfer.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/opt}"              # /data1/opt if you'd rather
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${BUILD:-$HERE/.build}"
TSDIR="$HOME/.emacs.d/tree-sitter"

# Emacs ends a failed build with a generic "make all failed" advice block, so
# `tail' shows the epilogue and not the cause -- and under -j the real error is
# interleaved far above. Pull out the compiler errors directly.
build_err() { # build_err <log>
  echo
  echo "--- first errors in $(basename "$1") ---"
  grep -nE "error:|undefined reference|No such file or directory|cannot find -l|command not found" "$1" \
    | grep -vE "advice-on-failure" | head -20 || echo "(no 'error:' lines - see tail below)"
  echo "--- last 15 lines ---"
  tail -15 "$1"
  echo
  echo "For a clean, serialized error (no -j interleaving):"
  echo "    JOBS=1 $0 emacs"
}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# Exactly one match, or a clear error naming what was missing.
one() { # one <glob...>
  local m=(); m=( "$@" )
  [ "${#m[@]}" -ge 1 ] && [ -e "${m[0]}" ] || { echo ""; return 1; }
  printf '%s\n' "${m[0]}"
}

mkdir -p "$PREFIX/bin" "$BUILD" "$TSDIR"

# ------------------------------------------------------------ preflight -----
preflight() {
  say "preflight"
  command -v gcc  >/dev/null || die "no gcc"
  command -v make >/dev/null || die "no make"
  echo "   gcc    $(gcc -dumpversion)"
  echo "   glibc  $(ldd --version | head -1 | awk '{print $NF}')"
  echo "   jobs   $JOBS"
  echo "   prefix $PREFIX"
  # ncurses headers are the ONLY hard build dep for a terminal-only Emacs 30:
  # 30 dropped libjansson, and GMP falls back to the bundled mini-gmp.
  printf '#include <curses.h>\nint main(void){return 0;}\n' > "$BUILD/.nc.c"
  gcc "$BUILD/.nc.c" -o "$BUILD/.nc.out" -lncurses 2>/dev/null \
    && echo "   ncurses headers OK" \
    || die "ncurses-devel headers not usable - Emacs will not configure"
  rm -f "$BUILD/.nc.c" "$BUILD/.nc.out"
}

# --------------------------------------------------------- libtree-sitter ---
build_tree_sitter() {
  say "libtree-sitter"
  if [ -f "$PREFIX/lib/libtree-sitter.so" ]; then echo "   already installed"; return 0; fi
  local tgz; tgz="$(one "$HERE"/libtree-sitter-*.tar.gz)" || die "no libtree-sitter-*.tar.gz in bundle"
  tar -C "$BUILD" -xzf "$tgz"
  local src; src="$(one "$BUILD"/tree-sitter-*/)" || die "tree-sitter source dir not found"
  echo "   building $(basename "$src")"
  # Its Makefile honors PREFIX and installs lib + headers + a .pc file.
  make -C "$src" -j"$JOBS" PREFIX="$PREFIX" >"$BUILD/ts-make.log" 2>&1 \
    || { build_err "$BUILD/ts-make.log"; die "libtree-sitter build failed"; }
  make -C "$src" install PREFIX="$PREFIX" >>"$BUILD/ts-make.log" 2>&1
  echo "   installed -> $PREFIX/lib"
}

# ----------------------------------------------------------------- emacs ----
build_emacs() {
  say "emacs"
  if [ -x "$PREFIX/bin/emacs" ]; then
    echo "   already built: $("$PREFIX/bin/emacs" --version | head -1)"; return 0
  fi
  local tgz; tgz="$(one "$HERE"/emacs-*.tar.gz)" || die "no emacs-*.tar.gz in bundle"
  local dir; dir="$(one "$BUILD"/emacs-*/)" || { tar -C "$BUILD" -xzf "$tgz"; dir="$(one "$BUILD"/emacs-*/)"; }
  cd "$dir"
  # TREE_SITTER_* are passed explicitly instead of via pkg-config: autoconf
  # treats them as precious override vars, so this works even where
  # pkg-config is absent or cannot see our private prefix.
  # The rpath is what lets the installed binary find libtree-sitter.so.0
  # with no LD_LIBRARY_PATH and no root access to ld.so.conf.
  ./configure \
    --prefix="$PREFIX" \
    --without-x --without-ns --with-tree-sitter \
    --with-gnutls=ifavailable \
    --without-dbus --without-selinux --without-gpm --without-sqlite3 \
    --without-xml2 --without-sound --without-libsystemd --disable-acl \
    TREE_SITTER_CFLAGS="-I$PREFIX/include" \
    TREE_SITTER_LIBS="-L$PREFIX/lib -ltree-sitter" \
    LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
    >"$BUILD/emacs-configure.log" 2>&1 \
    || { build_err "$BUILD/emacs-configure.log"; die "configure failed"; }
  grep -iE 'tree-sitter' "$BUILD/emacs-configure.log" | tail -2 | sed 's/^/   /' || true
  echo "   compiling with -j$JOBS (a few minutes)"
  make -j"$JOBS" >"$BUILD/emacs-make.log" 2>&1 \
    || { build_err "$BUILD/emacs-make.log"; die "build failed (log: $BUILD/emacs-make.log)"; }
  make install >/dev/null
  cd "$HERE"
  echo "   $("$PREFIX/bin/emacs" --version | head -1)"
}

# -------------------------------------------------------------- grammars ----
build_grammars() {
  say "tree-sitter grammars"
  [ -x "$HERE/build-grammars.sh" ] || die "build-grammars.sh missing from bundle"
  "$HERE/build-grammars.sh" "$HERE/grammars" "$TSDIR"
}

# ----------------------------------------------------------------- tools ----
install_tools() {
  say "go toolchain"
  local gotgz; gotgz="$(one "$HERE"/go*.linux-amd64.tar.gz)" || warn "no go tarball in bundle"
  if [ -x "$PREFIX/go/bin/go" ]; then echo "   already installed: $("$PREFIX/go/bin/go" version)"
  elif [ -n "${gotgz:-}" ]; then
    tar -C "$PREFIX" -xzf "$gotgz"; echo "   $("$PREFIX/go/bin/go" version)"
  fi

  say "gopls + dlv"
  for b in gopls dlv; do
    if [ -f "$HERE/bin/$b" ]; then install -m755 "$HERE/bin/$b" "$PREFIX/bin/$b"; echo "   $b"
    else warn "$b missing from bundle"; fi
  done

  say "clangd"
  local ctgz; ctgz="$(one "$HERE"/clangd-*.tar.gz)" || warn "no clangd archive in bundle"
  if [ -n "${ctgz:-}" ]; then
    local cdir="$PREFIX/clangd"
    if [ -x "$PREFIX/bin/clangd" ] && "$PREFIX/bin/clangd" --version >/dev/null 2>&1; then
      echo "   already installed: $("$PREFIX/bin/clangd" --version 2>&1 | head -1)"
    else
      rm -rf "$cdir"; mkdir -p "$cdir"; tar -C "$cdir" -xzf "$ctgz"
      # clangd finds its builtin headers relative to its own path, so the
      # bin/ + lib/ tree must stay together: symlink, never copy the binary out.
      local real; real="$(find "$cdir" -type f -name clangd -perm -u+x | head -1)"
      [ -n "$real" ] || die "clangd binary not found inside $ctgz"
      ln -sfn "$real" "$PREFIX/bin/clangd"
      echo "   $("$PREFIX/bin/clangd" --version 2>&1 | head -1)"
    fi
  fi

  say "shellcheck"
  local stgz; stgz="$(one "$HERE"/shellcheck-*.tar.gz)" || warn "no shellcheck archive in bundle"
  if [ -n "${stgz:-}" ]; then
    tar -C "$BUILD" -xzf "$stgz"
    local sb; sb="$(find "$BUILD" -type f -name shellcheck -perm -u+x | head -1)"
    [ -n "$sb" ] && install -m755 "$sb" "$PREFIX/bin/shellcheck" \
      && echo "   $("$PREFIX/bin/shellcheck" --version | awk '/version:/{print $2}')"
  fi

  say "python language server"
  if [ -d "$HERE/wheels-lsp" ] && command -v python3.11 >/dev/null; then
    [ -d "$PREFIX/venv-lsp" ] || python3.11 -m venv "$PREFIX/venv-lsp" \
      || warn "venv creation failed (python3.11 may lack ensurepip)"
    if [ -x "$PREFIX/venv-lsp/bin/pip" ]; then
      "$PREFIX/venv-lsp/bin/pip" install -q --no-index \
        --find-links "$HERE/wheels-lsp" python-lsp-server ruff \
        && for b in pylsp ruff; do
             [ -x "$PREFIX/venv-lsp/bin/$b" ] && ln -sfn "$PREFIX/venv-lsp/bin/$b" "$PREFIX/bin/$b"
           done \
        && echo "   pylsp + ruff linked into $PREFIX/bin" \
        || warn "python LSP install failed"
    fi
  else warn "skipping python LSP (no wheels-lsp/ or no python3.11)"; fi

  # Deploy the editor config if it rode along.
  if [ -d "$HERE/dotfiles" ] && [ -x "$HERE/dotfiles/install.sh" ]; then
    say "dotfiles"; ( cd "$HERE/dotfiles" && ./install.sh ) | sed 's/^/   /'
  fi
}

# ------------------------------------------------------------------ env -----
write_env() {
  say "env"
  cat > "$PREFIX/env.sh" <<ENV
# source this from ~/.bashrc
# $PREFIX/bin must precede /usr/bin so 'emacs' is the one we built, not 26.1.
export PATH="$PREFIX/bin:$PREFIX/go/bin:\$HOME/go/bin:\$PATH"
# Air-gapped Go: there is no proxy to reach, so fail fast instead of hanging.
# 'go build' then sees only a warm GOMODCACHE or a vendored tree.
export GOPROXY=off
ENV
  echo "   wrote $PREFIX/env.sh"
  grep -q "$PREFIX/env.sh" "$HOME/.bashrc" 2>/dev/null \
    && echo "   already sourced from ~/.bashrc" \
    || echo "   add to ~/.bashrc:   . $PREFIX/env.sh"
}

# ----------------------------------------------------------------- verify ---
verify() {
  say "verify"
  local E="$PREFIX/bin/emacs"
  [ -x "$E" ] || die "no emacs at $E"
  "$E" --batch --eval '(progn
    (princ (format "emacs             %s\n" emacs-version))
    (princ (format "treesit-available %s\n" (treesit-available-p)))
    (princ (format "grammar ABI       %s..%s\n"
                   (treesit-library-abi-version t) (treesit-library-abi-version)))
    (princ (format "eglot             %s\n" (if (locate-library "eglot") "yes" "NO")))
    (princ "grammars:\n")
    (dolist (l (list (quote go) (quote gomod) (quote c) (quote cpp) (quote python)
                     (quote bash) (quote yaml) (quote dockerfile) (quote cmake) (quote json)))
      (princ (format "  %-11s %s\n" l
             (if (car (treesit-language-available-p l t)) "OK" "MISSING")))))' \
    || warn "emacs self-check failed"
  echo "servers:"
  for b in gopls dlv clangd shellcheck pylsp ruff; do
    printf '  %-11s ' "$b"
    [ -x "$PREFIX/bin/$b" ] && echo OK || echo MISSING
  done
  echo
  echo "next:  . $PREFIX/env.sh && emacs"
}

case "${1:-all}" in
  all)      preflight; build_tree_sitter; build_emacs; build_grammars; install_tools; write_env; verify ;;
  emacs)    preflight; build_tree_sitter; build_emacs ;;
  grammars) build_grammars ;;
  tools)    install_tools; write_env ;;
  verify)   verify ;;
  *) echo "usage: $0 [all|emacs|grammars|tools|verify]" >&2; exit 2 ;;
esac
