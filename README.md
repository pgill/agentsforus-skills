# Agents For Us — Skills

Copy-paste abilities for your AI agent. Each folder is one skill: a set of
instructions your agent reads and follows, plus any scripts it needs.

## Available skills

### `github-backup`

Keeps your agent's workspace backed up to your own private GitHub repo, hourly,
and fixes its own sync problems. If it can't fix something, it tells you.

**What it protects:** every skill you've taught your agent, its memories, its
config, and your full conversation history.

**Install it** — paste this to your agent:

> Install the `github-backup` skill from https://github.com/pgill/agentsforus-skills
> Then set up hourly backups of my workspace. My Railway setup already has a
> backup token and a `hermes-backup` repo, so use those. Run one backup, then run
> a restore drill so I can see my conversations and skills actually come back.
> After that, keep it hourly: fix sync failures yourself, and only message me if
> you genuinely can't.

Your agent handles the rest.

---

## How restoring works

Your backup repo carries its own recovery instructions. If your server is ever
gone, open your `hermes-backup` repo on GitHub and read `RESTORE.md` — it's
written for someone who is not a developer, and it's kept up to date
automatically on every backup.

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

## A note on trust

Don't take a backup's word for it. Ask your agent to run a restore drill — it
will restore to a scratch folder and verify the recovered conversations match
the originals exactly. That's the difference between believing you have a backup
and knowing it.
