#!/usr/bin/env python3
"""
GitHub workspace backup bootstrap + watchdog for the hermes-agent Railway template.

Runs as a background process alongside server.py. It does TWO things:

  1. (first boot) Creates the private GitHub backup repo if it doesn't exist,
     and configures git identity on every boot.
  2. (nightly, 01:xx UTC) Checks that backups are actually landing, and sends a
     Telegram alert if they've gone stale.

It deliberately does NOT commit or push. The agent's `github-backup` skill owns
mirroring, exporting conversation history, and pushing:

    https://github.com/pgill/agentsforus-skills

WHY THE SPLIT
-------------
An earlier version of this file ran `git init` inside the live workspace and
pushed it hourly. That committed `state.db` (50-60 MB) on every run, plus any
model cache that landed under HERMES_HOME. Git history grew past GitHub's hard
100 MB per-file limit, every push started failing, and because the loop just
retried silently the backup looked healthy while going stale for weeks.

The skill fixes that by mirroring to a separate directory, exporting
conversations as compressed JSONL instead of committing the database, and
verifying `HEAD == origin/main` after every push. A push failure is an incident,
not something to retry quietly.

This file keeps the two jobs a shipped script is genuinely better at: creating
the repo before the agent needs it, and watching for silence.

WHY A WATCHDOG WHEN THE SKILL SELF-HEALS
----------------------------------------
The skill does handle its own failures — it detects a rejected push, fixes the
cause, and alerts if it can't. But it can only do that while it is running. The
watchdog covers the cases where it isn't:

  * the student never installed the skill, or never asked for hourly backups
  * the cron job was deleted, paused, or never created
  * the agent is wedged, out of credits, or the model provider is down
  * the skill errored before reaching its own alerting code

Those are exactly the "looks fine, is not fine" failures that cost 446 commits
last time. Something outside the agent has to notice silence, and this process is
already running with the Telegram credentials to say so. It is ~40 lines and only
reads a file — a cheap independent check, not a second backup system.

Environment variables:
  BACKUP_GITHUB_TOKEN       GitHub personal access token (repo scope). Required.
  BACKUP_REPO               owner/name of the backup repo (created if absent).
                            Defaults to <github_username>/hermes-backup.
  BACKUP_TELEGRAM_CHAT_ID   Telegram chat ID for stale-backup alerts (optional).
  TELEGRAM_BOT_TOKEN        Telegram bot token — also read from HERMES_HOME/.env.
"""

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/data/.hermes"))

# The skill writes this after every verified push. It is the single source of
# truth for "did a backup actually land", so the watchdog below reads it rather
# than tracking state this process no longer owns.
SKILL_MARKER = HERMES_HOME / "state" / "agent-backup-last-success.json"

# Legacy marker from the old push loop. Only read as a fallback so an existing
# install doesn't alarm on its first night after upgrading.
LEGACY_MARKER = HERMES_HOME / ".backup_last_success"

BOOTSTRAP_MARKER = HERMES_HOME / ".backup_bootstrapped"

POLL_INTERVAL_S = 300       # check every 5 min — fine enough to hit the daily window
VERIFY_HOUR_UTC = 1         # run nightly verify at 01:xx UTC
STALE_THRESHOLD_H = 25      # alert if no successful backup in this many hours

# If NO backup has ever landed, don't wait for the nightly window — that means
# the skill was never installed or its cron job never ran, so the student has
# zero protection right now. Nag them the same day instead of the next morning.
FIRST_BACKUP_GRACE_H = 6


def _env(key: str) -> str:
    val = os.environ.get(key, "")
    if val:
        return val
    env_file = HERMES_HOME / ".env"
    if env_file.exists():
        for line in env_file.read_text(errors="replace").splitlines():
            if line.startswith(f"{key}="):
                return line[len(key) + 1:].strip().strip('"').strip("'")
    return ""


def _github_api(
    path: str,
    token: str,
    method: str = "GET",
    data: dict | None = None,
) -> dict | None:
    url = f"https://api.github.com{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": "hermes-agent-template/2.0",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"[backup] GitHub API {method} {path} → {e.code}: "
              f"{e.read().decode(errors='replace')}", flush=True)
        return None
    except Exception as exc:
        print(f"[backup] GitHub API error: {exc}", flush=True)
        return None


def _configure_git() -> None:
    """Set git identity and branch defaults.

    Must run on EVERY boot, not just first bootstrap: ~/.gitconfig lives in the
    ephemeral container layer and is lost on redeploy, even though HERMES_HOME
    (the /data volume) persists. Without identity, the skill's commits fail with
    "unable to auto-detect email address".
    """
    for args in (
        ("user.email", "hermes-backup@railway.app"),
        ("user.name", "Hermes Backup"),
        # GitHub defaults new repos to main; match it so pushes don't land on
        # an unexpected master branch.
        ("init.defaultBranch", "main"),
    ):
        subprocess.run(["git", "config", "--global", *args],
                       capture_output=True, text=True)


def bootstrap(token: str, repo_name: str) -> bool:
    """Ensure the private backup repo exists. Returns True on success.

    Creates the repo only. It does NOT init a repo in the live workspace, wire a
    remote, or push — the skill owns all of that. Creating the repo here means
    it's ready before the agent's first backup, so the student never has to.
    """
    print(f"[backup] bootstrapping backup → {repo_name}", flush=True)

    user = _github_api("/user", token=token)
    if not user:
        print("[backup] ERROR: GitHub authentication failed. Check that "
              "BACKUP_GITHUB_TOKEN is valid and has 'repo' scope.", flush=True)
        return False
    username = user["login"]

    if "/" not in repo_name:
        repo_name = f"{username}/{repo_name}"
    owner, name = repo_name.split("/", 1)

    existing = _github_api(f"/repos/{owner}/{name}", token=token)
    if existing is None:
        print(f"[backup] creating private repo {repo_name}", flush=True)
        created = _github_api("/user/repos", token=token, method="POST", data={
            "name": name,
            "private": True,
            "description": "Hermes agent workspace backup "
                           "(auto-created by hermes-agent-template)",
            # auto_init omitted on purpose — an empty repo lets the skill push
            # its first commit without hitting a non-fast-forward rejection.
        })
        if not created:
            print("[backup] ERROR: could not create GitHub repo", flush=True)
            return False
        print(f"[backup] created: {created['html_url']}", flush=True)
        time.sleep(2)
    else:
        print(f"[backup] using existing repo: {existing['html_url']}", flush=True)

    # Record the resolved owner/name so the skill (and a human) can see which
    # repo this workspace backs up to without guessing.
    BOOTSTRAP_MARKER.parent.mkdir(parents=True, exist_ok=True)
    BOOTSTRAP_MARKER.write_text(repo_name)

    print("[backup] bootstrap complete. The github-backup skill owns pushing; "
          "this process now only watches for stale backups.", flush=True)
    return True


def _telegram(bot_token: str, chat_id: str, text: str) -> None:
    data = json.dumps({"chat_id": chat_id, "text": text,
                       "parse_mode": "Markdown"}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as exc:
        print(f"[backup] Telegram notify error: {exc}", flush=True)


def _last_success_epoch() -> float | None:
    """Seconds-since-epoch of the last verified backup, or None if never.

    Prefers the skill's JSON marker; falls back to the legacy bare-epoch file so
    upgrading installs don't alarm on their first night.
    """
    if SKILL_MARKER.exists():
        raw = SKILL_MARKER.read_text(errors="replace").strip()
        try:
            ts = json.loads(raw).get("timestamp_utc", "")
            return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
        except Exception:
            print(f"[backup] WARNING: could not parse {SKILL_MARKER}", flush=True)
    if LEGACY_MARKER.exists():
        try:
            return float(LEGACY_MARKER.read_text().strip())
        except ValueError:
            pass
    return None


def verify() -> None:
    """Check backup recency; send a Telegram alert if stale.

    This is the safety net for the failure mode that motivated the rewrite: a
    backup that stops working without anyone noticing.
    """
    last = _last_success_epoch()
    if last is None:
        stale, age_str = True, "never"
    else:
        age_h = (time.time() - last) / 3600
        stale = age_h > STALE_THRESHOLD_H
        age_str = f"{age_h:.1f}h ago"

    if not stale:
        print(f"[backup] verify OK — last backup {age_str}", flush=True)
        return

    print(f"[backup] STALE ({age_str}) — sending alert", flush=True)

    bot_token = _env("TELEGRAM_BOT_TOKEN") or _env("TELEGRAM_TOKEN")
    chat_id = _env("BACKUP_TELEGRAM_CHAT_ID")
    if not (bot_token and chat_id):
        print("[backup] no TELEGRAM_BOT_TOKEN/BACKUP_TELEGRAM_CHAT_ID — "
              "skipping notify", flush=True)
        return

    repo = (BOOTSTRAP_MARKER.read_text().strip()
            if BOOTSTRAP_MARKER.exists() else "your backup repo")
    if last is None:
        detail = ("No backup has completed yet.\n\n"
                  "Ask your agent: *set up hourly backups using the "
                  "github-backup skill*.")
    else:
        detail = (f"Last successful backup to `{repo}`: {age_str}\n\n"
                  "Ask your agent: *check my backups and fix them*.")

    _telegram(bot_token, chat_id, f"⚠️ *Hermes backup alert*\n\n{detail}")


def main() -> None:
    # Identity first — the skill's commits depend on it and the container layer
    # loses it on every redeploy.
    _configure_git()

    token = _env("BACKUP_GITHUB_TOKEN")
    if not token:
        print(
            "[backup] ERROR: BACKUP_GITHUB_TOKEN is not set. "
            "Workspace backups are required — add a GitHub personal access token "
            "(repo scope) as the BACKUP_GITHUB_TOKEN Railway variable and redeploy.",
            flush=True,
        )
        # Retry rather than exit, so adding the variable works without a full
        # redeploy.
        while not token:
            time.sleep(600)
            token = _env("BACKUP_GITHUB_TOKEN")
        print("[backup] BACKUP_GITHUB_TOKEN found — continuing", flush=True)

    repo_name = os.environ.get("BACKUP_REPO", "hermes-backup")

    if not BOOTSTRAP_MARKER.exists():
        if not bootstrap(token, repo_name):
            print("[backup] bootstrap failed — will retry on next container start",
                  flush=True)
            return

    print(f"[backup] watchdog started (nightly verify at "
          f"{VERIFY_HOUR_UTC:02d}:xx UTC). Pushing is handled by the "
          f"github-backup skill.", flush=True)

    last_verify_day: int | None = None

    while True:
        time.sleep(POLL_INTERVAL_S)
        now_utc = datetime.now(timezone.utc)

        due = now_utc.hour == VERIFY_HOUR_UTC

        # Never-backed-up escalation: once the grace period since bootstrap has
        # elapsed with nothing landing, become due on every poll (still deduped
        # to one alert per day) so a student who never installed the skill hears
        # about it on day one instead of tomorrow morning.
        if not due and _last_success_epoch() is None:
            try:
                boot_age_h = (time.time() - BOOTSTRAP_MARKER.stat().st_mtime) / 3600
                due = boot_age_h > FIRST_BACKUP_GRACE_H
            except OSError:
                due = False

        if due and last_verify_day != now_utc.day:
            last_verify_day = now_utc.day
            verify()


if __name__ == "__main__":
    main()
