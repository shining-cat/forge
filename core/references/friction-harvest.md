# Friction-Log Harvest Flow

The friction log is a **write-buffer**, not an archive. New entries land via `append-friction`; periodically the buffer gets harvested into structured forms (tasks, decisions, feedback memories) and consumed raw entries move to dated archive files. The live log stays bounded; the structured forms carry forward.

This reference documents the subcommands and the orchestrated flow Petra runs at weekly-wrap moments (or any time the log feels heavy).

---

## Subcommands

All live in `~/.claude/scripts/forge-context.sh`.

| Subcommand | Purpose |
|---|---|
| `append-friction` | Write a new friction entry (existing). Accepts `--pinned` to mark canonical entries. |
| `pin-friction --entry "<date>\|<prefix>"` | Mark an existing entry as pinned in both markdown and JSON. Idempotent. |
| `friction-tail [N]` | Headlines-only view, defaults to last 5. **Skips pinned entries** unless `--include-pinned`. Use `--full` to see bodies for triage. |
| `archive-friction-entries --entry "<date>\|<prefix>" ...` | Move matched entries to `friction-log-archive/YYYY-W<ISO-week>.md`. Skips pinned. Updates JSON with `archived_in: "YYYY-WNN"`. Idempotent. |
| `harvest-friction --days N [--pretty]` | Output JSON proposals for unpinned/unarchived entries in the last N days. Applies promotion heuristic. |
| `promote-friction --entry "..." --target archive\|task\|decision\|feedback` | Execute a promotion decision. `archive` chains to `archive-friction-entries`. For task/decision/feedback, prints scaffold hint — Petra writes the file directly via Write tool, then re-invokes with `--target archive` to clean up. |
| `bootstrap-harvest --older-than N [--dry-run]` | One-shot non-interactive sweep. Archives all unpinned/unarchived entries older than N days. Used periodically to reset accumulated log size. |

---

## Pinned-marker convention

Some friction entries are canonical references — load-bearing context for ongoing work. Example: the 2026-05-18 wellness-strike-blocks-recovery entry is the design rationale for an open task; archiving it would orphan that reference.

**Mechanism (dual surface):**

- **JSON:** entry has `pinned: true` field. Absence = false.
- **Markdown:** entry body contains a `- **Pinned:** true` bullet line. Lets a human grep see pinned entries quickly.

The JSON is the source of truth; the markdown bullet mirrors it for human-discoverability. `pin-friction` writes both atomically.

Pinned entries are excluded from `friction-tail`, `harvest-friction`, `archive-friction-entries`, and `bootstrap-harvest`. They still count toward "this pattern recurred N times" for promotion scoring.

---

## Identity key

Entries are identified by `(date, description-prefix)` across both surfaces:

- **Date** — `YYYY-MM-DD` from the entry frontmatter / heading
- **Description prefix** — leading characters of the entry's description (matched via `startswith`)

This avoids ID generation and lets Petra cite entries by their visible heading text. Pass as `--entry "<date>|<desc-prefix>"` — a single pipe between the two parts.

Prefix length: anything ≥ the unambiguous portion of the title works. The script uses 80 chars from the JSON when building specs internally.

---

## Archive routing

Consumed entries route to `{VAULT_PATH}/_shared/friction-log-archive/YYYY-W<ISO-week>.md` based on **the entry's own date** (not when it was archived). One file per ISO week. Append-mode, never read by the recovery script. Searchable on demand via grep.

A single `archive-friction-entries` call can route entries across multiple weeks — the script groups by entry date's ISO week and writes to the appropriate file.

---

## Promotion heuristic (Slice 3)

`harvest-friction` proposes a target per unpinned/unarchived entry using this table:

| Entry state | Proposed target | Justification |
|---|---|---|
| `action_ref` looks like a path + file exists | archive-only | Already promoted, raw entry redundant |
| `action_ref` looks like a path + file missing | task | Promoted, but task got lost — rewrite |
| `recurrence >= 2` | task | Pattern recurring — structural fix needed |
| Unclassified + date < 14 days old | task | Recent, likely needs new pattern |
| Unclassified + date >= 14 days old | archive-only | Old + uncategorized = informational only |

"Unclassified" = `action_ref` is `"needs_new_pattern"`, empty, or absent.

Output: JSON array of `{entry_id, date, description, pattern, recurrence, action_ref, proposed_target, justification}`. Sorted tasks-first.

---

## The orchestrated harvest flow (Petra)

Run at weekly-wrap moments (`eow_window` / `past_eow` state), or any time the log feels heavy:

1. **Survey** — `forge-context.sh harvest-friction --days 14 --pretty`. Read the JSON.
2. **Display** — render a table to the user: date, description, proposed target, justification. Group by target.
3. **Confirm / override** — ask the user: "OK to promote these? Anything to override?"
4. **Execute archive-only items** — single bundled call: `archive-friction-entries --entry "..." --entry "..." ...`.
5. **For task / decision / feedback targets** — Petra writes the file directly via Write tool using conversation context (slug, title, body, back-link to source entry). Then chains `promote-friction --entry "..." --target archive` to clean up the raw entry.
6. **Verify** — `friction-tail` after the pass; the buffer should now show only recent active entries.

Pinned entries never appear in the harvest proposal — they stay in the log indefinitely.

---

## Bootstrap (one-shot)

For initial cleanup of an accumulated log:

```
forge-context.sh bootstrap-harvest --dry-run --older-than 30   # preview
forge-context.sh bootstrap-harvest --older-than 30              # execute
```

No promotion heuristic — just sweeps all unpinned/unarchived entries older than the cutoff to per-week archive files. Use once when the log is bloated; subsequent maintenance via `harvest-friction` + `promote-friction`.

First run on the current vault (2026-05-26): archived 20 entries dated before 2026-04-26, reducing `friction-log.md` from 128 KB to 101 KB.

---

## Read-cost note

The session-entry friction view is `friction-tail` (default 5 headlines), so the read-cost-per-session is already bounded regardless of the live log's size. The harvest flow buys two other things:

1. **Bounded on-disk size** — `Read` calls during investigation stay cheap.
2. **Promotion discipline** — recurring patterns surface as tasks instead of accumulating as repeated raw entries.

The archive files exist for forensic grep, not for routine reading.
