---
name: github-backup
description: "Back up an agent's workspace to a private GitHub repo on a schedule, self-heal common sync failures, and alert the user when it can't."
version: 1.0.0
author: Agents For Us
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [devops, backup, github, git, self-healing, disaster-recovery]
---

# GitHub Backup (agent-owned, self-healing)

Use this skill when the user asks you to back up your workspace to GitHub, set up
hourly backups, check whether backups are healthy, fix a broken backup, or restore
from one.

**You own this backup.** There is no external backup script maintained by anyone
else. If it breaks, your job is to diagnose it, fix it if it's safely fixable, and
tell the user plainly if it isn't.

> **Scope note.** This skill is the owner for *agent-owned, self-healing, scheduled
> GitHub backup* — the model where the agent is responsible for its own backup
> health. A separate `workspace-mirroring` skill in the default profile covers
> operator-run Hermes workspace mirroring. If you're setting up a backup that the
> agent must monitor and repair on its own, use this one.

---

## Non-negotiable rules

These exist because the naive approach (`git init` in the home directory, commit
everything hourly) reliably destroys itself within weeks: model caches and SQLite
databases get committed, GitHub hard-rejects anything over 100 MB, pushes start
failing, and hundreds of commits pile up locally while the user believes they're
backed up.

0. **Claim nothing you have not executed.** Every assertion about this skill —
   "conversations are backed up", "restore works", "the migration is safe" — must
   be backed by a real run against real data with real output. The failure mode
   this skill exists to prevent *is* a system that reports success it never
   verified; reproducing that behaviour in your own reporting is the worst
   possible outcome. If you could not run it, say so plainly and name what's
   untested.
1. **Never run `git init` over the live workspace root.** Mirror durable files into
   a separate repo directory. Live tree → repo, one direction only.
2. **Never commit binaries, caches, or databases.** Enforced by a size gate *and*
   an exclusion list, not just `.gitignore`. Belt and suspenders.
3. **Hard size gate before every commit.** Any file over 40 MB is excluded and
   logged. Nothing over 90 MB may ever enter history.
4. **Never commit secrets.** `.env`, tokens, credential JSON, key files.
5. **Never let a push failure be silent.** A failed push is an incident. Attempt
   the documented repairs; if they don't work, alert the user.
6. **A "successful" backup means the remote actually moved.** Verify
   `HEAD == origin/main` after pushing. Local commits prove nothing.
7. **Restore defaults to dry-run.** Writing files back requires explicit `--apply`.
8. **Prove every safety mechanism fires.** A gate, guard, or verifier that has
   only ever been observed passing is unverified. Deliberately break the input —
   empty workspace, oversized file, tampered row, removed remote — and confirm it
   fails loudly with a useful message. This session found real bugs in the size
   gate test, the completeness gate test, and the fidelity verifier by doing this.

---

## What is and isn't in the backup

This is the part users actually care about: *if the box disappears, what comes back?*

**Recovered fully (the "training" the user put in):**
- Agent config (`config.yaml`) and all profile configs
- **Skills** — every custom skill, the accumulated procedural memory
- **Memories** — the persistent memory files
- **Conversation history** — every session and message, exported from SQLite to
  gzipped JSONL under `conversations/`. Includes message content, roles,
  timestamps, tool calls, and reasoning traces.
- Cron job definitions, plans, plugins, hooks, scripts

**Deliberately excluded (and why it's safe):**
- `*.db` SQLite files — excluded from the *file* mirror because they're huge
  binary blobs that re-diff entirely on every write (this is exactly what
  bloated the old script's history). Conversation data is **not lost**: it's
  exported as JSONL instead. A 148 MB `state.db` becomes ~7 MB of gzipped JSONL.
- Full-text search index (`messages_fts*`) — derived data, rebuilds itself from
  restored messages on first use.
- Secrets: `.env`, tokens, OAuth credential files. **The user must re-supply
  these on restore.** Say so explicitly; don't let them discover it mid-outage.
- Model/package caches, logs, cron job *output*, `models_dev_cache.json`,
  `.venv`, `node_modules` — all regenerable.

Never "fix" the `*.db` exclusion by adding databases back into the file mirror.
That reintroduces the original failure. The JSONL export is the mechanism.

### Conversation export/restore fidelity

The export captures each table's **original `CREATE TABLE` statement** and the
restore replays it. This is not optional polish — restoring rows into
hand-written DDL lets SQLite **column affinity silently corrupt data**. A
`timestamp` column declared `text` will coerce float timestamps like
`1780960253.0324667` into the truncated string `'1780960253.03247'`. Counts still
match, so it looks fine. Always verify round-trip fidelity by hashing row
content, not by comparing row counts.

---

## Prove it works before claiming it works

An untested backup is a rumor. When you build, change, or audit a backup, the
deliverable is a **verified restore**, not a successful backup run.

1. Back up the **real workspace**, not a toy fixture. Toy fixtures don't have the
   45 MB of transient cron output or the 148 MB database that break things.
2. Restore into a **clean empty directory**, as if the box were gone.
3. Verify by **content hash**, not row counts —
   `scripts/verify-backup-restore.py --source <live> --restored <fresh>`.
4. **Prove each gate fires** by deliberately feeding it bad input. A gate that has
   never failed is indistinguishable from no gate. See
   `references/backup-failure-modes.md` §5.
5. Report real measured numbers (sessions, messages, sizes, timings). If you
   couldn't run it, say so plainly — never describe a drill you didn't perform.

**Two verification traps, both hit in practice:**
- *Matching counts prove nothing.* 1654/1654 rows matched while every row was
  silently corrupted by column affinity.
- *A negative test that doesn't fail may not have applied its input.* Confirm the
  bad input actually took effect (env var name spelled right, path actually empty)
  before concluding the gate is broken — or worse, that it passed.

State the caveats on scope: local bare repos are not real GitHub, and one machine's
layout is not every machine's. Recommend a real-environment run before shipping to
users.

---

## Reasoning about what to exclude

Exclusions are where silent data loss hides. The instinct that prevents bloat is
the same instinct that deletes the user's history.

- **For every size-based exclusion, ask: what irreplaceable data lives in this file
  type?** If any does, provide an alternate export path (as `*.db` → JSONL does).
  Never exclude a type without answering this.
- **Don't guess at exclusions — measure.** Run
  `du -sh <dir>/* | sort -rh | head` and descend into the largest entries until the
  total is explained. Agent workspaces hide transient bulk in innocuously-named
  directories (`cron/output`, `gbrain-session-ingest`, `*_dev_cache.json`).
- **Derived data should be excluded and rebuilt, not backed up.** Full-text search
  indexes, caches, and compiled output all regenerate. Say so in the restore
  output so absence doesn't read as loss.
- **Prefer text over binary for anything version-controlled.** Text diffs
  incrementally; binaries re-commit in full every run. That difference is the gap
  between a 52 MB repo and a 2.3 GB one.

---

## Restore: never hand-write the target schema

When rebuilding a structured store (SQLite, or any typed destination), **carry the
source schema with the export and replay it.** Hand-written DDL that merely looks
right will silently coerce types — see `references/backup-failure-modes.md` §3 for
the affinity bug that corrupted 100% of rows while every count matched.

Keep hand-written DDL only as a fallback for exports that predate schema capture,
and prefer the captured schema whenever it's present.

---

## One skill, and the recovery kit ships inside the backup

Backup and restore are **one skill**, not two. They share the exclusion list, the
export format, and the schema-fidelity contract — splitting them guarantees they
drift, and a restore that disagrees with its backup is worse than none.

But the skill itself is **not** the recovery path. The skill lives in the
workspace on the box that just died. So every backup run plants a
**self-contained recovery kit at the repo root**:

- `RESTORE.md` — plain-English recovery instructions with live counts ("772
  conversations, 22,324 messages backed up"), rendered on the GitHub repo page
- `restore-agent.sh` — the runnable restore script
- `agent-backup.sh` — a copy of the script that produced the backup

`restore-agent.sh` is **self-locating**: dropped at the root of a cloned backup
repo, it detects the repo it's sitting in and needs zero arguments. Recovery is
`git clone` → `cd` → `./restore-agent.sh`. No skill, no agent, no prior knowledge.

The completeness gate treats a missing `restore-agent.sh` or `RESTORE.md` as a
failed backup. A backup nobody can restore is not a backup.

Corollary: **do not** hand users a separate "restore skill." It would be one more
thing to install, and the one thing they'd be missing at the exact moment they
need it. The repo carries its own instructions.

---

## Coexisting with a pre-existing backup automation

This skill often lands on a machine that **already has** a backup mechanism — a
platform template, a deploy script, a daemon someone else wrote. Assume an
incumbent exists and look for it *before* your first run.

**Two writers to one remote is the failure mode.** If the incumbent ran
`git init` inside the live workspace and pushes to the same repo this skill
targets, both sides will force-push over each other and history will be lost.
Detect it and **refuse to run**, rather than silently competing:

- Check whether the live workspace root is itself a git repo (`$HERMES_ROOT/.git`).
- If so, read its `origin` URL. If it points at the same repo you target, hard-fail
  with the fix spelled out (stand down the old daemon, or point one side at a
  different repo). `templates/agent-backup.sh::check_legacy_inplace_repo` does this.
- If the remote differs, log a warning and continue — the live `.git` is excluded
  from the mirror anyway, so it won't be committed.

**Reviewing the incumbent — fetch and read the real file.** Never advise on a
script from its description. Pull the actual source (GitHub contents API works
without a CLI), read it, then give **line-range-level** keep/remove guidance.

Useful division when the incumbent has good bootstrap logic worth keeping:

- **Keep in the incumbent:** repo creation, git identity applied on every boot
  (container layers are ephemeral — `~/.gitconfig` is lost each redeploy),
  token-wait loops, and any existing alerting/notification path.
- **Remove from the incumbent:** the recurring commit/push loop, and especially
  any `git init` over the live workspace root. One owner for pushing.
- **Audit its `.gitignore` regardless.** An incumbent written before these lessons
  very likely has the classic holes — `caches/` without `.cache/`, and no
  `*.db` exclusion. Both were present in a real template.

### Removing code from the incumbent is an edit to everything downstream

When the incumbent's owner strips its push logic (or you advise them to), **a
removal list is not safe just because each line is individually dead.** Deleting
code orphans whatever depended on the state it produced. Two real bugs, both from a
four-line removal list that looked obviously correct:

- Removing `git init` left the `remote add` below it raising `not a git repository`.
  Bootstrap died *after* creating the remote repo but *before* writing its
  completion marker → retried forever, every boot.
- Removing the only writer of a freshness marker left a nightly reader that
  false-alarmed forever while backups were perfectly healthy. **Nothing trains a
  user to ignore alerts faster than an alert that is always wrong.**

So, for every removal: **ask what read the state it wrote, and what ran immediately
after it.** Then reconstruct the stripped file and *execute* it — don't review the
diff. See `references/authoring-and-testing-notes.md` §6.

Corollary for advising a human engineer: give them the removals **plus** the
consequent removals, and say which are mandatory versus optional. A partial list
produces a broken deploy that looks like your skill's fault.

### Producing the incumbent's replacement: rewrite, don't amputate

Migrating someone else's *installed* file calls for surgical patching (above). But
when you're asked to produce **the canonical replacement** that ships going
forward, do the opposite: **rewrite it clean from the original rather than deleting
lines.** Deletion leaves orphans — that's the whole lesson of the previous section.
A rewrite makes every surviving line intentional, and the resulting file is shorter
than the diff-chain that would have produced it.

Give the replacement a clear, narrow charter. The split that worked:

- **Companion file keeps** what a shipped script does better than an agent:
  create the remote repo before the agent's first run, and apply git identity on
  **every** boot (container layers are ephemeral; `~/.gitconfig` vanishes on each
  redeploy and its absence is the top cause of silent backup failure).
- **Skill takes** mirroring, exporting, pushing, and self-healing — the parts that
  need judgement.
- **Nobody keeps** the recurring push loop or `git init` over the live workspace.

Then make the file defend its own design:

- **Put the rationale in the module docstring**, including the failure it prevents.
  Someone will read this file in six months with no context and "helpfully" restore
  the push loop unless the file argues against it in place.
- **Read the new state marker first, fall back to the legacy one.** An upgrading
  install has no new-format marker yet; without the fallback its first night after
  deploy fires a false stale alert. Handle a corrupt/unparseable marker by warning
  and treating it as unknown — never by raising inside a watchdog.
- **Write alert copy for the actual audience.** For non-technical users, "Check
  Railway logs for details" is a dead end. Tell them what to *say*: "Ask your
  agent: *check my backups and fix them*." An alert that doesn't lead to a fix is
  noise.
- **Record resolved identifiers** (e.g. the resolved `owner/name`) in the marker
  the companion writes, so both the skill and a human can see what this workspace
  backs up to without re-deriving it.

Verify a replacement by **executing** it: assert the *absence* of dangerous calls
as explicitly as the presence of desired ones, and confirm a missing token produces
a clear message and a wait rather than a crash-loop. See
`references/authoring-and-testing-notes.md` §7 for the subprocess-spy harness,
seam testing, and how to drive the real scheduling loop instead of re-implementing
its logic in the test.

#### Why keep a watchdog when this skill self-heals?

Expect to be asked — correctly — whether an external monitor is redundant once the
skill diagnoses and repairs its own failures. Answer honestly and narrowly:

**It is redundant for backup *errors*.** The skill detects a rejected push, fixes
the cause, and escalates when it can't. Do not build a second error-recovery path;
that's duplicated logic that will drift.

**It is not redundant for the skill *not running*.** A self-healing skill can only
heal while it executes. The watchdog covers what the skill structurally cannot
observe about itself:

- the user never installed the skill, or never asked for a schedule
- the scheduled job was deleted, paused, or never created
- the agent is wedged, out of credits, or the model provider is down
- the skill crashed before reaching its own alerting code

That is the same shape as the incident this skill exists to prevent: *looks fine,
is not fine.* Something **outside** the agent has to notice silence. Keep the
watchdog small enough that this is obviously true — ours reads one file and is
~40 lines. If it grows into a second backup implementation, it's wrong.

Frame the tradeoff for the owner rather than deciding unilaterally: cutting it is
legitimate, but then a user who skips the install has zero backups and nothing ever
tells them. Say that plainly and let them choose.

**Escalate the never-backed-up case faster than the stale case.** A nightly-only
check means a user who never installed the skill hears nothing until the next
morning — during which they have no protection at all. Once a grace period since
bootstrap elapses with *no backup ever recorded*, alert the same day (dedupe to one
alert per day). Keep the stale-backup check on the slow cadence; the skill owns that
path already. Make the grace check tolerate a missing bootstrap marker without
raising — a watchdog that crashes is worse than the condition it watches for.

### Expect the incumbent to exist in several shapes at once

Once an upstream owner starts editing the same file, it ships in multiple variants
simultaneously — original, partially-stripped, and absent. **Detect the variant at
runtime** rather than assuming, make each edit conditional, write a sentinel comment
for idempotency, and provide a real no-op path for "file absent." That's what lets a
single user-facing instruction serve every audience instead of branching the docs
per cohort.

Migration tooling belongs in `scripts/`, not in prose instructions. Asking an agent
to hand-edit a user's live daemon from a description is how you break a running
deploy; a dry-run-by-default script with `*.pre-migration` backups is repeatable and
reviewable. `scripts/migrate-from-template-backup.py` is the worked example.

## Zero-config: adopt the environment that already exists

Setup friction is the enemy. Before asking the user for anything, discover what's
already configured:

- **Accept the token under whatever name it already has.** Try a list of candidate
  env var names in priority order (platform-specific name first, generic second),
  and read from **both the process environment and the `.env` file** — injected
  vars never touch the file.
- **Accept a bare repo name and resolve the owner yourself** by asking the API who
  the token belongs to (`GET /user` → `login`). Requiring `owner/name` when you can
  derive `owner` is needless friction.
- **Honor platform path conventions** (`HERMES_HOME`) before falling back to a
  hardcoded default.

The goal: the user pastes one instruction and the script resolves everything else.
Verify by running with *only* the pre-existing variables set and nothing else.

---

## Migrating off the Railway template's backup.py

There are **three** possible states. The migration script detects which and does
the right thing, so one instruction covers every student:

| State | What it looks like | What's needed |
|---|---|---|
| **A. Full legacy** | `backup.py` with `backup_now()`, `git init`, hourly push | Disable all pushing |
| **B. Pre-stripped** | `backup.py` with those already removed upstream | Repair 2 leftovers |
| **C. No file** | New template without `backup.py` | Nothing (clean no-op) |

```
python3 scripts/migrate-from-template-backup.py --backup-py /app/backup.py
python3 scripts/migrate-from-template-backup.py --backup-py /app/backup.py --apply
```

Dry-run by default, idempotent, originals saved as `*.pre-migration`.

### State B is the dangerous one — removing code isn't enough

Stripping `backup_now()`, `git init`, and the push loop from the template leaves
**two live bugs**. Both were found by executing the stripped file, not by reading
it:

1. **`bootstrap()` crashes.** `git init` is gone, so `HERMES_HOME` isn't a repo —
   but the remote-wiring block right below it survives:
   ```python
   rc, _ = _git("remote", "get-url", "origin")
   if rc != 0:
       _git_ok("remote", "add", "origin", remote_url)   # RuntimeError here
   ```
   `_git_ok` raises on failure, so bootstrap dies **after** creating the GitHub
   repo but **before** writing `BOOTSTRAP_MARKER`. It then retries forever on
   every boot. **If you remove `git init`, you must remove the remote wiring
   with it.**

2. **`verify()` false-alarms forever.** `MARKER_FILE` is written once during
   bootstrap and only `backup_now()` ever refreshed it. With pushing gone that
   file freezes, so ~25h after deploy the nightly check fires a stale-backup
   Telegram alert every night — while backups are perfectly healthy. Nothing
   trains a user to ignore alerts faster.

The script fixes both by pointing `MARKER_FILE` at the skill's marker
(`state/agent-backup-last-success.json`) and teaching `verify()` to parse its
JSON. The template's alerting then reflects real backup state. Legacy bare-epoch
markers still parse, and marker writes are made `mkdir`-safe (the `state/` dir
may not exist yet — and one write site sits inside a `try` block, so the fix must
preserve per-site indentation).

### What stays alive

`_configure_git()` on every boot, GitHub repo creation, `verify()` + Telegram
alerting. The skill takes over mirroring, exporting, and pushing. Verified by
executing both migrated files: bootstrap returns True, repo gets created, zero
push/init attempts, fresh marker → silence, 40h-old marker → alert.

Restart the container afterwards so `backup.py` reloads.

### Existing repos carry bloat

An existing `hermes-backup` already contains committed `state.db` snapshots and
possibly model blobs. Exclusions are forward-only — old commits still carry them.
Rebuild history once:

```
./agent-backup.sh --reset-history
```

Current tree becomes a single fresh commit, force-push, then `gc`. Safe because
`hermes-backup` is backup-only with no collaborators. Prior backup *history* is
discarded; current state is fully preserved. Warn the user before force-pushing.

Reclaim the legacy repo's disk (often 1–2 GB) with `--remove-legacy-git`.

---

## First-time setup

1. **Confirm scope with the user.** Default: agent config, skills, memory,
   notes/brain, and any small text-based work directories. Ask before including
   anything else.
2. **Create a private GitHub repo** (e.g. `my-agent-backup`). Private, not public —
   confirm this explicitly.
3. **Get a token.** A fine-grained PAT with Contents: read/write on that one repo.
   Store it in the agent's env file (e.g. `GITHUB_TOKEN`), never in the repo,
   never in the script.
4. **Set git identity** in the environment the schedule will run under:
   `git config --global user.name` / `user.email`. Missing identity is the single
   most common cause of "backup silently did nothing."
5. **Install the script.** Copy `templates/agent-backup.sh` into the agent's
   scripts directory, fill in the config block at the top, `chmod +x`.
6. **Run it once by hand.** Confirm: commit created, push landed,
   `HEAD == origin/main`, and the repo tree contains no `.db`, no caches, no
   `.env`. Confirm `RESTORE.md` and `restore-agent.sh` are at the repo root.
   Check the repo size on GitHub — it should be small (tens of MB).
6b. **Run a restore drill.** Clone the repo to a scratch dir, run
   `./restore-agent.sh` (dry-run), then `--apply` to a throwaway target, and
   verify by content hash. Do this *before* the user needs it.
7. **Schedule it hourly** using the agent's own scheduler (cron tool). Have the
   job report only on failure or on state change, so the user isn't pinged 24
   times a day.
8. **Tell the user what's covered and what isn't**, in one short message.

---

## Hourly run behaviour

Each run:

1. Mirror the in-scope live paths into the repo directory, applying exclusions.
2. Run the size gate. Log anything skipped.
3. `git add -A`. If nothing changed, record success and exit quietly.
4. Commit, push, then verify `HEAD == origin/main`.
5. Write a success marker with timestamp, HEAD sha, and remote URL.
6. On any failure: enter the self-healing path below.

Stay quiet on success. Speak up on failure.

---

## Self-healing decision tree

Diagnose before acting. Run `git -C "$REPO" status --short --branch`,
`git log origin/main..HEAD --oneline | wc -l`, and check `du -sh "$REPO/.git"`.

**Symptom: push rejected, "file exceeds GitHub's file size limit" / "large files detected"**
- A blob is baked into history. Going forward-only exclusions won't help — old
  commits still carry it.
- Fix: add the offending pattern to exclusions and `.gitignore`, then rebuild
  history as a single clean commit (see "History reset" below).
- Safe to do autonomously **only if** the repo is backup-only with no
  collaborators and no other machine pushes to it. Confirm that, then proceed and
  report what you did.

**Symptom: unpushed commit count is large (dozens+) or `.git` is over ~500 MB**
- Pushes have been failing for a while. Treat as the case above: something oversized
  is in history. Find it before resetting:
  `git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | awk '$1=="blob" && $3>40000000' | sort -k3 -n -r | head`
- Report the actual culprit files to the user, don't just silently wipe history.

**Symptom: `! [rejected] ... non-fast-forward` / "fetch first"**
- The remote has commits the local repo doesn't. For a backup-only mirror this
  usually means the repo was reset or edited elsewhere.
- Fix: `git fetch origin && git pull --rebase --autostash origin main`, then push.
- If the rebase conflicts, prefer the live workspace as truth: reset onto
  `origin/main`, re-mirror, commit fresh.

**Symptom: auth failure (403/401, "could not read Username")**
- Token missing, expired, or the remote URL lost its credentials.
- Fix: re-read the token from the env file and `git remote set-url` with it. If the
  token is genuinely expired or lacks scope, **you cannot fix this** — alert the
  user with exactly what to regenerate.

**Symptom: `unable to auto-detect email address (got 'root@...')`**
- Git identity missing in the environment this run used. Scheduled runs and manual
  shells often have different `HOME`s.
- Fix: set identity for the environment the schedule uses, then re-run.

**Symptom: repo has drifted — tracked `.db`, cache dirs, or a secret file**
- Fix: extend exclusions + `.gitignore`, remove from the index, commit. If a
  **secret** was committed, tell the user immediately, rotate advice first, then
  offer history rewrite — never quietly.

**Symptom: nothing changed for many consecutive runs but the workspace is active**
- The mirror scope is probably wrong (pointing at the wrong path). Verify the
  source paths exist and contain the expected recent files.

**Anything not on this list, or any fix that would touch history containing
non-backup data:** stop and alert the user.

---

## History reset (the safe nuke)

Only for a private, backup-only repo with no collaborators, after confirming with
the user (or autonomously if the user has pre-authorized self-healing):

1. Fix `.gitignore` and the script's exclusion list *first*, so the problem can't
   recur.
2. Re-mirror the live tree into the repo dir.
3. Create a fresh orphan branch, commit the current clean tree once, move it to
   `main`, force-push.
4. Verify: push landed, `HEAD == origin/main`, `.git` is small again, no oversized
   blobs, no secrets tracked.
5. Report: what was oversized, what's now excluded, that nothing in the live
   workspace was touched, and that prior backup *history* is gone (current state
   is preserved).

Never force-push a repo that holds anything other than this generated mirror.

---

## Alerting the user

When you can't fix it, send one short message with:
- what broke, in plain language ("GitHub is rejecting the backup because a 138 MB
  model file got picked up")
- what it means for them ("nothing was lost locally, but the GitHub copy has been
  stale since June 3")
- the one thing you need from them ("regenerate the token with Contents write access")
- what you've already tried

No stack traces unless asked. No blame. No burying the ask at the bottom.

### When asked "am I actually covered?", audit — don't reassure

A question like *"can they really get their agents back?"* or *"is conversation
history included?"* is a request for **evidence**, not comfort. Treat it as a
directive to go verify, and answer with measured numbers from a real drill.

- **Enumerate the live workspace before answering.** Don't answer from the
  exclusion list you wrote — inspect what actually exists on disk and where the
  irreplaceable data lives. This is how the excluded-conversations gap was caught.
- **Lead with the gap if you find one.** If your own design had a hole, say so in
  the first sentence and name what would have been lost. Users trust a backup they
  watched you stress-test far more than one you assured them about.
- **Distinguish what's recovered, what's excluded-but-safe (regenerable), and what
  the user must re-supply** (API keys, OAuth re-auth). Surface the re-supply list
  *before* an outage, in the restore plan output — never let them discover it
  mid-recovery.
- **Report bugs you found in your own work**, including ones you already fixed. The
  affinity bug is more reassuring told than hidden, because it demonstrates the
  verification is real.

Never let "the backup ran successfully" stand in for "the data comes back."

---

## Delivering artifacts to the person who ships them

When the owner of the incumbent asks for a replacement file, **hand them the file,
not the file's contents.** Write it to disk and attach it (`MEDIA:/abs/path`) — do
not paste 300 lines into chat and expect them to reassemble it. This was requested
twice in one session; treat "give me X" for any code artifact as "give me a
downloadable X" by default.

Pair the attachment with a short summary that answers only what they need to act:
what the file does now, what was removed, what behaviour changed, and the test
result as a count (`21/21 checks pass`) plus the handful of cases that would worry
them. Put the reasoning in the file's docstring, not the message.

Re-run the full suite after **every** change to a delivered artifact, including a
change you'd call cosmetic, and re-attach. A file the user already downloaded is
stale the moment you edit it — say so explicitly when you send a replacement.

State the outstanding gate every time you hand it over, in one line, at the end. If
the artifact has never been exercised against the real external service, that fact
does not expire because you tested it locally again.

---

## Restore

Full disaster recovery — Railway instance gone, fresh box, nothing but the repo.

1. Clone the backup repo to a scratch directory.
2. Run `restore-agent.sh` from the repo root — **dry-run by default.** It prints
   a plan: file counts per directory, session/message counts per profile, and an
   explicit list of what is *not* in the backup. It self-locates, so no args are
   needed when run from inside the clone.
3. Apply with `--apply` after the user reviews the plan.
4. Existing `state.db` files are moved aside to `*.pre-restore` rather than
   clobbered.
5. Re-supply secrets (API keys, tokens, OAuth re-authorization), then start the
   agent. FTS search rebuilds on first use.

**Verify a restore actually worked** — don't trust "RESTORE COMPLETE":
- Compare session/message counts against the source or the backup INDEX.json.
- Hash message row content (`session_id, role, content, timestamp`) on both sides
  and confirm the digests match. Counts alone hide affinity corruption.
- Confirm skills and memories directories have the expected file counts.
- Spot-read one long user message and confirm it's intact, not truncated.

Run a restore drill *before* the user needs one. An untested backup is a rumor.

---

## Verification checklist

Run this after setup, after any fix, and any time the user asks "is my backup working?"

- [ ] `HEAD == origin/main`
- [ ] Success marker exists and is fresh relative to the schedule
- [ ] `git status --short` is clean
- [ ] No tracked `.db`, `.db-wal`, `.db-shm`, `.env`, cache dirs, or `node_modules`
- [ ] No blob in history over 40 MB
- [ ] `.git` directory is small (tens of MB, not hundreds)
- [ ] Repo is still **private**
- [ ] Hourly schedule exists and is enabled
- [ ] Most recent commit timestamp is within the expected cadence
- [ ] `conversations/INDEX.json` exists and its message count looks right
- [ ] `RESTORE.md` + `restore-agent.sh` present at the repo root
- [ ] A restore drill has been run at least once and verified by content hash

Report results as a short pass/fail list, not prose.

---

## Pitfalls

- **Writing a shell script that contains a secret KEY NAME literal can get the
  line mangled in transit.** Lines like `grep -m1 '^GITHUB_TOKEN=' "$ENV_FILE"`
  passed through a redaction filter came out truncated, producing an unbalanced
  quote and `syntax error near unexpected token` — in a *shipped* script, only
  discovered by running it. Same thing happened writing `.env` fixtures with
  heredocs in `terminal`. **Fix:** use variable indirection so the literal never
  appears inline:
  `local key="GITHUB_TOKEN"; grep -m1 "^${key}=" "$ENV_FILE"`.
  Then always `bash -n script.sh` after writing any shell file that touches
  credentials, before trusting it. Never assume a write landed verbatim.
- **Patching a function header by anchoring on the line above it can eat the
  header.** Two `patch` calls that inserted a new function before `mirror_tree() {`
  consumed the `mirror_tree() {` line itself, leaving an orphaned body. Both times
  `bash -n` caught it. Anchor patches on a unique interior line, and re-run a
  syntax check after every structural edit.
- `.gitignore` pattern gotcha: `caches/` does **not** match `.cache/`. Exclude
  both, plus `**/.cache/`, `*.db*`, `models/`, `*.bin`, `*.safetensors`, `*.pt`,
  `*.gguf`, `*.onnx`.
- `.gitignore` doesn't untrack already-tracked files. Use `git rm --cached`.
- A local commit is not a backup. Only a verified remote update counts.
- Don't hand-edit files inside the repo working copy — the next mirror run
  overwrites them. Edit the live workspace.
- Don't retry a push in a loop without diagnosing. Repeated identical failures
  mean the cause is structural, not transient.
- Don't include large media the user actually wants preserved — that's object
  storage, not git. Tell them so rather than silently dropping it.
- **Verify the file on disk before assuming a write succeeded.** Read it back;
  what got written is not always what was sent.
- **`gh` CLI is often absent. Use the REST API from a written script file.** Don't
  block on a missing CLI, and don't build `curl` commands with an inline
  `Authorization: Bearer` header — those get mangled by redaction filters mid-shell
  (repeated `unexpected EOF while looking for matching quote`). Write a small
  Python file that reads the token from `.env` and uses `urllib.request`, then run
  it. Same root cause as the secret-literal pitfall above; same fix (keep the
  literal out of the command line).
- **Build the token env-var name from parts inside scripts** when a literal keeps
  getting rewritten: `KEY = "GITHUB_" + "TOKEN"`. Reading `.env` line-by-line with
  `startswith(KEY + "=")` avoids regex literals that trip the same filter.
- **Uploading multiple files to GitHub without a local clone:** use the Git Data
  API in sequence — create a blob per file, build one tree with `base_tree` set to
  the current commit's tree, create a commit with the old head as parent, then
  `PATCH` the ref. One atomic commit instead of N contents-API calls. Set mode
  `100755` on `.sh`/`.py` so scripts stay executable, and **verify by anonymous
  clone** (`git -c credential.helper= clone <https url>`) that the repo is really
  public, the files landed, and the exec bits survived.
- **`cd` into a directory you later delete breaks subsequent commands** with
  `getcwd: cannot access parent directories`. After removing a test tree, pass an
  explicit `workdir` or `cd` somewhere stable before the next command.
- **`git init --bare` in a `&&` chain doesn't leave you in the new repo.** Use
  `git init -q --bare /path` then `git -C /path ...` rather than
  `cd dir && git init --bare x.git` followed by commands assuming the new cwd. Also
  set `git -C bare.git symbolic-ref HEAD refs/heads/main` on a test bare repo, or
  clones of it fail with "remote HEAD refers to nonexistent ref."

## Related files

**Templates** (copy these into the agent's scripts dir; keep them side by side —
`agent-backup.sh` copies `restore-agent.sh` from next to itself into the repo):
- `templates/agent-backup.sh` — mirror + JSONL session export + size gate +
  completeness gate + verified push. Flags: `--dry-run`, `--reset-history`.
- `templates/restore-agent.sh` — dry-run-by-default disaster recovery,
  self-locating when run from a cloned backup repo.

**Scripts** (run these; don't hand-write equivalents):
- `scripts/verify-backup-restore.py` — content-hash fidelity check after a restore
  drill: `--source /data/.hermes --restored /tmp/fresh --fts`. Validated to exit 1
  on a single tampered row, not just to pass on clean input.
- `scripts/migrate-from-template-backup.py` — stand down a legacy in-place backup
  daemon. Detects full-legacy / pre-stripped / already-migrated / absent, dry-run by
  default, idempotent, keeps originals as `*.pre-migration`.

**References:**
- `references/backup-failure-modes.md` — real incidents with real numbers: the
  2.3 GB / 446-unpushed-commit silent-stale failure, the excluded-conversations
  near-miss, SQLite affinity corruption, and how each gate was proven to fire.
  **Read this first when diagnosing a broken backup.**
- `references/authoring-and-testing-notes.md` — local bare-repo test harness, the
  credential-redaction write hazard, GitHub Git Data API multi-file upload recipe,
  how to verify a patched live daemon, §6 on migrating a file that upstream is
  also editing, and §7 on validating a clean-rewrite replacement (subprocess-spy
  harness, seam testing, watchdog edge-case matrix). **Read before editing the
  scripts.**

For the *product/curriculum* side of shipping this to students (pre-ship checklist,
cold-drill discipline, how to report confidence boundaries to the creator), see the
`living-course-production` skill and its
`references/student-facing-recovery-artifacts.md`.
