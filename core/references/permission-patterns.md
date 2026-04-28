# Permission Patterns

Reference for writing `permissions.allow` / `permissions.deny` entries in `~/.claude/settings.json` (and project-level `.claude/settings.local.json`). Each entry below documents a pitfall observed in the wild — every one has cost a debugging session.

## The 4 known pitfalls

### 1. Single `*` does NOT cross `/`

A single `*` in a Write/Edit pattern matches one path segment only. It does not span slashes.

```jsonc
"Write(*/.claude/forge-active)"   // ❌ does NOT match /Users/.../.claude/forge-active
"Write(**/.claude/forge-active)"  // ✓ ** crosses slashes (multi-segment glob)
"Write(.claude/forge-active)"     // ✓ literal CWD-relative
"Write(/Users/.../.claude/forge-active)"  // ✓ literal absolute
```

**Why it bites:** the pattern looks like it should work — `*` "matches anything before `.claude/`" — but the matcher only crosses one segment per `*`. Multi-segment paths silently fall through to the prompt.

### 2. Leading `*` in `Bash(...)` is LITERAL, not a wildcard

Bash patterns support exact match or `prefix*` form. A leading `*` is the literal character `*`, not a wildcard.

```jsonc
"Bash(*forge-context.sh*)"                              // ❌ literal *, never matches
"Bash(~/.claude/scripts/forge-context.sh *)"            // ✓ prefix form, tilde expansion
"Bash(/Users/.../.claude/scripts/forge-context.sh *)"   // ✓ prefix form, absolute
```

**Why it bites:** substring-style patterns (`*foo*`) are intuitive from shell glob experience, but Claude Code Bash matching is anchored. When both tilde and absolute invocation styles exist, allowlist BOTH forms — unverified whether tilde expansion happens before matching.

### 3. `deny` wins over `allow`

`permissions.deny` rules are checked first. A specific allow can never override a matching deny.

```jsonc
// Global deny (do not remove): "Bash(rm:*)"
"Bash(rm -f ~/.claude/forge-active)"   // ❌ blocked by Bash(rm:*) — adding this allow does NOTHING
```

**Why it bites:** the obvious workaround ("just allow the specific case") fails silently. Restructure the operation to avoid the deny entirely:
- For file removal: use `Edit` to clear contents (empty-marker convention) instead of `rm`
- For destructive Bash: prefer the equivalent dedicated tool (Edit, Write) which has its own permission rules

### 4. The matcher uses the path shown in the UI chip, NOT the tool argument

When a tool call appears in the user's UI as `Update(.claude/forge-active)` or `Write(./some/file)`, the parenthesised string IS the matcher input — typically the CWD-relative form, not the absolute path the tool argument carries.

```jsonc
// Tool called with: /Users/.../.claude/forge-active
// UI shows:        Update(.claude/forge-active)
// Matcher checks against: .claude/forge-active

"Edit(/Users/.../.claude/forge-active)"   // ❌ wrong shape entirely
"Edit(.claude/forge-active)"              // ✓ matches the matcher input
```

**Why it bites:** absolute-path entries look like the most precise/safe form, so they're the natural reach. They never match. Belt-and-braces: include both the literal CWD-relative form AND the absolute form (the latter for hypothetical alternative invocation paths) — the relative one is what actually does the work today.

**How to verify which form the matcher sees:** when the user reports a prompt for what looks like an allowed operation, ask them to share the UI chip text. The string inside the parentheses is the matcher input.

## Meta-rules for permission-pattern work

### Mid-session settings.json patches: assume they don't apply

Whether Claude Code reloads the allowlist when `settings.json` is modified mid-session is unverified. Treat as: **patches added during a session take effect on next session restart, not before.** Don't rely on a same-session test to verify a new pattern works.

### Tool-result success is NOT evidence the permission matched

Claude has no observable signal for permission prompts. The tool-result success path is identical for "allowlist matched, no prompt" and "user clicked Allow on the prompt." When debugging permission-pattern bugs:
- The only valid evidence sources are user feedback after each test, or the user's report of whether a prompt appeared on session restart
- Never declare a permission bug "resolved" based on Claude-side observations alone
- If iterating on patterns, batch the changes and ask the user to verify one pass at a time, not per-pattern

### Periodic audit recommended

Permission patterns rot silently — broken patterns produce prompts (not errors), the user clicks Allow, and the pattern looks healthy on paper. Worth a periodic review (every few weeks) of the allowlist against actual session friction. See task `Vault/PERSO/forge/tasks/open/2026-04-24-forge-permission-pattern-audit.md` for a proposed linter.

## When in doubt: belt-and-braces

For any new file/path that needs Write or Edit allowlisting, write four entries:

```jsonc
"Write(<cwd-relative-path>)",
"Edit(<cwd-relative-path>)",
"Write(<absolute-path>)",
"Edit(<absolute-path>)",
```

The CWD-relative form is what the matcher actually sees today. The absolute form is cheap insurance for alternative invocation paths. Anything else (`*` globs without `**`, leading-`*` Bash, etc.) is fragile until the matcher behavior is more thoroughly mapped.
