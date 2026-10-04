# Releasing ecto_sediment

Releases are published to Hex only by `.github/workflows/release.yml`, when a
GitHub release is published.

## Packaging

During development ecto_sediment depends on Sediment by path, which a Hex
package can't. With `SEDIMENT_HEX=1` it depends on `{:sediment, "~> 0.1.0-beta.1"}`
from Hex instead (see `sediment_dep/0` in `mix.exs`); the release workflow
sets it. Without it `mix hex.build` stops with missing metadata rather than
producing a package without its driver. To check a package locally:

```sh
SEDIMENT_HEX=1 mix hex.build --unpack
```

The required Sediment version must be on Hex first: release Sediment before
an ecto_sediment version that needs it, and raise the constraint in
`sediment_dep/0` when ecto_sediment starts using a newer Sediment.

## Release steps

1. On a branch: set `@version` in `mix.exs`, turn the top CHANGELOG heading
   into `## <version> (<date>)` (no "unreleased"), and, for a new minor
   version, update `{:ecto_sediment, "~> <major.minor>"}` in the installation
   instructions (README "Installation", guides/getting_started.md,
   guides/migrating_from_ecto_sqlite3.md, examples/s3_demo/README.md). Merge
   the PR into `main` once CI is green.
2. Make sure the Sediment version the constraint needs is on Hex.
3. Create a GitHub release on that commit of `main` with the tag
   `v<version>` (e.g. `v0.1.0`) and the CHANGELOG entry as its notes, and
   publish it.
4. The `Release` workflow waits for approval in the `hex` environment.
   Approve it: it checks that the tag matches `@version`, that CHANGELOG.md
   has a released entry for it, that the commit is on `main` and that the
   Sediment constraint resolves on Hex; runs `mix ci` on a clean build (no
   caches) against Sediment from Hex; and runs `mix hex.publish --yes`.
5. Check the package and its docs on hex.pm and hexdocs.pm.

If a step fails, fix it on `main`, delete the release and the tag, and start
again from step 3. A published Hex version can be retired
(`mix hex.retire`) but not replaced after the first hour.

## Hex API key

The workflow publishes with `HEX_API_KEY`, which exists only as a secret of
the `hex` environment (never at the repository or organization level).

* Create it with `mix hex.user key generate --key-name ecto_sediment-ci
  --permission api:write`, from an account that owns the package (on the
  first release: the account that publishes it). Store it as the
  environment secret `HEX_API_KEY` and nowhere else.
* Rotate it at least yearly and whenever a maintainer with access leaves:
  generate a new key, replace the secret, then revoke the old one with
  `mix hex.user key revoke ecto_sediment-ci` (or on hex.pm).
* If it may have leaked, revoke it first, then check the package's recent
  releases on hex.pm.

## Repository settings (one-time checklist)

- [ ] Environment `hex`: required reviewer = the maintainer, "Prevent
      self-review" off only if there is a single maintainer, deployment
      branches and tags restricted to the tag rule `v*`, no admin bypass;
      secret `HEX_API_KEY`.
- [ ] Branch protection on `main`: pull requests required, the CI checks
      required, no force pushes, no deletions.
- [ ] Actions: "Require approval for all outside collaborators" for fork
      pull request workflows; "Allow GitHub Actions to create and approve
      pull requests" disabled; workflow permissions read-only by default.
- [ ] Secret scanning and push protection enabled.

## CI security

* Pull requests run `ci.yml` with `pull_request` (fork PRs get no secrets
  and a read-only token); no workflow uses `pull_request_target` or
  `workflow_run`.
* Every workflow sets `permissions: contents: read` at the top, checks out
  with `persist-credentials: false`, and never interpolates
  `${{ github.event.* }}` into `run:` (values go through `env:`).
* Actions are pinned by full commit SHA with the version as a comment;
  Dependabot (`.github/dependabot.yml`) proposes updates weekly.
