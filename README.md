# Claude Beacon

Native macOS notifications for [Claude Code](https://claude.com/claude-code)
terminal sessions. When a session **finishes** or **needs you** (a permission
prompt or input), a Liquid‑Glass panel slides in from the corner of your screen.
Click **Focus Terminal** to jump straight back to the exact terminal that raised
it — even across many tabs, windows, and terminal apps.

Built for people who run several Claude sessions at once and keep losing track
of which one needs attention.

![position: bottom-left · one panel per session · stacks without overlap](<>)

---

## Features

- **Per‑session panels** — one notification per session, tied to its terminal.
- **Jump to the exact terminal** — _Focus Terminal_ brings the precise tab/pane
  to the front (see the support matrix below).
- **Focus‑aware auto‑dismiss** — a panel clears itself when you focus _its own_
  terminal; panels for other terminals stay put.
- **Two kinds** — `done` (a turn finished, green stripe) and `attention` (needs
  input or a permission decision, amber stripe).
- **Non‑intrusive** — the panel never steals keyboard focus; keep typing.
- **Subagent‑aware** — subagent lifecycle notifications (a session spawning
  subagents) don't each raise a panel; only events you act on do. Tunable via
  `notifications.suppressTypes`.
- **Stacks any number** — panels tile from the corner and wrap into columns;
  when more than a few pile up unattended they collapse into one macOS‑style
  stack you click to fan open (and it re‑collapses when idle again).
- **Fully themeable** — position, size, transparency, material, colors, fonts,
  animation, sound, and per‑type timeouts, all in one JSON file.

---

## Requirements

- macOS (Liquid Glass on macOS 26+, otherwise a frosted fallback).
- Xcode Command Line Tools (`xcode-select --install`) — to compile the panel.
- `jq` (preinstalled on modern macOS, else `brew install jq`).
- Claude Code (the hooks live in your Claude settings).
- Optional: the bundled **VS Code extension**, required only for exact
  per‑terminal focus/dismiss inside VS Code.

---

## Install

```bash
cd claude-beacon
./install.sh
```

This will:

1. Deploy the runtime to `~/.claude-beacon/` (binary, hook, config, `state/`).
2. Compile the native panel.
3. Install the VS Code companion extension to `~/.vscode/extensions/claude-beacon`.
4. Wire `Stop` + `Notification` hooks into `~/.claude/settings.json`.

Then, **once**:

1. **Reload VS Code** (`Cmd+R`, or _Developer: Reload Window_) to load the
   extension.
2. Add the keybinding (if the installer didn't find it) to VS Code
   `keybindings.json`:
   ```json
   { "key": "cmd+f19", "command": "claudeBeacon.focusTerminal" }
   ```
3. The first time _Focus Terminal_ runs, grant **Accessibility** permission to
   your editor/terminal app (System Settings → Privacy & Security →
   Accessibility). Only needed for the keystroke that focuses the terminal.

### Multiple Claude homes

The installer targets `~/.claude` by default. To wire other homes:

```bash
CLAUDE_HOMES="$HOME/.claude $HOME/.claude-work" ./install.sh
# or pass explicit settings.json paths:
./install.sh ~/.claude-work/settings.json
```

---

## Configuration

Everything lives in `~/.claude-beacon/config.json`. Edit and save — changes
apply to the **next** notification, no rebuild needed.

```jsonc
{
  "timeouts": { "done": 30, "attention": 0 }, // auto-dismiss seconds; 0 = never

  // Notification-event handling.
  "notifications": {
    // Notification .notification_type values that never raise a panel. Subagent
    // lifecycle (e.g. a subagent finishing) fires one per action and floods
    // otherwise; real prompts (permission_prompt, idle_prompt, ...) still show.
    "suppressTypes": ["agent_completed"],
    // Flip to true to append every raw hook payload to
    // state/debug-payloads.log, so you can read the exact notification_type
    // values your setup emits and tune suppressTypes. Turn back off when done.
    "debugLog": false,
  },

  // When more than `threshold` panels are alive and none has been acted on for
  // `delaySeconds`, they collapse into one macOS-style stack you click to fan
  // open (re-collapsing after another idle period). A brand-new panel peeks on
  // its own for `peekSeconds` before joining.
  "stacking": {
    "enabled": true,
    "threshold": 3,
    "delaySeconds": 20,
    "peekSeconds": 2.0,
    "cascadeOffset": 8, // px each stacked card peeks behind the front one
  },

  "sound": "Glass", // macOS system sound; "" = silent
  "position": "bottom-left", // bottom-left | bottom-right | top-left | top-right
  "size": { "width": 420, "height": 120 },
  "spacing": { "margin": 16, "gap": 12 }, // screen margin, gap between panels
  "cornerRadius": 22,
  "opacity": 1.0, // 0.0 (clear) .. 1.0 (opaque)
  "material": "liquid-glass", // liquid-glass | vibrancy | dark | light
  "minVisibleSeconds": 2.0, // shortest time a panel shows before focus-dismiss
  "slideOffset": 40, // slide-in/out distance
  "animation": { "appear": 0.28, "dismiss": 0.24, "reflow": 0.25 },

  "accent": {
    // left stripe color per kind
    "done": "#34C759",
    "attention": "#FF9F0A",
  },

  "title": { "fontSize": 14, "textColor": "" }, // "" = system default (light/dark aware)
  "message": { "fontSize": 12, "textColor": "" },

  "icon": "/Applications/Claude.app/Contents/Resources/electron.icns",

  "buttons": {
    "focus": {
      "label": "Focus Terminal",
      "backgroundColor": "",
      "textColor": "",
    },
    "dismiss": { "label": "Dismiss", "backgroundColor": "", "textColor": "" },
  },
}
```

**Color fields** take a hex string like `#0A84FF`. An empty string means "use the
system default" (adapts to light/dark). `buttons.focus.backgroundColor` empty
falls back to the system accent color.

### Updating the configuration

Edit `~/.claude-beacon/config.json` and save — that's the whole workflow. The
hook and the panel read the config **fresh on every notification**, so changes
apply to the **next** one that fires. No rebuild, reinstall, or reload needed.

- **This runtime file is the one that matters.** `hook/config.json` in the
  project is only the default template, seeded on first install.
- **Re-running `./install.sh` never overwrites your config** — it keeps an
  existing `~/.claude-beacon/config.json` untouched.
- **Preview a change immediately** without waiting for a session to finish:
  ```bash
  ~/.claude-beacon/beacon-panel "Test" "Preview my config" "" done 0 "" ""
  ```
- **Reset to defaults:**
  ```bash
  cp ~/Desktop/Personal/claude-beacon/hook/config.json ~/.claude-beacon/config.json
  ```

---

## How focus & dismiss work

Both _Focus Terminal_ and auto‑dismiss target the **exact** terminal by its tty.
Precision depends on what each terminal app exposes:

| Terminal            | Focus a specific tab/pane  | Auto‑dismiss on its focus  |
| ------------------- | -------------------------- | -------------------------- |
| **VS Code**         | ✅ via companion extension | ✅ via companion extension |
| **Terminal.app**    | ✅ (AppleScript, by tty)   | ✅ (AppleScript, by tty)   |
| **iTerm2**          | ✅ (AppleScript, by tty)   | ✅ (AppleScript, by tty)   |
| **WezTerm**         | ✅ (`wezterm cli`)         | ✅ (`wezterm cli`, by tty) |
| **Warp**            | ✅ (`WARP_FOCUS_URL`)      | ➖ click to dismiss¹       |
| **Ghostty / other** | ➖ app foreground          | ➖ click to dismiss        |

¹ Warp exposes no way for an external tool to know which tab is focused, so a
Warp panel never app‑level auto‑dismisses (which would wrongly clear across
tabs) — dismiss it with the button.

---

## Project layout

```
claude-beacon/
├── install.sh                 installer (idempotent)
├── hook/
│   ├── beacon.sh              the Stop/Notification hook
│   ├── beacon-panel.swift     the native panel (compiled at install)
│   └── config.json            default config (seeded on first install)
└── vscode-extension/
    ├── package.json
    └── extension.js           reports focused terminal + focuses by tty
```

Runtime (created by the installer):

```
~/.claude-beacon/
├── beacon.sh   beacon-panel   config.json
└── state/  →  slots/   focused/   focus-target
```

---

## Uninstall

```bash
# remove the runtime and extension
rm -rf ~/.claude-beacon ~/.vscode/extensions/claude-beacon
# remove the "Stop" and "Notification" hooks from your Claude settings.json
# and the cmd+f19 binding from VS Code keybindings.json
```

---

## Troubleshooting

- **Extension not visible in VS Code** — reload the window (`Cmd+R`); sideloaded
  extensions load on window start.
- **Focus Terminal does nothing (VS Code)** — reload once, and grant
  Accessibility permission the first time.
- **Nothing appears** — confirm the hooks are wired
  (`jq '.hooks' ~/.claude/settings.json`) and that
  `~/.claude-beacon/beacon-panel` exists (re‑run `./install.sh`).
- **Panel steals focus / looks wrong** — you're likely on an old build; re‑run
  `./install.sh`.
