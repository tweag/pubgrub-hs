# Contributing

How to read the project is [`CLAUDE.md`](CLAUDE.md); what works and what is planned is
[`docs/STATUS.md`](docs/STATUS.md). This file is the formatting, commit and release
process.

## Formatting

Every Haskell file is formatted by [stylish-haskell](https://github.com/haskell/stylish-haskell)
with [`.stylish-haskell.yaml`](.stylish-haskell.yaml), at the version pinned in
`mise.toml`. `mise run format` formats the tree, and `mise run format --check` reports
the files it would change. CI runs the check, and `ci-ok` fails on it.

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
- Every package in `cabal.project` has the version of the release.

The `version:` fields in the `.cabal` files are the only source of the version. Only the release task, and the maintainer in a release PR, change them and the `CHANGELOG.md` files.

## Making a release

The maintainer makes releases.

1. Make sure that `main` is green.
2. Run `mise run release-pr`. It reads the commits since the last release tag, sets the next version in every `.cabal` file, regenerates `CHANGELOG.md` and each package's own with [git-cliff](https://git-cliff.org/), and opens a pull request titled `chore(release): VERSION`. If there are no releasable commits, it says so and does nothing.
3. Review the pull request. The task changes only the `version:` fields, so a release that increments `A` or `B` also needs the bound of `pubgrub-cabal` on `pubgrub` raised by hand, or cabal cannot plan and `ci-ok` fails. To increment `A`, change the version by hand in every `.cabal` file, and change the header of every `CHANGELOG.md` and the commit description to the same version. Edits to a `CHANGELOG.md` are lost at the next release, which regenerates it; wording that must stay goes in `cliff.toml`.
4. When `ci-ok` passes, merge the pull request with rebase merge.
5. CI's `release` job sees the release commit on `main`. It publishes a GitHub release with the source distribution of every package, the documentation of `pubgrub` and `pubgrub-cabal` as Hackage takes it, and the `pubgrub` executable for each platform, their `SHA256SUMS`, and the notes from `CHANGELOG.md`. Publishing creates the tag. Then the `pages` job publishes the documentation of the release to <https://tweag.github.io/pubgrub-hs/>.
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
