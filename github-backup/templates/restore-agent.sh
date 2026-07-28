#!/usr/bin/env bash
# Restore an agent workspace from its private GitHub backup onto a fresh box.
#
# DRY RUN BY DEFAULT. Pass --apply to actually write.
#
#   ./restore-agent.sh                       # show the plan
#   ./restore-agent.sh --apply               # do it
#
# Rebuilds: config, skills, memories, notes, cron  (file copy)
#           conversation history                   (JSONL.gz -> state.db)
set -euo pipefail

# Self-locating: when this script sits at the root of a cloned backup repo (the
# normal recovery path -- clone the repo, run the script inside it), use that
# repo as the backup source. Falls back to a scratch clone dir otherwise.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SELF_DIR/.hermes" ] || [ -d "$SELF_DIR/conversations" ]; then
  DEFAULT_BACKUP="$SELF_DIR"
else
  DEFAULT_BACKUP="/tmp/agent-backup-restore"
fi

BACKUP="${AGENT_RESTORE_BACKUP:-$DEFAULT_BACKUP}"
REMOTE_SLUG="${AGENT_BACKUP_SLUG:-YOUR_GH_USER/YOUR_BACKUP_REPO}"
HERMES_ROOT="${AGENT_RESTORE_TARGET:-/data/.hermes}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

log() { printf '[restore] %s\n' "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# Only clone when we aren't already sitting in a usable backup tree.
if [ ! -d "$BACKUP/.hermes" ] && [ ! -d "$BACKUP/conversations" ]; then
  log "cloning backup from $REMOTE_SLUG -> $BACKUP"
  if [ "$APPLY" = 1 ]; then
    KEY="GITHUB_TOKEN"
    token="$(grep -m1 "^${KEY}=" "${AGENT_BACKUP_ENV_FILE:-/data/.hermes/.env}" 2>/dev/null | cut -d= -f2- | tr -d ' \r\n' || true)"
    if [ -n "${token:-}" ]; then
      git clone "https://x-access-token:${token}@github.com/${REMOTE_SLUG}.git" "$BACKUP"
    else
      git clone "https://github.com/${REMOTE_SLUG}.git" "$BACKUP"
    fi
  else
    die "backup not present at $BACKUP; re-run with --apply to clone, or clone it manually first"
  fi
fi

[ -d "$BACKUP/.hermes" ] || die "no .hermes tree in backup at $BACKUP"

echo
echo "================ RESTORE PLAN ================"
echo "  from : $BACKUP  ($REMOTE_SLUG)"
echo "  to   : $HERMES_ROOT"
echo
echo "-- files --"
for d in config.yaml skills memories plans plugins cron hooks scripts state workspace; do
  src="$BACKUP/.hermes/$d"
  [ -e "$src" ] || continue
  if [ -d "$src" ]; then
    printf "  %-14s %6s files\n" "$d/" "$(find "$src" -type f | wc -l)"
  else
    printf "  %-14s %6s\n" "$d" "$(du -h "$src" | cut -f1)"
  fi
done
if [ -d "$BACKUP/.hermes/profiles" ]; then
  printf "  %-14s %6s profiles\n" "profiles/" \
    "$(find "$BACKUP/.hermes/profiles" -maxdepth 1 -mindepth 1 -type d | wc -l)"
fi
echo
echo "-- conversation history --"
if [ -f "$BACKUP/conversations/INDEX.json" ]; then
  python3 - "$BACKUP/conversations/INDEX.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tot_s = tot_m = 0
for e in d["exports"]:
    print(f"  {e['source_db']:<48} {e['sessions']:>5} sessions {e['messages']:>7} messages")
    tot_s += e["sessions"]; tot_m += e["messages"]
print(f"  {'TOTAL':<48} {tot_s:>5} sessions {tot_m:>7} messages")
PY
else
  echo "  (none found - conversation history will NOT be restored)"
fi
echo
echo "-- NOT in the backup (you must re-supply these) --"
echo "  .env / API keys / tokens      -> paste back into env vars"
echo "  OAuth credential files        -> re-authorize (Google, etc.)"
echo "  model + package caches        -> re-download automatically on use"
echo "=============================================="
echo

if [ "$APPLY" != 1 ]; then
  log "DRY RUN. Nothing written. Re-run with --apply to restore."
  exit 0
fi

log "restoring files..."
mkdir -p "$HERMES_ROOT"
( cd "$BACKUP/.hermes" && tar cf - . ) | ( cd "$HERMES_ROOT" && tar xf - )

log "rebuilding conversation history..."
RESTORE_SRC="$BACKUP/conversations" RESTORE_ROOT="$HERMES_ROOT" python3 - <<'PY'
import gzip, json, os, pathlib, sqlite3, sys

src = pathlib.Path(os.environ["RESTORE_SRC"])
root = pathlib.Path(os.environ["RESTORE_ROOT"])
idx_path = src / "INDEX.json"
if not idx_path.exists():
    print("[restore] no conversation exports; skipping", file=sys.stderr)
    raise SystemExit(0)

# Fallback DDL only, used when an export predates schema capture. Preferred path
# is the original CREATE TABLE statements carried in the export's _type=schema
# record -- hand-written DDL risks SQLite affinity coercing values (e.g. float
# timestamps truncated into TEXT).
FALLBACK_DDL = {
    "sessions": """create table if not exists sessions (
  id text primary key, title text, created_at text, updated_at text,
  platform text, metadata text)""",
    "messages": """create table if not exists messages (
  id integer primary key autoincrement, session_id text, role text,
  content text, tool_call_id text, tool_calls text, tool_name text,
  timestamp text, token_count integer, finish_reason text, reasoning text,
  reasoning_content text, reasoning_details text, codex_reasoning_items text,
  codex_message_items text, platform_message_id text, observed integer,
  active integer)""",
}

for entry in json.load(open(idx_path))["exports"]:
    export = src / entry["export_file"]
    target = root / entry["source_db"]
    if not export.exists():
        print(f"[restore] WARN missing export {export.name}", file=sys.stderr)
        continue
    if target.exists():
        bak = target.with_suffix(target.suffix + ".pre-restore")
        target.replace(bak)
        print(f"[restore] existing {target.name} moved to {bak.name}", file=sys.stderr)
    target.parent.mkdir(parents=True, exist_ok=True)

    rows_s, rows_m = [], []
    schema = {}
    with gzip.open(export, "rt", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            kind = o.pop("_type")
            if kind == "schema":
                schema = o.get("tables") or {}
            elif kind == "session":
                rows_s.append(o)
            else:
                rows_m.append(o)

    con = sqlite3.connect(target)
    for tbl in ("sessions", "messages"):
        ddl = schema.get(tbl) or FALLBACK_DDL[tbl]
        try:
            con.execute(ddl)
        except sqlite3.Error:
            con.execute(FALLBACK_DDL[tbl])
    for tbl, rows in (("sessions", rows_s), ("messages", rows_m)):
        if not rows:
            continue
        have = {r[1] for r in con.execute(f"pragma table_info({tbl})")}
        cols = [c for c in rows[0] if c in have]
        ph = ",".join("?" * len(cols))
        con.executemany(
            f"insert or replace into {tbl} ({','.join(cols)}) values ({ph})",
            [tuple(r.get(c) for c in cols) for r in rows])
    con.commit()
    con.close()
    print(f"[restore] {target.relative_to(root)}: "
          f"{len(rows_s)} sessions, {len(rows_m)} messages", file=sys.stderr)
PY

echo
log "RESTORE COMPLETE."
log "Next: re-add your API keys/tokens as env vars, then start the agent."
log "Full-text search rebuilds itself on first use."
