# Forge

Session orchestration layer for AI-assisted development. One conversation, one orchestrator, all your projects in one vault.

---

## Why Forge

Most multi-agent setups quietly turn the human into a router. You open parallel windows because it feels like leverage, but each is another tab to read, another thread to merge, another context to hold. The agents work in parallel; you don't. You sequence yourself across them, paying a context-switch tax on every glance.

Forge inverts that. **One conversation, one orchestrator (Petra), who dispatches subagents internally and reports back.** You state intent, review results, make decisions. Routing, dispatch, context-sharing, and reconciliation happen behind the scenes.

It's not faster than N parallel windows. It's quieter.

Focus doesn't mean tunnel vision either — Forge holds all your projects in one vault. When a side-thought strikes mid-task, you log it in seconds and keep going. You don't lose the spark to the discipline of staying focused, and you don't break focus to chase the spark.

---

## What a day looks like

**Morning** — `/forge` in any Claude Code window. Petra wakes the anvil: loads the active project's vault, reconciles your open + reviewed PRs against GitHub, surfaces calendar interruptions for the day, flags merged review docs ripe for cleanup. Cold-start after a long gap gets a special banner (*"Forge was idle for 14h — re-read the checkpoint, don't trust it implicitly"*).

**During work** — you talk to one Petra. She delegates internally: **Keeper** logs decisions and checkpoints, **Refiner** catches corrections as friction events that compound into permanent fixes, **Reviewer** (or a Pattern A team of 3-5 reviewers in parallel) reviews PRs, **Architect** designs, **Builder** implements. Roles show up as `[Role]` tags so you see who's speaking.

**Stray ideas** — when a side-thought lands mid-task (*"oh, project X needs Y"*, *"we should look at Z later"*), you just dump it to Petra: *"log this for later: ..."*. She drops it in the brain-dump or files a quick task stub in the right project — without breaking your current thread. You don't lose the spark, you don't break focus chasing it. If you're not in a Claude Code session at all, there's an Obsidian hotkey for the same thing — drafts accumulate until the weekly wrap triages them.

**Project switching** — your vault holds all your projects. `/forge` in a new project's directory switches the active marker; the previous project's state stays intact, ready when you come back. Cross-project synthesis happens at the weekly wrap, not by accident.

**Wellness (optional)** — the wellness coach (you name them during onboarding) tracks your work time independently. Three personas, **calendar-aware** (won't strike during a meeting), **Pattern A-aware** (fires on assistant turn-end too, not just tool calls), **gated on Forge-active state** (zero monitoring when Forge isn't running). When a strike does fire, addressing the coach by name lifts it: e.g. *"&lt;your-coach&gt;, lift the strike, I'm on lunch."*

**Exit (daily)** — `/forge-exit` writes the final checkpoint, deactivates the marker, resets wellness. Hooks stop firing into a dead session. Saying *"calling it"* / *"done for today"* triggers the same offer in prose.

**Exit (weekly)** — `/forge-weekly` on Fridays. The Quartermaster persona harvests the week's friction into structured patterns, triages the captured drafts from the week into proper tasks, runs the cross-project retro, logs the week. Then `/forge-exit` as normal.

---

## Install

```bash
git clone git@github.com:shining-cat/forge.git
cd forge
./install.sh
```

Requires [Claude Code](https://claude.ai/code) + the [superpowers](https://github.com/obra/superpowers-marketplace) plugin. Full install + customization + rollback + maintainer-mode docs: see [docs/SETUP.md](docs/SETUP.md).

---

## Learn more

- **[docs/SETUP.md](docs/SETUP.md)** — install, customization, upgrades, rollback, first session, maintainer mode, extending, contributing
- **[docs/COMMANDS.md](docs/COMMANDS.md)** — slash-command reference + conversational triggers (most you'll never type by hand; Petra surfaces them)
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — components, where things live, vault structure, friction framework, wellness coach internals
- **[docs/ROLES.md](docs/ROLES.md)** — per-role specifications (Petra, Keeper, Refiner, Reviewer, Architect, Builder, Debugger, Release Manager, Toolsmith)
- **[docs/PROJECT-STRUCTURE.md](docs/PROJECT-STRUCTURE.md)** — vault project layout (INDEX vs checkpoint, on-demand folders, template inventory, single-doc task workflow)
- **[docs/draft-tasks.md](docs/draft-tasks.md)** — quick-capture lifecycle: 5-second Obsidian capture → weekly triage → on-demand refinement with Petra
- **[core/references/script-replacement-patterns.md](core/references/script-replacement-patterns.md)** — 5 patterns for converting recurrent friction into script-enforced mitigations
- **[core/references/friction-classifier.md](core/references/friction-classifier.md)** — decision tree for routing friction shape → pattern slug

## License

[GPL-3.0](LICENSE)
