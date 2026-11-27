# Agentic ARC

Run a large language model on a UTSA Arc GPU node and use it from VS Code as an agentic
coding assistant — editing files, running commands, and working on your code with the
model and the code on the same machine.

Everything runs inside your own SLURM allocation. No data leaves the cluster, no API keys,
no per-token cost.

> Written for Arc, UTSA's HPC cluster. Should adapt to any SLURM cluster running Open
> OnDemand with an Ollama module.

---

## What you end up with

- VS Code running on a GPU compute node, with your code on the cluster filesystem
- A code-specialized LLM served locally on that node's GPUs
- An agentic extension (Cline, Roo Code, or Kilo Code) that can read your files, write
  changes, and run terminal commands
- One command to start a session, and one file to configure everything

---

## Before you start

- An Arc account with access to a GPU partition
- A few GB of free space in your `/work` directory for model weights
- Roughly 30 minutes for first-time setup

No admin privileges or software install requests are needed. Everything goes in your home
directory.

---

## Why not VS Code Remote-SSH?

The obvious approach — run VS Code on your laptop, connect over SSH to a compute node —
**does not work on Arc**, and it is worth knowing why before you spend an evening on it.

Compute nodes are not reachable from outside the cluster. Their hostnames do not resolve
in public DNS, and inbound SSH is filtered. This is intentional cluster architecture, not
a configuration gap.

Jumping through a login node (`ProxyJump`) does work from a POSIX SSH client, but VS Code
cannot use it:

- Windows OpenSSH mishandles `ProxyCommand` (it runs through `cmd.exe`) and has never
  supported connection multiplexing, so every channel triggers its own Duo prompt
- VS Code's Remote-SSH always invokes the Windows SSH client, and `remote.SSH.path` takes
  an executable path only — you cannot point it at WSL's SSH
- Remote-SSH cannot be installed into a WSL window either; it is pinned local-side

**This approach avoids the problem entirely:** VS Code runs *on* the node, so there is no
connection to establish.

Terminal-only SSH into a node you hold works fine from WSL, Linux, or macOS using
`ProxyJump` through a login node. It just cannot be handed to VS Code.

---

## Install

Clone into your home directory — it is shared storage on Arc, so one copy works from
every node:

```bash
cd ~
git clone <this-repo-url> Agentic-ARC
cd Agentic-ARC
chmod +x SCRIPTS/*.sh
```

Then set your project directory in `config.yaml`:

```yaml
project_root: /work/$USER/my-project
```

`$USER`, `$HOME` and a leading `~/` are expanded, so the default `/work/$USER` works
without editing if your code lives at the top of your work directory.

---

## Setup

### 1. Start a virtual desktop on a GPU node

Go to `portal.arc.utsa.edu` → **Interactive Apps** → **Arc Virtual Desktop**.

Two fields:

| Field | What to enter |
|---|---|
| Number of hours | Up to 72. Start with 1 for testing, 4–8 for real work. |
| Partition | `gpu2v100` is a good default (2 × 32 GB V100S) |

**How GPU count is chosen.** The portal exposes no GPU field — the count comes from SLURM
partition defaults, and the partition name tells you what you get:

| Partition | GPUs | VRAM | Cores |
|---|---|---|---|
| `gpu1v100` | 1 × V100 | 32 GB | 40 |
| `gpu2v100` | 2 × V100S | 64 GB total | 40 |
| `gpu4v100` | 4 × V100 | 128 GB total | 40 |
| `gpu1a100` | 1 × A100 | — | 16 |

Pick the partition that fits your model. GPU nodes are in demand, so don't request four
cards for an 18 GB model.

Launch, wait for the session to start, click through to the desktop, open a terminal.

Sanity check:

```bash
nvidia-smi                      # should list your GPUs
echo $CUDA_VISIBLE_DEVICES      # e.g. 0,1
```

### 2. Install VS Code — once

```bash
~/Agentic-ARC/SCRIPTS/setup_vscode_arc.sh
```

Tests network reachability, downloads the Linux build of VS Code into your home
directory, extracts it, and installs the extensions listed in `config.yaml`.

Idempotent — re-run any time. `--check` reports state without changing anything:

```bash
~/Agentic-ARC/SCRIPTS/setup_vscode_arc.sh --check
```

Extensions persist across sessions, since `~/.vscode/extensions` is in your home
directory.

**If the marketplace is unreachable** from your node, download the `.vsix` for each
extension from the marketplace website on any machine with a browser, copy them into the
directory named by `vsix_dir` in `config.yaml`, and re-run. (On Arc's GPU nodes the
marketplace is reachable, so this is a fallback.)

### 3. Start a session — every time

```bash
~/Agentic-ARC/SCRIPTS/start_ai_session.sh
```

This:

- prints your node, job ID, partition, **walltime remaining**, and per-GPU memory
- starts Ollama in a `screen` session with the environment from `config.yaml`
- waits for it to come up and verifies your models are visible
- preloads the model so your first request isn't slow
- launches VS Code on your project root

Options:

```bash
start_ai_session.sh --status             # report, change nothing
start_ai_session.sh --no-code            # Ollama only
start_ai_session.sh qwen2.5-coder:32b    # a different model
```

### 4. Point the extension at the model

In the extension's settings:

| Setting | Value |
|---|---|
| API Provider | `Ollama` |
| Base URL | `http://127.0.0.1:11434` |
| Model | whatever `default_model` is set to |

Use the IPv4 literal `127.0.0.1`, not `localhost` — Node resolves `localhost` to IPv6
`::1` first while Ollama binds IPv4 only, which surfaces as an opaque `ECONNREFUSED`.

**Smoke test:** ask the agent to run `hostname`. It should return your compute node's
name, confirming its terminal tool calling executes on the node.

**Before opening a real project,** exclude large data directories from the extension's
indexing. Pointing a codebase indexer at multi-gigabyte data files on shared storage will
hang it.

---

## Configuration

Everything lives in `config.yaml` at the repo root. Both scripts read it, so there are no
settings duplicated in code.

The format is a deliberately flat subset of YAML:

```yaml
key: value          # a scalar

key:                # a list
  - item
  - item
```

It is not a full YAML parser — no nested maps, no multi-line strings, no anchors. Flat is
the point: the parser is about forty lines of bash with zero dependencies, and it fails in
obvious ways rather than subtle ones.

### Adding Ollama settings

Any key beginning `ollama_env_` is exported as `OLLAMA_<rest of the name, uppercased>`.
Add a line and the scripts pick it up with no code change:

```yaml
ollama_env_sched_spread: 1      # becomes OLLAMA_SCHED_SPREAD=1
```

A variable already set in your environment wins over the config, so one-off overrides
work:

```bash
OLLAMA_KEEP_ALIVE=5m ~/Agentic-ARC/SCRIPTS/start_ai_session.sh
```

### Config file discovery

Scripts look in order: `$AGENTIC_ARC_CONFIG`, then `config.yaml` beside the repo root
(relative to the script, so it works wherever you cloned it), then
`~/Agentic-ARC/config.yaml`.

---

## Models

Ollama's module sets `OLLAMA_MODELS` to a path under your `/work` directory. Because
`/work` is shared storage, **a model pulled once is available from every node**.

```bash
module load ollama
echo $OLLAMA_MODELS
ollama list
```

To pull a model (needs a running server — `start_ai_session.sh --no-code` will do):

```bash
ollama pull qwen3-coder:latest
```

### Choosing one

| Model | Size | Fits on |
|---|---|---|
| `qwen2.5-coder:7b` | ~4.5 GB | anything |
| `qwen2.5-coder:14b` | ~9 GB | one 32 GB card, comfortably |
| `qwen3-coder:latest` | ~18 GB | one 32 GB card — good default |
| `qwen2.5-coder:32b` | ~19 GB | one 32 GB card |
| `nomic-embed-text` | ~274 MB | embeddings, not chat |

Leave headroom beyond the weights for the KV cache. A model at 80% of a card's VRAM will
run but with little context left.

Agentic extensions lean hard on tool calling, so prefer models known to support it well.
If an agent starts producing malformed tool calls, trying a different model is often
faster than debugging prompts.

Note that V100s are Volta (compute capability 7.0) with **no bf16 support** —
quantizations assuming Ampere or newer may underperform.

---

## Two settings worth understanding

The scripts handle both, but these are the ones that cause confusion when they are wrong.

### Context length

On a multi-GPU node, Ollama sums the visible VRAM and picks an enormous default context:

```
msg="vram-based default context" total_vram="64.0 GiB" default_num_ctx=262144
```

A 256K KV cache alongside your weights will crowd or exceed VRAM, and the symptom looks
like a broken model rather than a bad default. `config.yaml` sets 32768.

### Keep-alive

By default Ollama unloads an idle model after five minutes, so the next request pays a
~9 second reload. `config.yaml` sets `-1` to hold it resident.

That removes reload latency. It does **not** help with the idle-GPU policy below, which
measures utilization rather than memory.

---

## Working with the idle-GPU policy

**Arc terminates GPU jobs after 2 hours of GPU inactivity, measured by utilization.**
Maximum job runtime is 72 hours, but the idle policy is what you will actually hit.

A model sitting loaded in VRAM produces no utilization between requests. Reading code,
writing a function, or stepping away for lunch all look idle to the scheduler.

Please don't generate synthetic GPU load to keep an allocation alive. GPU nodes are a
scarce shared resource, the policy exists because of real demand, and it would show in
utilization logs.

Work with it instead:

- Treat a session as a **focused burst** — a couple of hours of active work, not an
  editor left open all day
- Request realistic walltime; a 72-hour request you abandon after an hour helps nobody
- Make resumption cheap, so losing a session costs minutes (next section)
- For long non-interactive runs, use `sbatch` — batch jobs generate continuous load and
  the idle policy never fires

---

## Making sessions resumable

Since any session can end, the goal is that picking up again costs minutes rather than
re-explaining your whole project.

Keep working state in plain markdown **in your repo**, on the cluster filesystem, and
commit it. No servers, nothing to break, and it survives landing on a different node.

```
your-project/
├── .clinerules              # project rules, auto-injected into every conversation
└── memory-bank/
    ├── activeContext.md     # what you're working on right now, and why
    ├── progress.md          # append-only log of what changed
    ├── systemPatterns.md    # architectural decisions and their reasons
    └── decisions.md         # settled questions, so they aren't relitigated
```

A `.clinerules` worth copying:

```markdown
# Project: <name>

## Current state
<architecture in three or four sentences>

## Conventions
- <style and structural rules>
- Surgical edits only — no full-file rewrites unless asked

## Don't read
data/raw/, outputs/, logs/
```

Two habits make this work:

1. **End each session** by asking the agent to append what changed to `progress.md`.
   Thirty seconds, and it's what makes tomorrow's session start informed.
2. **Commit before your walltime expires.** Every time.

For retrieving knowledge *across* many projects, a vector store with local embeddings
(`nomic-embed-text` runs on the node) is the right tool — but get the markdown layer
working first. It solves most of the problem with none of the operational cost.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ollama list` → `could not connect` | Server not running | `start_ai_session.sh --no-code` |
| Server starts, `{"models":[]}` | `module load ollama` not run **inside** the screen session | Screen starts a fresh shell and inherits nothing. Use the script, which handles it. |
| Extension: `ECONNREFUSED` | Base URL uses `localhost` | Use `http://127.0.0.1:11434` |
| Model loads but is very slow | CPU offload — model too big for VRAM | `ollama ps` shows the CPU/GPU split. Smaller model, or bigger partition. |
| Session dies after ~2 hours | Idle-GPU policy | Expected. See above. |
| `nvidia-smi` finds nothing | Non-GPU partition | Relaunch on a `gpu*` partition |
| `project_root does not exist` | `config.yaml` points somewhere real | Fix `project_root` |
| Job rejected for CPU count | Core counts halved when hyperthreading was disabled | Check with `scontrol show partition <name>` |
| Agent indexing hangs | Pointed at large data files | Exclude data directories from indexing |

### Useful commands

```bash
squeue -u $USER                             # your jobs
squeue -h -j $SLURM_JOB_ID -o %L            # walltime remaining
sinfo -p gpu2v100 -o "%n %t %G"             # what's free on a partition
sacctmgr show assoc user=$USER format=partition,account   # partitions you can use
screen -r ollama                            # attach to the server log
ollama ps                                   # what's loaded, and until when
```

### Diagnosing a failed portal launch

Each session writes a directory under your home:

```
~/ondemand/data/sys/dashboard/batch_connect/sys/bc_desktop/<cluster>/output/<session-uuid>/
```

`output.log` holds session stdout. `job_script_options.json` shows the `sbatch` arguments
the portal built, which is the fastest way to confirm what was actually requested.

---

## Repository layout

```
Agentic-ARC/
├── README.md
├── config.yaml                  # all settings live here
└── SCRIPTS/
    ├── lib_config.sh            # shared config parser and output helpers
    ├── setup_vscode_arc.sh      # one-time: install VS Code + extensions
    └── start_ai_session.sh      # per-session: start Ollama + VS Code
```

`lib_config.sh` is sourced by the other two, not run directly.

---

## Notes and contributions

Verified on Arc in November 2026 with Ollama 0.15.6 and OnDemand 4.0.1 on the `gpu2v100`
partition. Module versions, partition defaults, and policies change — if something here is
stale or wrong on your account, corrections are welcome.

For Arc account and policy questions, go through the UTSA Service Now portal rather than
this repository.

