#!/usr/bin/env bash
# Claude Code "Stop" hook: modal notification + jump back to the originating terminal.
#
# Reads the hook payload JSON from stdin, resolves the current session's chat
# title from its transcript, plays a sound, and shows a dismissible dialog with
# a "Focus Terminal" default button. Clicking Focus brings the exact terminal
# that ran this session to the front. Focus precision varies by terminal:
#   Terminal.app / iTerm2 -> exact tab (matched by tty)
#   WezTerm               -> exact pane (via `wezterm cli` + $WEZTERM_PANE)
#   Warp (>= 2026.05.27)  -> exact pane (via $WARP_FOCUS_URL deep link)
#   VS Code               -> the project window (`code <cwd>` + app foreground);
#                            the terminal panel needs a helper extension, so we
#                            target the window (best available externally)
#   Ghostty / older Warp  -> app foreground only (no public per-tab API)
#
# Everything is resolved per invocation from the payload + inherited env, so it
# always targets the session that fired the hook, under any Claude home.

set -uo pipefail

readonly FALLBACK_TITLE="Claude Code"
readonly BEACON_HOME="$HOME/.claude-beacon"
readonly CONFIG="$BEACON_HOME/config.json"

# Sound + icon come from config (the panel reads the rest of the styling itself).
sound_name="$(/usr/bin/jq -r '.sound // "Glass"' "$CONFIG" 2>/dev/null)"
[[ "$sound_name" == "null" ]] && sound_name=""
# Restrict to a plain system-sound name so a config value can never traverse
# outside /System/Library/Sounds.
[[ "$sound_name" =~ ^[A-Za-z0-9._-]+$ ]] || sound_name=""
SOUND=""
[[ -n "$sound_name" ]] && SOUND="/System/Library/Sounds/${sound_name}.aiff"
ICON="$(/usr/bin/jq -r '.icon // empty' "$CONFIG" 2>/dev/null)"
[[ -z "$ICON" || "$ICON" == "null" ]] && ICON="/Applications/Claude.app/Contents/Resources/electron.icns"

payload="$(cat)"
transcript_path="$(printf '%s' "$payload" | /usr/bin/jq -r '.transcript_path // empty')"
session_cwd="$(printf '%s' "$payload" | /usr/bin/jq -r '.cwd // empty')"
hook_event="$(printf '%s' "$payload" | /usr/bin/jq -r '.hook_event_name // empty')"
notification_message="$(printf '%s' "$payload" | /usr/bin/jq -r '.message // empty')"

# Controlling tty of the Claude process that spawned this hook (e.g. /dev/ttys009).
session_tty="/dev/$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]')"

resolve_chat_title() {
    local latest
    if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
        latest="$(/usr/bin/grep '"type":"ai-title"' "$transcript_path" \
            | /usr/bin/tail -1 \
            | /usr/bin/jq -r '.aiTitle // empty' || true)"
        [[ -n "$latest" ]] && { printf '%s' "$latest"; return; }
    fi
    printf '%s' "$FALLBACK_TITLE"
}

# Bring the tab/pane/window that ran this session back to the front.
focus_terminal() {
    case "${TERM_PROGRAM:-}" in
        Apple_Terminal)
            /usr/bin/osascript - "$session_tty" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  set targetTTY to item 1 of argv
  tell application "Terminal"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is targetTTY then
            set selected of t to true
            set frontmost of w to true
            return
          end if
        end try
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
            ;;
        iTerm.app)
            /usr/bin/osascript - "$session_tty" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  set targetTTY to item 1 of argv
  tell application "iTerm"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            if (tty of s) is targetTTY then
              select w
              select t
              select s
              return
            end if
          end try
        end repeat
      end repeat
    end repeat
  end tell
end run
APPLESCRIPT
            ;;
        WezTerm)
            if command -v wezterm >/dev/null 2>&1 && [[ -n "${WEZTERM_PANE:-}" ]]; then
                wezterm cli activate-pane --pane-id "$WEZTERM_PANE" >/dev/null 2>&1 || true
            fi
            /usr/bin/open -b com.github.wez.wezterm >/dev/null 2>&1 || true
            ;;
        vscode)
            # `code <folder>` switches VS Code to the window that already has this
            # folder open; `open -b` foregrounds the app. Then write this session's
            # tty to the focus-target file and synthesize Cmd+F19, bound to the
            # companion extension command `claudeFocus.focusByTty`, which focuses
            # the exact integrated terminal whose shell runs on that tty (falling
            # back to the active terminal if none matches). Requires the companion
            # extension, the Cmd+F19 keybinding, and Accessibility permission for
            # the editor (all one-time).
            local vscode_bundle="${__CFBundleIdentifier:-com.microsoft.VSCode}"
            printf '%s' "$session_tty" > "$BEACON_HOME/state/focus-target" 2>/dev/null || true
            command -v code >/dev/null 2>&1 && [[ -n "$session_cwd" ]] \
                && code "$session_cwd" >/dev/null 2>&1 || true
            /usr/bin/open -b "$vscode_bundle" >/dev/null 2>&1 || true
            /bin/sleep 0.4
            /usr/bin/osascript -e 'tell application "System Events" to key code 80 using command down' \
                >/dev/null 2>&1 || true
            ;;
        WarpTerminal)
            # Warp >= 2026.05.27 exports WARP_FOCUS_URL: a deep link to this exact
            # pane. Opening it foregrounds Warp and switches to the precise tab/pane.
            # Older Warp has no focus API -> fall back to app foreground.
            if [[ -n "${WARP_FOCUS_URL:-}" ]]; then
                /usr/bin/open "$WARP_FOCUS_URL" >/dev/null 2>&1 || true
            else
                /usr/bin/open -b dev.warp.Warp-Stable >/dev/null 2>&1 || true
            fi
            ;;
        ghostty)
            /usr/bin/open -b com.mitchellh.ghostty >/dev/null 2>&1 || true
            ;;
        *)
            [[ -n "${__CFBundleIdentifier:-}" ]] \
                && /usr/bin/open -b "$__CFBundleIdentifier" >/dev/null 2>&1 || true
            ;;
    esac
}

chat_title="$(resolve_chat_title)"

# Play the sound without blocking the dialog.
[[ -n "$SOUND" ]] && /usr/bin/afplay "$SOUND" >/dev/null 2>&1 &

readonly PANEL_BIN="$BEACON_HOME/beacon-panel"

# Why did the panel appear? The Notification event fires when Claude needs a
# permission decision or is waiting for input and carries a human-readable
# reason in `.message`; Stop fires when the turn simply finished. `kind` drives
# the panel's accent stripe (amber = needs you, green = done).
if [[ "$hook_event" == "Notification" ]]; then
    message="${notification_message:-Waiting for your input.}"
    kind="attention"
else
    message="Finished and waiting for you."
    kind="done"
fi

# Per-kind auto-dismiss timeout (seconds; 0 = never) from the config file, with
# sensible defaults when it is missing or malformed.
timeout_seconds="$(/usr/bin/jq -r --arg k "$kind" '.timeouts[$k] // empty' "$CONFIG" 2>/dev/null)"
if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    [[ "$kind" == "attention" ]] && timeout_seconds=0 || timeout_seconds=30
fi

# Bundle id of the terminal this session runs in, so the panel can auto-dismiss
# once the user returns to that terminal.
case "${TERM_PROGRAM:-}" in
    Apple_Terminal) terminal_bundle="com.apple.Terminal" ;;
    iTerm.app)      terminal_bundle="com.googlecode.iterm2" ;;
    vscode)         terminal_bundle="${__CFBundleIdentifier:-com.microsoft.VSCode}" ;;
    WarpTerminal)   terminal_bundle="dev.warp.Warp-Stable" ;;
    WezTerm)        terminal_bundle="com.github.wez.wezterm" ;;
    ghostty)        terminal_bundle="com.mitchellh.ghostty" ;;
    *)              terminal_bundle="${__CFBundleIdentifier:-}" ;;
esac


# Show the panel and act on its result in a fully detached background job, so
# this hook returns immediately. Panels can stay up a long time (a persistent
# "attention" panel until you focus its terminal), and a blocking hook would
# leave Claude stuck "running stop hook". The ( ... & ) idiom orphans the job so
# it survives this script exiting. The block inherits the vars and functions.
(
    {
        action="dismiss"
        if [[ -x "$PANEL_BIN" ]]; then
            # Bottom-left, non-overlapping native panel; prints "focus" or "dismiss".
            action="$("$PANEL_BIN" "$chat_title" "$message" "$ICON" "$kind" "$timeout_seconds" "$terminal_bundle" "$session_tty" 2>/dev/null || echo dismiss)"
        else
            # Fallback: centered AppleScript dialog if the native panel is missing.
            # Title/icon/message are AppleScript arguments (never interpolated), so
            # values with quotes cannot break or inject. 0 timeout = no auto-close.
            icon_clause='with icon note'
            [[ -f "$ICON" ]] && icon_clause='with icon POSIX file (item 2 of argv)'
            giving_up=""
            [[ "$timeout_seconds" -gt 0 ]] && giving_up="giving up after $timeout_seconds"
            dialog_result="$(/usr/bin/osascript \
                -e 'on run argv' \
                -e "display dialog ((item 1 of argv) & return & return & (item 3 of argv)) with title \"$FALLBACK_TITLE\" buttons {\"Dismiss\", \"Focus Terminal\"} default button \"Focus Terminal\" $icon_clause $giving_up" \
                -e 'end run' \
                "$chat_title" "$ICON" "$message" 2>/dev/null || true)"
            [[ "$dialog_result" == *"Focus Terminal"* ]] && action="focus"
        fi
        [[ "$action" == "focus" ]] && focus_terminal
    } >/dev/null 2>&1 &
)

# Informational hook: always succeed immediately.
exit 0
