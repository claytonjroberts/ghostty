# Claylib fork of Ghostty: plan

Goal: replace the tmux tab bar, the stats pane and `claylib-claude-status` polling with native
macOS UI inside Ghostty. Four features:

1. **Claude in every tab**: status mark (waiting / idle / busy), session title, account color.
2. **Billing account**: which Claude account (`~/.config/claude-accounts.yaml`) each tab runs.
3. **Tab grouper**: tabs grouped and ordered by repo, colored by repo, hover, drag, `+` per group.
4. **Status bar**: CPU, memory meter plus swap, battery drain rate over 5m / 15m / 1h.

## Ground rules

- **Swift only, in one folder.** New code lives in `macos/Sources/Features/Claylib/`. Existing
  upstream files get a few lines each to mount our views. No Zig changes, so rebasing onto upstream
  stays cheap. Rebase on each upstream release tag.
- **One source of truth stays in claylib.** Repo name and color come from
  `claylib-tab-color --dir <cwd> --meta`; accounts come from `claude-accounts.yaml`. The fork
  calls or reads these, and never copies their logic.
- **Push, don't poll.** Watch files with `DispatchSource` / FSEvents. Sample system stats once per
  app, not once per window, and only while a window is visible. That fixes the battery problem tmux had.
- **Tests**: XCTest in `macos/Tests/Claylib/` for the parsing and mapping logic. Bug fixes go red, then green.

## What already exists upstream

- Native tabs, where each tab is an `NSWindow` in a tab group, so hover and drag come for free.
- A per-tab color, but only from a fixed palette:
  - `TerminalTabColor.swift`
  - the indicator view at `TerminalWindow.swift:29`
- Each surface's `pid`, `tty` and working directory (OSC 7). See `ScriptTerminal.swift`.
- Tab title overrides, through `TabTitleEditor` and AppleScript `name override`.

## Data sources

| Need | Source | How a tab is matched |
|---|---|---|
| Claude status, title | `~/.claude*/sessions/*.json` and `~/.claude-accounts/*/sessions/*.json`: `pid`, `status`, `name`, `nameSource` | Claude `pid` to its controlling tty (`proc_pidinfo`), compared with the surface's `tty` |
| Account label and color | The registry file's directory, matched to `config_dir` in `claude-accounts.yaml` (read through `yq -o json` when the file changes) | Same match as above |
| Repo, repo color, branch | `claylib-tab-color --dir <pwd> --meta`, run when the surface's pwd changes | The surface's pwd |
| CPU, memory, swap | `host_statistics64`, `sysctl vm.swapusage` | Global |
| Battery rate | `IOPSCopyPowerSourcesInfo`, a ring buffer of samples | Global |

## Phases

Each phase ships something usable on its own.

### 0. Build the baseline (half a day)
- Install Zig 0.17. It isn't installed now; Xcode 27.2 is.
- Build the macOS app following `macos/AGENTS.md` / `HACKING.md`. Run the debug build next to the
  installed Ghostty; the debug build has its own bundle id.
- Add a `claylib` branch and a `just`/make target that builds the app and installs it to `/Applications`.

### 1. Claude in the native tabs (1-2 days)
- `ClaudeSessions`: watches the registry directories, parses the files, maps pid to tty, publishes
  `[tty: ClaudeTab]`.
- `Accounts`: loads `claude-accounts.yaml`.
- Tab title: the Claude title when it was set rather than derived, else the branch, else the shell title.
  A status mark comes first.
- Make the tab color indicator take any `NSColor`, so it can show the account color as a block.
- Done when the tabs show a live status, title and account with no tmux running.

### 2. Status bar (1-2 days)
- A SwiftUI strip at the bottom of each window, mounted in `TerminalView`. It holds the account box
  and the stats.
- Port `claylib-sysstats`: CPU sparkline, a 20-cell memory meter (yellow at 80%, red at 90%), swap,
  and battery %/h over 5m, 15m and 1h with the same colors.
- One `SystemStats` sampler every 2 s, paused when the app is hidden or no window is visible.
- Port the current sysstats tests to XCTest.

### 3. Tab grouper (3-5 days, the riskiest part)
- **Step A (cheap):** keep the native tab bar. Reorder the tab group's windows so each repo's tabs
  sit together, and color each tab with its repo color. Native drag still works; regroup after a drop.
- **Step B (only if group labels are wanted):** hide the native tab bar and draw our own SwiftUI
  strip from the tab group: repo labels, pills with the account block, hover easing, drag preview,
  `+` per group that opens a tab in that repo. `tabs.tsx` is the visual spec.
- Decide between A and B after A is used for a few days.

### 4. Deeper Claude integration (open-ended)
- Waiting-on-you alerts: badge the tab and the dock, with an optional notification, when a session
  turns `waiting`. Clicking jumps to the tab.
- A command-palette entry to jump to the next waiting session.
- Claude Code hooks can already write OSC 9;4 progress and OSC 777 notifications to the terminal,
  and Ghostty handles both. Use those before inventing any IPC.

### 5. Cutover and cleanup
- Point claylib's install at the fork build.
- Delete what the fork replaces, with no shims:
  - in `claylib/tmux/`: the tab bar, the stats config and `ui/`
  - `claylib-tmux-tabs`, `claylib-sysstats`, `claylib-claude-status`
  - their tests and links
- Keep tmux itself only if session persistence is still wanted (see Decisions).

## Decisions to confirm

1. **Drop tmux: decided.** Everything that moved into tmux panes (tab bar, stats, account box)
   lives in Ghostty instead. Phase 5 deletes the tmux UI.
2. **Tab grouper**: start with step A (native tabs, sorted and colored) and move to B only if repo
   labels are missed.
3. **Billing account scope**: the account label and color per tab. If "billing" should also mean
   usage or cost, we need a data source: Claude Code doesn't expose per-account spend in the registry.

## Risks

- Hiding the native tab bar (step B) fights AppKit, as the Tahoe titlebar code in
  `TitlebarTabsTahoeTerminalWindow.swift` shows. That is why step A comes first.
- The session registry is Claude Code's internal format and could change. Parsing stays in one
  file, with tests on real samples.
- Upstream churn in `TerminalView` / `TerminalWindow`. We keep our edits there to a few lines each.
