# Shared helper and tool templates

On-demand detail for the Forge session-rule stub; not an entry-time library scan.

## Lookup before building

Before starting a new helper, tool, or task, Petra reads
`${VAULT_PATH}/PERSO/_shared/Templates/INDEX.md` if present. Use the configured
vault, not a checkout-relative path. Lookup is read-only from every project,
including PRO, and remains available in end-user mode.

Offer a relevant match using its summary and when-to-use metadata; read only the
matched README for its contract, wiring, adapt-before-use notes, and provenance.
An offer is not permission to copy or adapt it: let the user choose.
If the library or index is missing, silently skip lookup; do not seed, rebuild,
or suggest maintenance as a side effect. No fit means continue with the task.

## Capture only on request

Capture a new template ONLY when the user asks. The user alone decides
portability/IP; no export-authorization gate or warning is added.

Give Keeper the requested `<area>/<name>`, source files, metadata, and any
explicit `--replace old=new` substitutions. Keeper runs the installed
`forge-template.sh new <area>/<name>`, completes the scaffold's front matter
and contract/wiring/adaptation/provenance sections, then runs
`add <area>/<name> <file>... [--replace old=new]`, `index`, and `check`.
These are authored vault changes: synchronous Keeper dispatch with read-back
verification, never a Petra or Builder inline write. If the vault skeleton is
missing, Keeper seeds it from the packaged `shared-template.md` only as part of
the requested capture. Report failures or defer; do not claim capture succeeded.

## Weekly maintenance

During `/forge-weekly`, Keeper runs `index` then `check` as separate calls;
run `check` even if `index` fails so invalid metadata and unindexed templates
are reported. Verify the regenerated INDEX by reading it back after success.
Missing library, command failure, unavailable Keeper, or failed verification
leaves the wrap incomplete: never mark it done or announce it closed.

Report command outcomes and findings in both modes. Per
`references/maintainer-mode.md`, suppress ambient index/check maintenance nags
and follow-up invitations in end-user mode; lookup and the requested weekly
check still run. Weekly maintenance never captures new templates.
