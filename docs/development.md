# Development

## Repository layout

```text
src/cli.ts                       Public CLI command table and output formatting
src/client.ts                    Broker connect-or-start client
src/ipc.ts                       Broker JSON-lines protocol and socket path
src/broker.ts                    Singleton process and lifecycle owner
src/readiness.ts                 Filesystem/process event-driven readiness waits
src/contract.ts                  Standalone command, parameter, and result contract
src/bridge.ts                    Broker-owned runtime and command implementation
src/package-root.ts              Bundle-safe setup-helper path resolution
src/actions.ts                   Action preparation and result reconciliation
src/runtime.ts                   Immutable state store and resource scheduler
src/state.ts                     Saved UI state ownership and restoration
src/view.ts                      Stable refs and resulting-state change views
src/outline.ts                   Outline parsing, folding, search, and ref mapping
src/note.ts                      Disposable running-note generation
native/macos/bridge.swift        macOS helper for AX, capture, permissions, and input
native/windows/                 Windows backend/helper code when developing on Windows
scripts/build-native.mjs         macOS helper build script
scripts/setup-helper.mjs         macOS helper install script
scripts/check-invariants.mjs     Architecture invariant checks
scripts/check-bundled-runtime.mjs Source/dist/packed runtime-path checks
scripts/check-artifacts.mjs       Screenshot path, bytes, and permissions checks
scripts/check-cli-errors.mjs      Stable CLI error and recovery checks
scripts/check-package.mjs         npm tarball and cross-platform helper asset checks
scripts/check-runtime-concurrency.mjs Scheduler/state concurrency checks
scripts/check-broker-lifecycle.mjs Broker singleton, recovery, and idle-exit checks
scripts/check-macos-helper-transport.mjs Persistent helper transport checks
scripts/check-event-readiness.mjs No-polling filesystem/CDP readiness checks
scripts/pi-cubench-agent.mjs     Cubench gateway adapter using the core library
```

The public command surface lives in `src/cli.ts`, with shared parameter and result types in `src/contract.ts`. Keep it small. Internal complexity belongs in `src/bridge.ts`, `src/outline.ts`, `src/note.ts`, and the native helper.

`skills/better-computer-use/` is the Skill source. This machine installs it as a real directory at `~/.agents/skills/operations/better-computer-use/`; recursive Agent Skill discovery does not traverse a directory symlink. Sync the three files after changing the source, then run `~/.agents/scripts/check-skills-project.sh`. The installed copy is a deployment artifact, not a second source tree.

Broker IPC uses a Unix domain socket under `~/Library/Caches/bcu` on macOS and a per-user `\\.\pipe\bcu-broker-*` named pipe on Windows. macOS protects startup and shutdown socket replacement with an `O_EXLOCK` kernel lock; Windows pipe ownership and lifetime are kernel-managed.

## Checks

Run all static checks:

```bash
npm test
```

This runs TypeScript, CLI contract and bundled-layout checks, broker/helper lifecycle checks, architecture invariants, and native helper checks available on the current platform.

On macOS, rebuild the native helper after Swift changes:

```bash
npm run build:native
```

## Architecture rules

The runtime is state-scoped and outline-first:

- `observe-ui` returns a folded UI outline and running note.
- `search-ui`, `expand-ui`, and `inspect-ui` provide progressive disclosure.
- `act-ui` is the only public desktop action entrypoint.
- UI observations are immutable records; request-local hydration replaces global current state.
- The shared broker is the only process that owns saved states, resource scheduling, and CDP connections; CLI clients are stateless.
- Cached queries bypass scheduling; live work is ordered per physical resource.
- Browser pages and desktop surfaces share the `@r` root forest and `@e` outline contract.
- The helper owns grounding, preflight, execution, and verification.
- Removed direct operations such as `screenshot`, `click`, `set_text`, and `computer_actions` should not reappear as public CLI commands.

Run invariants after architecture changes:

```bash
npm run test:invariants
```

Set `BCU_LIVE=1` only when you want live helper checks in addition to static checks.

## Cubench

`scripts/pi-cubench-agent.mjs` drives a headed Cubench Chromium window through the shared bcu broker. Cubench must launch its web driver headed (the current development tree accepts `CUBENCH_HEADLESS=0`):

```bash
CUBENCH_HEADLESS=0 node ../cubench/bin/cubench.mjs suite run \
  --suite ../cubench/suites/core.json \
  --agent "node --experimental-transform-types $PWD/scripts/pi-cubench-agent.mjs" \
  --driver web \
  --trials 3 \
  --label picu
```

The adapter uses Cubench only for the instruction and final oracle; `find-roots`, `observe-ui`, `search-ui`, and `act-ui` all go through `requestBroker`, so it shares state and resource epochs with every other agent. `scripts/check-cubench-agent-broker.mjs` locks this routing contract without requiring a Cubench installation. Gateway action/observation counters do not trigger Cubench interference hooks, so stale/reorder cases still need a native-driver integration before their interference timing can be treated as benchmark evidence.

## Native platform helpers

On macOS, the helper installed for permissions is:

```text
/Applications/bcu.app
```

The macOS helper targets macOS 14+ and uses ScreenCaptureKit. Local development can use ad-hoc signing. Release builds must use the release workflow so the helper app is signed with the stable release certificate.

On Windows, development uses the Windows platform backend/helper and the active desktop session rather than the macOS app bundle or TCC permission model. The checkout and npm tarball must contain `prebuilt/windows/windows-bridge.exe`; runtime installation must not depend on Cargo. The current checked-in binary matches the upstream v0.4.3 release SHA-256 `c18af24ea1fe993053abfaf3edb24e4a65e2d88cfa9c25160f3165223dc57d6f`; the release workflow rebuilds it from the current Rust source.

The Windows CI job hashes the committed prebuilt, runs `npm test`, packs and globally installs that unchanged tarball, checks `where bcu`, then executes `bcu doctor` and `bcu find-roots`. Only after the package smoke does CI build current Rust source to a temporary output; the final hash check prevents that build from replacing the shipped prebuilt.

## Release signing

This section applies to macOS releases. macOS TCC keys Accessibility and Screen Recording grants to an app's code-signing identity. Ad-hoc and locally self-signed development builds may require permission review whenever their native code changes. Only Developer ID-signed release bundles should be treated as having a stable update identity.

Release setup:

1. Run `./scripts/make-signing-cert.sh` once, or use a Developer ID Application certificate.
2. Add repository secrets:
   - `APPLICATION_CERT_BASE64`
   - `CERT_PASSWORD`
   - `SIGN_IDENTITY`
3. For Developer ID notarization, set repository variable `NOTARIZE=true` and add:
   - `TEAM_ID`
   - `APPLE_ID`
   - `APP_SPECIFIC_PASSWORD`
4. Push a `v*` tag or run the `Release` workflow manually.

For macOS, `.github/workflows/publish-npm.yml` builds the universal helper, signs it, optionally notarizes it, stages a draft GitHub Release, injects the same signed helper app into the npm package, publishes npm, and only then publishes the GitHub Release.
