# Track upstream engine, own the tool surface

bcu is a rebranded fork of `injaneity/pi-computer-use` that replaced the Pi-extension
tool layer with a standalone CLI (`ToolResult` text contract, `BcuError`, broker-backed
commands). Upstream keeps evolving both layers, so every sync must decide what follows
and what stays.

Decision: sync by full `git merge upstream/main` (never cherry-pick, so the merge base
stays current). The platform/engine layer (`native/*`, `src/platform/*`, `scripts/setup-helper.mjs`)
follows upstream; the tool layer (`src/bridge.ts`, `src/contract.ts`, `src/actions.ts`,
`src/cli.ts`) keeps the bcu architecture, and upstream extension-coupled modules
(e.g. `src/output.ts`) are dropped rather than adapted. All identities are bcu-owned:
`BCU_*` env vars, `~/.bcu` helper paths, `com.sugeh.bcu`, `bcu.app`. Upstream community
files (CONTRIBUTING, release notes) are removed on sync.

Rejected: cherry-picking selected fixes — permanently degrades the merge base and makes
every future sync harder; adapting upstream's output envelope into the CLI — it exists to
serve the Pi extension runtime we deleted.
