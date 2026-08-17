# AGENTS.md

Working guide for AI agents and humans contributing to this repository.
Verify anything you rely on against the actual files — this document summarizes
them, it does not replace them.

## What this is

A Docker image for **ARK: Survival Evolved** dedicated servers, installed via
`steamcmd` and managed with
[arkmanager / ark-server-tools](https://github.com/arkmanager/ark-server-tools).
Base image: `cm2network/steamcmd:root`.

Published to three registries (same image, same tags):

- Docker Hub: `hermsi/ark-server`
- Quay.io: `quay.io/hermsi1337/ark-server`
- GHCR: `ghcr.io/hermsi1337/ark-server`

**Tag schema — public contract, do not change:**

| Tag | Meaning |
|---|---|
| `latest` | Most recent build from `master` |
| `latest-<unix-timestamp>` | Immutable pointer to a specific `latest` build |
| `tools-<sha>` | Build pinned to an ark-server-tools commit SHA |
| `pr-<n>` | Preview build for pull request `<n>` (same-repo PRs only) |

Users pin deployments to these tags. Renaming or dropping any of them breaks
downstream compose files and scripts.

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Image build; installs arkmanager via upstream `netinstall.sh` |
| `bin/docker-entrypoint.sh` | Container entrypoint (root: setup, cron, drops to steam user) |
| `bin/steam-entrypoint.sh` | Server bootstrap/run as the `steam` user |
| `bin/healthcheck.sh` | Container `HEALTHCHECK` (root: drops to the steam user, checks every managed instance) |
| `conf.d/` | Templates copied into the image (`arkmanager.cfg`, `arkmanager-user.cfg`, `crontab`) |
| `deploy/` | Example `docker-compose.yml` + `example.env` for end users |
| `tests/` | bats suite for the pure-bash parts of `bin/steam-entrypoint.sh` |
| `.github/workflows/build-and-deploy.yml` | "Build and Publish" — builds and pushes to all three registries |
| `.github/workflows/deploy-preview.yml` | "Build PR Preview" — builds PRs, pushes `pr-<n>` for same-repo PRs |
| `.github/workflows/update-arkmanager-pin.yml` | "Update arkmanager pin" — weekly bump PR for the `ARK_TOOLS_VERSION` default |
| `.github/workflows/lint.yml` | "Lint" — shellcheck, yamllint and hadolint on PRs and `master` |
| `.yamllint` | yamllint rule config; every disabled rule carries the reason it is off |
| `.github/workflows/tests.yml` | "Tests" — runs the bats suite on pull requests and on `master` |
| `.github/dependabot.yml` | Weekly `github-actions` version updates |

## CI/CD

**Build and Publish** (`build-and-deploy.yml`):

- Triggers: push to `master`, weekly cron **Mondays 02:00 UTC**, and manual
  `workflow_dispatch`. The weekly cron exists so the image regularly picks up
  fresh ARK/Steam/base-image state — keep it.
- Resolves the current ark-server-tools master commit at build time and passes
  it as `ARK_TOOLS_VERSION` (this is where `tools-<sha>` comes from).
- Uses `docker/login-action`, `docker/metadata-action`,
  `docker/build-push-action`; concurrency-guarded per ref.

**Build PR Preview** (`deploy-preview.yml`):

- Triggers on `pull_request` against `master`; concurrency-guarded per PR.
- **Fork-safe:** fork PRs build for validation only — they never receive
  secrets and never push. Same-repo PRs push `pr-<n>`, and only if the
  registry secrets are actually configured (the eligibility step checks for
  `DOCKERHUB_TOKEN`). Keep this property when editing the workflow.

**Update arkmanager pin** (`update-arkmanager-pin.yml`):

- Triggers: weekly cron **Mondays 01:00 UTC** and manual `workflow_dispatch`.
- Dependabot cannot track a build ARG, so this workflow checks the latest
  ark-server-tools release and opens a bump PR for the Dockerfile default.
- Uses only the built-in `GITHUB_TOKEN` — which means the bump PR does **not**
  trigger the preview build automatically (GitHub suppresses workflow-created
  events); close/reopen the PR to run it, or rely on the master build after
  merge. The actions it uses are themselves covered by Dependabot.

**Lint** (`lint.yml`):

- Triggers on `pull_request` against `master` and on pushes to `master`;
  concurrency-guarded per ref.
- Three independent jobs: shellcheck over `bin/*.sh` and
  `deploy/steam-login.sh`, yamllint over `.github/workflows/` and
  `deploy/docker-compose.yml`, hadolint over the `Dockerfile`.
- Kept separate from the publish workflows on purpose so a lint failure can
  never block a release. The publish workflows keep their own `bash -n`
  syntax check as the hard gate.
- shellcheck and yamllint versions are pinned in the workflow's `env:` block,
  not taken from the runner image, so a runner roll cannot turn `master` red on
  code nobody touched. Bump them by hand. hadolint's version rides the action
  tag, which Dependabot bumps.
- Suppressions are targeted, never repo wide: every hadolint ignore sits inline
  on the instruction it applies to and every shellcheck disable on the function
  it applies to, with the reason directly above. There is no `.hadolint.yaml`
  on purpose, a repo wide `DL3064` ignore would kill the only check that would
  catch a real credential baked into a layer later. If you add a suppression,
  write down why, and make sure the reason is actually true.
- `stop_server` carries both `SC2317` and `SC2329`. Same finding, shellcheck
  renumbered it in 0.10.0, and contributors on Ubuntu 24.04 have 0.9.x.
**Tests** (`tests.yml`):

- Triggers on `pull_request` against `master`, on pushes to `master` and via
  `workflow_dispatch`. Only pull request runs get cancelled by a newer push,
  every master commit finishes.
- Runs `bash -n` over the shell scripts, then the bats suite. The syntax check
  is not redundant: sourcing the entrypoint never parses the startup half, so
  without it a broken startup sequence passes the suite.
- bats comes from `bats-core/bats-action` with a pinned version. The suite
  needs bats 1.4.0 or newer (`BATS_TEST_TMPDIR`), which is why the distro
  package is not used.
- Nothing here builds an image or talks to the network, so it finishes in
  seconds.

**Required repository secrets:**

| Secret | Used for |
|---|---|
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | Docker Hub |
| `QUAY_USERNAME` / `QUAY_TOKEN` | Quay.io |
| — (built-in `GITHUB_TOKEN`, `permissions: packages: write`) | GHCR |

## Invariants — do not "optimize" these away

- **`no-cache: true` + `pull: true` is intentional.** Every publish must
  rebuild from scratch on a freshly pulled base so it captures current
  ARK/steamcmd state. Adding layer caching would silently ship stale servers.
- **`linux/amd64` only.** The base image and the ARK dedicated server are
  x86-only. Do not add arm64 builds or QEMU emulation — they cannot work.
- **arkmanager default pin.** `Dockerfile` pins
  `ARG ARK_TOOLS_VERSION="v1.6.69"` so local/manual builds are deterministic.
  The Dockerfile picks `--tag` vs `--commit` for `netinstall.sh` based on a
  leading `v`. CI overrides the ARG with a resolved commit SHA at build time.
- **`SHELL ["/bin/bash", "-o", "pipefail", "-c"]` stays above the install
  `RUN`.** The `RUN` pipes `netinstall.sh` into `bash`. Without `pipefail` a
  failed download exits 0, the build happily continues and the image ships
  without arkmanager.
- **The healthcheck fails while the container bootstraps.** `bin/healthcheck.sh`
  must never report healthy when it cannot tell what is running (no
  `/app/running-instances`, empty or truncated file). A fresh container
  downloads ~25GB, and `--start-period=6h` is what keeps that in `starting`
  instead of `unhealthy`. Reporting healthy there would unblock
  `depends_on: condition: service_healthy` and Swarm rollouts before the server
  exists. It is also judged per container, not per instance: one dead map must
  not restart the container serving the other two. And a probe that gives up on
  a hung `arkmanager status` has to leave nothing running: it goes off every
  minute for the life of the container, so one surviving child per instance and
  probe piles up into hundreds an hour. That is why the call runs as its own
  process group and the group is signalled, instead of `timeout` alone, which
  signals the command but not reliably what the command forked.
- **`TARGET_MANIFEST_ID` bypasses arkmanager on purpose.** arkmanager can only
  ever update to the newest build (steamcmd's `app_update` takes no manifest
  argument, and arkmanager has no `download_depot` support), so a pinned
  install calls `steamcmd +download_depot` directly and copies the depot into
  the server directory. Do not fold this back into an `arkmanager
  install/update` call. Consequences worth knowing before touching that path:
  - Bypassing `app_update` means no `steamapps/appmanifest_376030.acf` is
    written and the depot ships no `version.txt`, so none of arkmanager's
    version bookkeeping describes a pinned install. `server/.ark_manifest_pin`
    is the image's own record (pinned manifest plus the Steam build id at pin
    time) and the only thing that proves a pinned install completed.
  - A changed build id means something ran `app_update` behind the pin (a cron
    `arkmanager update`); the next start detects that and re-applies the pin.
  - Un-pinning deletes that stale bookkeeping so the normal install path runs a
    full validate back to the current build. Without it arkmanager reads a
    stale build id and calls the downgraded server up to date.
  - `arkmanager run` does **not** auto-update (`doRun` never calls `doUpdate`);
    `start`/`restart` do, via `arkAutoUpdateOnStart`. Forcing
    `UPDATE_ON_START=false` while pinned covers those and the cron environment,
    it is not what holds the pin on a normal start.
  - `download_depot` never learned Steam's 2021 manifest request codes and can
    silently deliver the current build instead. The install verifies the
    manifest steamcmd reports and the `depotcache/<depot>_<manifest>.manifest`
    it leaves behind, and refuses to copy anything it cannot confirm.
- Keep entrypoint/runtime behavior and documented environment variables
  backward compatible; users run long-lived servers against `latest`.
- **`bin/steam-entrypoint.sh` is sourceable.** Everything above the
  `BASH_SOURCE` guard is function definitions, everything below it is the
  startup sequence. The test suite sources the script to get at the functions,
  so new startup code goes below the guard and stays in the same order.

## Common tasks

- **Run the tests:** `bats tests` from the repository root
  (`brew install bats-core`, needs 1.4.0 or newer). The suite sources
  `bin/steam-entrypoint.sh` and exercises the pure-bash parts (sub instance
  keys and ports, generated sub instance configs, the `Game.ini` symlink
  healing, the declarative INI files, mod id collection, install detection,
  the directory setup, the cluster config guard, the Discord config migration
  and its hardcoded webhook warning, the disk space check, the appended
  arkmanager.cfg blocks, the backup budget and crash restart validation, the
  `running-instances` state file the healthcheck reads). It never installs a
  server, arkmanager and steamcmd are stubbed in `tests/stubs`.
- **Writing tests:** assert with `[ ... ]` or the helpers in
  `tests/helper.bash`, never with `[[ ... ]]`. macOS ships bash 3.2, where a
  failing non-final `[[ ... ]]` does not fail the test, so those assertions
  pass locally and only bite in CI.
- **Bump the arkmanager pin:** automated — the "Update arkmanager pin"
  workflow opens a weekly PR when a new ark-server-tools release exists;
  review and merge it. Manual fallback: check
  `gh api repos/arkmanager/ark-server-tools/releases/latest --jq .tag_name`,
  update the `ARK_TOOLS_VERSION` ARG default in `Dockerfile`, PR it.
- **Action version updates:** Dependabot opens weekly PRs; review the
  changelog, merge. The PR preview build doubles as the smoke test.
- **Scheduled workflow got disabled?** GitHub disables cron workflows after
  ~60 days without repository activity — this affects both "Build and Publish"
  and "Update arkmanager pin". Re-enable with
  `gh workflow enable "<name>"` (or via the Actions tab), then
  `gh workflow run "Build and Publish"` for an immediate build.
- **Manual release:** `gh workflow run "Build and Publish"` on `master`.

## Known follow-ups / out of scope

- **ARK: Survival Ascended (ASA)** is deliberately not supported here — it has
  a different server (Windows/Proton-based) and would be a separate image, not
  a feature flag in this one.
- The old `DOCKER_CONFIG_JSON` secret is unused since the CI modernization and
  can be deleted once the per-registry secrets are in place.

## Note for Windows contributors

`CLAUDE.md` is a git symlink to `AGENTS.md` (index mode `120000`). On Windows
checkouts without symlink support it materializes as a plain text file whose
content is just `AGENTS.md` — that is expected. Never re-stage that file with
`git add CLAUDE.md` from such a checkout: it would replace the symlink with a
regular file. Edit `AGENTS.md` only.
