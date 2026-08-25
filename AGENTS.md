# CC toolkit — agent instructions

## Shared project context

Before work, read private repository `zashliu/personal-ai-vault`:

- `projects/REGISTRY.md`
- `projects/cc-toolkit.md`
- `docs/PROJECT_PROTOCOL.md`

On the SER8 it is `/home/pig/data/personal-ai-vault`. The Vault provides context;
this repository remains the source of truth for its scripts and documentation.

## Safety

Read `README.md` before work. Treat scripts as potentially operational: inspect
their target and side effects before running them, prefer dry runs, and preserve
unrelated user configuration. Never commit credentials, tokens, private keys,
machine-specific configuration, or raw user data.

## Handoff

After meaningful work, record the change, branch/commit, verification, risk, and
next action through the Vault protocol. Unattended agents use the Vault inbox for
candidate context and do not silently rewrite canonical context.
