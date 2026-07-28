#!/usr/bin/env python3
"""Stand down the Railway template's legacy in-place backup daemon.

WHY: the template's backup.py runs `git init` inside the live workspace and
pushes that tree to hermes-backup on an hourly loop. The github-backup skill
mirrors to a separate directory and pushes to the same repo. Two writers to one
remote clobber each other, and the legacy path commits state.db (50-60 MB) on
every run, which is what bloats history until GitHub rejects the push.

WHAT THIS DOES (bootstrap is preserved -- repo creation, git identity, the
Telegram stale-alert all stay):
  1. Neuters the hourly push loop in backup.py (backup_now + its scheduler call).
  2. Stops backup.py from running `git init` on the live workspace.
  3. Repairs the .gitignore patterns that let state.db / .cache/ through.
  4. Optionally removes the legacy .git dir from the live workspace.

DRY RUN BY DEFAULT. Pass --apply to write. Every edited file is backed up to
<file>.pre-migration first.

Usage:
    migrate-from-template-backup.py --backup-py /app/backup.py
    migrate-from-template-backup.py --backup-py /app/backup.py --apply
    migrate-from-template-backup.py --backup-py /app/backup.py --apply --remove-legacy-git
"""
import argparse
import pathlib
import re
import shutil
import sys

SENTINEL = "# [github-backup-skill] pushing disabled"

EXTRA_IGNORES = [
    ".cache/", "**/.cache/", "*.db", "*.db-wal", "*.db-shm",
    "*.sqlite", "*.sqlite3", "lsp/", "bin/", "cron/output/",
    "models_dev_cache.json", "*.bin", "*.safetensors", "*.gguf", "*.onnx",
]


def find_backup_py(explicit=None):
    if explicit:
        p = pathlib.Path(explicit)
        return p if p.is_file() else None
    for cand in ("/app/backup.py", "/backup.py", "./backup.py",
                 "/data/backup.py", "/app/scripts/backup.py"):
        p = pathlib.Path(cand)
        if p.is_file():
            return p
    return None


def patch_backup_py(path: pathlib.Path, apply: bool):
    """Disable the push loop and the in-place git init. Returns list of changes."""
    src = path.read_text()
    if SENTINEL in src:
        print(f"  already migrated ({path}) -- no changes needed")
        return []

    changes = []
    out = src

    # 1) Make backup_now() a no-op. Keep the function so any caller still works.
    m = re.search(r"^def backup_now\([^)]*\)[^:]*:\n", out, re.M)
    if m:
        indent = "    "
        stub = (
            m.group(0)
            + f'{indent}"""DISABLED: the github-backup skill owns pushing now."""\n'
            + f"{indent}{SENTINEL}\n"
            + f"{indent}return False\n"
            + f"{indent}# --- original body retained below but unreachable ---\n"
        )
        out = out[:m.start()] + stub + out[m.end():]
        changes.append("backup_now() neutered (returns False immediately)")
    else:
        print("  WARN could not find backup_now() -- inspect manually")

    # 2) Never git init the live workspace.
    before = out
    out = re.sub(
        r'^(\s*)(if not \(HERMES_HOME / "\.git"\)\.exists\(\):\n\s*_git_ok\("init"\))',
        lambda mm: (f'{mm.group(1)}{SENTINEL} -- do not git init the live tree\n'
                    f'{mm.group(1)}if False:\n'
                    f'{mm.group(1)}    pass'),
        out, flags=re.M)
    if out != before:
        changes.append("git init on live workspace disabled")
    else:
        # fall back to commenting any bare _git_ok("init")
        out2 = re.sub(r'^(\s*)_git_ok\("init"\)',
                      lambda mm: f'{mm.group(1)}pass  {SENTINEL} (was: git init)',
                      out, flags=re.M)
        if out2 != out:
            out = out2
            changes.append('_git_ok("init") commented out')

    # 3) Disable the initial add/commit/force-push inside bootstrap().
    before = out
    out = re.sub(r'^(\s*)_git_ok\("push", "--force", "origin", "HEAD:main"\)',
                 lambda mm: f'{mm.group(1)}pass  {SENTINEL} (was: initial force push)',
                 out, flags=re.M)
    if out != before:
        changes.append("initial force-push in bootstrap() disabled")

    # 3b) With `git init` gone, HERMES_HOME is not a repo, so the remote-wiring
    # block below it would raise "not a git repository" and abort bootstrap
    # (taking repo creation and the Telegram alert down with it). That block only
    # existed to serve the now-disabled push, so disable it too.
    before = out
    out = re.sub(
        r'^(\s*)rc, _ = _git\("remote", "get-url", "origin"\)\n'
        r'\s*if rc != 0:\n'
        r'\s*_git_ok\("remote", "add", "origin", remote_url\)\n'
        r'\s*else:\n'
        r'\s*_git_ok\("remote", "set-url", "origin", remote_url\)',
        lambda mm: (f'{mm.group(1)}{SENTINEL} -- live tree is no longer a git repo,\n'
                    f'{mm.group(1)}# so remote wiring here would raise. The skill owns the remote.'),
        out, flags=re.M)
    if out != before:
        changes.append("remote wiring in bootstrap() disabled (would crash without git init)")

    # 3c) The unconditional set-url at the top of backup_now() has the same
    # problem, but backup_now() already returns early, so it is unreachable.

    # 3d) The success log after the disabled push now lies. Correct it.
    before = out
    out = out.replace(
        'print("[backup] initial push succeeded", flush=True)',
        'print("[backup] bootstrap complete; the github-backup skill owns pushing", flush=True)')
    if out != before:
        changes.append("misleading 'initial push succeeded' log corrected")

    # 5) verify() reads MARKER_FILE, which only backup_now() used to update.
    # With pushing disabled, that file goes stale and the nightly check would
    # false-alarm forever. Repoint it at the marker the skill writes, so the
    # template's Telegram alerting keeps working against real backup state.
    before = out
    out = re.sub(
        r'^MARKER_FILE = HERMES_HOME / "\.backup_last_success"$',
        'MARKER_FILE = HERMES_HOME / "state" / "agent-backup-last-success.json"\n'
        f'{SENTINEL} -- repointed at the skill\'s marker so nightly verify\n'
        '# reflects real backup state instead of the dead legacy marker.',
        out, flags=re.M)
    if out != before:
        changes.append("verify() repointed at the skill's success marker "
                       "(prevents nightly false alarms)")

    # The skill's marker is JSON, not a bare epoch. Teach verify() to read both.
    before = out
    out = out.replace(
        "        last = int(MARKER_FILE.read_text().strip())",
        "        _raw = MARKER_FILE.read_text().strip()\n"
        "        if _raw.startswith('{'):\n"
        "            import json as _json, datetime as _dt\n"
        "            _ts = _json.loads(_raw).get('timestamp_utc', '')\n"
        "            last = _dt.datetime.strptime(\n"
        "                _ts, '%Y-%m-%dT%H:%M:%SZ').replace(\n"
        "                tzinfo=_dt.timezone.utc).timestamp()\n"
        "        else:\n"
        "            last = int(_raw)")
    if out != before:
        changes.append("verify() taught to parse the skill's JSON marker")

    # 6) Disable the hourly scheduler call.
    before = out
    out = re.sub(r'^(\s*)if backup_now\(token\):\n(\s*)last_backup = now',
                 lambda mm: (f'{mm.group(1)}{SENTINEL} -- skill handles hourly push\n'
                             f'{mm.group(1)}last_backup = now'),
                 out, flags=re.M)
    if out != before:
        changes.append("hourly push scheduler call disabled")

    if apply and changes:
        shutil.copy2(path, path.with_suffix(path.suffix + ".pre-migration"))
        path.write_text(out)
    return changes


def patch_gitignore(hermes_home: pathlib.Path, apply: bool):
    gi = hermes_home / ".gitignore"
    if not gi.exists():
        return []
    existing = gi.read_text()
    missing = [p for p in EXTRA_IGNORES if p not in existing.split()]
    if not missing:
        print("  .gitignore already covers the bloat patterns")
        return []
    if apply:
        shutil.copy2(gi, gi.with_suffix(".pre-migration"))
        gi.write_text(existing.rstrip("\n")
                      + "\n\n# added by github-backup skill migration\n"
                      + "\n".join(missing) + "\n")
    return [f".gitignore += {len(missing)} patterns: {', '.join(missing[:6])}"
            + ("..." if len(missing) > 6 else "")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backup-py", help="path to the template's backup.py")
    ap.add_argument("--hermes-home", default="/data/.hermes")
    ap.add_argument("--apply", action="store_true", help="actually write changes")
    ap.add_argument("--remove-legacy-git", action="store_true",
                    help="also delete the .git dir inside the live workspace")
    args = ap.parse_args()

    hermes_home = pathlib.Path(args.hermes_home)
    mode = "APPLY" if args.apply else "DRY RUN (nothing will be written)"
    print(f"=== legacy backup migration -- {mode} ===\n")

    bp = find_backup_py(args.backup_py)
    planned = []

    if bp is None:
        print("backup.py: NOT FOUND -- nothing to migrate.")
        print("  (New students' templates ship without it. This is fine.)")
    else:
        print(f"backup.py: {bp}")
        planned += patch_backup_py(bp, args.apply)

    print(f"\n.gitignore: {hermes_home / '.gitignore'}")
    planned += patch_gitignore(hermes_home, args.apply)

    live_git = hermes_home / ".git"
    print(f"\nlegacy repo in live workspace: {live_git} "
          f"({'present' if live_git.exists() else 'absent'})")
    if live_git.exists():
        size = sum(f.stat().st_size for f in live_git.rglob("*") if f.is_file())
        print(f"  size: {size / 1048576:.0f} MB")
        if args.remove_legacy_git:
            if args.apply:
                shutil.rmtree(live_git)
                planned.append(f"removed {live_git}")
            else:
                planned.append(f"would remove {live_git} ({size/1048576:.0f} MB)")
        else:
            print("  left in place. The skill mirrors from a separate dir and "
                  "excludes .git, so this is inert -- but it wastes disk.")
            print("  Pass --remove-legacy-git to reclaim it.")

    print("\n--- planned changes ---" if not args.apply else "\n--- changes made ---")
    if planned:
        for c in planned:
            print("  *", c)
    else:
        print("  (none)")

    if not args.apply:
        print("\nRe-run with --apply to make these changes.")
    else:
        print("\nDone. Originals saved as *.pre-migration.")
        print("Restart the container/daemon so backup.py reloads.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
