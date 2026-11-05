# Contributing

What the project is, and how to build and run it, is the [README](README.md); why it is
built this way is [`docs/DESIGN.md`](docs/DESIGN.md). This file is how to change it: what
decides whether a change is kept, the conventions, and the commit and release process.

## What decides whether a change is kept

`scripts/gate.sh` does: eight gates over 27 real problems, one line per gate and a
non-zero exit on any regression. It holds five numeric baselines. Only the problem count
is exact, and the others are floors or ceilings. Move a baseline in the change that earns
it. The two proof ceilings are tight, 77 sentences and no `no version` line, so a reporting
change has to earn its way past them.

Every run in the gate and the harness is pinned to the index-state in `bench/index-state`,
so the numbers stop moving with the weekly index refresh. Move the pin in the change that
re-measures. [`docs/benchmarking.md`](docs/benchmarking.md) has the details, and is the
reference for measuring anything.

Two things matter to any change in reporting. The gate and the harness count sentences by
the connective that opens them, so a new line must open with none of them. And the golden
proofs are the spec's own examples, so a wording change earns its way past them.

CI also runs `scripts/check-haddock.sh pubgrub pubgrub-cabal`: no Haddock warning, and
every export documented.

## Invariants you can break by accident

Each of these is a decision whose argument and evidence are in
[`docs/DESIGN.md`](docs/DESIGN.md). The line here says what the plausible wrong edit is.
Read the section before you touch the code.

- **A flag is a solver variable, and the value carries no flags** (§2, §3). `InstanceSet`
  is an installed set plus one version range, canonical and exact; `Var` is a package name
  or a `(package, Flag)` pair, and `Flag` is a name *with its declared default*. Do not put
  flags back into the value, and do not key a flag variable by release.
- **`PubGrub.Store` merges on insert and keeps scan position** (§5). A merge replaces the
  clause where it sits, and the merged clause stays a leaf. Propagation judges only the
  dirty clauses and acts on the newest actionable one; mark every change to a variable's
  term or a clause's terms dirty, or the search changes.
- **The derived index is a cache that follows the index by block** (§6). It stores the
  pre-environment form; raise `storeFormatVersion` on any encoding change.
- **Memoise the reduced form, never the parse tree** (§11).
- **A dependency of `p` on `p` adds no goal and no edge, and its range is still checked**
  (§8): a release the range excludes is banned, and otherwise nothing is stated.
- **An unbuildable component contributes no dependencies** (§15), through Cabal-syntax's
  own `addBuildableCondition`; the library is not gated.
- **Build tools and `setup-depends` are not dependencies** (§16). They ride in `Release` as
  `relTools` and `relSetup` for a planner to solve in a namespace of its own, and `mkExpand`
  tries a `Preference` before installed and newest. Do not fold them into `GuardedDeps`.
- **Boot packages are installed-only** (§7).
- **A depender term names a slot, not a version**, and the first slot has no lower bound
  (§4).
- **A guarded dependency's flag terms are positive and name the depender's own flags**, and
  a fact merges only with one under the same guard (§3, §5).
- **Versions compare with trailing zeros insignificant**, and Cabal's type stops at the
  bridge (§14).
- **The request is a list of seeds** (§10): the terminal test, the level-0 backtrack floor
  and the closing step all rest on it.
- **Decision order is discovery order**, measured against the spec's (§12).

## Conventions

- GHC 9.12 or 9.14 (`base >=4.21 && <4.23`). `pubgrub` alone also builds on 9.10
  (`base >=4.20`). `cabal-version: 3.0` in every package.
- `default-language: GHC2021` on every component, with
  `default-extensions: ImportQualifiedPost`. The test-suites of `pubgrub-cabal`,
  `pubgrub-hs` and `pubgrub-doctest` lack the extension.
- `-Wall` everywhere.
- No partial functions (`head`, `fromJust`). Use pattern matching or `Maybe`/`Either`.
- Prefer `newtype` wrappers over type aliases for domain types.

## Citations

- **Cite nothing external in a Haddock.** The Haddocks of `pubgrub` and `pubgrub-cabal` are
  read on Hackage, where none of this repository can be opened. They name no other project,
  cite no spec line, and point at nothing in the harness or in `docs/`. State the rule or
  the reason itself. The two rules below are for plain comments and documents.
- **Cite `references/pubgrub.md` by line, and check the line first.** Citations have landed
  on blank lines before.
- **Cite the Rust implementation, pubgrub-rs, by function name, not by line.** This
  repository does not carry it, and its line numbers move with upstream. Write
  `merge_dependents`, not `:173`.

## Formatting

Every Haskell file is formatted by [stylish-haskell](https://github.com/haskell/stylish-haskell)
with [`.stylish-haskell.yaml`](.stylish-haskell.yaml), at the version pinned in
`mise.toml`. Run `mise run format` before committing; `mise run format --check` reports
the files it would change. CI runs the check, and `ci-ok` fails on it. CI installs the
tools from `mise.lock`, so run `mise lock` after changing a version in `mise.toml`.

## Commit messages

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/). For example:

```
fix(cabal): a dependency of p on p is dropped in both halves of the flatten
feat(core,cabal,app): constraint seeds, the conflict set of a failure, and --constraint for both solvers
refactor!: split the solver and its cabal domain into the pubgrub and pubgrub-cabal packages
docs: the two reports regenerated on 2026-10-08, and the status figures with them
```

The allowed types are `feat`, `fix`, `perf`, `docs`, `ci`, `test`, `refactor`, `build`, `chore`, `style` and `revert`. A scope in parentheses is optional. `!` before the colon, or a `BREAKING CHANGE:` footer, marks a breaking change. The `commits` CI job checks every commit of a pull request with [git-cliff](https://git-cliff.org/), so the allowed types are the ones that the commit parsers in `cliff.toml` know. jj does not run git hooks, so this check is the only one.

The commit types choose the next version:

| Commits since the last release | Next version |
|---|---|
| At least one breaking change, of any type | `B` + 1 |
| At least one `feat` | `C` + 1 |
| At least one `fix` or `perf` | `D` + 1 |
| Only `docs`, `ci`, `test`, `refactor`, `build`, `chore`, `style`, `revert` | No release |

Pull requests are merged with rebase merge. A squash merge would leave only the PR title for the release task to read.

## Versions

Versions follow the [Haskell Package Versioning Policy](https://pvp.haskell.org/) (PVP) and have four components, `A.B.C.D`, for example `0.1.0.0`. `A.B` is the major version, `C` the minor version and `D` the patch version.

- git-cliff calculates the next version from the commit types, as in the table above. This is Semantic Versioning (SemVer) applied to `B.C.D`. There is no special rule for versions below 1.0: a breaking change increments `B` even when it is `0`.
- Incrementing a field sets all fields to its right to `0`.
- `A` changes only by hand, when the maintainer decides that a release deserves a new number. Like a change of `B`, it makes a major release.
- Release tags are `v` followed by the version, for example `v0.1.0.0`. The first release is `0.1.0.0`.
- Every package in `cabal.project` has the version of the release. The release task keeps it so; CI does not check it.

The `version:` fields in the `.cabal` files are the only source of the version. Only the release task, and the maintainer in a release PR, change them and the `CHANGELOG.md` files.

## Making a release

The maintainer makes releases.

1. Make sure that `main` is green.
2. Run `mise run release-pr`. It reads the commits since the last release tag, sets the next version in every `.cabal` file, regenerates `CHANGELOG.md` and each package's own with [git-cliff](https://git-cliff.org/), and opens a pull request titled `chore(release): VERSION`. If there are no releasable commits, it says so and does nothing.
3. Review the pull request. The task changes only the `version:` fields, so a release that increments `A` or `B` also needs the bound of `pubgrub-cabal` on `pubgrub` raised by hand, or cabal cannot plan and `ci-ok` fails. To increment `A`, change the version by hand in every `.cabal` file, and change the header of every `CHANGELOG.md` and the commit description to the same version. Edits to a `CHANGELOG.md` are lost at the next release, which regenerates it; wording that must stay goes in `cliff.toml`.
4. When `ci-ok` passes, merge the pull request with rebase merge.
5. CI's `release` job sees the release commit on `main`. It publishes a GitHub release with the source distribution and the documentation of `pubgrub` and `pubgrub-cabal` as Hackage takes them, and the `pubgrub` executable for each platform, their `SHA256SUMS`, and the notes from `CHANGELOG.md`. Publishing creates the tag, named from the version in the commit's subject. Then the `pages` job publishes the documentation of the release to <https://tweag.github.io/pubgrub-hs/>.
6. Verify the release:

   ```
   gh release verify vVERSION
   gh attestation verify ASSET --repo tweag/pubgrub-hs
   ```

To publish a release on Hackage too, upload the source distribution and the documentation of `pubgrub`, then of `pubgrub-cabal`, which depends on it. The other packages stay here. CI built both files, and they are on the GitHub release:

```
gh release download vVERSION --repo tweag/pubgrub-hs --pattern 'PACKAGE-VERSION.tar.gz' --pattern 'PACKAGE-VERSION-docs.tar.gz'
cabal upload --publish PACKAGE-VERSION.tar.gz
cabal upload --publish --documentation PACKAGE-VERSION-docs.tar.gz
```

Releases are immutable: a published version cannot change. If a release is wrong, fix it and make a new release. If the `release` job fails before it publishes, rerun the failed jobs; the job continues the draft release.

### Release artifacts without a release

Every CI run, on a pull request or started by hand, uploads everything that a release would publish as one artifact, `dist`: the same files and `SHA256SUMS`, without attestations. To get them for any branch without releasing:

```
gh workflow run ci.yml --ref BRANCH
gh run list --workflow ci.yml --branch BRANCH --event workflow_dispatch --limit 1
gh run download RUN_ID --name dist
```

The `release` job runs only on a push to `main`, so a manual run never releases. The `github-pages` artifact of a run is the documentation site, as a tar file.
