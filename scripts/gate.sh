#!/usr/bin/env bash
#
# The single gate. Runs every check that must not regress, prints one summary
# line per gate, and exits non-zero if any of them fails.
#
#   scripts/gate.sh                  # everything
#   OUT=/tmp/gate scripts/gate.sh    # keep the per-problem logs
#
# The gates, in order:
#
#   problems   the union set still holds every problem it is meant to
#   corpus     every problem in bench/unsat-problems.txt still fails to resolve
#              under our solver (docs/failure-cases.md: all 20 reproduce here)
#   agreement  ours and cabal's solver return the SAME verdict, over the union of
#              bench/problems.txt and bench/unsat-problems.txt
#   vs-cabal   our proof is no longer than cabal's message on any corpus problem
#   proof      the corpus totals: proof sentences, and "no version for" lines
#   golden     the two published PubGrub examples still render their exact proofs
#   pkgconfig  the pkg-config / buildable: False modelling tests
#   unit       the whole test suite
#
# Baselines are the five numbers below. EXPECT_PROBLEMS is exact. The other four
# are floors or ceilings, not targets: a run that beats one prints IMPROVED and
# still exits 0, and the number here is then stale on purpose — move it in the
# same change that earned it.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# --- baselines --------------------------------------------------------------
# Measured on 2026-09-22 at the index-state in bench/index-state. See the
# header: floors and ceilings, not targets.
#
# The proof baselines are over the CORPUS only, so adding a problem to
# bench/problems.txt moves MIN_AGREEMENT and EXPECT_PROBLEMS and nothing else.
: "${MIN_AGREEMENT:=26}"    # problems where both solvers return the same verdict
: "${EXPECT_PROBLEMS:=26}"  # problems in the union set. A drop means a lost case
: "${EXPECT_CORPUS:=20}"    # reproducible failure cases
: "${MAX_PROOF:=76}"        # total proof sentences over the corpus (ceiling)
: "${MAX_NOVER:=0}"         # total "no version for" lines over the corpus (ceiling)

OUT=${OUT:-$(mktemp -d)}
TIMEOUT=${TIMEOUT:-300}
mkdir -p "$OUT"

EXE=${EXE:-$(cabal list-bin pubgrub 2>/dev/null)}
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

failed=0
summary=()

# Record one gate's outcome. $1 = name, $2 = ok|FAIL, rest = the detail shown.
gate() {
    local name=$1 status=$2
    shift 2
    summary+=("$(printf '%-10s %-6s %s' "$name" "$status" "$*")")
    [ "$status" = FAIL ] && failed=1
    return 0
}

# --- the problem set --------------------------------------------------------
# Everything not a comment and not blank. A problem is a comma-separated list of
# targets, each a package with an optional version range:
#
#     aeson <2                 one target
#     hlint, hadolint ==2.15.1 two targets, solved together
#
# `targets_of` splits a line back into one argument per target, because the driver
# takes each target as a WHOLE argument (a range holds spaces). Nothing here may
# rely on word-splitting.
problems_in() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }

targets_of() {
    printf '%s\n' "$1" | tr ',' '\n' |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

mapfile -t CORPUS < <(problems_in bench/unsat-problems.txt)
mapfile -t BENCH < <(problems_in bench/problems.txt)
ALL=("${BENCH[@]}" "${CORPUS[@]}")

# One solve. $1 = ours|cabal, $2 = log basename, rest = the pubgrub arguments.
# Echoes the verdict: sat, UNSAT, TIMEOUT or "exit N".
#
# The exit code says nothing — the driver returns 0 whether it found a plan or
# proved there is none — so the verdict comes from the text, exactly as
# `parseRun` in app/Harness.hs reads it. `grep -a` is a precaution: GNU grep
# treats output containing a NUL byte as binary and silently reports no match.
solve_one() {
    local tag=$1 base=$2
    shift 2
    local flags=("${INDEX_STATE[@]}")
    [ "$tag" = cabal ] && flags+=(--cabal)

    timeout "$TIMEOUT" "$EXE" "${flags[@]}" "$@" \
        >"$OUT/$base.$tag.log" 2>&1
    local code=$?

    if [ $code -eq 124 ]; then
        echo TIMEOUT
    elif grep -aqE 'version solving failed|^Because|no plan' "$OUT/$base.$tag.log"; then
        echo UNSAT
    elif [ $code -ne 0 ]; then
        echo "exit $code"
    else
        echo sat
    fi
}

# --- gate: the failure corpus, and agreement over the union set --------------
# One pass, two gates: the corpus cases must still fail under ours, and every
# problem in the union set must get the same verdict from both solvers.
echo "running ${#ALL[@]} problems through both solvers (logs in $OUT)" >&2

# Warm the index once, outside the gate: the first run of the day may bootstrap
# or refresh it, and that is not what any of these numbers are about.
"$EXE" "${INDEX_STATE[@]}" vector >/dev/null 2>&1 || true

agree=0
disagree=()
corpus_ok=0
corpus_bad=()

for problem in "${ALL[@]}"; do
    base=$(echo "$problem" | tr -c 'A-Za-z0-9' '-')
    mapfile -t targets < <(targets_of "$problem")
    ours=$(solve_one ours "$base" "${targets[@]}")
    theirs=$(solve_one cabal "$base" "${targets[@]}")

    if [ "$ours" = "$theirs" ]; then
        agree=$((agree + 1))
    else
        disagree+=("$problem: ours=$ours cabal=$theirs")
    fi
    printf '  %-34s ours=%-8s cabal=%-8s\n' "$problem" "$ours" "$theirs" >&2
done

# The explanation deliverable, off the logs the pass above already wrote.
#
# `ours` counts proof sentences by the connective each opens with, exactly as
# bench/summarise.awk does and NOT by a leading number: the reporter numbers only
# the conclusions it refers back to (references/pubgrub.md:673), so most lines of
# a proof carry none. `cabal` counts the non-blank lines of its "Could not resolve
# dependencies:" block — its actual explanation, not the whole log.
proof_total=0
nover_total=0
longer=()

for problem in "${CORPUS[@]}"; do
    base=$(echo "$problem" | tr -c 'A-Za-z0-9' '-')
    if grep -aqE 'version solving failed|^Because' "$OUT/$base.ours.log"; then
        corpus_ok=$((corpus_ok + 1))
    else
        corpus_bad+=("$problem")
    fi

    ours_lines=$(grep -acE '^([0-9]+\. )?(Because|And because|So, because|Thus,)' "$OUT/$base.ours.log")
    nover_lines=$(grep -acE 'no version for' "$OUT/$base.ours.log")
    cabal_lines=$(sed -n '/Could not resolve dependencies:/,$p' "$OUT/$base.cabal.log" |
        tail -n +2 | grep -acv '^$')

    proof_total=$((proof_total + ours_lines))
    nover_total=$((nover_total + nover_lines))
    [ "$ours_lines" -gt "$cabal_lines" ] && longer+=("$problem ($ours_lines>$cabal_lines)")
    printf '  %-34s proof=%-4s cabal=%-4s noVer=%s\n' \
        "$problem" "$ours_lines" "$cabal_lines" "$nover_lines" >&2
done

if [ "${#ALL[@]}" -ne "$EXPECT_PROBLEMS" ]; then
    gate problems FAIL "${#ALL[@]} problems in the union set, expected $EXPECT_PROBLEMS"
else
    gate problems ok "${#ALL[@]} problems (${#BENCH[@]} bench + ${#CORPUS[@]} corpus)"
fi

if [ "$corpus_ok" -lt "$EXPECT_CORPUS" ]; then
    gate corpus FAIL "$corpus_ok/$EXPECT_CORPUS reproduce; resolved: ${corpus_bad[*]:-}"
else
    gate corpus ok "$corpus_ok/$EXPECT_CORPUS reproduce as unsat"
fi

if [ "$agree" -lt "$MIN_AGREEMENT" ]; then
    gate agreement FAIL "$agree/${#ALL[@]} (floor $MIN_AGREEMENT); ${disagree[*]:-}"
elif [ "$agree" -gt "$MIN_AGREEMENT" ]; then
    gate agreement IMPROVED "$agree/${#ALL[@]} (floor $MIN_AGREEMENT); ${disagree[*]:-none}"
else
    gate agreement ok "$agree/${#ALL[@]}; ${disagree[*]:-none}"
fi

# Two gates on the proof, because they fail for different reasons: being longer
# than cabal on any single problem loses the deliverable outright, while the
# totals catch a change that trades one proof's length for another's.
if [ "${#longer[@]}" -ne 0 ]; then
    gate vs-cabal FAIL "longer than cabal on ${#longer[@]}: ${longer[*]}"
else
    gate vs-cabal ok "shorter than cabal on all ${#CORPUS[@]}"
fi

if [ "$proof_total" -gt "$MAX_PROOF" ] || [ "$nover_total" -gt "$MAX_NOVER" ]; then
    gate proof FAIL "$proof_total sentences (ceiling $MAX_PROOF), $nover_total no-version (ceiling $MAX_NOVER)"
elif [ "$proof_total" -lt "$MAX_PROOF" ] || [ "$nover_total" -lt "$MAX_NOVER" ]; then
    gate proof IMPROVED "$proof_total sentences (was $MAX_PROOF), $nover_total no-version (was $MAX_NOVER)"
else
    gate proof ok "$proof_total sentences, $nover_total no-version lines"
fi

# --- gate: golden proofs, pkg-config modelling, the whole suite --------------
# Tasty patterns are awk expressions over the path components, so each of these
# selects a subtree by name. --accept is deliberately never passed here: a golden
# diff is the review, and a gate that rewrote its own expectations would be no
# gate at all.
run_tests() {
    local name=$1 pattern=$2
    local log="$OUT/tests.$name.log"
    # Three packages, three suites: a pattern selects by name in each, and a
    # suite where it matches nothing passes with zero tests.
    if [ -z "$pattern" ]; then
        timeout "$TIMEOUT" cabal test all >"$log" 2>&1
    else
        timeout "$TIMEOUT" cabal test all --test-options="-p $pattern" >"$log" 2>&1
    fi
    local code=$?
    local count
    count=$(grep -aoE '[0-9]+ tests? passed' "$log" | awk '{s += $1} END {print s " tests passed"}')
    if [ $code -eq 0 ]; then
        gate "$name" ok "${count:-passed}"
    else
        gate "$name" FAIL "see $log: $(grep -aE 'FAIL|failure' "$log" | head -3 | tr '\n' ' ')"
    fi
}

run_tests golden '"$2==\"PubGrub paper examples\"&&$3~/Error Reporting/"'
run_tests pkgconfig '"$3==\"buildability (pkg-config, buildable: False)\""'
run_tests unit ''

# --- summary ----------------------------------------------------------------
echo
echo "== gate summary =="
printf '%s\n' "${summary[@]}"
echo
if [ $failed -ne 0 ]; then
    echo "GATE FAILED (logs in $OUT)"
    exit 1
fi
echo "GATE PASSED (logs in $OUT)"
