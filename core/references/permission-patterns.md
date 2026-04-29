# Permission Patterns

Reference for writing `permissions.allow` / `permissions.deny` entries in `~/.claude/settings.json` (and project-level `.claude/settings.local.json`). Each entry below documents a pitfall observed in the wild — every one has cost a debugging session.

## The 5 known pitfalls

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

### 5. `~/.claude/` is a hardcoded sensitive zone — allowlist patterns DO NOT apply

Claude Code treats `~/.claude/` as a protected directory with mandatory permission prompts on Write/Edit/Bash operations targeting files inside it. Allowlist patterns cannot suppress these prompts, regardless of pattern shape (CWD-relative, absolute, single `*`, double `**`).

```jsonc
"Write(.claude/forge-active)"                                  // ❌ chip text matches but still prompts
"Write(/Users/shiva.bernhard@m10s.io/.claude/forge-active)"   // ❌ same
"Edit(**/.claude/forge-active)"                                // ❌ same (and even ** doesn't help here)
```

**Why it bites:** the four pitfalls above (single `*`, leading `*` in Bash, deny precedence, CWD-relative chip text) all suggest the model "right-shape pattern → match → no prompt." Inside `~/.claude/` that pipeline is bypassed by an upstream sensitive-zone check. The pattern is loaded, the chip matches, the matcher would have allowed — but the request is gated separately and prompts anyway.

**Verified 2026-04-29:** identical-shape patterns work in vault paths and fail in `~/.claude/`. See design doc `~/__DEV/PERSO/forge/.claude/plans/2026-04-29-marker-relocation-design.md` for the case study (the `forge-active` marker, originally at `~/.claude/forge-active`, kept prompting through every pattern shape until it was relocated to `${VAULT_PATH}/_shared/forge-active`).

**The fix:** for runtime state files that need silent writes, place them outside `~/.claude/` — typically in the vault, which is freely allowlistable. Reserve `~/.claude/` for files Claude Code itself manages (settings.json, hooks/, skills/, scripts/) where the prompt friction is acceptable because those files change rarely.

**Implications for past hypotheses:** pitfall #4 (matcher uses CWD-relative chip text) is correct for normal paths, but inside `~/.claude/` it's moot — no allowlist match fires regardless. Don't trust mid-session pattern experiments inside `~/.claude/`; they'll always fail, and the failure tells you nothing about whether the pattern shape is correct.

## Meta-rules for permission-pattern work

### Mid-session settings.json patches DO NOT apply until restart

**Verified 2026-04-28:** Claude Code does NOT reload the allowlist when `settings.json` is modified mid-session. Patches added during a session take effect ONLY after a session restart.

This was confirmed end-to-end: a new `Edit(.claude/forge-active)` pattern was added to settings.json, then the very next Edit on `~/.claude/forge-active` (the marker clear at `/forge-exit`) STILL prompted the user. The pattern is in the file but not in the running session's allowlist.

Implications:
- Never rely on a same-session test to verify a new pattern works
- When patching settings live, surface this to the user explicitly: "this won't take effect until you restart Claude Code"
- For verification: the only valid test is a session restart followed by user-observed behavior
- Avoid Edit/Write loops in the same session that depend on a new pattern you just added — they will prompt

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
