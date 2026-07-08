# Jira Plugin

Interact with Jira issues using natural language via the Atlassian CLI (`acli`).

**Instance-agnostic:** this plugin ships no organisation-specific configuration. You authenticate `acli` to your own Atlassian site; nothing here is pre-wired.

## Features

- **View issues**: See issue details, comments, and metadata
- **Search issues**: Find issues using JQL queries
- **Update status**: Transition issues through workflows
- **Edit issues**: Update summary, description, assignee
- **Add comments**: Comment on issues with rich formatting (ADF)

## Installation

From the Forge neutral plugin marketplace (Claude Code adapter):

```
/plugin marketplace add <path-or-url-to>/adapters/claude-code/plugins
/plugin install jira@forge-plugins
```

## Setup

The Atlassian CLI (`acli`) must be installed and authenticated to your site.

**1. Install `acli`**

macOS/Linux:
```bash
brew tap atlassian/acli
brew install acli
```

Windows:
```bash
winget install Atlassian.AtlassianCLI
```

**2. Authenticate to your Atlassian site**

```bash
acli jira auth login
```

During authentication:
1. Choose **"web"** authentication (not "api-token")
2. Enter **your** Atlassian site URL when prompted
3. Complete the browser login flow

Verify with `acli jira auth status`.

**3. (Optional) Register your project keys**

Edit `skills/jira/SKILL.md` → the *Known Jira Projects* section, and add your own project keys so Claude recognises them in natural-language requests.

## Usage Examples

Ask Claude naturally (substitute your own issue keys):

- "View ABC-123"
- "What's the status of PROJ-456?"
- "Mark TEAM-789 as done"
- "Assign ABC-123 to me"
- "Comment on PROJ-456 with the update"
- "Find my open tickets"
- "Search for tickets in project ABC created this week"

## Supported Operations

| Action | Example |
|--------|---------|
| View issue | "show me ABC-123" |
| Search | "find open bugs in project ABC" |
| Transition | "move ABC-123 to In Progress" |
| Assign | "assign ABC-123 to me" |
| Comment | "add a comment to ABC-123" |
| Create | "create a task in project ABC" |
