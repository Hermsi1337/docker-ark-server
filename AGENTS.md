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
| `conf.d/` | Templates copied into the image (`arkmanager.cfg`, `arkmanager-user.cfg`, `crontab`) |
| `deploy/` | Example `docker-compose.yml` + `example.env` for end users |
| `.github/workflows/build-and-deploy.yml` | "Build and Publish" — builds and pushes to all three registries |
| `.github/workflows/deploy-preview.yml` | "Build PR Preview" — builds PRs, pushes `pr-<n>` for same-repo PRs |
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
- Keep entrypoint/runtime behavior and documented environment variables
  backward compatible; users run long-lived servers against `latest`.

## Common tasks

- **Bump the arkmanager pin:** check
  `gh api repos/arkmanager/ark-server-tools/releases/latest --jq .tag_name`,
  update the `ARK_TOOLS_VERSION` ARG default in `Dockerfile`, PR it.
- **Action version updates:** Dependabot opens weekly PRs; review the
  changelog, merge. The PR preview build doubles as the smoke test.
- **Scheduled workflow got disabled?** GitHub disables cron workflows after
  ~60 days without repository activity. Re-enable with
  `gh workflow enable "Build and Publish"` (or via the Actions tab), then
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
