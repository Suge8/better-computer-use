# Hand-port the macOS engine from trycua/cua, own everything else

bcu began as a fork of `injaneity/pi-computer-use` and has since diverged on purpose: it is
macOS-only, has no browser or CDP path, exposes a standalone CLI contract (one top-level JSON
result per command, `BCUError` codes, one resident process behind every command), and splits
the code into a pure logic core, a platform-free runtime, the platform layer and the resident
command handlers. pi-computer-use no longer leads on the parts bcu cares about. The engine
reference is now trycua/cua's macOS driver, `libs/cua-driver/rust/crates/platform-macos`
(Rust, MIT): accessibility enablement and traversal, background input through SkyLight,
focus and delivery rules. bcu's SkyLight rung was ported from it in the first place.

Decision: treat cua as an engine reference, not a merge parent. When syncing, read cua's own
history of the macOS platform layer, down to the last ported commit below, and port the
relevant hunks by hand into `Sources/BCUPlatform`:

```bash
git clone https://github.com/trycua/cua && cd cua
git log -p <last-ported>..origin/main -- libs/cua-driver/rust/crates/platform-macos
```

Port what applies to the macOS engine; reimplement fixes that touch bcu-owned layers in
bcu's own structure; drop everything else (the MCP tool layer, other platforms, cua's cursor,
recording and session machinery). All identities stay bcu-owned: `BCU_*` env vars,
`~/Library/Caches/bcu` paths, `com.sugeh.bcu`, `bcu.app`.

Ported so far, reviewed up to `864fd4e52`:

- `4f7084573`, `1e93424e5`: ask for the tree with AXManualAccessibility, AXEnhancedUserInterface
  only where that is unsupported; wait for a window's AXWebArea to have children; back off
  a timed-out process by pid and start time instead of caching for good.
- `8a66f0d8d`, `8347d6cd8`: confirm keyboard focus on the target before targeted keys, the
  element's own AXFocused counting as confirmation.
- `1dc9b52bd`: a background drag that starts a drag-and-drop session releases at once and
  needs the foreground. Not ported: the brief foreground drag.
- `b1633ef91`: a locked screen is its own error. Not ported: keeping the display awake.
- `f87f19152`: background mouse events carry explicit, empty modifier flags.
- `e32127764`: the defocus half of focus-without-raise was already dropped here. Not
  ported: the per-pid key-focus guard tap.

Rejected: merging or vendoring cua. It is a Rust MCP server with its own tool surface,
session model and cursor; bcu runs the platform in process behind its own API, with element
handles owned by saved states, none of which cua has.

Rejected: keeping pi-computer-use as the reference. Its Swift helper is what bcu started from,
but the background-input and enablement fixes bcu needs land in cua.
