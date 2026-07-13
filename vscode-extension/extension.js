const vscode = require("vscode");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const STATE_DIR = path.join(os.homedir(), ".claude-beacon", "state");
const TARGET_FILE = path.join(STATE_DIR, "focus-target");
// Each window's extension host writes the tty of its focused terminal here (one
// file per host pid). Panels read this directory to know which terminal is
// focused right now, across every window.
const FOCUSED_DIR = path.join(STATE_DIR, "focused");
const MY_FOCUSED_FILE = path.join(FOCUSED_DIR, String(process.pid));

// The tty of a shell PID, normalized to "/dev/ttysNNN" (or "" if unknown).
function ttyForPid(pid) {
  try {
    const raw = execFileSync("ps", ["-o", "tty=", "-p", String(pid)], {
      encoding: "utf8",
    }).trim();
    if (!raw || raw === "??") return "";
    return raw.startsWith("/dev/") ? raw : "/dev/" + raw;
  } catch {
    return "";
  }
}

// Focus the integrated terminal whose shell runs on the tty named in the target
// file. Falls back to focusing the active terminal when nothing matches.
async function focusByTty() {
  let target = "";
  try {
    target = fs.readFileSync(TARGET_FILE, "utf8").trim();
  } catch {
    // No target written; just focus the active terminal.
  }
  const wanted =
    target && !target.startsWith("/dev/") ? "/dev/" + target : target;

  if (wanted) {
    for (const terminal of vscode.window.terminals) {
      const pid = await terminal.processId;
      if (pid && ttyForPid(pid) === wanted) {
        terminal.show(false);
        return;
      }
    }
  }
  await vscode.commands.executeCommand("workbench.action.terminal.focus");
}

// Write the tty of the terminal that currently has focus in THIS window, or ""
// when the window is unfocused or the terminal panel doesn't hold focus. A
// terminal is treated as focused when the window is focused, a terminal is
// active, and no text editor holds focus.
async function updateFocusedTerminal() {
  let tty = "";
  try {
    // The focused terminal is the active terminal of the focused window. We do
    // NOT gate on activeTextEditor: VS Code keeps it set (the most-recently
    // changed editor) even while the terminal has focus, so that check would
    // suppress the signal almost always. Consequence: a notification whose
    // terminal is the active terminal also clears while you're in the editor of
    // that window -- an acceptable trade for reliable dismissal.
    const term = vscode.window.activeTerminal;
    const windowFocused = vscode.window.state.focused;
    if (term && windowFocused) {
      const pid = await term.processId;
      if (pid) tty = ttyForPid(pid);
    }
  } catch {
    tty = "";
  }
  try {
    fs.mkdirSync(FOCUSED_DIR, { recursive: true });
    fs.writeFileSync(MY_FOCUSED_FILE, tty);
  } catch {
    // best effort
  }
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("claudeBeacon.focusTerminal", focusByTty),
    vscode.window.onDidChangeActiveTerminal(updateFocusedTerminal),
    vscode.window.onDidChangeWindowState(updateFocusedTerminal),
    vscode.window.onDidChangeActiveTextEditor(updateFocusedTerminal)
  );
  updateFocusedTerminal();
}

function deactivate() {
  try {
    fs.unlinkSync(MY_FOCUSED_FILE);
  } catch {
    // already gone
  }
}

module.exports = { activate, deactivate };
