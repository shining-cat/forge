# Friction Classifier — Decision Tree

Maps a friction event to a named pattern in `script-replacement-patterns.md`. This document is the single source of truth for classifier logic; `forge-classify-friction.sh` walks this tree.

Each leaf returns one of: `config-generator-staleness`, `hook-injection`, `wrapper-subcommand`, `marker-state-guard`, `allowlist-patch`, `template-slot`, or `needs_new_pattern`.

---

## Decision tree

```
Q0. Does the friction recur because a generator (install.sh / template / config emitter) re-produces a stale or no-longer-honored artifact, so manual removal doesn't stick?
├── Yes → config-generator-staleness
└── No  →
    Q1. Was the friction a permission prompt (Claude asked for approval)?
    ├── Yes →
    │   Q2. Is the operation safe to allowlist?
    │   ├── Yes →
    │   │   Q3. Does the existing allowlist pattern not match due to a glob subtlety?
    │   │   ├── Yes → allowlist-patch
    │   │   └── No  →
    │   │       Q4. Is the operation safer wrapped in a subcommand (multiple call sites, prompts on each)?
    │   │       ├── Yes → wrapper-subcommand
    │   │       └── No  → allowlist-patch (just add the precise pattern)
    │   └── No  → needs_new_pattern  (operation requires per-call review — no script fix)
    └── No  →
        Q5. Was the friction a hook firing when it shouldn't have (nag, block)?
        ├── Yes → marker-state-guard
        └── No  →
            Q6. Was the friction prose-discipline drift (header missing, time guessed, format wrong)?
            ├── Yes →
            │   Q7. Is the required output a verbatim string the agent should produce?
            │   ├── Yes → hook-injection
            │   └── No  → needs_new_pattern  (stylistic discipline — no current pattern)
            └── No  →
                Q8. Did the agent reconstruct multi-line structured text from memory and drift?
                ├── Yes → template-slot
                └── No  → needs_new_pattern
```

Q0 is a pre-emptive gate: it asks *why a fix won't stick* rather than *what the symptom was*. A generator re-emitting a dead artifact dominates the fix strategy (fix the generator, not the artifact), so it precedes the symptom cascade regardless of how the friction surfaced.

---

## Examples

| Friction | Path through tree | Pattern |
|---|---|---|
| `install.sh` re-seeds a dead `Write(...)` permission rule the host ignores; hand-removal doesn't survive re-install | Q0 yes (generator re-emits the stale artifact) | `config-generator-staleness` |
| `gws calendar events list` triggered prompt | Q0 no → Q1 yes → Q2 yes → Q3 yes (verbose form not allowlisted) | `allowlist-patch` |
| `forge-context.sh wrap-up-state; echo ---` triggered prompt | Q0 no → Q1 yes → Q2 yes → Q3 no → Q4 yes (compound recidivism, 3rd) | `wrapper-subcommand` |
| Wellness nag fired during /forge entry | Q0 no → Q1 no → Q5 yes (hook didn't check marker == __pending__) | `marker-state-guard` |
| Keeper Stop hook fired with 999-min stale checkpoint despite zero activity | Q0 no → Q1 no → Q5 yes (didn't check activity stop count) | `marker-state-guard` |
| Forge header `[Forge: ENV/Project | HH:MM]` missing from response | Q0 no → Q1 no → Q5 no → Q6 yes → Q7 yes (verbatim format) | `hook-injection` |
| Task file frontmatter missing fields | Q0 no → Q1 no → Q5 no → Q6 no → Q8 yes | `template-slot` |

---

## When the tree returns `needs_new_pattern`

Caller (Refiner or operator) should still call `forge-context.sh append-friction --description "..." --pattern needs_new_pattern --action-ref tasks/open/<stub-slug>.md` (a real task path, or the literal `needs_new_pattern` when no stub file exists yet — `append-friction` rejects any other `--action-ref` value, e.g. prose or `none`, so it can't write a garbage file at vault root). The stub task pre-fills "candidate for new catalog entry". Toolsmith reviews these during catalog reviews and either extends an existing pattern or adds a new one to `script-replacement-patterns.md` (then updates this tree to route to it).
