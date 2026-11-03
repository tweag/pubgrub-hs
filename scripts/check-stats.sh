#!/usr/bin/env bash
#
# Check that the counters `pubgrub --stats` keeps in-process agree, number for
# number, with the ones bench/summarise.awk derives by counting a `-v` trace
# (docs/benchmarking.md, "Quiet and counted"). The awk can be retired only once
# they do.
#
#   scripts/check-stats.sh                # every problem in both sets
#   OUT=/tmp/stats scripts/check-stats.sh # keep the per-problem outputs
#
# One line per problem, non-zero exit on any mismatch. Compared: deciding, chose,
# conflicts, learned, resolving, backtracked, noversion, and the resolution-depth
# histogram (the awk prints it as `K×C`, the driver as `K:C`; both are
# normalised to `K:C` here). The read counters are not compared: `--stats` does
# not print them, the provider's own closing line does, and that line is the
# same under both runs.
#
# It lives here and not in the tasty suite because it needs the index.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

OUT=${OUT:-$(mktemp -d)}
TIMEOUT=${TIMEOUT:-300}
mkdir -p "$OUT"

EXE=${EXE:-$(cabal list-bin exe:pubgrub 2>/dev/null)}
# Every run is pinned to the index-state in bench/index-state, so the numbers
# below stop moving with the weekly refresh. PUBGRUB_INDEX_STATE=<timestamp>
# overrides it; PUBGRUB_INDEX_STATE=head runs against everything the local index
# holds. Move the file's value in the change that re-measures.
PINNED=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' bench/index-state 2>/dev/null | grep -v '^$' | head -1)
PUBGRUB_INDEX_STATE=${PUBGRUB_INDEX_STATE:-$PINNED}
INDEX_STATE=()
if [ -n "$PUBGRUB_INDEX_STATE" ] && [ "$PUBGRUB_INDEX_STATE" != head ]; then
    INDEX_STATE=(--index-state "$PUBGRUB_INDEX_STATE")
fi
if [ -z "${EXE:-}" ] || [ ! -x "$EXE" ]; then
    echo "cannot locate the pubgrub executable; run 'cabal build' first" >&2
    exit 1
fi

# The problem set, exactly as scripts/gate.sh reads it: everything not a comment
# and not blank. A problem is a comma-separated list of targets, and `targets_of`
# splits it into one argument per target — the driver takes each target whole,
# because a range holds spaces.
problems_in() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }

targets_of() {
    printf '%s\n' "$1" | tr ',' '\n' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

mapfile -t BENCH < <(problems_in bench/problems.txt)
mapfile -t CORPUS < <(problems_in bench/unsat-problems.txt)
ALL=("${BENCH[@]}" "${CORPUS[@]}")

# Warm the index once, outside the comparison: the first run of the day may
# bootstrap or refresh it.
"$EXE" "${INDEX_STATE[@]}" vector >/dev/null 2>&1 || true

# `grep -a` everywhere below is a precaution: GNU grep treats output with a NUL
# byte as binary and silently reports no match.
FIELDS=(deciding chose conflicts learned resolving backtracked noversion)

# The awk's two lines, reduced to one `key=value` per line in FIELDS order plus
# `depth=K:C,...`. $1 = the awk's output file.
from_awk() {
    local f
    for f in "${FIELDS[@]}"; do
        grep -a -oE "(^| )$f=[0-9]+" "$1" | tr -d ' '
    done
    # "depth histogram: 0×40 1×9" -> "depth=0:40,1:9"
    grep -a '^depth histogram:' "$1" |
        sed -e 's/^depth histogram://' -e 's/×/:/g' |
        tr -s ' ' '\n' | grep -v '^$' | paste -sd, - | sed 's/^/depth=/'
}

# The driver's `stats:` line, in the same shape. $1 = the driver's output file.
from_stats() {
    local line f
    line=$(grep -a '^stats: ' "$1" | sed 's/^stats: //')
    for f in "${FIELDS[@]}"; do
        printf '%s\n' "$line" | tr ' ' '\n' | grep -a "^$f="
    done
    printf '%s\n' "$line" | tr ' ' '\n' | grep -a '^depth='
}

failed=0
for problem in "${ALL[@]}"; do
    base=$(printf '%s' "$problem" | tr -c 'A-Za-z0-9' '-')
    mapfile -t targets < <(targets_of "$problem")
    timeout "$TIMEOUT" "$EXE" "${INDEX_STATE[@]}" --stats "${targets[@]}" >"$OUT/$base.stats.log" 2>&1
    timeout "$TIMEOUT" "$EXE" "${INDEX_STATE[@]}" -v "${targets[@]}" 2>&1 | awk -f bench/summarise.awk >"$OUT/$base.awk.log"

    from_stats "$OUT/$base.stats.log" >"$OUT/$base.stats.norm"
    from_awk "$OUT/$base.awk.log" >"$OUT/$base.awk.norm"

    if [ ! -s "$OUT/$base.stats.norm" ]; then
        printf '  %-34s FAIL no stats: line (see %s)\n' "$problem" "$OUT/$base.stats.log"
        failed=1
    elif cmp -s "$OUT/$base.stats.norm" "$OUT/$base.awk.norm"; then
        printf '  %-34s ok   %s\n' "$problem" "$(paste -sd' ' "$OUT/$base.stats.norm")"
    else
        printf '  %-34s FAIL\n' "$problem"
        diff "$OUT/$base.awk.norm" "$OUT/$base.stats.norm" | sed 's/^/        /'
        failed=1
    fi
done

if [ $failed -ne 0 ]; then
    echo "STATS MISMATCH (outputs in $OUT)"
    exit 1
fi
echo "stats agree with bench/summarise.awk on all ${#ALL[@]} problems (outputs in $OUT)"
