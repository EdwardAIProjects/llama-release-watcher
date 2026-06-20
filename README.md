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
   | `docker_registry` | Private registry hostname, for example `registry.example.com` |
   | `docker_registry_username` | Username for the private registry |
   | `docker_registry_key` | Password or access key for the private registry |

Images are pushed to `<docker_registry>/llama-cpp`.

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
