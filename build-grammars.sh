#!/usr/bin/env bash
# Compile tree-sitter grammars from source tarballs. No git, no network, no
# tree-sitter CLI -- which is the whole point: `treesit-install-language-grammar'
# shells out to `git clone' and is therefore useless on an air-gapped box.
#
#   ./build-grammars.sh <dir-of-grammar-tarballs> [install-dir]
#
# Portable between the Mac (.dylib) and the RHEL target (.so) so the exact
# recipe can be validated here first.
set -euo pipefail

SRCDIR="${1:?usage: $0 <tarball-dir> [install-dir]}"
DEST="${2:-$HOME/.emacs.d/tree-sitter}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  Darwin) EXT=dylib; SOFLAG="-dynamiclib" ;;
  *)      EXT=so;    SOFLAG="-shared" ;;
esac

CC="${CC:-cc}"
CXX="${CXX:-c++}"
mkdir -p "$DEST"

# tree-sitter-yaml ships a C++ external scanner, so that one grammar needs a
# C++ compiler while the other nine do not. Say so up front instead of
# surfacing it as one mysterious failure at the end.
command -v "$CXX" >/dev/null 2>&1 \
  || echo "!! no '$CXX' on PATH: grammars with a C++ scanner (yaml) will fail" >&2

built=() failed=()
for tgz in "$SRCDIR"/*.tar.gz; do
  base="$(basename "$tgz")"
  lang="${base%%-*}"                      # "python-v0.23.6.tar.gz" -> "python"
  [ "$lang" = "tree" ] && continue        # skip the libtree-sitter tarball
  rm -rf "$WORK/x"; mkdir -p "$WORK/x"
  tar -C "$WORK/x" -xzf "$tgz"
  root="$(find "$WORK/x" -maxdepth 1 -mindepth 1 -type d | head -1)"

  # Most grammars put src/ at the repo root; multi-grammar repos nest it.
  src="$(find "$root" -type d -name src -path '*src' | grep -v node_modules | head -1)"
  if [ -z "$src" ] || [ ! -f "$src/parser.c" ]; then
    echo "!! $lang: no src/parser.c found"; failed+=("$lang"); continue
  fi

  objs=(); linker="$CC"
  "$CC" -O2 -fPIC -std=c11 -I "$src" -c "$src/parser.c" -o "$WORK/parser.o"
  objs+=("$WORK/parser.o")
  # External scanners are optional and may be C or C++. A .cc scanner forces
  # the whole link through the C++ driver so libstdc++ comes along.
  if [ -f "$src/scanner.c" ]; then
    "$CC" -O2 -fPIC -std=c11 -I "$src" -c "$src/scanner.c" -o "$WORK/scanner.o"
    objs+=("$WORK/scanner.o")
  elif [ -f "$src/scanner.cc" ]; then
    "$CXX" -O2 -fPIC -std=c++14 -I "$src" -c "$src/scanner.cc" -o "$WORK/scanner.o"
    objs+=("$WORK/scanner.o"); linker="$CXX"
  fi

  out="$DEST/libtree-sitter-$lang.$EXT"
  "$linker" $SOFLAG "${objs[@]}" -o "$out"
  echo "   built $(basename "$out")"
  built+=("$lang")
done

echo
echo "built:  ${built[*]:-none}"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
