#!/usr/bin/env bash
# Agent workspace -> private GitHub backup.
#
# Mirrors durable content one-way (live tree -> repo), exports conversation
# history to compressed JSONL, enforces a hard per-file size gate, commits,
# pushes, and VERIFIES the remote actually moved.
#
# Setup: fill the CONFIG block, chmod +x, run once by hand, then schedule hourly.
set -euo pipefail

# ---------------------------- CONFIG ----------------------------------------
# Zero-config on the Railway template: BACKUP_GITHUB_TOKEN and the hermes-backup
# repo already exist, so the defaults below resolve without the student editing
# anything. Override any of them via environment variables.
REPO="${AGENT_BACKUP_REPO:-/data/work/agent-backup}"   # repo working dir (NOT the live tree)
REMOTE_SLUG="${AGENT_BACKUP_SLUG:-${BACKUP_REPO:-}}"   # owner/name; auto-resolved below if bare
ENV_FILE="${AGENT_BACKUP_ENV_FILE:-/data/.hermes/.env}"
STATE_DIR="${AGENT_BACKUP_STATE_DIR:-/data/.hermes/state}"
HERMES_ROOT="${AGENT_BACKUP_HERMES_ROOT:-${HERMES_HOME:-/data/.hermes}}"
MAX_FILE_BYTES=$((40 * 1024 * 1024))                    # skip anything bigger

# Token env var names tried in order. BACKUP_GITHUB_TOKEN is what the Railway
# template already sets, so it comes first.
TOKEN_KEYS=("BACKUP_GITHUB_TOKEN" "GITHUB_TOKEN")

# Live paths to mirror: "SOURCE:DEST_SUBDIR_IN_REPO"
MIRRORS=(
  "${HERMES_ROOT}:.hermes"
)
# ---------------------------------------------------------------------------

MARKER="$STATE_DIR/agent-backup-last-success.json"
SKIPLOG="$STATE_DIR/agent-backup-skipped.log"
DRY_RUN=0
RESET_HISTORY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --reset-history) RESET_HISTORY=1 ;;
  esac
done

log() { printf '[agent-backup] %s\n' "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# NOTE: *.db is excluded from the file mirror on purpose -- SQLite files are huge,
# binary, and re-diff entirely on every write. Conversation history is NOT lost:
# it is exported as compressed JSONL by export_sessions() below. Do not "fix"
# this by adding *.db back in.
EXCLUDES=(
  '.git' '.env' '.env.*' '*.pem' '*.key' 'credentials.json' 'token.json'
  '*.db' '*.db-wal' '*.db-shm' '*.sqlite' '*.sqlite3'
  '.cache' 'caches' 'cache' '__pycache__' 'node_modules' '.venv' 'venv' '.bun'
  'dist' 'build' 'coverage' '.next' '.turbo'
  'logs' '*.log' '*.pid' '*.lock' '*.tmp' '*.swp' '*.swo'
  'models' '*.bin' '*.safetensors' '*.pt' '*.pth' '*.gguf' '*.onnx' '*.ckpt'
  'lsp' 'bin' 'audio_cache' 'image_cache' 'sandboxes' 'home'
  'output' 'models_dev_cache.json' '*.bak-*' 'gbrain-session-ingest'
  '*.zip' '*.tar' '*.tar.gz' '*.tgz' '*.mp4' '*.mov' '*.wav' '*.ogg'
  'request_dump_*.json'
)

get_token() {
  local t k
  # 1) process environment (Railway injects vars directly)
  for k in "${TOKEN_KEYS[@]}"; do
    t="${!k:-}"
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  done
  # 2) the agent's .env file
  if [ -f "$ENV_FILE" ]; then
    for k in "${TOKEN_KEYS[@]}"; do
      t="$(grep -m1 "^${k}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d ' "'\''\r\n' || true)"
      [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    done
  fi
  die "no backup token found (looked for ${TOKEN_KEYS[*]} in env and $ENV_FILE)"
}

# Resolve REMOTE_SLUG to owner/name. Accepts a bare name ("hermes-backup") and
# asks GitHub who the token belongs to. Matches the Railway template's default.
resolve_slug() {
  local token slug login
  slug="${REMOTE_SLUG:-hermes-backup}"
  if [[ "$slug" == */* ]]; then
    REMOTE_SLUG="$slug"
    return 0
  fi
  token="$(get_token)"
  login="$(TOKEN="$token" python3 - <<'PY'
import json, os, urllib.request, urllib.error
req = urllib.request.Request(
    "https://api.github.com/user",
    headers={"Authorization": "Bearer " + os.environ["TOKEN"],
             "Accept": "application/vnd.github+json",
             "User-Agent": "agent-backup"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print(json.load(r).get("login", ""))
except Exception:
    print("")
PY
)"
  [ -n "$login" ] || die "could not resolve GitHub username from token (check the token is valid)"
  REMOTE_SLUG="${login}/${slug}"
  log "resolved backup repo: $REMOTE_SLUG"
}

write_gitignore() {
  local f="$REPO/.gitignore"
  : > "$f"
  for p in "${EXCLUDES[@]}"; do
    [ "$p" = '.git' ] && continue
    printf '%s\n**/%s\n' "$p" "$p" >> "$f"
  done
  # sessions/ JSONL exports are the whole point -- never ignore them
  printf '!sessions-export/\n!sessions-export/**\n' >> "$f"
}

# --- conversation history -----------------------------------------------------
# Every state.db under HERMES_ROOT becomes conversations/<name>.jsonl.gz
# 148 MB SQLite -> ~7 MB gzipped JSONL. Human-readable, diffable, restorable.
export_sessions() {
  EXPORT_ROOT="$HERMES_ROOT" EXPORT_DST="$REPO/conversations" python3 - <<'PY'
import gzip, json, os, pathlib, sqlite3, sys

root = pathlib.Path(os.environ["EXPORT_ROOT"])
dst = pathlib.Path(os.environ["EXPORT_DST"])
dst.mkdir(parents=True, exist_ok=True)

dbs = sorted(p for p in root.rglob("*.db") if ".git" not in p.parts)
if not dbs:
    print("[agent-backup] WARN no state.db found to export", file=sys.stderr)

total_s = total_m = 0
index = []
for db in dbs:
    # name it by its location so multi-profile setups don't collide
    rel = db.relative_to(root).as_posix().replace("/", "__").removesuffix(".db")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        tables = {r[0] for r in con.execute(
            "select name from sqlite_master where type='table'")}
        if "messages" not in tables:
            con.close()
            continue
        mcols = [r[1] for r in con.execute("pragma table_info(messages)")]
        has_sessions = "sessions" in tables
        scols = ([r[1] for r in con.execute("pragma table_info(sessions)")]
                 if has_sessions else [])

        out = dst / f"{rel}.jsonl.gz"
        n_s = n_m = 0
        # Preserve the ORIGINAL CREATE TABLE statements. Restoring into
        # hand-written DDL lets SQLite column affinity silently coerce values
        # (float timestamps -> truncated TEXT). Round-trip fidelity requires
        # the real schema.
        schema = {r[0]: r[1] for r in con.execute(
            "select name, sql from sqlite_master where type='table' "
            "and name in ('sessions','messages') and sql is not null")}
        # mtime=0 => byte-identical output when data is unchanged => no churn commit
        with gzip.GzipFile(filename="", fileobj=open(out, "wb"),
                           mode="wb", compresslevel=9, mtime=0) as gz:
            def emit(obj):
                gz.write((json.dumps(obj, default=str, sort_keys=True,
                                     ensure_ascii=False) + "\n").encode())
            emit({"_type": "schema", "tables": schema})
            if has_sessions:
                for row in con.execute("select * from sessions order by rowid"):
                    emit({"_type": "session", **dict(zip(scols, row))})
                    n_s += 1
            order = "id" if "id" in mcols else "rowid"
            for row in con.execute(f"select * from messages order by {order}"):
                emit({"_type": "message", **dict(zip(mcols, row))})
                n_m += 1
        con.close()
    except sqlite3.Error as e:
        print(f"[agent-backup] WARN could not export {db}: {e}", file=sys.stderr)
        continue

    total_s += n_s
    total_m += n_m
    index.append({"source_db": db.relative_to(root).as_posix(),
                  "export_file": out.name,
                  "sessions": n_s, "messages": n_m,
                  "bytes": out.stat().st_size})

(dst / "INDEX.json").write_text(json.dumps(
    {"note": "Conversation history exported from SQLite to gzipped JSONL. "
             "Restore with restore-agent.sh --apply.",
     "exports": index}, indent=2, sort_keys=True) + "\n")
print(f"[agent-backup] exported {total_s} sessions / {total_m} messages "
      f"from {len(index)} db(s)", file=sys.stderr)
PY
}

# A backup nobody can restore is not a backup. Plant the recovery script and a
# plain-English README at the REPO ROOT on every run, so someone who has lost
# their box and is staring at this repo on github.com can recover without the
# skill, without the agent, and without any prior knowledge.
plant_recovery_kit() {
  local self_dir restore_src
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  restore_src="$self_dir/restore-agent.sh"

  if [ -f "$restore_src" ]; then
    cp "$restore_src" "$REPO/restore-agent.sh"
    chmod +x "$REPO/restore-agent.sh"
  else
    log "WARN restore-agent.sh not found next to this script; recovery kit incomplete"
  fi

  # Snapshot the backup script itself so the repo documents how it was produced.
  cp "${BASH_SOURCE[0]}" "$REPO/agent-backup.sh" 2>/dev/null || true

  RK_SLUG="$REMOTE_SLUG" RK_ROOT="$HERMES_ROOT" RK_DEST="$REPO/RESTORE.md" python3 - <<'PY'
import json, os, pathlib
dest = pathlib.Path(os.environ["RK_DEST"])
slug = os.environ["RK_SLUG"]
root = os.environ["RK_ROOT"]
idx = dest.parent / "conversations" / "INDEX.json"
tot_s = tot_m = 0
if idx.exists():
    d = json.load(open(idx))
    tot_s = sum(e["sessions"] for e in d["exports"])
    tot_m = sum(e["messages"] for e in d["exports"])

dest.write_text(f"""# How to get your agent back

This repo is an automatic backup of an AI agent's workspace. If your server,
Railway instance, or machine is gone, everything you need is here.

**Currently backed up: {tot_s} conversations, {tot_m} messages, plus all skills,
memories, and config.**

## Recover in three steps

    git clone https://github.com/{slug}.git agent-backup
    cd agent-backup
    ./restore-agent.sh                 # shows a plan, writes nothing

Review the plan, then:

    ./restore-agent.sh --apply         # restores for real

Restore target defaults to `{root}`. Override with:

    AGENT_RESTORE_TARGET=/your/path ./restore-agent.sh --apply

## What comes back

- All your **skills** (everything you taught the agent)
- All your **memories**
- Your full **conversation history** (in `conversations/`, as readable JSONL)
- Config, cron jobs, plans, plugins

## What you must re-add yourself

- **API keys and tokens** — these are deliberately NOT backed up. Paste them
  back into your environment variables.
- **OAuth logins** (Google, etc.) — re-authorize once.
- Caches and search indexes rebuild themselves automatically.

## No terminal? No agent?

Your conversation history in `conversations/*.jsonl.gz` is plain text once
unzipped — one JSON object per line. Your skills and memories under
`.hermes/` are plain files you can read or copy by hand, right here in GitHub's
web view. Nothing is locked in a proprietary format.

---
*Generated automatically by agent-backup.sh. Do not edit by hand — this file is
overwritten on every backup.*
""")
PY
}

mirror_tree() {
  MIRROR_SRC="$1" MIRROR_DST="$2" MIRROR_MAX="$MAX_FILE_BYTES" \
  MIRROR_SKIPLOG="$SKIPLOG" MIRROR_EXCLUDES="$(printf '%s\n' "${EXCLUDES[@]}")" \
  python3 - <<'PY'
import fnmatch, os, pathlib, shutil, sys, time

src = pathlib.Path(os.environ["MIRROR_SRC"])
dst = pathlib.Path(os.environ["MIRROR_DST"])
maxb = int(os.environ["MIRROR_MAX"])
skiplog = pathlib.Path(os.environ["MIRROR_SKIPLOG"])
pats = [p for p in os.environ["MIRROR_EXCLUDES"].splitlines() if p]

if not src.exists():
    print(f"[agent-backup] WARN source missing: {src}", file=sys.stderr)
    raise SystemExit(0)

def ignored(name):
    return any(fnmatch.fnmatch(name, p) for p in pats)

skipped = []
if dst.exists():
    shutil.rmtree(dst)
dst.mkdir(parents=True, exist_ok=True)

for root, dirs, files in os.walk(src):
    root_p = pathlib.Path(root)
    rel_root = root_p.relative_to(src)
    dirs[:] = [d for d in dirs if not ignored(d)]
    target_dir = dst / rel_root
    target_dir.mkdir(parents=True, exist_ok=True)
    for f in files:
        if ignored(f):
            continue
        sf = root_p / f
        try:
            if sf.is_symlink():
                os.symlink(os.readlink(sf), target_dir / f)
                continue
            size = sf.stat().st_size
        except OSError:
            continue
        if size > maxb:
            skipped.append(f"{sf} ({size/1048576:.1f} MB)")
            continue
        try:
            shutil.copy2(sf, target_dir / f)
        except OSError as e:
            skipped.append(f"{sf} (copy error: {e})")

for root, dirs, files in os.walk(dst, topdown=False):
    p = pathlib.Path(root)
    if p != dst and not any(p.iterdir()):
        p.rmdir()

if skipped:
    skiplog.parent.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with skiplog.open("a") as fh:
        for s in skipped:
            fh.write(f"{stamp} SKIP {s}\n")
    print(f"[agent-backup] skipped {len(skipped)} oversized/unreadable file(s)",
          file=sys.stderr)
PY
}

size_gate() {
  local big
  big="$(find "$REPO" -path "$REPO/.git" -prune -o -type f -size +40M -print 2>/dev/null | head -5)"
  if [ -n "$big" ]; then
    log "oversized files present after mirror:"
    printf '%s\n' "$big" >&2
    die "size gate tripped - fix EXCLUDES before backing up"
  fi
}

# Fail loudly if the things the user actually cares about are missing.
completeness_gate() {
  local missing=0
  for must in "conversations/INDEX.json" ".hermes/config.yaml" \
              "restore-agent.sh" "RESTORE.md"; do
    [ -e "$REPO/$must" ] || { log "MISSING from backup: $must"; missing=1; }
  done
  for d in skills memories; do
    if [ -d "$HERMES_ROOT/$d" ] && [ ! -d "$REPO/.hermes/$d" ]; then
      log "MISSING from backup: .hermes/$d"; missing=1
    fi
  done
  if ! ls "$REPO"/conversations/*.jsonl.gz >/dev/null 2>&1; then
    log "MISSING from backup: no conversation exports"; missing=1
  fi
  [ "$missing" = 0 ] || die "completeness gate tripped - backup would be incomplete"
}

bootstrap_repo() {
  local token url
  token="$(get_token)"
  url="https://x-access-token:${token}@github.com/${REMOTE_SLUG}.git"
  if [ ! -d "$REPO/.git" ]; then
    log "cloning $REMOTE_SLUG"
    git clone "$url" "$REPO" >/dev/null 2>&1 || { mkdir -p "$REPO"; git -C "$REPO" init -q -b main; }
  fi
  git -C "$REPO" remote set-url origin "$url" 2>/dev/null || git -C "$REPO" remote add origin "$url"
  git -C "$REPO" fetch origin >/dev/null 2>&1 || true
  git -C "$REPO" checkout -q main 2>/dev/null || git -C "$REPO" checkout -q -B main
  git -C "$REPO" pull --rebase --autostash origin main >/dev/null 2>&1 || true
  git -C "$REPO" config user.name  >/dev/null 2>&1 || die "git user.name not set for HOME=$HOME"
  git -C "$REPO" config user.email >/dev/null 2>&1 || die "git user.email not set for HOME=$HOME"
}

write_marker() {
  mkdir -p "$STATE_DIR"
  local head origin ts tmp msgs
  head="$(git -C "$REPO" rev-parse HEAD)"
  origin="$(git -C "$REPO" rev-parse origin/main 2>/dev/null || echo none)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  msgs="$(python3 -c "
import json,sys
try:
    d=json.load(open('$REPO/conversations/INDEX.json'))
    print(sum(e['messages'] for e in d['exports']))
except Exception: print(0)")"
  tmp="$(mktemp)"
  printf '{\n  "timestamp_utc": "%s",\n  "head": "%s",\n  "origin_main": "%s",\n  "remote": "%s",\n  "messages_backed_up": %s,\n  "in_sync": %s\n}\n' \
    "$ts" "$head" "$origin" "$REMOTE_SLUG" "$msgs" \
    "$([ "$head" = "$origin" ] && echo true || echo false)" > "$tmp"
  mv "$tmp" "$MARKER"
}

# The Railway template's backup.py ran `git init` INSIDE the live workspace and
# pushed it to the same hermes-backup repo. Two writers to one remote = force-push
# fights and lost history. Detect that legacy repo and refuse to run until it is
# stood down, rather than silently competing with it.
check_legacy_inplace_repo() {
  local live_git="$HERMES_ROOT/.git"
  [ -d "$live_git" ] || return 0
  local live_remote
  live_remote="$(git -C "$HERMES_ROOT" remote get-url origin 2>/dev/null || true)"
  log "WARNING: the live workspace $HERMES_ROOT is itself a git repo."
  case "$live_remote" in
    *"${REMOTE_SLUG#*/}"*)
      log "It pushes to the SAME backup repo this script targets (${REMOTE_SLUG})."
      log "Refusing to run: two writers to one remote will clobber each other."
      log "Fix: stop the old in-place backup daemon, then either point this"
      log "script at a different repo (AGENT_BACKUP_SLUG=owner/other-repo) or"
      log "remove the legacy repo dir: rm -rf '$live_git'"
      die "legacy in-place backup repo conflicts with this backup"
      ;;
    *)
      log "Its remote ($live_remote) differs from ${REMOTE_SLUG}; continuing."
      log "Note: $live_git is excluded from the mirror, so it won't be committed."
      ;;
  esac
}

# One-time migration for repos that already carry bloat (committed state.db
# snapshots, model blobs) from the legacy in-place backup. Rebuilds the branch as
# a single clean commit and force-pushes. Only safe for a backup-only repo with
# no collaborators -- which hermes-backup is by definition.
reset_history() {
  log "REBUILDING HISTORY: current tree becomes a single fresh commit."
  log "Prior backup *history* will be discarded; current state is preserved."
  local before after
  before="$(du -sh "$REPO/.git" 2>/dev/null | cut -f1 || echo '?')"
  git -C "$REPO" checkout -q --orphan _clean_rebuild
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "agent backup (history rebuilt) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git -C "$REPO" branch -q -D main 2>/dev/null || true
  git -C "$REPO" branch -q -m main
  if ! git -C "$REPO" push -q --force origin main 2>"$STATE_DIR/agent-backup-push.err"; then
    log "FORCE PUSH FAILED:"; cat "$STATE_DIR/agent-backup-push.err" >&2
    die "history rebuild could not be pushed"
  fi
  git -C "$REPO" reflog expire --expire=now --all >/dev/null 2>&1 || true
  git -C "$REPO" gc --prune=now --quiet >/dev/null 2>&1 || true
  after="$(du -sh "$REPO/.git" 2>/dev/null | cut -f1 || echo '?')"
  log "history rebuilt and force-pushed (.git ${before} -> ${after})"
}

# ------------------------------- run ----------------------------------------
resolve_slug
check_legacy_inplace_repo
bootstrap_repo
write_gitignore
for m in "${MIRRORS[@]}"; do
  mirror_tree "${m%%:*}" "$REPO/${m#*:}"
done
export_sessions
plant_recovery_kit
size_gate
completeness_gate

if [ "$DRY_RUN" = 1 ]; then
  log "dry run - would commit:"; git -C "$REPO" add -A -n >/dev/null 2>&1 || true
  git -C "$REPO" status --short | head -20 >&2
  exit 0
fi

if [ "$RESET_HISTORY" = 1 ]; then
  reset_history
  git -C "$REPO" fetch origin >/dev/null 2>&1
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ] \
    || die "force-push reported success but HEAD != origin/main"
  write_marker
  log "backup pushed and verified"
  exit 0
fi

git -C "$REPO" add -A
if git -C "$REPO" diff --cached --quiet; then
  log "no changes"
  write_marker
  exit 0
fi

git -C "$REPO" commit -q -m "agent backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! git -C "$REPO" push origin main >/dev/null 2>"$STATE_DIR/agent-backup-push.err"; then
  log "PUSH FAILED:"; cat "$STATE_DIR/agent-backup-push.err" >&2
  log "unpushed commits: $(git -C "$REPO" rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
  log ".git size: $(du -sh "$REPO/.git" | cut -f1)"
  die "push rejected - consult the github-backup skill self-healing tree"
fi

git -C "$REPO" fetch origin >/dev/null 2>&1
[ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ] \
  || die "push reported success but HEAD != origin/main"

write_marker
log "backup pushed and verified"
