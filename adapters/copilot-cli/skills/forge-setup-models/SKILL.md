---
name: forge-setup-models
description: Guide user through discovering available models and mapping them to Forge neutral tiers (economy/standard/premium). One-shot setup, idempotent. Saves to canonical catalog at ${VAULT_PATH}/_shared/model-catalog/catalog.json
---

# Forge Model Catalog Setup

Walks users through setting up their model catalog by discovering available models and assigning them to Forge's neutral tiers.

**Use when:**
- First-run Forge setup (onboarding)
- User's org enables new models and catalog needs refresh
- User wants to re-map tier assignments
- Invoked with `/forge-setup-models`

## Flow

### 1. Input Discovery

Prompt user:
```
Paste your available models from {ORG}/settings/copilot/features (one per line, or comma-separated).
Format: model-name [optional: vendor, capability notes]

Example:
claude-opus-5 (Anthropic)
claude-sonnet-5 (Anthropic)
gpt-5.6-luna (OpenAI)
gemini-3.8-flash (Google)
```

Read models from user input or stdin.

### 2. Parse & Infer Vendor

For each model, extract:
- Model ID (canonical, e.g. `claude-opus-5`)
- Inferred vendor (Anthropic / OpenAI / Google / etc.) based on model name pattern
- Inferred capability tier based on naming (e.g. `opus` → premium, `sonnet` → standard, `3.8-flash` → economy)

**Inference rules** (fallback logic):
- Capability model keywords: `opus` / `gpt-5.6` / `luna` / `terra` / `sol` → *premium*
- `sonnet` / `gpt-5.4` / `gpt-5.3` → *standard*
- `haiku` / `flash` / `3.8` → *economy*
- Unknown → ask user

### 3. Interactive Tier Assignment

For each model, present:
```
Model: claude-opus-5 (Anthropic)
Inferred tier: premium
Capabilities: reasoning, extended-thinking, code, analysis

Confirm tier assignment:
  1) economy   2) standard   3) premium   4) skip

Your choice [3]:
```

Capture user's response. Allow override.

### 4. Confirm Dispatch ID

For each selected model, confirm it should be a dispatch_id (defaults to yes):
```
Use claude-opus-5 as active dispatch candidate? [Y/n]
```

### 5. Validate Schema

Build catalog JSON with collected mappings:
- For each model: identity, tier, evidence (captured_at, source: "manual"), bindings (active: true, dispatch_id, captured_at)
- Validate against catalog schema: vendor, tier, evidence array, bindings array
- Catch schema errors before write

### 6. Test Resolve

For each model, call resolve() with the assigned tier:
```
Testing resolve(tier={tier}, bindings={dispatch_id}) for {model}...
  ✓ Resolved to: {dispatch_id}
  ✗ Failed: {error}
```

If any fail, halt and ask user to re-check mappings.

### 7. Write Canonical Catalog

After all validations pass:
```
Writing catalog to ${VAULT_PATH}/_shared/model-catalog/catalog.json...
  {N} models added
  {N} models skipped
✓ Setup complete
```

Update `${VAULT_PATH}/_shared/model-catalog/catalog.json` with full record (schema_version, clock, records).

## Idempotency

- If canonical catalog already exists: prompt user to review and update, or skip
- Records are replaced by dispatch_id (updated, not merged)
- Stale records older than 24h are re-prompted for confirmation

## Error Handling

- Malformed vendor: ask user explicitly
- Unknown tier: ask user to pick from economy/standard/premium
- Schema validation failure: show error, ask user to edit (or skip that model)
- Resolve test failure: show error, suggest re-checking tier assignment

## Success Criteria

- Canonical catalog file written with all user-confirmed models
- All resolve() tests pass
- User can run `forge-model-catalog resolve --role keeper --tier standard` and get a valid dispatch_id

## Notes

- Vendor-agnostic: no GitHub Copilot CLI / Anthropic / OpenAI API calls
- User discovery is manual (copy/paste from org settings) — keeps Forge neutral
- One-shot per user, idempotent if re-run
- Used in Forge onboarding flow after VAULT_PATH is set
