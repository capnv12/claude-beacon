// Claude Beacon notification panel.
//
// Usage: beacon-panel <title> <message> <iconPath> <kind> <timeoutSeconds> <terminalBundle> <tty>
// Prints "focus" or "dismiss" on stdout depending on the button clicked
// (auto-dismiss also prints "dismiss").
//
// Appearance and behaviour are read from ~/.claude-beacon/config.json. Multiple
// panels stack without overlapping (rank among alive panels), wrap into columns
// when a column fills the screen, animate in/out, reflow when one closes, and
// dismiss when their own terminal (targetTty) gains focus.

import AppKit

// MARK: - Arguments

let arguments = CommandLine.arguments
func argument(_ index: Int, default fallback: String) -> String {
    guard index < arguments.count, !arguments[index].isEmpty else { return fallback }
    return arguments[index]
}
let titleText = argument(1, default: "Claude Code")
let messageText = argument(2, default: "Finished and waiting for you.")
let iconPath = arguments.count > 3 ? arguments[3] : ""
let kind = argument(4, default: "done")
let timeoutSeconds = Double(argument(5, default: "30")) ?? 30
let targetTerminalBundle = argument(6, default: "")
let targetTty = argument(7, default: "")

// MARK: - Config

let configPath = NSString(string: "~/.claude-beacon/config.json").expandingTildeInPath
let config: [String: Any] = {
    guard let data = FileManager.default.contents(atPath: configPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}()
func configValue(_ keyPath: String) -> Any? {
    var node: Any? = config
    for key in keyPath.split(separator: ".") {
        node = (node as? [String: Any])?[String(key)]
        if node == nil { return nil }
    }
    return node
}
func cfgDouble(_ keyPath: String, _ fallback: Double) -> Double {
    (configValue(keyPath) as? NSNumber)?.doubleValue ?? fallback
}
func cfgString(_ keyPath: String, _ fallback: String) -> String {
    (configValue(keyPath) as? String) ?? fallback
}
func cfgBool(_ keyPath: String, _ fallback: Bool) -> Bool {
    (configValue(keyPath) as? NSNumber)?.boolValue ?? fallback
}
extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
func cfgColor(_ keyPath: String, _ fallback: NSColor) -> NSColor {
    (configValue(keyPath) as? String).flatMap { NSColor(hex: $0) } ?? fallback
}
// nil when the config value is missing or an empty string (= "use the default").
func cfgColorOptional(_ keyPath: String) -> NSColor? {
    guard let s = configValue(keyPath) as? String, !s.isEmpty else { return nil }
    return NSColor(hex: s)
}

// MARK: - Resolved style

let width = cfgDouble("size.width", 420)
let height = cfgDouble("size.height", 120)
let margin = cfgDouble("spacing.margin", 16)
let gap = cfgDouble("spacing.gap", 12)
let cornerRadius = cfgDouble("cornerRadius", 22)
let panelOpacity = cfgDouble("opacity", 1.0)
let material = cfgString("material", "liquid-glass")
let position = cfgString("position", "bottom-left")
let slideOffset = cfgDouble("slideOffset", 40)
let minVisibleSeconds = cfgDouble("minVisibleSeconds", 2.0)
let appearDuration = cfgDouble("animation.appear", 0.28)
let dismissDuration = cfgDouble("animation.dismiss", 0.24)
let reflowDuration = cfgDouble("animation.reflow", 0.25)
let titleFontSize = cfgDouble("title.fontSize", 14)
let messageFontSize = cfgDouble("message.fontSize", 12)
let focusLabel = cfgString("buttons.focus.label", "Focus Terminal")
let dismissLabel = cfgString("buttons.dismiss.label", "Dismiss")
let focusButtonColor = cfgColorOptional("buttons.focus.backgroundColor") ?? .controlAccentColor
let dismissButtonColor = cfgColorOptional("buttons.dismiss.backgroundColor")
let focusTextColor = cfgColorOptional("buttons.focus.textColor")
let dismissTextColor = cfgColorOptional("buttons.dismiss.textColor")
let titleColor = cfgColorOptional("title.textColor") ?? .labelColor
let messageColor = cfgColorOptional("message.textColor") ?? .secondaryLabelColor
let accentColor = cfgColor("accent.\(kind)", kind == "attention" ? .systemOrange : .systemGreen)

// Stacking: once more than `stackThreshold` panels are alive and none has been
// acted on for `stackDelay` seconds, they collapse into a single click-to-open
// pile. A brand-new panel peeks on its own for `peekSeconds` before joining.
let stackingEnabled = cfgBool("stacking.enabled", true)
let stackThreshold = Int(cfgDouble("stacking.threshold", 3))
let stackDelay = cfgDouble("stacking.delaySeconds", 20)
let peekSeconds = cfgDouble("stacking.peekSeconds", 2.0)
let cascadeOffset = cfgDouble("stacking.cascadeOffset", 8)

let isRight = position.contains("right")
let isTop = position.contains("top")

// MARK: - Geometry (position-aware, column-wrapping)

let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let panelsPerColumn = max(1, Int((visible.height - margin) / (height + gap)))

func targetOrigin(forRank rank: Int) -> NSPoint {
    let column = CGFloat(rank / panelsPerColumn)
    let row = CGFloat(rank % panelsPerColumn)
    let x = isRight
        ? visible.maxX - margin - width - column * (width + gap)
        : visible.minX + margin + column * (width + gap)
    let y = isTop
        ? visible.maxY - margin - height - row * (height + gap)
        : visible.minY + margin + row * (height + gap)
    return NSPoint(x: x, y: y)
}
// Off-screen-edge X for slide in/out (toward the nearer horizontal edge).
func slideOutX(_ x: CGFloat) -> CGFloat { isRight ? x + slideOffset : x - slideOffset }

// MARK: - Shared slots (rank-based stacking)

let slotsDirectory = NSString(string: "~/.claude-beacon/state/slots").expandingTildeInPath
try? FileManager.default.createDirectory(atPath: slotsDirectory, withIntermediateDirectories: true)
func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
let myPid = getpid()
let mySlotPath = "\(slotsDirectory)/slot-\(myPid)"
let myStart = Date().timeIntervalSince1970
try? "\(myStart)".write(toFile: mySlotPath, atomically: true, encoding: .utf8)
func releaseSlot() { try? FileManager.default.removeItem(atPath: mySlotPath) }
// Every alive panel, oldest first (ties broken by pid), pruning dead slots.
func aliveSlots() -> [(pid: Int32, start: Double)] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: slotsDirectory)) ?? []
    var alive: [(pid: Int32, start: Double)] = []
    for file in files where file.hasPrefix("slot-") {
        guard let pid = Int32(file.dropFirst(5)) else { continue }
        let path = "\(slotsDirectory)/\(file)"
        if pid != myPid, !processAlive(pid) {
            try? FileManager.default.removeItem(atPath: path); continue
        }
        let start = (try? String(contentsOfFile: path, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        alive.append((pid, start))
    }
    alive.sort { $0.start != $1.start ? $0.start < $1.start : $0.pid < $1.pid }
    return alive
}
func currentRank() -> Int { aliveSlots().firstIndex { $0.pid == myPid } ?? 0 }

// MARK: - Shared "last user action" (drives collapse / re-collapse timing)

// A unix timestamp written whenever the user clicks Focus / Dismiss / expand on
// ANY panel. Automatic dismissal (timeout, terminal-focus) never writes it, so
// an unattended pile still collapses on schedule.
let lastActionPath = NSString(string: "~/.claude-beacon/state/last-action").expandingTildeInPath
func recordUserAction() {
    try? "\(Date().timeIntervalSince1970)".write(toFile: lastActionPath, atomically: true, encoding: .utf8)
}
func lastActionTime() -> Double? {
    (try? String(contentsOfFile: lastActionPath, encoding: .utf8))
        .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

// "Dismiss all" from a collapsed stack: one panel writes a timestamp and every
// panel alive at that moment (start <= signal) self-dismisses on its next tick.
// Panels spawned afterwards (start > signal) ignore it, so a later burst is safe.
let dismissAllPath = NSString(string: "~/.claude-beacon/state/dismiss-all").expandingTildeInPath
func signalDismissAll() {
    try? "\(Date().timeIntervalSince1970)".write(toFile: dismissAllPath, atomically: true, encoding: .utf8)
}
func shouldDismissAll() -> Bool {
    guard let s = try? String(contentsOfFile: dismissAllPath, encoding: .utf8),
          let t = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return t >= myStart
}

// MARK: - Per-tick layout (normal tile vs collapsed stack vs peek)

typealias Layout = (origin: NSPoint, alpha: CGFloat, front: Bool, back: Bool,
                    collapsed: Bool, isFront: Bool, count: Int)
func desiredLayout() -> Layout {
    let alive = aliveSlots()
    let count = alive.count
    let rank = alive.firstIndex { $0.pid == myPid } ?? 0
    let full = CGFloat(panelOpacity)
    // Not stacking, or too few panels: normal tiled layout.
    guard stackingEnabled, count > stackThreshold else {
        return (targetOrigin(forRank: rank), full, false, false, false, false, count)
    }
    let now = Date().timeIntervalSince1970
    let reference = lastActionTime() ?? (alive.first?.start ?? myStart)
    guard (now - reference) >= stackDelay else {
        return (targetOrigin(forRank: rank), full, false, false, false, false, count)
    }
    // Newest panel peeks on its own before joining the collapsed stack.
    if alive.last?.pid == myPid, (now - myStart) < peekSeconds {
        return (targetOrigin(forRank: 1), full, true, false, false, false, count)
    }
    // Collapsed: front card (rank 0) on top; deeper cards cascade behind + fade.
    let depth = rank
    let base = targetOrigin(forRank: 0)
    let dy = CGFloat(min(depth, 3)) * cascadeOffset
    let origin = NSPoint(x: base.x, y: base.y + (isTop ? -dy : dy))
    let alpha: CGFloat = depth == 0 ? full : depth == 1 ? 0.55 : depth == 2 ? 0.3 : 0.0
    return (origin, alpha, depth == 0, depth != 0, true, depth == 0, count)
}

// MARK: - App + panel

final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

var settledOrigin = desiredLayout().origin
var settledAlpha = CGFloat(panelOpacity)
var orderedFront = false
var orderedBack = false
let panelFrame = NSRect(origin: settledOrigin, size: NSSize(width: width, height: height))
let panel = NonKeyPanel(contentRect: panelFrame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
panel.level = .floating
panel.isFloatingPanel = true
panel.hidesOnDeactivate = false
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true

let content = NSView(frame: NSRect(origin: .zero, size: panelFrame.size))
content.wantsLayer = true

let stripe = NSView(frame: NSRect(x: 0, y: 0, width: 5, height: height))
stripe.wantsLayer = true
stripe.layer?.backgroundColor = accentColor.cgColor
content.addSubview(stripe)

let padding: CGFloat = 16
var textLeft = padding
if !iconPath.isEmpty, let icon = NSImage(contentsOfFile: iconPath) {
    let size: CGFloat = 52
    let iconView = NSImageView(frame: NSRect(x: padding, y: (height - size) / 2, width: size, height: size))
    iconView.image = icon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    content.addSubview(iconView)
    textLeft = padding + size + 12
}

let titleLabel = NSTextField(labelWithString: titleText)
titleLabel.font = NSFont.boldSystemFont(ofSize: titleFontSize)
titleLabel.textColor = titleColor
titleLabel.lineBreakMode = .byTruncatingTail
titleLabel.frame = NSRect(x: textLeft, y: height - 40, width: width - textLeft - padding, height: 22)
content.addSubview(titleLabel)

let messageLabel = NSTextField(labelWithString: messageText)
messageLabel.font = NSFont.systemFont(ofSize: messageFontSize)
messageLabel.textColor = messageColor
messageLabel.lineBreakMode = .byTruncatingTail
messageLabel.frame = NSRect(x: textLeft, y: height - 64, width: width - textLeft - padding, height: 18)
content.addSubview(messageLabel)

// MARK: - Controller

final class PanelController: NSObject {
    var result = "dismiss"
    var closing = false
    var target: NSPanel?
    // A user click records an action (resetting the shared collapse idle timer);
    // automatic paths (timeout, terminal-focus) dismiss without recording, so an
    // unattended pile still collapses on schedule.
    @objc func focusClicked() { recordUserAction(); result = "focus"; finish() }
    @objc func dismissClicked() { recordUserAction(); result = "dismiss"; finish() }
    // Clicking a collapsed stack only records the action; the reflow tick then
    // sees a fresh last-action and fans the panels back out (no dismissal).
    @objc func expandClicked() { recordUserAction() }
    // "Dismiss all" on the collapsed stack: signal every alive panel to close,
    // then close this one. This panel's own result stays "dismiss" (no focus).
    @objc func dismissAllClicked() { recordUserAction(); signalDismissAll(); autoDismiss() }
    func autoDismiss() { result = "dismiss"; finish() }
    func finish() {
        if closing { return }
        closing = true
        print(result)
        guard let target else { releaseSlot(); NSApp.terminate(nil); return }
        let current = target.frame.origin
        let off = NSRect(x: slideOutX(current.x), y: current.y, width: width, height: height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dismissDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            target.animator().alphaValue = 0
            target.animator().setFrame(off, display: true)
        }, completionHandler: { releaseSlot(); NSApp.terminate(nil) })
    }
}
let controller = PanelController()
controller.target = panel

func makeButton(_ title: String, action: Selector, x: CGFloat, w: CGFloat,
                background: NSColor?, textColor: NSColor?) -> NSButton {
    let button = NSButton(title: title, target: controller, action: action)
    button.bezelStyle = .rounded
    button.frame = NSRect(x: x, y: 14, width: w, height: 28)
    if let background { button.bezelColor = background }
    if let textColor {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: textColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
    }
    return button
}
let focusWidth: CGFloat = 132
let dismissWidth: CGFloat = 88
let focusX = width - padding - focusWidth
let dismissX = focusX - 8 - dismissWidth
let focusButton = makeButton(focusLabel, action: #selector(PanelController.focusClicked),
                             x: focusX, w: focusWidth, background: focusButtonColor, textColor: focusTextColor)
let dismissButton = makeButton(dismissLabel, action: #selector(PanelController.dismissClicked),
                               x: dismissX, w: dismissWidth, background: dismissButtonColor, textColor: dismissTextColor)
content.addSubview(focusButton)
content.addSubview(dismissButton)

// MARK: - Collapsed-stack chrome (hidden unless this is the front of a pile)

// Bottom row of a collapsed front card: a "Dismiss all" button at the right, a
// count badge to its left, and a hint. The transparent full-card overlay under
// them turns any other click into "expand"; the Dismiss-all button sits ABOVE it
// so it keeps its own click.
let dismissAllWidth: CGFloat = 112
let dismissAllX = width - padding - dismissAllWidth
let badgeSize: CGFloat = 30
let badgeX = dismissAllX - 8 - badgeSize
let badge = NSView(frame: NSRect(x: badgeX, y: 13, width: badgeSize, height: badgeSize))
badge.wantsLayer = true
badge.layer?.backgroundColor = accentColor.cgColor
badge.layer?.cornerRadius = badgeSize / 2
let badgeLabel = NSTextField(labelWithString: "")
badgeLabel.font = NSFont.boldSystemFont(ofSize: 13)
badgeLabel.textColor = .white
badgeLabel.alignment = .center
badgeLabel.frame = NSRect(x: 0, y: (badgeSize - 17) / 2, width: badgeSize, height: 17)
badge.addSubview(badgeLabel)
badge.isHidden = true
content.addSubview(badge)

let expandHint = NSTextField(labelWithString: "Click to expand")
expandHint.font = NSFont.systemFont(ofSize: 11)
expandHint.textColor = .secondaryLabelColor
expandHint.frame = NSRect(x: textLeft, y: 16, width: max(0, badgeX - 8 - textLeft), height: 16)
expandHint.isHidden = true
content.addSubview(expandHint)

let expandOverlay = NSButton(title: "", target: controller, action: #selector(PanelController.expandClicked))
expandOverlay.isBordered = false
expandOverlay.isTransparent = true
expandOverlay.frame = NSRect(origin: .zero, size: panelFrame.size)
expandOverlay.isHidden = true
content.addSubview(expandOverlay)

// Added last -> above the overlay, so its clicks dismiss the whole stack.
let dismissAllButton = makeButton("Dismiss all", action: #selector(PanelController.dismissAllClicked),
                                  x: dismissAllX, w: dismissAllWidth,
                                  background: dismissButtonColor, textColor: dismissTextColor)
dismissAllButton.isHidden = true
content.addSubview(dismissAllButton)

// MARK: - Card material

let cardFrame = NSRect(origin: .zero, size: panelFrame.size)
func wrapVibrancy(_ appearance: NSAppearance.Name?) {
    let v = NSVisualEffectView(frame: cardFrame)
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = cornerRadius
    v.layer?.masksToBounds = true
    if let appearance { v.appearance = NSAppearance(named: appearance) }
    content.frame = v.bounds
    v.addSubview(content)
    panel.contentView = v
}
switch material {
case "vibrancy": wrapVibrancy(nil)
case "dark": wrapVibrancy(.vibrantDark)
case "light": wrapVibrancy(.vibrantLight)
default:
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: cardFrame)
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        panel.contentView = glass
    } else {
        wrapVibrancy(nil)
    }
}

// MARK: - Per-terminal focus detection

func runProcess(_ path: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false) ? out : nil
}
func runOsascript(_ script: String) -> String? { runProcess("/usr/bin/osascript", ["-e", script]) }

// Locate the `wezterm` CLI. WezTerm exports WEZTERM_EXECUTABLE_DIR (the .app's
// MacOS dir, which also holds `wezterm`); fall back to the common install paths.
func weztermBinary() -> String? {
    var candidates: [String] = []
    if let dir = ProcessInfo.processInfo.environment["WEZTERM_EXECUTABLE_DIR"] {
        candidates.append("\(dir)/wezterm")
    }
    candidates += ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
                   "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
// The tty of the WezTerm pane that currently has GUI focus, or nil. list-clients
// reports the focused pane id per client (pick the least-idle client); list maps
// that pane id to its tty. Requires the inherited WEZTERM_UNIX_SOCKET to reach
// the originating mux, so it targets the right WezTerm instance.
func weztermFocusedTty() -> String? {
    guard let wezterm = weztermBinary(),
          let clientsJSON = runProcess(wezterm, ["cli", "list-clients", "--format", "json"]),
          let clients = (try? JSONSerialization.jsonObject(with: Data(clientsJSON.utf8))) as? [[String: Any]],
          !clients.isEmpty
    else { return nil }
    func idle(_ c: [String: Any]) -> Double {
        guard let it = c["idle_time"] as? [String: Any] else { return .greatestFiniteMagnitude }
        let secs = (it["secs"] as? NSNumber)?.doubleValue ?? 0
        let nanos = (it["nanos"] as? NSNumber)?.doubleValue ?? 0
        return secs + nanos / 1e9
    }
    guard let paneId = clients.min(by: { idle($0) < idle($1) })?["focused_pane_id"] as? Int,
          let panesJSON = runProcess(wezterm, ["cli", "list", "--format", "json"]),
          let panes = (try? JSONSerialization.jsonObject(with: Data(panesJSON.utf8))) as? [[String: Any]]
    else { return nil }
    for pane in panes where (pane["pane_id"] as? Int) == paneId {
        if let tty = pane["tty_name"] as? String, !tty.isEmpty { return tty }
    }
    return nil
}
func focusedTerminalTty() -> String? {
    guard !targetTerminalBundle.isEmpty,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetTerminalBundle
    else { return nil }
    switch targetTerminalBundle {
    case "com.apple.Terminal":
        return runOsascript("tell application \"Terminal\" to return tty of selected tab of front window")
    case "com.googlecode.iterm2":
        return runOsascript("tell application \"iTerm\" to return tty of current session of current window")
    case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss":
        let dir = NSString(string: "~/.claude-beacon/state/focused").expandingTildeInPath
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files {
            let filePath = "\(dir)/\(file)"
            if let hostPid = Int32(file), !processAlive(hostPid) {
                try? FileManager.default.removeItem(atPath: filePath); continue
            }
            if let tty = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    case "com.github.wez.wezterm":
        return weztermFocusedTty()
    default:
        // No per-tab focus API (Warp, Ghostty, ...): never auto-dismiss on focus.
        return nil
    }
}

let focusCheckStart = Date()
let focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    if controller.closing || targetTty.isEmpty { return }
    guard Date().timeIntervalSince(focusCheckStart) >= minVisibleSeconds else { return }
    if focusedTerminalTty() == targetTty { controller.autoDismiss() }
}
RunLoop.main.add(focusTimer, forMode: .common)

// MARK: - Reflow (tile by rank, collapse into a stack, and peek/fan animations)

// Show buttons vs the collapsed-stack badge/hint/click-target for this tick.
func applyChrome(_ layout: Layout) {
    let showButtons = !layout.collapsed
    focusButton.isHidden = !showButtons
    dismissButton.isHidden = !showButtons
    let showBadge = layout.collapsed && layout.isFront
    badge.isHidden = !showBadge
    expandHint.isHidden = !showBadge
    expandOverlay.isHidden = !showBadge
    dismissAllButton.isHidden = !showBadge
    if showBadge { badgeLabel.stringValue = "\(layout.count)" }
}
// Keep the front card above its stack and deeper cards behind it. Latches so the
// order is nudged only on transitions, not every tick.
func applyOrder(_ layout: Layout) {
    if layout.front {
        if !orderedFront { panel.orderFrontRegardless(); orderedFront = true }
        orderedBack = false
    } else if layout.back {
        if !orderedBack { panel.order(.below, relativeTo: 0); orderedBack = true }
        orderedFront = false
    } else {
        orderedFront = false; orderedBack = false
    }
}

let reflowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if controller.closing { return }
    // A "Dismiss all" on any panel clears every panel alive at that moment.
    if shouldDismissAll() { controller.autoDismiss(); return }
    let layout = desiredLayout()
    applyChrome(layout)
    applyOrder(layout)
    // Faded cards behind the front of a collapsed stack must not swallow clicks
    // meant for the front card.
    panel.ignoresMouseEvents = layout.back
    let originChanged = abs(layout.origin.x - settledOrigin.x) > 0.5 || abs(layout.origin.y - settledOrigin.y) > 0.5
    let alphaChanged = abs(layout.alpha - settledAlpha) > 0.001
    if originChanged || alphaChanged {
        settledOrigin = layout.origin
        settledAlpha = layout.alpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reflowDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: layout.origin, size: NSSize(width: width, height: height)), display: true)
            panel.animator().alphaValue = layout.alpha
        }
    }
}
RunLoop.main.add(reflowTimer, forMode: .common)

// MARK: - Appear + timeout

let appearLayout = desiredLayout()
settledOrigin = appearLayout.origin
settledAlpha = appearLayout.alpha
applyChrome(appearLayout)
panel.alphaValue = 0
panel.setFrame(NSRect(x: slideOutX(settledOrigin.x), y: settledOrigin.y, width: width, height: height), display: false)
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = appearDuration
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    panel.animator().alphaValue = appearLayout.alpha
    panel.animator().setFrame(NSRect(origin: settledOrigin, size: NSSize(width: width, height: height)), display: true)
}

if timeoutSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { controller.autoDismiss() }
}

application.run()
