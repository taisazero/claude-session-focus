# claude-session-focus

Fork-free deeplinks to Claude desktop (Claude Code) sessions on macOS.

`ccfocus://<title substring>` focuses the matching live session in the Claude
desktop app. No snapshot fork, no duplicate session.

```sh
open "ccfocus://RCA%20investigation"                          # by title substring
open "ccfocus://8c328af1-398c-40ee-94ca-20ff53a825be"         # by session id
```

## The problem this solves

The Claude desktop app ships exactly three `claude://` deeplink hosts (`resume`,
`claude.ai/mcp-auth-callback`, `cowork/shared-artifact`) and none of them focus an
existing session. `claude://resume?session=<uuid>` calls `importCliSession`, which
builds a NEW session from the on-disk transcript: a snapshot fork, even when the
original session is open right next to it. The app bundle contains internal
`setFocusedSession` IPC, but no URL host is wired to it.

This tool drives that focus path from the outside: it presses the real sidebar
session row through the macOS Accessibility API. Pressing the row is exactly what a
human click does, so the app switches to the live session.

## How it works

Two pieces:

- `claude-session-focus` (Swift CLI): finds the Claude app process, sets
  `AXManualAccessibility` so Chromium exposes its full accessibility tree, walks the
  tree for the sidebar session row whose title matches, scrolls it visible, and
  performs `AXPress`. Then it raises the app.
- `ClaudeSessionFocus.app` (AppleScript applet built by `install.sh`): registers the
  `ccfocus://` URL scheme with LaunchServices and shells out to the CLI, logging
  every invocation to `last-run.log` in this directory.

## Requirements

- macOS (built and verified on macOS 15 / Darwin 25, Claude desktop v1.21459.0)
- The Claude desktop app, running
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`)

## Install

```sh
git clone git@github.com:taisazero/claude-session-focus.git
cd claude-session-focus
./install.sh
```

`install.sh` compiles the CLI, builds the applet into `~/Applications/`, registers
the `ccfocus` scheme, and ad-hoc signs the app. It bakes the clone location into the
applet, so clone the repo to wherever you want it to live BEFORE installing, and
re-run `install.sh` if you later move the directory.

### Grant permissions (one time)

Accessibility authorization attaches to the process responsible for the AX calls,
so two grants cover the two entry points:

1. System Settings > Privacy & Security > Accessibility > enable
   **ClaudeSessionFocus**. This powers `ccfocus://` links. The app self-prompts on
   its first denied run, which adds it to the list unchecked; toggle it on.
2. Optionally enable your terminal app (or whatever process runs the CLI directly)
   if you want to invoke `./claude-session-focus` without going through links.

Rebuilding the applet (re-running `install.sh`) re-signs it, which can invalidate
the grant. If links stop working after a rebuild, re-toggle the checkbox.

### Verify

```sh
./claude-session-focus --list          # visible session row titles
open "ccfocus://<some title substring, spaces as %20>"
cat last-run.log                       # each run logs its target and outcome
```

## Usage

```sh
# clickable link form, for dashboards, docs, status boards:
open "ccfocus://Fleet%20babysit"

# CLI form:
./claude-session-focus "fleet babysit"     # focus best match
./claude-session-focus --dry "fleet"       # show what would be pressed
./claude-session-focus --list              # list visible rows

# session-id forms: a Claude Code CLI uuid or the app's local_<uuid> both work
# and resolve to the session's CURRENT title, so id links survive renames:
open "ccfocus://8c328af1-398c-40ee-94ca-20ff53a825be"
./claude-session-focus "local_887f7696-63ba-46ef-a097-905ff611d282"
```

In HTML or Markdown surfaces, `<a href="ccfocus://Fleet%20babysit">` works anywhere
custom-scheme anchors are allowed. Browsers gate the click behind an
"Open ClaudeSessionFocus?" confirmation, which is expected. Sandboxed webviews
(inline chat widgets, some embeds) are a different story: custom-scheme
navigation blanks the frame instead of opening the link, and host link bridges
may refuse custom schemes outright (Claude inline widgets do, for both raw
anchors and `openLink()`). In those surfaces fall back to a copyable
`open "ccfocus://..."` command, or have the agent run the `open` command (in
Claude widgets: a `sendPrompt` button that asks the session to run it).

## Matching semantics

- A query shaped like a session id (uuid, or `local_<uuid>`) is first resolved to
  the session's current title via `~/Library/Logs/Claude/main.log`:
  "Mapping internal session" lines map CLI uuids to app-local ids, and
  "LocalSessions.updateSession" lines map local ids to titles. Last write wins,
  so renamed sessions resolve to their current title.
- Case-insensitive. Exact title match wins, then substring.
- The sidebar prefixes running sessions with `Running `; matching ignores it.
- The shallowest match in the accessibility tree wins, which prefers sidebar rows
  over same-named buttons inside chat content.
- If no rendered row matches (the sidebar list is virtualized), the tool presses
  "Load more sessions" up to 3 times and rescans.
- Duplicate titles resolve to the first match; use a longer substring.

Exit codes: `0` focused, `2` no match, `3` press failed, `4` Accessibility not
granted, `5` Claude app not running, `6` session id not resolvable from app logs.

## Limitations

- Id resolution depends on the app's log window: `main.log` (plus `main.log.old`)
  must still contain the session's mapping and title lines. Old sessions rotate
  out; resolution failure exits 6 and a title substring still works. Prefer id
  links for durability (they re-resolve the current title at click time; title
  links break on rename).
- Sessions older than the load-more window are not reachable yet. Fallback ideas:
  drive the sidebar search button (accessibility desc "Search"), or list archived
  sessions through the app's session-management MCP from inside a session.
- Claude app updates can reshape the accessibility tree. Matching anchors on titles
  and roles rather than positions, so cosmetic updates should survive; debug with
  `--dry` and `--list` if a link stops landing.

## Troubleshooting

- `last-run.log` records every link invocation with its target and outcome.
- "Accessibility not granted": re-toggle the ClaudeSessionFocus entry, especially
  after a rebuild (re-signing changes the code signature TCC pinned).
- Links do nothing at all: the scheme registration may be stale. Re-run
  `install.sh`, which re-runs `lsregister`.
- First press after the Claude app launches can need an extra half second while
  Chromium builds the accessibility tree; the CLI already waits for it.

## Uninstall

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u ~/Applications/ClaudeSessionFocus.app
rm -rf ~/Applications/ClaudeSessionFocus.app
# then delete this directory and remove the Accessibility entries in System Settings
```

## Security notes

The Accessibility grant lets these two binaries drive UI on your machine; that is
the entire mechanism, so review `claude-session-focus.swift` and
`wrapper.applescript.template` (about 200 lines total) before granting. The CLI
only ever targets the Claude app bundle id, presses session rows and the load-more
button, and never types text or reads content. An alternative approach, relaunching
the app with `--remote-debugging-port` and calling the internal `setFocusedSession`
bridge over CDP, was rejected because a standing open debug port lets any local
process puppet the app.
