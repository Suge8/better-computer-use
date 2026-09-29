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

## Swift core

`Package.swift` builds `BCUCore`, the pure logic library (outline, projection, successor
changes, search, contract types, errors, action validation and preparation, CLI parsing and
rendering), with Swift 6 strict concurrency for macOS 14+. It has no AppKit dependency.

```bash
swift test                       # also run by npm test as test:swift, with the helper build
swift test --filter projection   # one golden file: outline, projection, view, actions, errors, cli, queries
```

`Tests/BCUCoreTests/Golden/` holds the outputs the TS implementation produced on the same
inputs; every case must match byte for byte. `node scripts/generate-swift-golden.mjs`
regenerates them from the TS code. Where the Swift core deliberately differs, the generator
states the difference and writes the Swift expectation: numeric CLI options accept only
non-negative decimal integers.

## Native helper

The helper is the SwiftPM `bridge` product: `Sources/bridge` is only its entry point, and
`BCUPlatform` holds everything it does behind the in-process `Platform` API. The platform
targets stay in the Swift 5 language mode (see `Package.swift`). `/Applications/bcu.app`
targets macOS 14+ and uses ScreenCaptureKit. After Swift changes:

```bash
npm run build:native && npm run build && node dist/setup-helper.mjs
```

`ensureInstalled()` installs or repairs the helper before the first command that uses it.
`build:native` runs `swift build -c release` for arm64 and x86_64 (`--arch arm64|x64` builds
one) and places each binary at `prebuilt/macos/<arch>/bridge`; `dist/setup-helper.mjs`
installs that binary as the helper app and signs it with a locally generated certificate
whose identity is stable across rebuilds on this machine, because macOS keys the
Accessibility and Screen Recording grants to the code-signing identity. Replacing the binary
also restarts the helper daemon if one is running: it would otherwise keep serving the code
it started with, which the protocol version alone cannot tell apart from the new build.
Bundle id and deployment target come from `scripts/lib/helper-target.mjs`. Bump
`helperProtocolVersion` in `Sources/BCUPlatform/WireProtocol.swift` together with
`HELPER_PROTOCOL_VERSION` in `src/macos/helper.ts` when a helper request or response
changes shape; the Broker refuses a mismatched helper instead of degrading.

## Upstream engine

The macOS engine tracks `injaneity/pi-computer-use` by hand-porting diffs. See
[ADR 0001](./adr/0001-upstream-tracking-fork.md).
