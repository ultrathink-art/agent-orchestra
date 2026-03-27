# Agent Orchestra

Multi-agent task orchestration for [Claude Code](https://claude.ai/claude-code) projects. Define agent roles, queue tasks, and let an orchestrator spawn Claude Code agents to complete them autonomously.

**Zero dependencies.** Pure Ruby, YAML file-based queue, works with any Claude Code project.

```
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐
│ agent-task   │────>│  queue.yml   │<────│ agent-orchestrator│
│ (add tasks)  │     │  (YAML file) │     │ (spawns agents)   │
└─────────────┘     └──────────────┘     └────────┬─────────┘
                                                   │
                                          ┌────────▼─────────┐
                                          │  agent-worker     │
                                          │  (runs claude)    │
                                          └────────┬─────────┘
                                                   │
                                          ┌────────▼─────────┐
                                          │  claude --agent   │
                                          │  (does the work)  │
                                          └──────────────────┘
```

## 5-Minute Quickstart

### 1. Install

```bash
git clone https://github.com/ultrathink/agent-orchestra.git
cd agent-orchestra
```

Or copy the `agent-orchestra/` directory into your project.

### 2. Configure

```bash
# Copy example config to your project root
cp agents.yml.example /path/to/your/project/agents.yml
```

Edit `agents.yml` to define your roles:

```yaml
max_concurrent_agents: 3
poll_interval: 60
state_dir: .orchestra
agents_dir: .claude/agents

roles:
  coder:
    description: "Implements features and fixes bugs"
    git_push: true
  qa:
    description: "Reviews code and runs tests"
```

### 3. Create Agent Definitions

Each role needs a `.claude/agents/<role>.md` file in your project:

```bash
mkdir -p .claude/agents

cat > .claude/agents/coder.md << 'EOF'
# You are a Senior Software Engineer

You implement features, fix bugs, and maintain code quality.

## Rules
- Run tests before committing
- Follow existing code patterns
- Write clear commit messages
EOF
```

### 4. Add Your First Task

```bash
cd /path/to/your/project
/path/to/agent-orchestra/bin/agent-task add coder "Fix the login bug" bugfix P0 --ready
```

### 5. Run the Orchestrator

```bash
# One-shot: spawn agents for all ready tasks
/path/to/agent-orchestra/bin/agent-orchestrator

# Or run as daemon (recommended)
/path/to/agent-orchestra/bin/agent-orchestrator --daemon
```

That's it. The orchestrator will claim the task, spawn a Claude Code agent with the `coder` role, and manage completion.

## CLI Reference

### agent-task — Manage the Task Queue

```bash
agent-task add <role> <subject> [type] [priority] [--ready] [--no-chain]
agent-task ready <id>              # Mark pending → ready
agent-task claim <role>            # Claim next ready task
agent-task complete <id> [notes]   # Mark complete
agent-task fail <id> [reason]      # Fail (retries 3x, then permanent)
agent-task cancel <id>             # Cancel
agent-task reset <id>              # Reset claimed → ready
agent-task list [--status S] [--role R]
agent-task show <id>               # Full task details
agent-task status                  # Summary counts
```

### agent-orchestrator — Spawn and Manage Agents

```bash
agent-orchestrator              # Run once
agent-orchestrator --daemon     # Run continuously
agent-orchestrator --status     # Show running agents + queue
agent-orchestrator --dry-run    # Preview (no spawning)
```

### queue-monitor — Health Monitoring

```bash
queue-monitor              # Health check + stale reset
queue-monitor --status     # Queue status counts
queue-monitor --stale      # Reset stale tasks only
queue-monitor --health     # Full health check
```

### company-status — Quick Overview

```bash
company-status             # Active agents, queue, completions
```

## Task Lifecycle

```
pending ──── ready ──── claimed ──── in_progress ──── complete
                │                        │
                │                        └──── failed (retries 3x)
                └──── cancelled
```

- **pending**: Created, not yet ready for work
- **ready**: Available for orchestrator to claim
- **claimed**: Assigned to an agent, about to start
- **in_progress**: Agent actively working
- **complete**: Done (triggers `next_tasks` chain if defined)
- **failed**: 3 failures = permanent. Otherwise auto-retries.
- **cancelled**: Manually cancelled

## Task Chains

Tasks can automatically spawn follow-up tasks on completion:

```bash
# Coder tasks auto-chain to QA by default
agent-task add coder "Add dark mode"
# → Creates: coder task + auto-chains QA review

# Skip auto-chaining
agent-task add coder "Quick fix" --no-chain
```

## Configuration (agents.yml)

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrent_agents` | 3 | Max agents running simultaneously |
| `poll_interval` | 60 | Daemon poll interval (seconds) |
| `max_agent_runtime` | 3600 | Kill stuck agents after (seconds) |
| `state_dir` | `.orchestra` | Where queue + state files live |
| `agents_dir` | `.claude/agents` | Where agent `.md` definitions live |

### Role Options

```yaml
roles:
  coder:
    git_push: true     # Limit to 1 concurrent (prevent deploy conflicts)
    serialize: true    # Limit to 1 concurrent (prevent race conditions)
```

## Adding a New Agent Role

1. Define the role in `agents.yml`:

```yaml
roles:
  docs:
    description: "Writes and maintains documentation"
```

2. Create the agent definition:

```bash
cat > .claude/agents/docs.md << 'EOF'
# You are a Documentation Writer

You write clear, concise documentation for developers.

## Rules
- Use active voice
- Include code examples
- Keep it under 500 words per section
EOF
```

3. Queue a task:

```bash
agent-task add docs "Document the authentication API" --ready
agent-orchestrator
```

## Before vs After

### Before Agent Orchestra (manual)

```bash
# Terminal 1: "Hey Claude, fix the login bug"
claude "Fix the login bug in auth_controller.rb"

# Terminal 2: Wait... check if it's done... run tests manually
bin/rails test

# Terminal 3: "Now review the security implications"
claude "Review the auth changes for security issues"

# You: context-switching between terminals, copy-pasting results
```

### After Agent Orchestra

```bash
# One command to queue work
agent-task add coder "Fix login bug" bugfix P0 --ready

# Orchestrator handles everything
agent-orchestrator --daemon
# → Spawns coder agent
# → Agent fixes bug, runs tests, commits
# → Auto-chains QA review
# → QA agent reviews the fix
# → You check company-status when you're ready
```

## How It Works

1. **YAML Queue**: Tasks stored in `.orchestra/queue.yml`. No database needed.
2. **File Locking**: Concurrent access handled via `flock()` on queue file.
3. **Process Management**: Orchestrator spawns agents via `Process.spawn`, tracks PIDs.
4. **Completion Protocol**: Agents output `TASK_COMPLETE:`, `NEEDS_REVIEW:`, or `BLOCKED:`. Orchestrator parses logs.
5. **Auto-Recovery**: Dead agents detected via PID check. Stale tasks auto-reset after timeout.
6. **Task Chains**: `next_tasks` on a task auto-spawn child tasks on completion.

## Production Lessons

This tool was extracted from a production system that ran 2,500+ agent tasks. Key learnings baked in:

- **3-strike failure**: Tasks retry twice, then permanently fail (prevents infinite loops)
- **0-byte log detection**: Crashed agents that produce no output are marked failed, not auto-completed
- **Serialized roles**: Prevent race conditions from concurrent agents modifying the same files
- **Git-push serialization**: Only 1 deploy-capable agent at a time (prevents overlapping CI/CD)
- **Stuck agent timeout**: Agents killed after `max_agent_runtime` (default 1h)
- **Process-level kill**: Uses `Process.spawn` + `Process.kill`, not Ruby `Timeout` (which can't reliably kill blocking I/O)

## Related Tools

Part of the [Ultrathink Agent Suite](https://ultrathink.art/blog/agent-toolkit-suite):

- **[Agent Architect Kit](https://github.com/ultrathink-art/agent-architect-kit)** — Multi-agent starter kit with role definitions, memory, and process docs
- **[Agent Cerebro](https://github.com/ultrathink-art/agent-cerebro)** — Long-term memory with semantic search for persistent agent knowledge
- **[AgentBrush](https://github.com/ultrathink-art/agentbrush)** — Image editing toolkit for AI agents

Built by an AI-run dev shop. [Read how →](https://ultrathink.art/blog/ai-agent-running-real-business)

## License

MIT
