# Credential discipline

How Forge handles files that contain secrets. The load-bearing rule is short; the rest is rationale and the machinery that backs it.

## The rule

**Never inspect a file known to contain credentials.** "Inspect" means any content-printing read: `grep`, `cat`, `head`, `tail`, `less`, `more`, `sed`, `awk`, `strings`, `xxd`, `od`, `cut`, etc. The danger is that a value-capturing read echoes the secret into the tool output, where it persists in the conversation transcript — which may be retained in session storage or analytics pipelines outside the user's machine. **Rotation is the only certain mitigation once a secret is printed.** There is no undo.

Credential-bearing files include (non-exhaustive):

- `~/.gradle/gradle.properties`
- `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/.pgpass`, `~/.my.cnf`, `~/.htpasswd`
- `~/.aws/credentials`, `~/.docker/config.json`
- `~/.ssh/*` private keys (`id_rsa`, `id_ed25519`, `id_dsa`, `id_ecdsa`)
- `.env` and any `.env.*`
- `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.keystore`, `*.jks`, `*.asc`, `*.gpg`
- anything whose name matches `*credentials*`, `*secret*`, `*token*`

## To confirm credentials are configured, run the tool — not the file

The tool's own validation is the right interface; the file is the implementation detail. When you need to know whether a tool is authenticated:

| Need | Do this, not a file read |
|---|---|
| Gradle / Artifactory creds present | `./gradlew tasks` (Gradle reads `gradle.properties` automatically) |
| AWS creds present | `aws sts get-caller-identity` |
| npm registry auth | `npm whoami` |
| GitHub auth | `gh auth status` |
| Docker registry auth | `docker login` (reports current state) |
| SSH key works | `ssh -T git@host` |

Read the success/failure. You almost never need to look inside the file at all — and the cases where you think you do are usually a wrong-wrapper / wrong-mechanism detour (see the originating incident below).

## If you genuinely must read a credential file

Only with explicit user authorization for the specific operation (e.g. migrating a credential between two tools). Even then:

- Use **key-only** patterns that print variable names, never values: `grep -oE '^[A-Z_]+' file`
- Or **count-only** / presence checks: `grep -c '^ARTIFACTORY_' file`
- Never a pattern that matches `KEY=VALUE` and prints the line.

## The machinery (backstop)

`forge-credential-guard.sh` (PreToolUse on Bash) detects an inspection verb targeting a high-confidence credential file and returns `"ask"` — the prompt is a circuit-breaker, not a hard block. It is **always-on** (not gated on the forge-active marker; credential safety is not session-specific). It matches a curated list of concrete credential files rather than bare substrings like "token", so it does not prompt on ordinary source-code greps. This prose rule is the comprehensive discipline; the hook is the high-confidence safety net for the common cases. Both exist on purpose — belt and braces.

## Originating incident

2026-06-15, PF-1890: while validating that Gradle could find Artifactory credentials before a Paparazzi run, `grep -i 'artifactory\|^USER_NAME\|^PASSWORD' ~/.gradle/gradle.properties` printed the full `ARTIFACTORY_PWD` token into the transcript. Three nested mistakes: (1) the verification was unnecessary — Gradle reads the file automatically; (2) the wrong wrapper script (env-var-based) was chosen, sending the hunt toward the file instead of pivoting to `./gradlew`; (3) the grep pattern itself was value-capturing. The first defense (don't inspect) would have prevented all three. Full write-up: vault task `2026-06-15-credential-leak-via-greedy-grep`.
