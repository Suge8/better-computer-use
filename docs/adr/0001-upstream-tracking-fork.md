# Hand-port the upstream macOS engine, own everything else

bcu began as a fork of `injaneity/pi-computer-use` and has since diverged on purpose:
it is macOS-only, has no browser or CDP path, exposes a standalone CLI contract
(`ToolResult` text, `BcuError` codes, broker-backed commands), and splits the runtime
into session, roots, observe, and act modules. Upstream still evolves the parts bcu
cares about: the Swift helper's accessibility traversal, capture, grounding, input
delivery, and root discovery.

Decision: treat upstream as an engine reference, not a merge parent. When syncing,
read the diff for the engine surface only and port the relevant hunks by hand:

```bash
git fetch upstream
git diff upstream/main -- native/macos src/macos
```

Port what applies to the macOS engine; reimplement fixes that touch bcu-owned layers in
bcu's own structure; drop everything else. All identities stay bcu-owned: `BCU_*` env
vars, `~/.bcu` helper paths, `com.sugeh.bcu`, `bcu.app`.

Rejected: whole-repository `git merge upstream/main`. Most upstream churn now lands in
directories bcu deleted (Windows and Linux helpers, browser/CDP control, the Pi
extension tool layer), so every merge would be a conflict-resolution exercise that
re-adds deleted platforms before deleting them again. Keeping a current merge base is
worth less than keeping the tree small, and the engine surface that actually matters is
two directories wide.

Rejected: vendoring upstream's Swift helper as an unmodified dependency. bcu's helper
carries local protocol changes (architecture invariants, batched transactions, the agent
cursor) that upstream does not have.
