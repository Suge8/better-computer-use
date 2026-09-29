# Development

Module index: [`AGENTS.md`](../AGENTS.md). Design rules: [architecture.md](./architecture.md).
Why one Swift process: [ADR 0002](./adr/0002-single-swift-process.md).

`skills/better-computer-use/` is the Skill source; `~/.agents/skills/operations/better-computer-use`
is a symlink to it, so edits are live immediately.

## Build and install

`Package.swift` builds one executable, `bcu`: without arguments beyond a command it is the
client, and `bcu serve` is the resident process that runs inside `bcu.app`.

```bash
swift build --product bcu     # a debug client in .build/debug/bcu
scripts/install.sh            # release build installed as /Applications/bcu.app and linked as bcu
```

The resident process must run as `bcu.app`, launched through LaunchServices
(`open -n -g bcu.app --args serve`): macOS attributes Accessibility and Screen Recording to
the app that way, and keys the grants to its bundle id and code-signing identity. The
install script therefore signs with a self-signed identity it creates once per Mac
(`bcu Local Signing (com.sugeh.bcu)` in the login keychain), and `BCU_CODESIGN_IDENTITY`
overrides it. A debug client can drive the installed resident as long as both speak the
same wire protocol (`wireProtocolVersion` in `Sources/BCURuntime/Wire.swift`); bump it when
a request or result changes shape, and reinstall.

## Checks

```bash
npm test                      # swift test, then the CLI black-box gates
BCU_LIVE=1 npm run test:smoke # the live gates; needs an unlocked desktop and a current install
```

Node runs only the `scripts/check-*.mjs` gates; bcu itself does not need it. Each gate's
header states the behaviour it protects. The CLI gates build the debug `bcu` and drive it
against a scripted resident or a throwaway app bundle, so they need no permissions. The live
gates drive the installed `bcu.app` (or `BCU_BIN` / `BCU_APP_PATH`), each on its own socket
through `BCU_SOCKET_PATH`, so run `scripts/install.sh` after Swift changes and before them.
A change that breaks a gate is either a regression or a contract change — in the second
case update the gate in the same commit.

## Swift core

`BCUCore` is the pure logic library (outline, projection, successor changes, search,
contract types, errors, action validation and preparation, CLI parsing and rendering), with
Swift 6 strict concurrency and no AppKit dependency.

```bash
swift test --filter projection   # one golden file: outline, projection, view, actions, errors, cli, queries
```

`Tests/BCUCoreTests/Golden/` holds the expected outputs byte for byte. They were recorded
from the retired TS implementation and are now the contract itself: a behaviour change
edits the affected cases by hand and commits them on their own, before the code.

## Upstream engine

The macOS engine tracks `injaneity/pi-computer-use` by hand-porting diffs. See
[ADR 0001](./adr/0001-upstream-tracking-fork.md).
