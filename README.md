# Agents For Us — Skills

Copy-paste abilities for your AI agent. Each folder is one skill: instructions
your agent reads and follows, plus any scripts it needs.

## Available skills

### `github-backup`

Keeps your agent's workspace backed up to your own private GitHub repo, hourly,
and fixes its own sync problems. If it can't fix something, it tells you.

**What it protects:** every skill you've taught your agent, its memories, its
config, and your full conversation history.

**Install it** — paste the prompt from the course into your agent. It works
whether you set up recently or months ago; the agent checks which case you're in
and does the right thing.

---

## How restoring works

Your backup repo carries its own recovery instructions. If your server is ever
gone, open your `hermes-backup` repo on GitHub and read `RESTORE.md` — written
for someone who isn't a developer, and kept current automatically on every
backup.

Recovery is three commands:

```
git clone https://github.com/YOUR-USERNAME/hermes-backup.git
cd hermes-backup
./restore-agent.sh
```

That first run only *shows you a plan* — it writes nothing. Add `--apply` when
you're ready.

**What comes back:** skills, memories, conversation history, config, cron jobs.

**What you re-add yourself:** your API keys and tokens. Those are deliberately
never backed up, so a leaked repo can't leak your credentials.

---

## If you deployed before this skill existed

Older Railway deploys included a `backup.py` daemon that pushed on its own. It
had a bug: it committed your database on every run, which eventually grew the
repo past GitHub's size limit and made pushes fail **silently** — the backup
looked fine while going stale for weeks.

The skill takes over pushing; `backup.py` keeps doing the parts it does well
(creating the repo, and the nightly "your backup is stale" alert). Your agent
handles this changeover for you — it runs a migration script that shows a plan
first and writes nothing until you approve.

New deploys don't have `backup.py` at all, and the same instructions work
unchanged.

---

## A note on trust

Don't take a backup's word for it. Ask your agent to run a restore drill — it
restores to a scratch folder and verifies the recovered conversations match the
originals exactly. That's the difference between believing you have a backup and
knowing it.
