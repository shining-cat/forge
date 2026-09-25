# Forge Deployment Workflow

## Overview

The Forge repository is separate from the installed Forge instance in `~/.copilot/`. 

- **Repository**: `/Users/shiva.bernhard/__DEV/PERSO/forge/core/` — maintainer work
- **Installed instance**: `~/.copilot/` — user experience (what users run)

When you make changes to skills, scripts, or tools in the repo, **you must deploy them explicitly** to test them as a user would.

## Deploy Process

### Deploy a single skill

```bash
SKILL_NAME="forge-setup-models"
REPO_SKILL="$FORGE_ROOT/core/skills/$SKILL_NAME"
INSTALLED_SKILL="$HOME/.copilot/skills/$SKILL_NAME"

rm -rf "$INSTALLED_SKILL"
cp -r "$REPO_SKILL" "$INSTALLED_SKILL"
```

### Deploy all skills

```bash
FORGE_ROOT=/Users/shiva.bernhard/__DEV/PERSO/forge/core

for skill_dir in "$FORGE_ROOT/skills"/*; do
    skill_name=$(basename "$skill_dir")
    echo "Deploying $skill_name..."
    rm -rf "$HOME/.copilot/skills/$skill_name"
    cp -r "$skill_dir" "$HOME/.copilot/skills/"
done

echo "✓ All skills deployed to $HOME/.copilot/skills/"
```

### Deploy tools (forge-model-catalog-setup.py, etc.)

```bash
FORGE_ROOT=/Users/shiva.bernhard/__DEV/PERSO/forge/core

mkdir -p "$HOME/.copilot/forge/core/tools"
cp -r "$FORGE_ROOT/tools"/* "$HOME/.copilot/forge/core/tools/"

echo "✓ Tools deployed to $HOME/.copilot/forge/core/tools/"
```

## Testing Workflow

1. **Edit** the repo code: `/Users/shiva.bernhard/__DEV/PERSO/forge/core/skills/X/...`
2. **Deploy** changes: Run the appropriate deploy command above
3. **Test** as a user would: `bash ~/.copilot/skills/X/scripts/X.sh` or `/skill-name` in Forge mode
4. **Verify** installed instance reflects changes: `ls -la ~/.copilot/skills/X` (should NOT be a symlink)

## Why No Symlinks?

Symlinks hide the deployment boundary and make it impossible to test real user behavior. A genuine user has no symlink — their skills are standalone copies. We must test the same way.

## Future: Automated Deploy

Consider adding a `make deploy` or `./deploy.sh` script to automate this workflow.
