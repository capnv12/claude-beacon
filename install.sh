#!/usr/bin/env bash
# Claude Beacon installer.
#
# Deploys the runtime to ~/.claude-beacon, installs the VS Code companion
# extension, and wires the Stop/Notification hooks into your Claude settings.
#
# Usage:
#   ./install.sh                 # installs hooks into ~/.claude/settings.json
#   ./install.sh <settings.json> # also wire an additional Claude home
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BEACON_HOME="$HOME/.claude-beacon"
readonly HOOK_CMD="$BEACON_HOME/beacon.sh"
# VS Code recognises sideloaded extensions by the publisher.name-version folder
# convention, so derive the folder from the manifest.
EXT_VERSION="$(jq -r '.version' "$PROJECT_DIR/vscode-extension/package.json")"
readonly EXT_DIR="$HOME/.vscode/extensions/local.claude-beacon-${EXT_VERSION}"

log() { printf '  %s\n' "$*"; }

has_vscode() { command -v code >/dev/null 2>&1 || [[ -d "/Applications/Visual Studio Code.app" ]]; }

echo "Installing Claude Beacon..."

# 1. Runtime files ------------------------------------------------------------
# Top level holds only the tool + config; all transient state lives in state/.
mkdir -p "$BEACON_HOME/state"
cp "$PROJECT_DIR/hook/beacon.sh" "$BEACON_HOME/beacon.sh"
chmod +x "$BEACON_HOME/beacon.sh"
# Preserve an existing user config; otherwise seed the default.
if [[ ! -f "$BEACON_HOME/config.json" ]]; then
    cp "$PROJECT_DIR/hook/config.json" "$BEACON_HOME/config.json"
    log "config.json seeded"
else
    log "config.json kept (already present)"
fi

# 2. Compile the native panel from source into the runtime binary -------------
if xcrun --find swiftc >/dev/null 2>&1; then
    xcrun swiftc -swift-version 5 -O "$PROJECT_DIR/hook/beacon-panel.swift" -o "$BEACON_HOME/beacon-panel"
    log "beacon-panel compiled"
else
    log "WARNING: swiftc not found (install Xcode Command Line Tools). Falling back to an AppleScript dialog at runtime."
fi

# 3. VS Code companion extension (only if VS Code is installed) ---------------
# The extension is needed only for exact per-terminal focus/dismiss inside VS
# Code; Terminal.app / iTerm work without it.
if has_vscode; then
    rm -rf "$HOME"/.vscode/extensions/local.claude-beacon-* "$HOME"/.vscode/extensions/claude-beacon
    mkdir -p "$EXT_DIR"
    cp "$PROJECT_DIR/vscode-extension/package.json" "$PROJECT_DIR/vscode-extension/extension.js" "$EXT_DIR/"
    log "VS Code extension installed to $EXT_DIR"
else
    log "VS Code not found - skipping the companion extension"
fi

# 4. Wire hooks into Claude settings -----------------------------------------
# Defaults to ~/.claude; override or add homes with CLAUDE_HOMES or by passing
# settings.json paths as arguments:
#   CLAUDE_HOMES="$HOME/.claude $HOME/.claude-work" ./install.sh
#   ./install.sh ~/.claude-work/settings.json
wire_settings() {
    local settings="$1"
    [[ -f "$settings" ]] || { log "skip (no settings file): $settings"; return; }
    local tmp; tmp="$(mktemp)"
    # Merge: append the beacon entry only if absent, never replacing hooks the
    # user already has on these events.
    jq --arg cmd "$HOOK_CMD" '
        def ensure(event): .hooks[event] =
            ((.hooks[event] // []) as $entries |
             if ($entries | any(.hooks[]?.command == $cmd)) then $entries
             else $entries + [{ "hooks": [{ "type": "command", "command": $cmd }] }]
             end);
        .hooks = (.hooks // {}) | ensure("Stop") | ensure("Notification")
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    log "hooks wired: $settings"
}
IFS=' ' read -r -a homes <<< "${CLAUDE_HOMES:-$HOME/.claude}"
for home in "${homes[@]}"; do wire_settings "$home/settings.json"; done
for extra in "$@"; do wire_settings "$extra"; done

# 5. VS Code keybinding note (only if VS Code is installed) -------------------
if has_vscode; then
    KB="$HOME/Library/Application Support/Code/User/keybindings.json"
    if [[ -f "$KB" ]] && grep -q 'claudeBeacon.focusTerminal' "$KB"; then
        log "keybinding already present (cmd+f19)"
    else
        log "ACTION: add this to $KB :"
        log '  { "key": "cmd+f19", "command": "claudeBeacon.focusTerminal" }'
    fi
fi

cat <<'DONE'

Claude Beacon installed.

Next steps:
  1. Reload VS Code (Cmd+R, or "Developer: Reload Window") to load the extension.
  2. Grant Accessibility permission to your editor/terminal app the first time
     the "Focus Terminal" button runs (System Settings > Privacy & Security >
     Accessibility) - needed only for the keystroke that focuses the terminal.

Config: ~/.claude-beacon/config.json  (per-type auto-dismiss seconds; 0 = never)
DONE
