# Model capability catalog

Forge core owns the catalog and stores it at `${VAULT_PATH}/_shared/model-catalog/catalog.json`. When the canonical file is absent, core reads the legacy `${VAULT_PATH}/_shared/capability-snapshot.json` path as a read-only fallback; malformed or stale canonical data fails closed without fallback. Records have opaque identity, declared/public/passive evidence, normalized capabilities, neutral tier (`economy`, `standard`, `premium`), and runtime bindings. Snapshots older than 24 hours, malformed, incompatible, or missing are rejected without probing or overwrite. Resolution is exact-tier, capability-filtered, active-binding-only, and deterministic. `inherit` returns explicitly; there is no cross-tier fallback or cost selection.

Core owns persistence, path resolution, validation, and catalog policy. Adapters only acquire runtime data and dispatch bindings. They do not rank models or infer dispatch IDs. Legacy `MODEL_<ROLE>` values remain readable; migration is backup, idempotent, non-destructive, and leaves unknown vendor values pending.

## Manual publication and migration

A fresh install can publish an explicit manual/runtime input with `forge-model-catalog.sh publish --input FILE`; missing metadata receives current UTC capture metadata, while all supplied records are recursively validated. No probe, network request, or billing data is used. Legacy configuration migration is available through `forge-model-catalog.sh migrate --config PATH` and writes `MODEL_TIER_<ROLE>` plus `forge-model-migration.json`; it never sources config, overwrites existing keys, deletes legacy keys, or replaces the first backup.
