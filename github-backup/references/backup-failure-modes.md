# Backup failure modes seen in the field

Concrete incidents with real numbers. Read this when diagnosing a broken backup —
matching a symptom here is faster than reasoning from scratch.

---

## 1. The silent-stale-backup incident (the reason this skill exists)

A course member's hourly agent backup had been failing for weeks while appearing
healthy. Reported by his own agent after investigation:

- The backup repo picked up a **138 MB** `faster-whisper-base` model blob cached
  under the home directory.
- `state.db` had grown to **50–57 MB** and was committed on *every hourly run* —
  dozens of full 50–60 MB snapshots accumulated in history.
- `.git` reached **2.3 GB**.
- GitHub hard-rejects >100 MB (warns >50 MB). The whisper blob tripped the hard
  limit.
- Once the oversized blob was in local history, **every push failed** — but the
  script kept committing locally and retrying, so **446 commits** sat unpushed.
- Nothing was lost locally; the *remote* had been stale for weeks. The user
  believed he was backed up.

**Root cause in the script:** `.gitignore` excluded `caches/` but not `.cache/`
(different pattern), and never excluded `state.db` at all.

**Lessons encoded into this skill:**
- A push failure must exit non-zero and be surfaced, never retried silently.
- Success requires verifying `HEAD == origin/main` after re-fetch. A local commit
  is not a backup.
- Exclusion by pattern list *and* a hard per-file size gate — `.gitignore` alone
  is too easy to get subtly wrong.
- Never `git init` over a live workspace root; mirror into a separate repo dir.

**Why the fix isn't forward-only:** exclusions added later don't help, because old
commits still carry the blob. History must be rebuilt (see SKILL.md "History reset").

---

## 2. The excluded-conversations near-miss

First iteration of this skill excluded `*.db` to prevent exactly the bloat above.
That silently dropped **all conversation history** — the agent's accumulated
context, which is the single thing users most fear losing. Backups would have
reported healthy while losing everything that mattered.

**Resolution:** conversations are exported SQLite → gzipped JSONL instead of being
copied as binary. Measured on a real 9-profile workspace:

| source | result |
|---|---|
| `state.db` 148 MB | 7.0 MB gzipped JSONL |
| whole workspace 4.4 GB | `.git` 52 MB, `conversations/` 18 MB |
| 9 databases | 772 sessions / 22,212 messages in ~12 s |

JSONL is strictly better than committing the DB: it's text (git diffs
incrementally instead of re-committing 50 MB hourly — the original bloat cause)
and it's human-readable, so history is recoverable even without the tooling.

**Generalizable rule:** when excluding a file *type* for size reasons, ask what
irreplaceable data lives in that type and provide an alternate export path for it.
Size-based exclusions are where silent data loss hides.

---

## 3. SQLite column-affinity corruption on restore (counts lie)

The first restore reported `RESTORE COMPLETE`, and **message counts matched
exactly** — 10,954 / 3,896 / 1,654 across three DBs. Content hashes did not.

Cause: the restore script created tables from **hand-written DDL** declaring
`timestamp text`. SQLite applied TEXT affinity and coerced every float timestamp:

```
source  (float): 1780960253.0324667
restored (str) : '1780960253.03247'
```

**1654 of 1654 rows corrupted, invisibly.** Every row count, every session title,
every message body looked perfect.

**Fix:** the export captures each table's original `CREATE TABLE` statement from
`sqlite_master` and the restore replays it, falling back to hand-written DDL only
for legacy exports.

**Two durable lessons:**
1. Never hand-write DDL for a restore target. Carry the source schema.
2. **Row counts are not verification.** Verify by hashing typed row content —
   `repr()` the tuple so a float and its truncated string form hash differently.
   Run `scripts/verify-backup-restore.py`.

---

## 4. Working-tree bloat from transient agent state

Even with DBs excluded, the mirror was 183 MB. Culprits found by walking
`du -sh` down the tree:

- `cron/output/` — **45 MB** of transient job logs
- `models_dev_cache.json` — 3.2 MB, regenerable, per profile
- `gbrain-session-ingest/` — 7.2 MB derived data
- `config.yaml.bak-*` timestamped backup copies

All added to exclusions. **Method worth repeating:** don't guess at exclusions —
run `du -sh <dir>/*  | sort -rh | head` and descend into the largest entries until
the size is explained. Agent workspaces accumulate transient state in
directories whose names don't suggest it.

---

## 5. Gates must be proven to fire

A gate that never fails is indistinguishable from no gate. Both were tested by
deliberately breaking the input:

- **Size gate:** dropped a 60 MB `.csv` (deliberately *not* on the exclusion list)
  into the source. Result: skipped, logged to the skip log, backup still
  succeeded. Confirms a novel oversized file can't reach history.
- **Completeness gate:** pointed the script at an empty workspace root. Result:
  `MISSING from backup: .hermes/config.yaml`, exit 1. Confirms a hollow backup
  can never be recorded as success.
- **Push failure:** moved the remote out from under it. Result: error printed,
  unpushed-commit count and `.git` size reported, exit 1, pointer to the
  self-healing tree.

**Test-design pitfall hit here:** the first completeness-gate test appeared to
pass-through because the override env var was `AGENT_BACKUP_HERMES_ROOT`, not
`HERMES_ROOT` — the script silently used the real default path. When a negative
test *doesn't* fail, verify the test actually applied the bad input before
concluding the gate is broken.
