---
name: forge-setup-models
description: Ask the user to map available models to all four neutral Forge tiers. Save user-confirmed bindings in the canonical vault catalog.
---

# Forge model setup

Run during first-run onboarding after `VAULT_PATH` is configured, or when the user explicitly requests a remap. Do not discover, rank, benchmark, or assign a tier from a model name. Ask the user to supply model IDs available in their **active runtime** and to choose one model for each of `minimal`, `economy`, `standard`, and `premium`. The same available model may be selected for more than one tier. No tier may be skipped or defaulted.

Use the installed script `skills/forge-setup-models/scripts/forge-setup-models.sh` (or this repo's `core/skills/forge-setup-models/scripts/forge-setup-models.sh`). Set `FORGE_RUNTIME=claude` for Claude Code or `FORGE_RUNTIME=copilot-cli` for Copilot CLI. The script displays the full supplied list for each tier, rejects missing/invalid selections, runs the catalog resolver's `check-coverage` against a temporary candidate, and only then replaces `${VAULT_PATH}/_shared/model-catalog/catalog.json`. **Ownership boundary:** Model setup only edits user-selected tier-to-model catalog bindings. It never writes `MODEL_TIER_<ROLE>` or `MODEL_<ROLE>` keys; role-to-tier policy belongs to Forge core. It never writes `forge.conf` (including `ONBOARDING_COMPLETE`) or creates config backups. Legacy config migration is a separate task, not a step of model setup. If setup fails or the user defers, do not treat mapping as complete.

Manual bindings remain valid until the user changes them, including across sessions and days. System-sourced snapshots retain their 24-hour limit. A mixed-runtime manual catalog preserves other runtime bindings when remapping the active runtime; expired system-sourced catalogs can be manually republished after schema/future-date validation. Other runtime records remain visible but their former system-sourced bindings are inactive until that runtime is manually remapped; they are never silently promoted to permanent active bindings. To verify later, run the installed `scripts/forge-model-catalog.sh check-coverage --snapshot "${VAULT_PATH}/_shared/model-catalog/catalog.json" --binding <runtime>` (or the core CLI directly); it must report all four tiers resolved. No cross-tier fallback occurs at dispatch.

Legacy `setup-models-noninteractive.sh`, `setup-models-batch.py`, and backend `parse|validate|infer|resolve-test` modes are retired with explicit errors: they relied on inferred/default tier writes. Use the interactive script for user-selected mappings.
