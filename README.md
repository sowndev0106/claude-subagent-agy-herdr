# claude-subagent-agy-herdr

A toolkit and agent skills suite enabling **Claude Code** to orchestrate **Antigravity CLI (`agy`)** as worker subagents, managed and visualized through the **`herdr`** terminal multiplexer.

---

## 💡 Operational Philosophy

> **Claude Code = Planner + Manager + Verifier**  
> **Antigravity (`agy`, Gemini 3.8 Flash High) = Fast, cost-effective Worker**

* **Claude Code** handles planning, task breakdown, progress tracking, result verification, and code merging.
* **`agy`** operates independently with high velocity, running with `--dangerously-skip-permissions` to swiftly execute well-scoped instructions.
* **1 Claude Code Session = 1 `herdr` Workspace** (e.g., `#132 Evaluate suggestion engine`).
* **1 Subagent = 1 Tab** inside that workspace (tab label matches job ID: `a-<task>-xxxx`).
* **Source Isolation**: The optional `-W` flag provisions an isolated Git worktree (branch `agy/<id>`), preventing uncommitted changes and conflicts on the main working tree.

---

## 📦 Suite Components

| Skill / Tool | Description | Primary Commands |
|---|---|---|
| **`agy-subagent`** | Delegate scoped tasks to an agy subagent; manage via herdr TUI or headless runner. | `agy-hd start`, `agy-sub`, `agy-ctl` |
| **`agy-parallel`** | Fan-out 2–4 independent tasks concurrently across isolated tabs and worktrees. | `agy-hd fan`, `agy-fan` |
| **`agy-review`** | Solicit an independent read-only second opinion on diffs/code, validated against a JSON schema (`schema.json`). | `agy-sub -R -s schema.json` |
| **`claude-task-id`** | Allocate and maintain a 3-digit task identifier (`#132 ...`) shared across Claude Code and herdr workspaces. | `agy-id claim`, `agy-id show` |
| **`agy-accounts`** | Run agy on several Google accounts (one profile each): hidden login, per-account quota, default account, auto-pick and quota failover for jobs. | `agy-p add`, `agy-p usage`, `agy-p default`, `agy-hd start -u` |
| **`agy-login`** | Log an account in without the agy UI (this machine or a remote one over ssh), re-login, move accounts between machines. | `agy-p add`, `agy-p remote <host> add`, `agy-p relogin`, `agy-p export/import` |
| **`agy-quota`** | Quota left per account (Gemini/Claude, weekly and 5-hour): HTML dashboard, live terminal view, table. | `agy-p dash`, `agy-p top`, `agy-p usage`, `agy-p whoami` |
| **`agy-switch`** | Switch the account: default, current terminal, one running agy-hd job (same conversation), or auto by quota. | `agy-p switch [--auto]`, `agy-p use`, `agy-hd switch` |

Windows: headless runners also ship as PowerShell + CMD wrappers (`agy-sub`, `agy-ctl`, `agy-fan`, `agy-id` `.ps1`/`.cmd`); add the `scripts/` folders to `PATH`.

---

## ⏱️ Health Monitoring & Auto-Recovery (Scheduler)

Subagents can occasionally stall or hit API rate limits (such as Google Antigravity quota 429 / `RESOURCE_EXHAUSTED`). The suite employs a two-tier monitoring architecture:

1. **Systemd User Timer (`agy-hd-tick.timer`)**:
   * Executes `agy-hd tick` every minute independent of the active Claude Code session.
   * Maintains real-time status in `~/.cache/agy-hd/STATUS.tsv` and logs transitions to `events.log`.
   * **Automatic Quota Recovery**: Detects `RESOURCE_EXHAUSTED` (429), gracefully closes the hung process, and resumes the exact conversation via `agy-hd restart <job>` without losing context or restarting from scratch.
2. **Claude Code Cron Check-in**:
   * During async execution (`start -A` or `fan`), Claude Code schedules a 1-minute check-in to query `agy-hd tick --show` and react accordingly:
     * `RUNNING`: Actively working; continue monitoring.
     * `DONE`: Task completed; verify diffs and tests, then close tab (`agy-hd close` or `wt-merge`).
     * `QUOTA`: Automatically undergoing recovery by scheduler.
     * `STOPPED` / `STALL`: Process halted or hung; inspect logs, interrupt, or resume.
     * `BLOCKED`: Awaiting interactive human input.

---

## 👥 Multiple Accounts (`agy-accounts`)

Each Google account is an **agy-p profile** (`~/.agy-profiles/<name>`; `main` is `~/.gemini`) with its own OAuth token.
Skills, plugins, MCP config and **conversations are shared**, so any conversation can be resumed under another account.

```bash
agy-p add                  # prints a login URL; open it, pick the account, then: agy-p code <session> <code>
agy-p ls                   # profiles and emails (* = default)
agy-p usage                # weekly + 5-hour Gemini / Claude quota left per account
agy-p dash                 # visual HTML quota dashboard (opens in the browser)
agy-p default work         # default account for new runs
agy-hd start -u work ...   # pin a job to an account; omit -u to auto-pick
agy-p whoami               # which account this terminal / plain agy uses
agy-p switch --auto        # make the account with the most quota the default
agy-hd switch <job> work   # move a job to another account, same conversation
agy-p remote <host> add    # log in on another machine over ssh (link printed here)
agy-p doctor               # health check
```

* **Auto-pick** (`agy-p pick`, used by `agy-hd start/fan` and `agy-sub` without `-u`): the default profile while it has ≥ 20 % Gemini quota and < 2 open jobs, otherwise the account with the best `quota / (1 + open jobs)`; accounts under 5 % are skipped and profiles sharing an email count once.
* **Quota failover**: when the tick sees `QUOTA`, the job restarts on another account with quota and resumes the same conversation.
* agy's built-in `invoke_subagent` and nested `agy` calls inside a job run on the job's account (a PATH shim pins `--gemini_dir`).
* How it works: agy stores the token in a file only when an SSH variable is set, otherwise in one gnome-keyring entry shared by every profile. agy-p always sets `SSH_CONNECTION` and passes agy's hidden `--gemini_dir` flag. Re-check after `agy update`: `agy-p <new-profile> models` must say "Please sign in".
* Switch the default with `agy-p default`, not `/logout` + `/login` in `~/.gemini`: another running session refreshes and writes the old account back.

---

## 🚀 Installation

### 1. Clone repository
```bash
git clone git@github.com:sowndev0106/claude-subagent-agy-herdr.git
cd claude-subagent-agy-herdr
```

### 2. Run the installer
The installer script links skills to `~/.claude/skills/`, places executable binaries into `~/.local/bin/`, and sets up the systemd user timer:

```bash
./install.sh
```

### 3. Grant permissions in Claude Code
Add the required bash tool executions to `permissions.allow` in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(agy-hd:*)",
      "Bash(agy-sub:*)",
      "Bash(agy-fan:*)",
      "Bash(agy-ctl:*)",
      "Bash(agy-id:*)",
      "Bash(agy-p:*)"
    ]
  }
}
```

---

## 🛠️ Quick Start

### 1. Claim a Task ID for your session
```bash
agy-id claim "Refactor parser module"
# Returns: #133 Refactor parser module
```

### 2. Launch an agy subagent in herdr (with isolated worktree)
```bash
# Launch task in dedicated worktree asynchronously
agy-hd start -n parser -d /path/to/repo -W -f task.md -A

# Inspect live in herdr TUI
herdr --session cas

# Or directly attach to the agent's tab
agy-hd open <job-id>

# Review diff once done
agy-hd wt-diff <job-id>

# Merge changes into current branch and close tab
agy-hd wt-merge <job-id>
```

### 3. Run parallel tasks (`fan-out`)
```bash
# Prepare tasks directory containing individual <task_id>.md files
agy-hd fan -i ./tasks -o ./results -j 3 -d /path/to/repo -W
```

### 4. Independent Code Review with JSON Schema
```bash
git diff main...HEAD > /tmp/diff.patch
agy-sub -R -d /path/to/repo -s "$(cat ~/.claude/skills/agy-review/schema.json)" \
  -p "Review diff at /tmp/diff.patch. Detect logic bugs, race conditions, missing tests."
```

---

## 📂 Repository Structure

```
claude-subagent-agy-herdr/
├── README.md                  # Documentation and architecture guide
├── install.sh                 # Automatic symlinker and systemd service setup
├── .gitignore
├── agy-subagent/              # Core subagent skill
│   ├── SKILL.md
│   ├── REFERENCE.md
│   ├── scripts/
│   │   ├── agy-hd.sh          # Primary runner via herdr multiplexer (TUI)
│   │   ├── agy-sub.sh         # Headless single-job runner
│   │   ├── agy-fan.sh         # Headless parallel runner
│   │   ├── agy-ctl.sh         # Job lifecycle CLI controller
│   │   ├── *.ps1 / *.cmd      # Windows runners (agy-sub, agy-ctl, agy-fan)
│   │   ├── selftest.sh        # Headless automated test suite
│   │   └── selftest-hd.sh     # Herdr integration automated test suite
│   └── systemd/
│       ├── agy-hd-tick.service
│       └── agy-hd-tick.timer  # 1-minute watchdog timer & quota auto-restart
├── agy-parallel/              # Multi-agent fan-out orchestration skill
│   └── SKILL.md
├── agy-review/                # Second-opinion code review skill
│   ├── SKILL.md
│   └── schema.json            # JSON schema validating review findings
├── claude-task-id/            # Session ID & workspace naming skill
│   ├── SKILL.md
│   └── scripts/
│       └── agy-id.sh          # Maps session IDs to #100..#999 task identifiers
├── agy-login/                 # Skill: log in (local / remote), re-login, move accounts
├── agy-quota/                 # Skill: quota dashboard and views
├── agy-switch/                # Skill: switch default / terminal / job account
└── agy-accounts/              # Multiple Google accounts for agy (agy-p and its docs)
    ├── SKILL.md
    └── scripts/
        ├── agy-p.sh           # Profiles: add/ls/usage/default/pick/env/rm, run agy on a profile
        ├── login.py           # Hidden login: drives the agy TUI in a pty, prints the OAuth URL
        ├── dashboard.html     # Template for agy-p dash
        └── shim/agy           # Keeps nested agy calls on the same profile
```
