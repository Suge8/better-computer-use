# Development

Module index: [`AGENTS.md`](../AGENTS.md). Design rules: [architecture.md](./architecture.md).
The public command surface lives in `src/cli.ts`, with shared parameter and result types
in `src/contract.ts`; internal complexity belongs in the runtime modules and the native helper.

`skills/better-computer-use/` is the Skill source; `~/.agents/skills/operations/better-computer-use`
is a symlink to it, so edits are live immediately.

## Checks

```bash
npm test                      # every gate in the test script of package.json
BCU_LIVE=1 npm run test:smoke # needs an unlocked desktop session
```

Each `npm run test:*` entry maps to one `scripts/check-*.mjs`; the file header states the
behaviour it protects. A change that breaks a gate is either a regression or a contract
change — in the second case update the gate in the same commit.

## Native helper

`/Applications/bcu.app` targets macOS 14+ and uses ScreenCaptureKit. After Swift changes:

```bash
npm run build:native && node dist/setup-helper.mjs
```

首次运行任意命令时，`ensureInstalled()` 会安装或修复 helper。`build:native` compiles `prebuilt/macos/<arch>/bridge`; `dist/setup-helper.mjs` installs that
binary as the helper app and signs it with a locally generated certificate whose identity is
stable across rebuilds on this machine, because macOS keys the Accessibility and Screen
Recording grants to the code-signing identity. Replacing the binary also restarts the helper
daemon if one is running: it would otherwise keep serving the code it started with, which the
protocol version alone cannot tell apart from the new build. Compile target, frameworks and
bundle id come from `scripts/lib/helper-target.mjs`. Bump `HELPER_PROTOCOL_VERSION` when a
helper request or response changes shape; the Broker refuses a mismatched helper instead
of degrading.

## Upstream engine

The macOS engine tracks `injaneity/pi-computer-use` by hand-porting diffs. See
[ADR 0001](./adr/0001-upstream-tracking-fork.md).
