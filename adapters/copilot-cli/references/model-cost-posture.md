# Model cost posture (GitHub Copilot CLI) — provider-native usage

GitHub Copilot CLI binding of the vendor-neutral principle in
[`core/references/model-cost-posture.md`](../../../core/references/model-cost-posture.md).
That file states *why* Forge tiers its models; this one describes Copilot CLI's
user-owned model bindings and provider-native usage reporting. Historical
Anthropic measurements below are context, not Copilot billing evidence.

Load this file (via the `references/model-cost-posture.md` symlink in the forge
skill) when choosing a role tier, when the user asks about cost/model tiering,
or when considering a main-loop model change.

Origin: decision `2026-08-10-model-tiering-cost-posture` (in the forge vault). The
ratios below are **environment- and pricing-specific** — re-measure with
`forge-cost-audit.py` before treating them as ground truth in a new environment.

## Role tiers in Copilot CLI

The main-loop model is selected in Copilot CLI (`/model`); Forge does not
override it. Role tiers (`minimal`, `economy`, `standard`, `premium`, or
`inherit`) are configured with `MODEL_TIER_<ROLE>` in `forge.conf`. The vault
model catalog binds each tier to a Copilot `dispatch_id`, chosen by the user
through `/forge-setup-models`. Forge's Copilot dispatch guidance requires
resolving the configured tier and passing the resulting model explicitly.
Only `inherit` deliberately uses the session model; an unresolved configured
tier blocks that dispatch. See [`subagent-models.md`](subagent-models.md).

The original Claude Code measurement found that an Opus main loop accounted for
~94% of estimated Anthropic cost in one 30-day profile. That is a motivation
for tiering, not a claim about Copilot AI-credit costs or which models a user's
Copilot catalog maps to each tier.

## The four moves, in GitHub Copilot CLI terms

1. **Choose the main-loop model intentionally.** Use Copilot's `/model` for the
   session and `/config model` for a user default. Forge does not choose it for you.

2. **Use role tiers rather than changing the main-loop model to run hard,
   self-contained work.** Resolve each role against the active Copilot catalog;
   the role model is independent of the main loop. Anthropic cache-write
   measurements do not establish a Copilot-specific cost for switching models.

3. **Dispatch heavy churn when it saves context.** Multi-file work can run in
   a fresh subagent context. Trivial edits stay inline; compare actual AI-credit
   usage rather than assuming the Claude pricing profile transfers to Copilot.

4. **Keep resident context lean.** Large persistent instructions and entry
   reads add context overhead on every turn, regardless of role mapping.

## Measuring your own profile

The Anthropic ratios above are historical and do not describe Copilot billing.
The Copilot adapter's audit defaults to all locally recorded Copilot CLI
sessions (**not Forge-project-only**, but not an account-wide billing total
across devices or other Copilot clients). With `--provider both`, it includes
local Claude logs and keeps Copilot AI credits and Anthropic estimated USD
separate:

```bash
"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-cost-audit.py"                                # Copilot CLI sessions by default
"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-cost-audit.py" --provider both                # both providers, separate totals
"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-cost-audit.py" --provider copilot --days 30    # all locally recorded CLI sessions
"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-cost-audit.py" --provider anthropic --cache-composition
```

Use `--copilot-db` to select a different Copilot `session-store.db`, or `--root`
to select a different Claude project-log directory. The audit reads the Copilot
database without modifying it. Its AI credits are derived from locally recorded
nano-AI units, not an account billing/quota API; use `/usage` for current-session
usage. `--cache-composition` applies only to the Anthropic pricing model and
requires `--provider anthropic`.

## Ruled out (don't re-propose without new measurement)

- **1-hour extended cache TTL** (`ENABLE_PROMPT_CACHING_1H`). Measured **net loss** in
  the reference profile. The 1h TTL raises the write price on *every* cache-write
  (~1.6×) but only saves the idle-re-write bucket. Break-even needs the saveable
  (5min–1h gap) share to exceed ~39.5% of writes; measured share was ~20%, dominated by
  a ~72% ≤60s active-churn bucket that just gets more expensive. Re-run
  `--cache-composition`; only revisit if *your* saveable share clears ~40%.

- **Mid-session model flipping as the tiering mechanism.** The original Claude
  profile found a cache penalty; use Copilot role dispatch for role-specific
  model selection instead of assuming that pricing result transfers.
  Tier at the session boundary and via subagents instead.
