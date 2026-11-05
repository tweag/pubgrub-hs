#!/bin/sh
# Fail if a package's Haddocks build with a warning, or leave anything the
# package exports undocumented: Haddock's own report, read after it builds.
# POSIX sh, because CI runs it on a runner without zsh.
#
# usage: scripts/check-haddock.sh PACKAGE...
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: $0 PACKAGE..." >&2
  exit 2
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# Haddock finds no page for the names GHC generates for a Generic instance (Rep_*)
# and an associated type instance (D:R:*). Nothing in the source could give them
# one, so those warnings say nothing about the documentation.
generated=$(for name in \
  PubGrub.Cabal.D:R:SetOfVar \
  PubGrub.Cabal.D:R:ValueOfVar \
  PubGrub.Cabal.D:R:FactOfVar \
  PubGrub.Cabal.Flatten.Rep_Branch \
  PubGrub.Cabal.Flatten.Rep_LibNode \
  PubGrub.Cabal.Flatten.Rep_Node \
  PubGrub.Cabal.Flatten.Rep_StoredRelease \
  PubGrub.Cabal.Flatten.Rep_Tree; do
  printf -- '--ignore-link-symbol=%s ' "$name"
done)

status=0
for pkg in "$@"; do
  if ! cabal haddock "$pkg" --haddock-options="$generated" >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  report=$(sed -n '/^Haddock coverage:/,$p' "$log")
  if [ -z "$report" ]; then
    echo "$pkg: Haddock printed no coverage report" >&2
    status=1
    continue
  fi
  # A warning, a link with no destination, or a module below 100%.
  problems=$(printf '%s\n' "$report" \
    | grep -E 'Warning|could not find link|^ *[0-9]+% ' \
    | grep -vE '^ *100% ' || true)
  if [ -n "$problems" ]; then
    echo "$pkg: Haddock is not clean" >&2
    printf '%s\n' "$report" >&2
    status=1
  else
    echo "$pkg: no Haddock warnings, every export documented"
  fi
done
exit "$status"
