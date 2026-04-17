# Agent-Agnostic Forge Architecture — Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Forge driveable by any agent, not just Claude Code, by separating agent-neutral specs (core) from agent-specific implementations (adapters).

**Architecture:** Core specs define *what* each role, workflow, and vault contract does in agent-neutral prose. Adapters translate specs into the agent's native primitives (skills, hooks, etc.). The install script orchestrates: core setup first, then adapter-specific wiring.

**Approach:** A (Core Specification + Adapter Implementation) — chosen over shared-skill imports (fragile coupling) and config-driven generation (YAGNI).

---

## 1. Core Spec Structure

New directories under `core/`:

```
core/
  roles/              ← agent-neutral role specs (9 files)
  workflows/          ← entry, checkpoint, exit flows
  vault-contract/     ← file formats, naming, structure rules
  references/         ← vocabulary, lifecycle, wellness-awareness (already exists)
  vault-templates/    ← checkpoint, decision, architecture templates (already exists)
```

### Spec file format

Each spec uses this structure:

```markdown
---
name: {role/workflow name}
type: role | workflow | contract
---

# {Name}

## Responsibility / Purpose
What this role/workflow does — agent-agnostic prose.

## Triggers
When it activates (for roles) or when it runs (for workflows).

## Behavior
Step-by-step description. No agent-specific syntax.
References vault-contract for file operations.

## Adapters

| Agent | File | Last synced |
|-------|------|-------------|
| claude-code | adapters/claude-code/skills/{name}/SKILL.md | YYYY-MM-DD |
```

The Adapters table is the drift-prevention mechanism:
- Editing a spec → check the table, update each listed adapter, bump "Last synced"
- Adding an adapter → register it in the table
- If you can't update an adapter → mark it "out of sync" in the table

### Core spec files to create

**Roles (9):**
- `core/roles/forge-master.md` — session orchestration, Petra persona, delegation
- `core/roles/keeper.md` — decisions, checkpoints, scope monitoring, INDEX
- `core/roles/refiner.md` — friction detection, root cause, rule proposals
- `core/roles/reviewer.md` — plan validation checklist
- `core/roles/impl.md` — implementation execution
- `core/roles/architect.md` — design, tradeoff analysis
- `core/roles/debugger.md` — systematic root cause analysis
- `core/roles/release-manager.md` — verification, commits, PRs
- `core/roles/toolsmith.md` — skill/tool authoring

**Workflows (3):**
- `core/workflows/entry.md` — session start: detect environment, load vault, sync PRs, present context
- `core/workflows/checkpoint.md` — gather state, fold brain dump, write checkpoint, log decisions
- `core/workflows/exit.md` — final checkpoint, session summary, deactivate

**Vault contract (3):**
- `core/vault-contract/structure.md` — directory layout, per-project vs shared, on-demand folders
- `core/vault-contract/naming.md` — file naming conventions (YYYY-MM-DD prefix, slugs, etc.)
- `core/vault-contract/file-formats.md` — frontmatter schema, checkpoint template, decision template

## 2. What belongs where

**Split principle: core says *what*, adapter says *how*.**

| Concern | Core | Adapter |
|---------|------|---------|
| Role behavior | "Keeper logs validated decisions as files" | Write tool, YAML frontmatter, specific paths |
| Checkpoint flow | "Gather branch, items, overwrite file" | Agent tool dispatch with model param, brain dump folding |
| Break enforcement | "Block work after threshold, allow credits through" | PreToolUse hook, emit_deny(), prefs access exception |
| Persona | Vocabulary table, voice rules | Conversation formatting for the agent's output model |
| Vault I/O | File format schemas, naming rules | Agent's file read/write primitives |
| Model tuning | "Routine role / deep reasoning role" | forge.conf MODEL_* keys, Agent tool model param |
| Hooks | Not in core — hooks are agent-specific | adapters/{agent}/hooks/ |
| Status line | Not in core — terminal UI is agent-specific | adapters/{agent}/scripts/ |

**The vault contract is the critical shared interface.** Any adapter that reads/writes the vault correctly can participate in Forge. A Gemini adapter doesn't need Claude's hook system — it needs to write checkpoints in the right format.

## 3. Install script refactor

Current `install.sh` handles everything (core + Claude Code). Refactored flow:

```
install.sh (root)
  1. Prerequisites (git, jq — universal)
  2. Vault path prompt
  3. Write forge.conf
  4. Create vault structure (core)
  5. Copy vault templates and references (core)
  6. Detect/ask which agent:
     - Scan for installed agents (check ~/.claude/, future: gemini CLI, .cursor/)
     - Present detected options, let user pick
     - If only one found, confirm and proceed
  7. Delegate to adapters/{agent}/install-adapter.sh
```

`adapters/claude-code/install-adapter.sh` handles:
- Copy skills to ~/.claude/skills/
- Symlink references
- Copy hooks and scripts
- Merge settings.json (permissions, hooks, statusline)
- Patch vault paths in skill files

Today's users see no change — the script auto-detects Claude Code and proceeds.

## 4. Drift prevention

**Bidirectional sync rule (extends BLUEPRINT):**

> When modifying a core spec, update each adapter listed in its Adapters table. When modifying an adapter's implementation, verify it still matches the core spec.

**Enforcement layers:**
1. **Adapters table** in each spec — visual checklist of what to update
2. **Refiner** catches behavioral drift during sessions — flags as friction
3. **CI check** (future, parked) — automated comparison of spec sync dates vs adapter modification dates. Blocked until a second adapter exists.

## 5. Scope

**In scope:**
- Core spec format with Adapters table
- Core specs for all 9 roles, 3 workflows, vault contract (3 files)
- Refactor install.sh into core setup + adapter delegation
- Move Claude Code-specific install logic to install-adapter.sh
- Extend BLUEPRINT sync rule to be bidirectional

**Not in scope:**
- Building a second adapter (needs Level 1 research first)
- Template rendering or code generation from specs
- CI drift detection automation
- Changes to Claude Code adapter behavior — functionally identical, just reorganized

**Success criteria:**
- A new adapter author can read core specs and implement roles for their agent without reading the Claude Code adapter
- Existing Claude Code behavior is unchanged
- Install script works the same for current users
