# Checks ggerganov/llama.cpp for a new release. When one appears, commits the
# new tag to last_release_version.txt in this repo and pushes it using an SSH
# deploy key. The push triggers the Woodpecker release-build pipeline
# (.woodpecker/build-release.yml), so git remains the single source of truth
# for the last seen release.
import os
import subprocess
import tempfile

import requests

UPSTREAM_REPO = "ggerganov/llama.cpp"
VERSION_FILE = "last_release_version.txt"


def notify_discord(webhook_url: str, release_tag: str, repo_ssh_url: str, branch: str) -> None:
    webhook_url = webhook_url.strip()
    if not webhook_url:
        return

    message = "\n".join(
        [
            f"New llama.cpp release detected: {release_tag}",
            "",
            "The watcher updated `last_release_version.txt` and pushed to the build branch.",
            f"Upstream release: https://github.com/{UPSTREAM_REPO}/releases/tag/{release_tag}",
            f"Repository: `{repo_ssh_url}`",
            f"Branch: `{branch}`",
        ]
    )
    print("Sending Discord notification.")
    response = requests.post(
        webhook_url,
        json={
            "username": "llama-release-watcher",
            "content": message,
            "allowed_mentions": {"parse": []},
        },
        timeout=30,
    )
    response.raise_for_status()
    print("Discord notification sent.")


def main(
    deploy_key: str,
    repo_ssh_url: str = "git@github.com:EdwardJXLi/llama-release-watcher.git",
    branch: str = "main",
    github_token: str = "",
    discord_webhook_url: str = "",
    git_user_name: str = "windmill-bot",
    git_user_email: str = "windmill-bot@users.noreply.github.com",
):
    headers = {"Accept": "application/vnd.github+json"}
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"

    response = requests.get(
        f"https://api.github.com/repos/{UPSTREAM_REPO}/releases/latest",
        headers=headers,
        timeout=60,
    )
    response.raise_for_status()
    latest_tag = response.json()["tag_name"]

    with tempfile.TemporaryDirectory() as tmp:
        key_path = os.path.join(tmp, "deploy_key")
        with open(key_path, "w", encoding="utf-8") as handle:
            handle.write(deploy_key.strip() + "\n")
        os.chmod(key_path, 0o600)

        env = dict(os.environ)
        env["GIT_SSH_COMMAND"] = (
            f"ssh -i {key_path}"
            f" -o UserKnownHostsFile={tmp}/known_hosts"
            " -o StrictHostKeyChecking=accept-new"
        )

        repo_dir = os.path.join(tmp, "repo")

        def git(*args: str) -> None:
            subprocess.run(["git", "-C", repo_dir, *args], env=env, check=True)

        subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", branch, repo_ssh_url, repo_dir],
            env=env,
            check=True,
        )

        version_path = os.path.join(repo_dir, VERSION_FILE)
        last_tag = None
        if os.path.exists(version_path):
            with open(version_path, encoding="utf-8") as handle:
                last_tag = handle.read().strip() or None

        print(f"Latest upstream tag: {latest_tag}")
        print(f"Last seen tag: {last_tag}")

        if latest_tag == last_tag:
            print("No new release detected.")
            return {"new_release": False, "release_tag": latest_tag}

        print(f"New release detected: {latest_tag}, committing version file.")
        with open(version_path, "w", encoding="utf-8") as handle:
            handle.write(latest_tag + "\n")

        git("config", "user.name", git_user_name)
        git("config", "user.email", git_user_email)
        git("add", VERSION_FILE)
        git("commit", "-m", f"chore: update last seen release version to {latest_tag}")
        git("push", "origin", branch)
        notify_discord(discord_webhook_url, latest_tag, repo_ssh_url, branch)

    return {"new_release": True, "release_tag": latest_tag}
