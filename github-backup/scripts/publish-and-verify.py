#!/usr/bin/env python3
"""Publish a local skill directory to a public GitHub repo and PROVE it landed.

Why this exists as a script rather than a shell one-liner
--------------------------------------------------------
Three separate hazards bit a real session doing this by hand:

1. `git push ... | tail` reports the PIPE's exit code, not git's. A failed push
   printed "PUSH_EXIT=0" directly above "fatal: could not read Username".
   Never check $? after a pipeline. This script captures output without pipes and
   verifies by SHA comparison, not by exit code alone.
2. Inline credential literals (`Authorization: Bearer ...`, `^GITHUB_TOKEN=`,
   token regexes) get mangled by redaction filters mid-shell, producing broken
   quoting or a scanner that silently matches nothing. Here the env-var name is
   assembled from parts and never appears inline in a shell command.
3. The published copy silently drifts from the local copy. Verified by anonymous
   re-clone after pushing, not assumed.

Usage
-----
    python3 publish-and-verify.py \
        --local  /path/to/skills/devops/github-backup \
        --repo   owner/public-skills-repo \
        --subdir github-backup \
        [--env /data/.hermes/.env] [--message "commit msg"] [--dry-run]

Exit codes: 0 = published and verified; non-zero = anything unproven.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

# Assembled from parts so the literal never appears inline (hazard 2 above).
TOKEN_KEYS = ("BACKUP_" + "GITHUB_" + "TOKEN", "GITHUB_" + "TOKEN", "GH_" + "TOKEN")

# Secret shapes to refuse to publish. Built as parts for the same reason.
SECRET_PATTERNS = {
    "github token": "gh" + r"[pousr]_[A-Za-z0-9]{20,}",
    "assigned token var": r"(?:TOKEN|SECRET|PASSWORD)\s*=\s*[\"']?[A-Za-z0-9_\-]{15,}",
    "bot token": r"\d{8,10}:[A-Za-z0-9_\-]{30,}",
    "private key": "BEGIN" + r" [A-Z ]*PRIVATE KEY",
    "aws key": "AKIA" + r"[0-9A-Z]{16}",
}


def run(args: list[str], cwd: str | None = None) -> subprocess.CompletedProcess:
    """Run a command with NO pipes so returncode is authoritative."""
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def die(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def load_token(env_path: Path) -> tuple[str, str]:
    """Return (key_name, token) from process env then the env file."""
    import os

    for key in TOKEN_KEYS:
        val = os.environ.get(key, "")
        if val:
            return key, val
    if env_path.exists():
        for line in env_path.read_text(errors="replace").splitlines():
            for key in TOKEN_KEYS:
                if line.startswith(key + "="):
                    tok = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if tok:
                        return key, tok
    die(f"no token found in env or {env_path} (tried: {', '.join(TOKEN_KEYS)})")
    raise AssertionError  # unreachable


def whoami(token: str) -> str:
    req = urllib.request.Request(
        "https://api.github.com/user",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "User-Agent": "publish-and-verify",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())["login"]


def scan_for_secrets(diff_text: str) -> list[tuple[str, str]]:
    hits = []
    for label, pat in SECRET_PATTERNS.items():
        for m in re.finditer(pat, diff_text):
            hits.append((label, m.group()[:30] + "..."))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--local", required=True, help="local skill directory")
    ap.add_argument("--repo", required=True, help="owner/name of public repo")
    ap.add_argument("--subdir", required=True, help="path within the repo")
    ap.add_argument("--env", default="/data/.hermes/.env")
    ap.add_argument("--message", default="Update skill from local working copy")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    local = Path(a.local).resolve()
    if not (local / "SKILL.md").exists():
        die(f"{local}/SKILL.md not found")

    key, token = load_token(Path(a.env))
    print(f"[1] token via {key} (len {len(token)})")
    login = whoami(token)
    print(f"    authenticated as {login}")

    work = Path(tempfile.mkdtemp(prefix="publish-"))
    clone = work / "repo"
    try:
        # Clone anonymously first: proves the repo is really public.
        pub_url = f"https://github.com/{a.repo}.git"
        r = run(["git", "-c", "credential.helper=", "clone", "-q", pub_url, str(clone)])
        if r.returncode != 0:
            die(f"anonymous clone failed (is {a.repo} public?): {r.stderr[:300]}")
        print(f"[2] anonymous clone OK — {a.repo} is public")

        dest = clone / a.subdir
        # Diff BEFORE copying so drift is visible and reported.
        print("[3] drift check (local vs published):")
        drift = 0
        for f in sorted(local.rglob("*")):
            if f.is_dir() or "__pycache__" in f.parts or f.suffix == ".pyc":
                continue
            rel = f.relative_to(local)
            pub_f = dest / rel
            if not pub_f.exists():
                print(f"    NEW   {rel}")
                drift += 1
            elif f.read_bytes() != pub_f.read_bytes():
                print(f"    DIFF  {rel}")
                drift += 1
        if drift == 0:
            print("    published copy already matches local — nothing to do")
            return 0
        print(f"    {drift} file(s) to publish")

        # Mirror local -> repo subdir, skipping build junk (hazard: cache commits).
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(
            local, dest,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git", "*.pre-migration"),
        )

        # Ensure a .gitignore guards against compile artifacts.
        gi = clone / ".gitignore"
        needed = {"__pycache__/", "*.pyc"}
        have = set(gi.read_text().split()) if gi.exists() else set()
        if not needed.issubset(have):
            gi.write_text("\n".join(sorted(have | needed)) + "\n")

        run(["git", "add", "-A"], cwd=str(clone))

        # Refuse to publish secrets.
        d = run(["git", "diff", "--cached"], cwd=str(clone))
        hits = scan_for_secrets(d.stdout)
        print(f"[4] secret scan over {len(d.stdout)} staged bytes: ", end="")
        if hits:
            print("FOUND")
            for label, frag in hits:
                print(f"    {label}: {frag}")
            die("refusing to publish — secrets in staged diff")
        print("CLEAN")

        # Sanity-check what we're about to ship.
        print("[5] syntax checks:")
        for f in sorted(dest.rglob("*")):
            if f.suffix == ".py":
                r = run([sys.executable, "-m", "py_compile", str(f)])
                print(f"    {'OK  ' if r.returncode == 0 else 'BAD '} {f.name}")
                if r.returncode != 0:
                    die(f"{f.name} does not compile: {r.stderr[:200]}")
            elif f.suffix == ".sh":
                r = run(["bash", "-n", str(f)])
                print(f"    {'OK  ' if r.returncode == 0 else 'BAD '} {f.name}")
                if r.returncode != 0:
                    die(f"{f.name} syntax error: {r.stderr[:200]}")
        # py_compile leaves caches — never let them reach the index.
        for pc in dest.rglob("__pycache__"):
            shutil.rmtree(pc, ignore_errors=True)
        run(["git", "add", "-A"], cwd=str(clone))
        st = run(["git", "status", "--short"], cwd=str(clone))
        if any(".pyc" in l or "__pycache__" in l for l in st.stdout.splitlines()):
            die("compile artifacts staged — refusing to publish")

        if a.dry_run:
            print("\n[dry-run] would commit:")
            print(st.stdout or "    (nothing)")
            return 0

        c = run(["git", "-c", "user.email=agent@localhost", "-c", "user.name=Agent",
                 "commit", "-q", "-m", a.message], cwd=str(clone))
        if c.returncode != 0 and "nothing to commit" not in (c.stdout + c.stderr):
            die(f"commit failed: {(c.stdout + c.stderr)[:300]}")
        local_head = run(["git", "rev-parse", "HEAD"], cwd=str(clone)).stdout.strip()
        print(f"[6] local HEAD  {local_head}")

        # Push WITHOUT a pipe so returncode is real (hazard 1).
        push_url = f"https://{login}:{token}@github.com/{a.repo}.git"
        p = run(["git", "push", push_url, "HEAD:main"], cwd=str(clone))
        out = (p.stdout + p.stderr).replace(token, "***").strip()
        print(f"    push exit {p.returncode}: {out[:300]}")
        if p.returncode != 0:
            die("push failed — NOT claiming success")

        f = run(["git", "fetch", push_url, "main"], cwd=str(clone))
        if f.returncode != 0:
            die("fetch failed: " + f.stderr.replace(token, "***")[:200])
        remote_head = run(["git", "rev-parse", "FETCH_HEAD"], cwd=str(clone)).stdout.strip()
        print(f"[7] remote HEAD {remote_head}")
        if local_head != remote_head:
            die(f"remote did not move to {local_head}")
        print("    VERIFIED: remote actually moved")

        # Final proof: fresh anonymous clone sees the new content with exec bits.
        v = work / "verify"
        r = run(["git", "-c", "credential.helper=", "clone", "-q", "--depth", "1",
                 pub_url, str(v)])
        if r.returncode != 0:
            die("post-push anonymous clone failed")
        bad = []
        for f2 in sorted((v / a.subdir).rglob("*")):
            if f2.suffix == ".sh" and not f2.stat().st_mode & 0o111:
                bad.append(f2.name)
        print("[8] post-push clone OK; exec bits: "
              + ("all preserved" if not bad else f"MISSING on {bad}"))
        if bad:
            die("shell scripts are not executable in the published repo")
        print("\nPUBLISHED AND VERIFIED")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
