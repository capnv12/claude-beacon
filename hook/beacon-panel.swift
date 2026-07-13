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
func currentRank() -> Int {
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
    return alive.firstIndex { $0.pid == myPid } ?? 0
}

// MARK: - App + panel

final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

var settledOrigin = targetOrigin(forRank: currentRank())
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
    @objc func focus() { result = "focus"; finish() }
    @objc func dismiss() { result = "dismiss"; finish() }
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
content.addSubview(makeButton(focusLabel, action: #selector(PanelController.focus),
                              x: focusX, w: focusWidth, background: focusButtonColor, textColor: focusTextColor))
content.addSubview(makeButton(dismissLabel, action: #selector(PanelController.dismiss),
                              x: dismissX, w: dismissWidth, background: dismissButtonColor, textColor: dismissTextColor))

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

func runOsascript(_ script: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false) ? out : nil
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
    default:
        // No per-tab focus API (Warp, Ghostty, ...): never auto-dismiss on focus.
        return nil
    }
}

let focusCheckStart = Date()
let focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    if controller.closing || targetTty.isEmpty { return }
    guard Date().timeIntervalSince(focusCheckStart) >= minVisibleSeconds else { return }
    if focusedTerminalTty() == targetTty { controller.dismiss() }
}
RunLoop.main.add(focusTimer, forMode: .common)

// MARK: - Reflow (slide to new rank when a lower panel closes)

let reflowTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if controller.closing { return }
    let origin = targetOrigin(forRank: currentRank())
    if abs(origin.x - settledOrigin.x) > 0.5 || abs(origin.y - settledOrigin.y) > 0.5 {
        settledOrigin = origin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reflowDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
    }
}
RunLoop.main.add(reflowTimer, forMode: .common)

// MARK: - Appear + timeout

panel.alphaValue = 0
panel.setFrame(NSRect(x: slideOutX(settledOrigin.x), y: settledOrigin.y, width: width, height: height), display: false)
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = appearDuration
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    panel.animator().alphaValue = panelOpacity
    panel.animator().setFrame(NSRect(origin: settledOrigin, size: NSSize(width: width, height: height)), display: true)
}

if timeoutSeconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { controller.dismiss() }
}

application.run()
