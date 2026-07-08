---
name: jira
description: Use when the user mentions Jira, tickets, issues, sprints, or references issue keys like ABC-123, PROJ-456, TEAM-789.
allowed-tools: Bash(acli --version), Bash(acli jira auth *), Bash(acli jira workitem view *), Bash(acli jira workitem search *), Bash(acli jira board get *), Bash(acli jira board list-projects *), Bash(acli jira board list-sprints *), Bash(acli jira board search *)
---

# Jira Integration

Interact with Jira using the Atlassian CLI (`acli`). This skill enables natural language Jira operations.

## Prerequisites

Verify `acli` is installed by running `acli --version`.

If not installed, inform the user:

> The Atlassian CLI (`acli`) is required but not installed.
>
> **macOS/Linux:**
> ```bash
> brew tap atlassian/acli
> brew install acli
> acli jira auth login
> ```
>
> **Windows:**
> ```bash
> winget install Atlassian.AtlassianCLI
> acli jira auth login
> ```
>
> During authentication:
> 1. Choose **"web"** authentication (not "api-token")
> 2. Enter your Atlassian site URL when prompted
> 3. Complete the browser login flow

## Command Reference

**Important**: Always use `--yes` flag for non-interactive confirmation.

### View an Issue

```bash
acli jira workitem view <issue-key>
acli jira workitem view <issue-key> --fields summary,description,labels,priority
acli jira workitem view <issue-key> --fields '*all' --json
```

**Default fields**: `key`, `issuetype`, `summary`, `status`, `assignee`, `description`

**Common additional fields**: `labels`, `priority`, `created`, `updated`, `parent`, `customfield_10020` (sprint — do not use `sprint` as the field name)

#### Fetching comments

**Important**: Comments are only visible in JSON output. The text/table output silently omits them even when requested.

To fetch comments, use `--json` and parse the nested structure:
```bash
acli jira workitem view <issue-key> --fields '*all' --json
```

Comments are in `fields.comment.comments[]` with structure:
```json
{
  "author": { "displayName": "Name" },
  "body": { "content": [{ "content": [{ "text": "Comment text" }] }] },
  "created": "2025-12-17T09:25:10.678+0000"
}
```

To extract comment text from ADF body, recursively collect all `text` nodes from `body.content`.

### Sprint Operations

#### Fetching sprint data

**Important**: The `sprint` field name does not work with `--fields`. Sprint data is stored in a custom field (`customfield_10020`). You must use JSON output:

```bash
acli jira workitem view <issue-key> --fields customfield_10020 --json | jq '.fields.customfield_10020[0].name'
```

Sprint objects contain fields: `id`, `name`, `state`, `startDate`, `endDate`, `boardId`.

For JQL queries involving sprint, use `cf[10020]` instead of `sprint`:
```bash
acli jira workitem search --jql "cf[10020] = 12531"  # by sprint ID
```

#### Finding the active sprint

```bash
acli jira board list-sprints --id <board-id> --state active --json | jq '.sprints[0]'
```

To find closed sprints (e.g. the latest one):
```bash
acli jira board list-sprints --id <board-id> --state closed --json --paginate | jq -s '[.[].sprints[]] | sort_by(.endDate) | last'
```

#### Adding/changing sprint on an issue

**Important**: `acli jira workitem edit` does not support setting custom fields like sprint. To move an issue to a sprint, use the Jira UI or the Jira REST API directly (`POST /rest/agile/1.0/sprint/{sprintId}/issue`).

### Search for Issues

**The `--jql` flag is required.** Always include it:

```bash
acli jira workitem search --jql "project = XX AND status not in (Done)"
acli jira workitem search --jql "project = XX AND status not in (Done)" --fields key,summary,status
acli jira workitem search --jql "project = XX AND type = Epic" --fields key,summary
```

**Note**: The `search` command does not support the `comment` field. To get comments, first search for issue keys, then fetch each issue individually with `--json`.

**JQL tip**: Use `status not in (Done)` rather than the `!=` operator to avoid shell escaping issues.

### Edit an Issue

**Requires `--key` flag**:
```bash
acli jira workitem edit --key <issue-key> --summary "New title" --yes
acli jira workitem edit --key <issue-key> --description "New description" --yes
acli jira workitem edit --key <issue-key> --assignee "@me" --yes
```

For multi-line descriptions, use heredoc (renders as plain text, not formatted - see "Rich Formatting with ADF" for proper formatting):
```bash
acli jira workitem edit --key XX-123 --description "$(cat <<'EOF'
Summary

Multi-line description here.

Details

More content.
EOF
)" --yes
```

### Transition Status (not "move")

**Use `transition`, not `move`**:
```bash
acli jira workitem transition --key <issue-key> --status "Done" --yes
acli jira workitem transition --key <issue-key> --status "In Progress" --yes
```

### Add Comments

**Use `comment create`, not `comment add`**:
```bash
acli jira workitem comment create --key <issue-key> --body "Comment text"
```

For multi-line comments (renders as plain text):
```bash
acli jira workitem comment create --key XX-123 --body "$(cat <<'EOF'
Multi-line comment here.

With multiple paragraphs.
EOF
)"
```

### Create Issues

```bash
acli jira workitem create --project XX --type Task --summary "Title" --description "Description"
```

### Rich Formatting with ADF

**Important**: Jira uses Atlassian Document Format (ADF), not Markdown. Plain text or markdown passed via `--description` will render as unformatted text.

For properly formatted descriptions with headings, bullet lists, code blocks, etc., use `--from-json` with ADF structure:

```bash
cat > /tmp/workitem.json << 'EOF'
{
  "additionalAttributes": {
    "priority": { "name": "High" }
  },
  "projectKey": "XX",
  "parentIssueId": "<epic-key>",
  "summary": "Task title",
  "type": "Task",
  "description": {
    "type": "doc",
    "version": 1,
    "content": [
      {
        "type": "heading",
        "attrs": { "level": 2 },
        "content": [{ "type": "text", "text": "Context" }]
      },
      {
        "type": "paragraph",
        "content": [
          { "type": "text", "text": "Description with " },
          { "type": "text", "text": "inline code", "marks": [{ "type": "code" }] },
          { "type": "text", "text": " formatting." }
        ]
      },
      {
        "type": "heading",
        "attrs": { "level": 2 },
        "content": [{ "type": "text", "text": "Tasks" }]
      },
      {
        "type": "bulletList",
        "content": [
          {
            "type": "listItem",
            "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "First item" }] }]
          },
          {
            "type": "listItem",
            "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Second item" }] }]
          }
        ]
      }
    ]
  }
}
EOF
acli jira workitem create --from-json /tmp/workitem.json
```

#### ADF Node Types

| Type | Usage |
|------|-------|
| `heading` | `{ "type": "heading", "attrs": { "level": 2 }, "content": [...] }` |
| `paragraph` | `{ "type": "paragraph", "content": [...] }` |
| `bulletList` | Contains `listItem` nodes |
| `orderedList` | Contains `listItem` nodes |
| `listItem` | `{ "type": "listItem", "content": [{ "type": "paragraph", ... }] }` |
| `codeBlock` | `{ "type": "codeBlock", "attrs": { "language": "python" }, "content": [...] }` |
| `text` | `{ "type": "text", "text": "content" }` |
| `text` + code | `{ "type": "text", "text": "code", "marks": [{ "type": "code" }] }` |
| `text` + bold | `{ "type": "text", "text": "bold", "marks": [{ "type": "strong" }] }` |

**Important**: Tasks must always belong to an epic. Ask the user which epic the task should be added to before creating. Use JQL to find epics: `acli jira workitem search --jql "project = XX AND type = Epic"`

Available priorities: `Highest`, `High`, `Medium`, `Low`, `Lowest`, `Not prioritized`

## Supported Operations

Examples of natural language requests:
- "view XX-123" → `workitem view XX-123`
- "mark XX-123 as done" → `workitem transition --key XX-123 --status "Done" --yes`
- "assign XX-123 to me" → `workitem edit --key XX-123 --assignee "@me" --yes`
- "comment on XX-123" → `workitem comment create --key XX-123 --body "..."`

## JQL Examples

```bash
# Find latest ticket in project
acli jira workitem search --jql "project = XX ORDER BY created DESC" --limit 1

# Find tickets created recently
acli jira workitem search --jql "project = XX AND created >= -7d"

# Find my open tickets
acli jira workitem search --jql "assignee = currentUser() AND status not in (Done)"

# Find tasks in an epic
acli jira workitem search --jql "project = XX AND 'Epic Link' = XX-2 AND status not in (Done)"
```

## Known Jira Projects

<!-- Add your project keys here so Claude recognises them, e.g.: -->
<!-- - ABC (Example Project) -->

## Common Mistakes to Avoid

| Wrong | Correct |
|-------|---------|
| `workitem move` | `workitem transition` |
| `comment add` | `comment create` |
| `edit XX-123 --summary` | `edit --key XX-123 --summary` |
| `search "project = XX"` | `search --jql "project = XX"` (--jql is required) |
| Missing `--yes` | Always include `--yes` for edits/transitions |
| `--priority "High"` | Use `--from-json` with `additionalAttributes` |
| Creating task without epic | Always ask user for epic first |
| Markdown in `--description` | Use `--from-json` with ADF for rich formatting |
| `view --fields comment` (text output) | Use `--json` to see comments |
| `search --fields comment` | Not supported; fetch each issue with `view --json` |
| `--fields sprint` | Use `--fields customfield_10020 --json` |
| JQL `sprint = "Name"` | Use `cf[10020] = <sprint-id>` |
| JQL `closedSprints()` | Use `acli jira board list-sprints --id <board-id> --state closed` |
| `workitem edit` to set sprint | Not supported; use Jira UI or REST API |

## Hard-won tips (field quirks)

These come from real usage — Jira field behaviour varies by site config, so **verify on first use against your own instance** and fall back to the two-call form if a field comes back empty.

- **Batch into a single `--from-json` create.** Set every field you can at creation time (project, type, summary, ADF description, labels, parent) in one `acli jira workitem create --from-json` call. Each separate `acli` call is another confirmation/permission step, so prefer one command per logical action; only fall back to a follow-up `edit` for fields that can't be set at create.
- **`--label` does NOT work on `create`.** The flag is accepted in argv but silently never applied (labels come back empty, no error). Set labels via `additionalAttributes.labels` in `--from-json`, or a follow-up `acli jira workitem edit --key <issue-key> --labels <label> --yes` — note `--labels` (plural). `--label` (singular) exists on neither `create` nor `edit`.
- **`--assignee "@me"` can fail** with `User '<id>' cannot be assigned issues` on projects that restrict assignment to active members — the authed identity doesn't always map to an assignable user. Workaround: omit assignee on create, self-assign in the UI afterward. Same caveat for `"assignee": "@me"` inside `--from-json`.
- **There is no `workitem update` verb** — it's `edit` (e.g. `acli jira workitem edit --key <issue-key> -d "..." --yes`; `-d` accepts plain text or ADF).
- **Priority may not be settable via `edit`** — some sites reject a `priority` field on the edit path. Set it via `additionalAttributes.priority` in `create --from-json`, or via the UI after creation.
- **Comments** — the verb is `comment create` (not `comment add`); markdown-flavoured text in `--body` renders fine, but bash-escape backticks (`` \` ``) if the comment includes inline code.

## Error Handling

If commands fail:
1. Check authentication: `acli jira auth status`
2. Verify issue key exists and user has access
3. Run `acli jira workitem <command> --help` to check syntax
