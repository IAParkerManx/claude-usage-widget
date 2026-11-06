# Claude Usage Widget

A native macOS menu bar app that shows how much of your Claude Pro/Max plan limits are left: the 5-hour and 7-day windows, with a countdown to each reset. An optional floating overlay shows the same figures, along with your recent token activity.

## How it works

Claude Code passes `rate_limits` to its status line command after every response. This app is built as a single binary that runs in two modes:

- `ClaudeUsage --statusline` is set as Claude Code's `statusLine` command. It records the limits to `~/.claude/usage-widget/limits.json` and prints a short status line.
- Run normally, it is the menu bar app. It reads that file, and adds token activity from your local Claude Code transcripts.

The app has no network calls and needs no API key.

## Build

Requires macOS 14+ on Apple Silicon and the Xcode command line tools.

```bash
./build.sh
```

This compiles `ClaudeUsage.swift` with `swiftc`, ad-hoc signs it, and installs `ClaudeUsage.app` to `~/Applications`.

Then add this to `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --statusline" }
```

## Stack

Swift, SwiftUI and Cocoa, in a single source file with no dependencies.
