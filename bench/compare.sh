#!/usr/bin/env bash
#
# Run every problem in bench/problems.txt through both solvers and print a table:
# verdict, elapsed, peak RSS, GC max residency, total allocation, and (for ours) the
# trace-derived counts.
#
#   bench/compare.sh                     # the whole set, both solvers
#   bench/compare.sh aeson '<2'          # one problem, both solvers
#   OUT=/tmp/bench bench/compare.sh      # keep the logs somewhere you choose
#
# Read docs/benchmarking.md before believing any single number: elapsed time on a
# desktop moves by ±25% run to run, so allocation is the metric to compare, and the
# first run after an index update pays for the update.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

EXE=${EXE:-$(cabal list-bin pubgrub)} || {
    echo "cannot locate the pubgrub executable; run 'cabal build' first" >&2
    exit 1
}
OUT=${OUT:-$(mktemp -d)}
TIMEOUT=${TIMEOUT:-300}
mkdir -p "$OUT"
echo "logs in $OUT"

# Warm the index once, outside the measurement: the first run of the day may
# bootstrap or refresh the index and rebuild the version cache.
"$EXE" vector >/dev/null 2>&1 || true

# One solve. $1 = ours|cabal, $2 = log basename, rest = the pubgrub arguments.
#
# The solver trace is ON here (-v) because the counts come from it. That makes these
# elapsed times an upper bound: rendering thousands of lines is not free. Time
# without -v when timing is the point.
measure() {
    local tag=$1 base=$2
    shift 2
    local flags=(-v)
    [ "$tag" = cabal ] && flags=(-v --cabal)

    /usr/bin/time -f "%e s rss=%M KB" -o "$OUT/$base.$tag.time" \
        timeout "$TIMEOUT" "$EXE" "${flags[@]}" "$@" +RTS -s \
        >"$OUT/$base.$tag.log" 2>"$OUT/$base.$tag.rts"
    local code=$?

    local verdict=sat
    if [ $code -eq 124 ]; then
        verdict=TIMEOUT
    elif grep -aqE 'version solving failed|^Because|no plan' "$OUT/$base.$tag.log"; then
        verdict=UNSAT
    elif [ $code -ne 0 ]; then
        verdict="exit $code"
    fi

    local alloc res
    alloc=$(grep -a -oE '[0-9,]+ bytes allocated' "$OUT/$base.$tag.rts" | head -1 | cut -d' ' -f1)
    res=$(grep -a -oE '[0-9,]+ bytes maximum residency' "$OUT/$base.$tag.rts" | head -1 | cut -d' ' -f1)

    printf '  %-6s %-8s %-22s res=%-14s alloc=%-16s' \
        "$tag" "$verdict" "$(cat "$OUT/$base.$tag.time")" "${res:-?}" "${alloc:-?}"
    if [ "$tag" = ours ]; then
        awk -f bench/summarise.awk "$OUT/$base.$tag.log" | head -1
    else
        # cabal's own log is a search trace, not our events, so its length is the
        # only comparable number.
        printf 'cabal-log-lines=%s\n' "$(wc -l <"$OUT/$base.$tag.log")"
    fi
}

run_problem() {
    local base
    base=$(echo "$*" | tr -c 'A-Za-z0-9' '-')
    echo "== $* =="
    measure ours "$base" "$@"
    measure cabal "$base" "$@"
}

if [ $# -gt 0 ]; then
    run_problem "$@"
else
    # Strip comments and blanks; everything left on a line is one problem.
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' bench/problems.txt |
        grep -v '^$' |
        while read -r problem; do
            # shellcheck disable=SC2086 # deliberate: the range is a separate argument
            run_problem $problem
        done
fi
