# Hand-port the upstream macOS engine, own everything else

bcu began as a fork of `injaneity/pi-computer-use` and has since diverged on purpose:
it is macOS-only, has no browser or CDP path, exposes a standalone CLI contract
(one top-level JSON result per command, `BCUError` codes, one resident process behind
every command), and splits the code into a pure logic core, a platform-free runtime, the
platform layer and the resident command handlers. Upstream still evolves the parts bcu
cares about: its Swift helper's accessibility traversal, capture, grounding, input
delivery, and root discovery.

Decision: treat upstream as an engine reference, not a merge parent. When syncing,
read upstream's changes to the engine surface only and port the relevant hunks by hand.
Upstream keeps the helper under `native/macos`; bcu's port is split across
`Sources/BCUPlatform`, so read upstream's own history rather than a diff against bcu's tree:

```bash
git fetch upstream
git log -p upstream/main -- native/macos src/macos   # newest first, down to the last ported change
```

Port what applies to the macOS engine; reimplement fixes that touch bcu-owned layers in
bcu's own structure; drop everything else. All identities stay bcu-owned: `BCU_*` env
vars, `~/Library/Caches/bcu` paths, `com.sugeh.bcu`, `bcu.app`.

Rejected: whole-repository `git merge upstream/main`. Most upstream churn now lands in
directories bcu deleted (Windows and Linux helpers, browser/CDP control, the Pi
extension tool layer), so every merge would be a conflict-resolution exercise that
re-adds deleted platforms before deleting them again. Keeping a current merge base is
worth less than keeping the tree small, and the engine surface that actually matters is
two directories wide.

Rejected: vendoring upstream's Swift helper as an unmodified dependency. bcu runs the
platform in process behind its own API, with element handles owned by saved states and the
agent cursor, none of which upstream has.
