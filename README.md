# claude-status-line

A lightweight, minimal Claude Code status line. **Pure shell + `jq`** — no Node,
no TypeScript, no build step.

```
 Opus 4.8 (1M context)  󰓅 low  󰍛 7%   main
5h  ●●○○○○○○○○   22%   2026-07-22 20:00
7d  ●●○○○○○○○○   16%   2026-07-24 14:00
```

## Layout

| Line | Content |
|------|---------|
| 1 | ` Model  │  󰓅 Effort  │  󰍛 Context%  │   branch` |
| 2 | `5h` — 5-hour token window: 10-circle bar, `%`, reset timestamp |
| 3 | `7d` — weekly (7-day) token window: same format |

Branch appears only inside a repo. Fields are separated by a dim Powerline soft
divider ``.

**Requires a truecolor terminal** (iTerm2, WezTerm, Kitty, …) **and a
[Nerd Font](https://www.nerdfonts.com/)** for the icons (` 󰓅 󰍛  `); without a
Nerd Font they render as tofu — swap them in the glyph block at the top of
`statusline.sh`.

### Colors — restraint by design

Structure (icons, dividers, labels, timestamps) is **dim**; color is reserved for
signals that deserve attention.

- **Context & tokens** (by usage): `< 30%` green · `30–70%` yellow · `≥ 70%` red.
- **Model** (bold name; icon colored by family): Sonnet green · Opus yellow ·
  Fable red · Haiku / unknown neutral.
- **Effort** — quiet unless expensive: `low`/`medium` dim · `high` red ·
  `xhigh` purple · `max` bold red.

### Startup cache

`rate_limits` is empty until the first API response (~10–15 s), so the two token
lines are cached to `~/.claude/statusline-cache.json` (a single, fixed-size,
atomically-overwritten file). During the warm-up window the last-known numbers
are shown with a dim `~` prefix; context shows a `⋯` skeleton until live.

### Responsive

Adapts to `COLUMNS`: **wide** shows everything; **medium** shortens the model
name and uses an `MM-DD HH:MM` timestamp; **narrow** drops the branch and
timestamps and shows only the model's first word.

## Requirements

- [`jq`](https://jqlang.org/) — used by both the status line and the installer.
  Install with `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).

## Install (one command)

```sh
curl -fsSL https://raw.githubusercontent.com/underdog-org/minimal-claude-statusline/main/install.sh | sh
```

This downloads `statusline.sh` to `~/.claude/statusline.sh` and atomically merges
a `statusLine` block into `~/.claude/settings.json` (your other settings are
preserved). `refreshInterval: 10` keeps the reset countdown fresh while idle.
Re-running is safe — it just overwrites the `statusLine` key.

Then restart Claude Code and accept the workspace-trust dialog if prompted.

**Uninstall:**

```sh
curl -fsSL https://raw.githubusercontent.com/underdog-org/minimal-claude-statusline/main/install.sh | sh -s -- uninstall
```

### Prefer not to pipe into a shell?

Download and inspect first, then run:

```sh
curl -fsSLO https://raw.githubusercontent.com/underdog-org/minimal-claude-statusline/main/install.sh
less install.sh          # review it
sh install.sh            # or: sh install.sh uninstall
```

### Manual install

1. Copy the script and make it executable:
   ```sh
   cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
   ```
2. Add this block to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "refreshInterval": 10,
       "padding": 0
     }
   }
   ```
3. Restart Claude Code.

## Test without Claude Code

```sh
# full data (Pro/Max subscriber)
echo '{"model":{"display_name":"Opus 4.8"},"effort":"high","context_window":{"used_percentage":45.3},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1753200000},"seven_day":{"used_percentage":82.7,"resets_at":1753600000}}}' | ./statusline.sh

# after /compact (null context) + no subscription rate_limits
echo '{"model":{"display_name":"Sonnet 5"},"context_window":{"used_percentage":null}}' | ./statusline.sh
```

## Design constraints

- **Single `jq` pass** (`@tsv`) extracts all 7 fields at once → fast cold start.
- **No temp files, no cached state** → no leaks, no staleness. (No git calls, so
  no caching is needed.)
- **Graceful fallbacks**: `rate_limits` is absent for non–Pro/Max users and until
  the first API response → shows `n/a`. `context_window.used_percentage` is `null`
  at session start and after `/compact` → treated as `0`.
- **Portable dates**: `date -r` (macOS/BSD) with a `date -d @` (GNU/Linux) fallback.

## Customize

Everything tweakable lives in the constants block at the top of `statusline.sh`:
colors (`GREEN`/`YELLOW`/`RED`), bar characters (`FILLED`/`EMPTY`), bar length
(`BAR_LEN`), and thresholds (`LOW`/`HIGH`).
