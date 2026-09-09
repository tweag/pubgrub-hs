#!/usr/bin/awk -f
#
# Reduce a `pubgrub -v` trace to event counts and the resolution-depth histogram.
#
#   pubgrub -v 'aeson <2' | awk -f bench/summarise.awk
#
# Every number here is a count of trace lines, which is why a run cannot be both
# quiet and counted (see docs/benchmarking.md, "The one thing that is missing").
#
# depth: the "resolving at" lines between a Conflict and its Learned, one per
# resolution step. A deep entry is a single clause learned over many iterations,
# which is what generation-time depender collapsing exists to avoid.
/^Deciding /             { deciding++ }
/^Chose /                { chose++ }
/^No version available / { noversion++ }
/^Conflict /             { conflicts++; depth = 0; inres = 1 }
/^  resolving at /       { if (inres) depth++; resolving++ }
/^Learned /              { learned++; hist[depth]++; inres = 0 }
/^Backtracked /          { backtracked++ }
# The provider's closing line is
#   read N .cabal files, decoded D from the derived index, served R repeat lookups ...
# so parses, decodes and cache hits are three separate numbers. Match them by name,
# not by field position: a clause added to the line silently turns a positional
# match into 0.
/^read .* \.cabal files/ {
    parses = $2
    for (i = 1; i < NF; i++) {
        if ($i == "decoded") decoded = $(i + 1)
        if ($i == "served")  reused  = $(i + 1)
    }
}
# Proof lines, on failure only. Matched by the connective each line opens with,
# not by a leading number: the reporter numbers only the conclusions it refers
# back to (references/pubgrub.md:673), so most lines of a proof carry no number.
# Counting "^[0-9]+\. " reported 9 lines for a 57-line aeson proof.
/^([0-9]+\. )?(Because|And because|So, because|Thus,)/ { proof++ }
END {
    printf "deciding=%d chose=%d conflicts=%d learned=%d resolving=%d backtracked=%d noversion=%d parses=%d decoded=%d reused=%d proof=%d\n",
        deciding, chose, conflicts, learned, resolving, backtracked, noversion, parses, decoded, reused, proof
    n = asorti(hist, keys, "@ind_num_asc")
    printf "depth histogram:"
    for (i = 1; i <= n; i++) printf " %s×%d", keys[i], hist[keys[i]]
    printf "\n"
}
