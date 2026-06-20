# Llama Release Watcher

A pipeline that monitors the official [llama.cpp](https://github.com/ggerganov/llama.cpp) repository for new releases and automatically builds and publishes optimized CUDA Docker images to a private Docker registry.

The release check runs as a [Windmill](https://www.windmill.dev/) scheduled script every 5 minutes; builds run on [Woodpecker CI](https://woodpecker-ci.org/). The two are connected through git: Windmill commits the new release tag to this repo using a deploy key, and that push triggers the Woodpecker build.

## Overview

This project solves the need for automated, consistent Docker images of `llama.cpp` specifically tailored for CUDA environments without needing to maintain a full fork of the upstream repository.

### Key Features
- **Automated Polling:** A Windmill schedule checks for new `llama.cpp` releases every 5 minutes.
- **Git as State:** The last seen release tag lives in `last_release_version.txt`, committed by Windmill — every build is traceable to a commit.
- **Targeted Builds:** Focuses specifically on **CUDA 12** and **CUDA 13** for Linux `amd64`.
- **Optimized Builds:** Limits CUDA compilation to modern architectures (Ampere, Ada, Hopper) to reduce build time and suppress legacy warnings.
- **Upstream Integrity:** Instead of mirroring code, the build clones the upstream repository at the specific release tag, ensuring 100% parity with official releases.

## Architecture

1. **Check (Windmill):** `.windmill/check_release.py` runs every 5 minutes. It queries the GitHub API for the latest release tag and clones this repo (shallow) to compare against `last_release_version.txt`.
2. **Commit (Windmill):** On a new tag, the script writes the tag to `last_release_version.txt`, commits as `windmill-bot`, and pushes to `main` using an SSH deploy key stored as a Windmill secret.
3. **Build & Push (Woodpecker):** The push triggers `.woodpecker/build-release.yml`. It clones `llama.cpp` at the committed tag and builds the `server` target of `.devops/cuda.Dockerfile` for CUDA 12 and CUDA 13 (matrix), pushing all tags to the private registry with a registry-backed build cache.

If a build fails, the version file is already committed, so the watcher will not re-trigger the same tag — restart the pipeline from the Woodpecker UI.

## Setup & Configuration

### Deploy Key

1. Generate a key pair: `ssh-keygen -t ed25519 -f llama-watcher-deploy -N '' -C windmill-bot`
2. Add the public key as a **deploy key with write access** on this repository (GitHub → Settings → Deploy keys).
3. Store the private key as a Windmill secret variable at `f/llama_watcher/deploy_key`.

### Woodpecker

1. Enable this repository in Woodpecker.
2. Add repository secrets:
   | Secret | Description |
   | :--- | :--- |
   | `DOCKER_REGISTRY` | Private registry hostname, for example `registry.example.com` |
   | `DOCKER_REGISTRY_USERNAME` | Username for the private registry |
   | `DOCKER_REGISTRY_KEY` | Password or access key for the private registry |

Images are pushed to `<docker_registry>/llama-cpp`.

#### Compile caching (sccache) — optional

Builds route C/C++ through [sccache](https://github.com/mozilla/sccache) backed by any S3-compatible store, so objects are cached across runs even when Kaniko's layer cache misses. The upstream `cuda.Dockerfile` is patched at build time by `.woodpecker/enable-sccache.sh` — no fork. nvcc is also cached on **CUDA 12**, but not CUDA 13 (sccache mis-parses CUDA 13's nvcc and dies at the `fatbinary` step); both still cache C/C++.

This is **entirely opt-in and configured via secrets** — nothing is hardcoded. sccache is enabled only when all four of the following are set; leave them unset and the build runs without it:

   | Secret | Description |
   | :--- | :--- |
   | `SCCACHE_BUCKET` | Bucket name for the cache |
   | `SCCACHE_ENDPOINT` | S3 endpoint host (e.g. `s3.example.com`) |
   | `AWS_ACCESS_KEY_ID` | Access key for the bucket |
   | `AWS_SECRET_ACCESS_KEY` | Secret key for the bucket |

Optional knobs: `SCCACHE_REGION` (default `auto`) and `SCCACHE_S3_USE_SSL` (default `true`). Cache objects are namespaced per CUDA toolchain under the `llama-cpp/<cuda_suffix>` key prefix.

Note: Kaniko has no build-time secret mounts, so the credentials transit the build's `.kaniko.env` file and are passed as build args, persisting in the (private) build-stage cache layers — use a least-privilege, rotatable key scoped to the cache bucket. The published `server` image is a separate build stage and does not contain them.

### Windmill

Create a Windmill scheduled script from `.windmill/check_release.py` with cron `0 */5 * * * *` (Windmill cron includes a leading seconds field). Script arguments:

| Argument | Description | Default |
| :--- | :--- | :--- |
| `deploy_key` | SSH private key with write access (from `$var:f/llama_watcher/deploy_key`) | (required) |
| `repo_ssh_url` | SSH clone URL of this repo | `git@github.com:EdwardJXLi/llama-release-watcher.git` |
| `branch` | Branch to commit to | `main` |
| `github_token` | Optional token to raise GitHub API rate limits | (none) |

## Image Tagging Convention

Images are published with the following naming scheme:

| Image Type | CUDA Version | General Tag | Versioned Tag |
| :--- | :--- | :--- | :--- |
| **Server** | 12 | `server-cuda` / `server-cuda12` | `server-cuda12-<tag>` |
| **Server** | 13 | `server-cuda13` | `server-cuda13-<tag>` |
