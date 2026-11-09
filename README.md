# wm

A small tiling window manager for macOS, in the spirit of Hyprland:

- **Dwindle auto-layout**: each new window splits the remaining space along its longer side.
- **Up to 9 workspaces**, shown in the menu bar as a domino face (1–9 pips).
- **Configurable gaps**: 2px around and between windows by default.
- **Active window border** drawn in the gap around the focused window.
- **Hot-reloaded config** at `~/.config/wm/config.toml` (created with defaults on first launch).

## Build & run

Requires macOS 14+ and the Swift toolchain (Xcode or `xcode-select --install`).

```sh
make install  # build, install to /Applications/wm.app and relaunch (run after every change)
make test     # unit tests for config parsing, layout, borders and domino icons
```

On first launch macOS asks for **Accessibility** permission (System Settings → Privacy & Security →
Accessibility). wm starts managing windows as soon as it's granted.

That permission is tied to the code signature. Run `scripts/create-signing-identity.sh` once to create
a local "wm Local Signing" certificate; builds are then signed with it automatically and keep the
permission across updates. Without it, builds are ad-hoc signed and must be re-granted after each
update. `CODESIGN_IDENTITY` overrides the identity used.

## Default keys

| Keys | Action |
| --- | --- |
| `⌥1` … `⌥9` | switch to workspace |
| `⌥⇧1` … `⌥⇧9` | move focused window to workspace |
| `⌥H/J/K/L` | focus left / down / up / right |
| `⌥⇧H/J/K/L` | swap with neighbour |
| `⌥⇧Space` | toggle floating |
| `⌥⇧R` | reload config |
| `⌘1` … `⌘9` | switch to workspace |
| `⌘←/↓/↑/→` | focus left / down / up / right |
| `⌘⇧←/↓/↑/→` | swap with neighbour |

Everything is configurable in `[binds]`; see the comments in the generated config file.

## How it works

macOS has no public API for creating Spaces, so workspaces are emulated (as AeroSpace does): windows
on inactive workspaces are parked just off the bottom-right corner of the screen. Quitting wm (menu,
Ctrl-C or `kill`) brings them all back.

Activating a window on another workspace (Cmd-Tab, Dock) switches to that workspace. Dropping a dragged
tiled window onto another tile swaps the two; anywhere else it snaps back into place.

## Multiple displays

With an external display connected, odd workspaces live on the external display and even
workspaces on the MacBook's built-in display, and each display shows one of its workspaces at a
time. Switching to a workspace only changes its own display. Focus keys move across displays. With
more displays, workspaces are dealt out round-robin.

The menu bar has one domino per display, left to right in the same order as the displays are
arranged, each showing that display's workspace. The focused display's domino is drawn solid.

## Current limitations

- Only the dwindle layout.
- Windows on other macOS Spaces aren't seen; use a single macOS Space.

## Profiling

`kill -USR1 $(pgrep -f wm.app/Contents/MacOS/wm)` runs a built-in benchmark of the hot paths
(focus lookup, border updates, re-tiling) without moving any windows. It reports the time per
operation and how many Accessibility round trips each one makes; those block the main thread
until the target app answers, so they're the main cost. Results go to stderr and the unified
log (`/usr/bin/log show --predicate 'subsystem == "local.wm"' --last 5m`).
