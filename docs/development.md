# Development

## Repository layout

```text
src/cli.ts                       Public CLI command table, parsing, output, platform guard
src/client.ts                    Broker connect-or-start client
src/ipc.ts                       Broker JSON-lines protocol and socket path
src/broker.ts                    Singleton process, command dispatch, doctor and setup
src/contract.ts                  Command, parameter, and result contract
src/session.ts                   Operation state, scheduling, saved states, tool executor
src/roots.ts                     Root discovery, target selection, find-roots
src/root-refs.ts                 Stable @r identity across a session
src/observe.ts                   Look capture, result rendering, cached queries
src/act.ts                       Checked action transactions and postconditions
src/actions.ts                   Action validation, preparation, outcome reconciliation
src/runtime.ts                   Immutable state store and resource scheduler
src/state.ts                     Saved UI state ownership and hydration
src/outline.ts                   Outline parsing, folding, search, and ref mapping
src/view.ts                      Stable refs and resulting-state change views
src/note.ts                      Disposable running-note generation
src/readiness.ts                 Filesystem event-driven readiness waits
src/artifacts.ts                 Screenshot files, permissions, and capacity
src/macos/helper.ts              Persistent helper transport and install/repair
src/macos/backend.ts             Helper command surface used by the runtime
src/macos/protocol.ts            Helper wire types, coercion, architecture assertion
src/macos/permissions.ts         Permission probe and readiness
native/macos/bridge.swift        AX, capture, permissions, and input delivery
native/macos/agent_cursor*.swift Agent cursor overlay and motion
scripts/build-native.mjs         Helper build script
scripts/setup-helper.mjs         Helper install and local signing
scripts/lib/harness.mjs          Shared broker/CLI test harness
scripts/check-*.mjs              Regression and architecture checks
scripts/bench.mjs                Helper and broker benchmarks
```

The public command surface lives in `src/cli.ts`, with shared parameter and result
types in `src/contract.ts`. Keep it small: internal complexity belongs in the four
runtime modules, `src/outline.ts`, and the native helper.

`skills/better-computer-use/` is the Skill source. This machine installs it as a real
directory at `~/.agents/skills/operations/better-computer-use/`; recursive Agent Skill
discovery does not traverse a directory symlink. Sync the files after changing the
source, then run `~/.agents/scripts/check-skills-project.sh`. The installed copy is a
deployment artifact, not a second source tree.

Broker IPC uses a Unix domain socket under `~/Library/Caches/bcu`. Startup and shutdown
socket replacement is protected with an `O_EXLOCK` kernel lock.

## Checks

```bash
npm test
```

This runs TypeScript, CLI contract and bundled-layout checks, broker and helper
lifecycle checks, architecture invariants, packaging checks, and the Swift typecheck.

Live checks need a real desktop session:

```bash
BCU_LIVE=1 npm run test:smoke        # TextEdit end-to-end smoke
BCU_LIVE=1 npm run test:invariants   # helper invariants against the running helper
```

Rebuild the native helper after Swift changes:

```bash
npm run build:native
```

## Architecture rules

The runtime is state-scoped and outline-first:

- `observe-ui` returns a folded UI outline and running note.
- `search-ui`, `expand-ui`, and `inspect-ui` provide progressive disclosure.
- `act-ui` is the only public action entrypoint.
- UI observations are immutable records; request-local hydration replaces global current state.
- The broker is the only process that owns saved states and resource scheduling; CLI clients are stateless.
- Cached queries bypass scheduling; live work is ordered per physical resource.
- The helper owns grounding, preflight, execution, and verification.
- Removed direct operations such as `screenshot`, `click`, `set_text`, and `computer_actions` must not reappear as public CLI commands.
- bcu is macOS-only and has no browser or CDP code path. Page-level automation belongs to `flow-browser-use`.

Run invariants after architecture changes:

```bash
npm run test:invariants
```

## Upstream engine

The macOS engine tracks `injaneity/pi-computer-use` by hand-porting diffs. See
[ADR 0001](./adr/0001-upstream-tracking-fork.md).

## Native helper

The installed helper used for permissions is:

```text
/Applications/bcu.app
```

It targets macOS 14+ and uses ScreenCaptureKit. Local development can use ad-hoc
signing. Release builds must use the release workflow so the helper app is signed with
the stable release certificate.

## Release signing

macOS TCC keys Accessibility and Screen Recording grants to an app's code-signing
identity. Ad-hoc and locally self-signed development builds may require permission
review whenever their native code changes. Only Developer ID-signed release bundles
should be treated as having a stable update identity.

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

`.github/workflows/publish-npm.yml` builds the universal helper, signs it, optionally
notarizes it, stages a draft GitHub Release, injects the same signed helper app into the
npm package, publishes npm, and only then publishes the GitHub Release.
