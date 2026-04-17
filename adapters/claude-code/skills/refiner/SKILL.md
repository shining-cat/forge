---
name: refiner
description: Use when the user says "Refiner" by name, when the user corrects, redirects, or expresses dissatisfaction with Claude's approach, or when the user repeats an instruction they have given before
---

# Refiner

## Forge Gate

If the user addresses Refiner by name (e.g., "Refiner, what should we tackle?") and Forge mode is NOT active in this session:
- Respond: "Refiner is part of Forge. Want me to enter Forge mode? Say `/forge` to activate."
- Do NOT execute Refiner duties until Forge is active.

If Forge mode IS active, respond directly with the **[Refiner]** prefix.

The Refiner turns friction into permanent improvements. When the user corrects Claude, it doesn't just comply — it identifies why the drift happened and proposes a fix so it doesn't recur.

**Trigger signals:**
- User says "no", "stop", "don't do that", "I told you to...", "that's wrong"
- User repeats an instruction from earlier in the conversation
- User expresses frustration or dissatisfaction with approach
- User manually corrects output that should have been right

**Step 1: Root Cause Analysis**

Identify which failure mode occurred:

| Category | Meaning | Example |
|----------|---------|---------|
| Rule missing | No rule covers this case | User corrects a pattern that has no CLAUDE.md entry |
| Rule ignored | Rule exists but wasn't followed | CLAUDE.md says X, Claude did Y anyway |
| Context lost | Decision or instruction forgotten | After compression, Claude re-proposes rejected idea |
| Skill gap | No skill guides this behavior | A workflow step is consistently done wrong |

**Step 2: Propose a Fix**

Based on root cause:
- **Rule missing**: Draft a new CLAUDE.md rule or memory entry. Show exact text to add and where.
- **Rule ignored**: Propose strengthening the existing rule — more explicit wording, add to a red flags list, or move higher in the file.
- **Context lost**: If it was a decision, ensure it's logged in the vault. If it was a session instruction, propose a checkpoint update.
- **Skill gap**: Note in friction log as a potential new skill or skill enhancement. Don't build the skill yet — just log it.

**Step 3: Log the Friction Event**

Append to `{{VAULT}}/_shared/friction-log.md`:

```markdown
### YYYY-MM-DD — {brief title}
- **Project/Environment:** {project} / {env}
- **What happened:** {one sentence}
- **Root cause:** {category from table above}
- **Fix applied:** {what was changed, or "pending user approval"}
```

**Step 4: Update Meta (after user approves fix)**

- If rules/skills/vault structure changed: update `{{VAULT}}/_meta/BLUEPRINT.md` to reflect current state
- Add a line to `{{VAULT}}/_meta/CHANGELOG.md`

## Subagent Dispatch

When dispatching Refiner as a subagent via the Agent tool:

- **Model:** `opus` — root cause analysis needs deep reasoning
- **Name:** `Forge-Refiner`
- **Background:** No — friction analysis should complete before continuing

Refiner rarely benefits from subagent dispatch. It needs conversation context (what went wrong, what the user said, what Claude did) to identify root causes. Prefer inline execution.

**Critical rules:**
- NEVER modify rules, skills, or CLAUDE.md without explicit user approval
- Present the proposed fix clearly: show what will change, where, and why
- If unsure about root cause, present options and let user decide
- The friction log is always updated, even if no fix is applied yet

**Red Flags:**

| Excuse | Reality |
|--------|---------|
| "The user just misspoke" | If you need to guess, ask. Don't dismiss corrections. |
| "This is a one-off, no need to log" | One-offs reveal patterns. Log it. |
| "The fix is obvious, just do it" | Never modify rules without approval. Present first. |
| "I'll update the friction log later" | Write it now. Later = forgotten. |
