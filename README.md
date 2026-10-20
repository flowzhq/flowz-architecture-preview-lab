# flowzhq/flowz-architecture-preview-lab

A GitHub composite Action that publishes an **interactive architecture graph** on
every pull request. One `uses:` step scans the repo, enriches it with the Flowz
analyzer, and posts a login-free viewer link on the PR.

Everything runs on **your** GitHub-hosted runner — your source never leaves your
CI. The private scanner + analyzer are pulled from GHCR with **your** token; this
public Action carries no credentials.

## Usage

```yaml
name: flowz architecture (PR)
on: [pull_request]
permissions:
  contents: read
  pull-requests: write        # required, so the Action can comment
jobs:
  arch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: flowzhq/flowz-architecture-preview-lab@v1
        with:
          analyzer-image: ghcr.io/flowzhq/flowz-analyzer:1.4.0   # pin the version we gave you
          scanner-image:  ghcr.io/flowzhq/flowz-cli:v0.4.0        # pin the version we gave you
          registry-user:  ${{ secrets.FLOWZ_REGISTRY_USER }}
          registry-token: ${{ secrets.FLOWZ_REGISTRY_TOKEN }}      # read:packages on both packages
          preview-token:  ${{ secrets.FLOWZ_PREVIEW_TOKEN }}
```

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `analyzer-image` | yes | — | Private GHCR analyzer image, pinned. |
| `scanner-image` | yes | — | Private GHCR CLI OCI artifact, pinned. |
| `registry-user` | yes | — | GHCR user with `read:packages` on both. |
| `registry-token` | yes | — | GHCR `read:packages` token (a secret). |
| `preview-token` | yes | — | Must match the Flowz BFF's `--preview-token` (a secret). |
| `app-url` | no | `https://app.codeflowz.ai` | Dashboard base for the viewer link. |
| `scan-path` | no | `.` | Monorepo root to scan. |
| `comment` | no | `true` | Upsert the PR comment. |

## Output

| Output | Notes |
|---|---|
| `view-url` | The interactive preview URL (empty if publishing was skipped/failed). |

## What it does

`docker login` GHCR → pull the scanner (`oras`) → run the analyzer as a `docker
run` sidecar → `flowz scan --monorepo` → `calc-efsg` per service (**content-
addressed cache**, so unchanged services skip the analyzer) → `calc-system` →
`POST /internal/v1/preview` → upsert the PR comment. The analyzer container is
removed on exit.

## Security

- **Your source stays on your runner.** The scanner runs there; only the derived
  architecture bundle is published to `app-url`.
- **The Action is public; the artifacts are not.** The scanner + analyzer stay
  private on GHCR — your `registry-token` is the access boundary. No token ⇒ the
  pulls fail. This repo holds no credentials.
- **Pin the Action.** Reference `@v1` (or a commit SHA) and the artifact versions
  we provide, so a run is reproducible and can't silently change.

## Requirements

`ubuntu-latest` (Linux + Docker). `oras` is installed by the Action; `jq`, `gzip`,
`sha256sum`, `docker`, `curl` are preinstalled on GitHub-hosted runners.
