import Cocoa
import ServiceManagement
import ApplicationServices

// MARK: - AX helpers

func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func axString(_ e: AXUIElement, _ a: String) -> String? { axAttr(e, a) as? String }

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Frame in AX coordinates (origin top-left of primary screen).
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

/// AX (top-left origin) -> Cocoa (bottom-left origin).
func toCocoa(_ r: CGRect) -> CGRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/CloseFromExpose.log")

func log(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Mission Control model

/// Detection rules, overridable at runtime from
/// ~/Library/Application Support/CloseFromExpose/config.json (re-read every time Mission Control opens),
/// so they can be tuned for a new macOS without rebuilding (and re-granting Accessibility).
struct Config: Codable {
    var processes = ["com.apple.WindowManager", "com.apple.dock"]
    var thumbnailRoles = ["AXButton", "AXImage", "AXGroup"]
    var excludeIdentifierPrefixes = ["mc.spaces"]
    var minWidth: CGFloat = 80
    var minHeight: CGFloat = 60
    var maxScreenFraction: CGFloat = 0.9
    var requireTitle = true
    var dump = false

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CloseFromExpose/config.json")

    static func load() -> Config {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
        let c = Config()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: url)
        return c
    }
}

struct Thumbnail {
    let title: String
    let frame: CGRect   // AX coords
    /// Owning app, parsed from the thumbnail's AX identifier ("<bundle id>.space.<n>") on macOS 27.
    let bundleID: String?
    /// CGWindowID of the real window ("wid" AX attribute on macOS 27).
    let windowID: CGWindowID?

    /// Space the thumbnail belongs to, parsed from "<bundle id>.space.<n>".
    let spaceID: Int?

    static func spaceID(fromIdentifier ident: String) -> Int? {
        guard let r = ident.range(of: ".space.", options: .backwards) else { return nil }
        return Int(ident[r.upperBound...])
    }

    static func bundleID(fromIdentifier ident: String) -> String? {
        guard let r = ident.range(of: ".space.", options: .backwards) else { return nil }
        let id = String(ident[..<r.lowerBound])
        return id.isEmpty ? nil : id
    }
}

final class MissionControl {
    var config = Config.load()

    /// macOS 27 draws Mission Control in WindowManager (full-screen layer-19 window);
    /// older versions add an "mc" group to the Dock's AX tree.
    func isOpen() -> Bool {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let wm = list.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "WindowManager" &&
            ($0[kCGWindowLayer as String] as? Int) == 19
        }
        if wm { return true }
        if let dock = appElement("com.apple.dock") {
            return axChildren(dock).contains { axString($0, kAXIdentifierAttribute) == "mc" }
        }
        return false
    }

    func appElement(_ bundleID: String) -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        else { return nil }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.5)
        return e
    }

    func reloadConfig() { config = Config.load() }

    /// All window thumbnails currently displayed.
    func thumbnails() -> [Thumbnail] {
        let c = config
        let screenW = NSScreen.screens.map { $0.frame.width }.max() ?? 10000
        var out: [Thumbnail] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 14 else { return }
            let ident = axString(e, kAXIdentifierAttribute) ?? ""
            if c.excludeIdentifierPrefixes.contains(where: { !$0.isEmpty && ident.hasPrefix($0) }) { return }
            let role = axString(e, kAXRoleAttribute) ?? ""
            if c.thumbnailRoles.contains(role), let f = axFrame(e),
               f.width >= c.minWidth, f.height >= c.minHeight, f.width < screenW * c.maxScreenFraction {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { axString(e, $0) }.first { !$0.isEmpty } ?? ""
                let bundleID = Thumbnail.bundleID(fromIdentifier: ident)
                // Untitled windows (e.g. PDFgear) are fine when the identifier tells us the app.
                if !c.requireTitle || !title.isEmpty || bundleID != nil {
                    out.append(Thumbnail(title: title, frame: f, bundleID: bundleID,
                                         windowID: (axAttr(e, "wid") as? NSNumber)?.uint32Value,
                                         spaceID: Thumbnail.spaceID(fromIdentifier: ident)))
                    return  // outermost match wins
                }
            }
            for ch in axChildren(e) { walk(ch, depth: depth + 1) }
        }
        for p in c.processes { if let app = appElement(p) { walk(app, depth: 0) } }
        return sanitize(out)
    }

    /// Windows assigned to several desktops (e.g. "Options → Assign To → All Desktops") show up only
    /// under another Space's identifier, listed twice, with that Space's frame — not where they're
    /// drawn. Keep the current Space's thumbnails once per window, and rebuild the others' frames.
    func sanitize(_ ts: [Thumbnail]) -> [Thumbnail] {
        func dedupe(_ ts: [Thumbnail]) -> [Thumbnail] {
            var seen = Set<CGWindowID>()
            return ts.filter { t in t.windowID.map { seen.insert($0).inserted } ?? true }
        }
        let current = currentSpaces()
        guard !current.isEmpty, ts.contains(where: { $0.spaceID.map(current.contains) == true }) else { return dedupe(ts) }
        let here = dedupe(ts.filter { $0.spaceID.map(current.contains) ?? true })
        let hereIDs = Set(here.compactMap(\.windowID))
        let elsewhere = dedupe(ts.filter { t in
            guard let s = t.spaceID, !current.contains(s), let wid = t.windowID, !hereIDs.contains(wid) else { return false }
            return !current.isDisjoint(with: spaces(ofWindow: wid))
        })
        return here + relocate(elsewhere, known: here)
    }

    /// WindowManager draws an "App Icon Window" (layer 17) centred on every thumbnail's bottom edge,
    /// including the ones whose AX frame is wrong. Icons not claimed by a known thumbnail mark where
    /// the others really are; thumbnails share one scale, so the size comes from the real window.
    /// Identity: the assignment that best preserves their positions from the other Space's layout.
    func relocate(_ lost: [Thumbnail], known: [Thumbnail]) -> [Thumbnail] {
        guard !lost.isEmpty else { return [] }
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var bounds: [CGWindowID: CGRect] = [:]
        var icons: [CGRect] = []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            if let id = w[kCGWindowNumber as String] as? Int { bounds[CGWindowID(id)] = r }
            if (w[kCGWindowOwnerName as String] as? String) == "WindowManager",
               (w[kCGWindowLayer as String] as? Int) == 17,  // name ("App Icon Window") needs Screen Recording
               (w[kCGWindowIsOnscreen as String] as? Bool) == true { icons.append(r) }
        }
        let iconOffset: CGFloat = 41  // thumbnail bottom edge = icon.minY + 41
        func anchor(_ f: CGRect) -> CGPoint { CGPoint(x: f.midX, y: f.maxY) }
        func anchor(icon r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.minY + iconOffset) }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 6 && abs(a.y - b.y) < 6 }
        let free = icons.filter { i in !known.contains { near(anchor($0.frame), anchor(icon: i)) } }

        let ratios = known.compactMap { t in t.windowID.flatMap { bounds[$0] }.map { t.frame.width / max($0.width, 1) } }.sorted()
        guard free.count == lost.count, lost.count <= 6, !ratios.isEmpty else { return [] }
        let scale = ratios[ratios.count / 2]

        // Brute-force the cheapest icon assignment (≤ 6! permutations).
        var best: [Int] = [], bestCost = CGFloat.infinity
        func search(_ perm: [Int], _ rest: Set<Int>, _ cost: CGFloat) {
            guard cost < bestCost else { return }
            if rest.isEmpty { best = perm; bestCost = cost; return }
            let t = lost[perm.count]
            for i in rest {
                let a = anchor(t.frame), b = anchor(icon: free[i])
                search(perm + [i], rest.subtracting([i]), cost + hypot(a.x - b.x, a.y - b.y))
            }
        }
        search([], Set(free.indices), 0)

        return zip(lost, best).compactMap { t, i in
            guard let wid = t.windowID, let real = bounds[wid] else { return nil }
            let w = real.width * scale, h = real.height * scale, a = anchor(icon: free[i])
            return Thumbnail(title: t.title, frame: CGRect(x: a.x - w / 2, y: a.y - h, width: w, height: h),
                             bundleID: t.bundleID, windowID: wid, spaceID: t.spaceID)
        }
    }

    func spaces(ofWindow wid: CGWindowID) -> Set<Int> {
        let arr = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        return Set((arr as? [Int]) ?? [])
    }

    /// Managed Space ID currently shown on each display (private SkyLight API, as used by yabai).
    func currentSpaces() -> Set<Int> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
    }

    func dumpAll() -> String {
        config.processes.compactMap { p in appElement(p).map { "== \(p)\n" + dumpTree($0) } }.joined()
    }

    func dumpTree(_ e: AXUIElement, depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        let role = axString(e, kAXRoleAttribute) ?? ""
        if depth == 1 && role == "AXList" { return "" }  // Dock icons, noise
        let ident = axString(e, kAXIdentifierAttribute) ?? ""
        let title = axString(e, kAXTitleAttribute) ?? ""
        let desc = axString(e, kAXDescriptionAttribute) ?? ""
        let sub = axString(e, kAXSubroleAttribute) ?? ""
        let f = axFrame(e).map { "\($0)" } ?? ""
        var s = String(repeating: "  ", count: depth) + "\(role)/\(sub) id=\(ident) title=\(title) desc=\(desc) \(f)\n"
        for c in axChildren(e) { s += dumpTree(c, depth: depth + 1) }
        return s
    }
}

// MARK: - Window lookup & closing

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

/// Private but long-stable API (used by yabai, AltTab, …): the CGWindowID behind an AX window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct RealWindow {
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
    let frame: CGRect
}

func windows(of app: NSRunningApplication) -> [RealWindow] {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.3)
    return ((axAttr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []).compactMap { w in
        if (axAttr(w, kAXMinimizedAttribute) as? Bool) == true { return nil }
        guard let f = axFrame(w) else { return nil }
        return RealWindow(element: w, app: app, title: axString(w, kAXTitleAttribute) ?? "", frame: f)
    }
}

/// Exact lookup by CGWindowID (macOS 27 thumbnails expose it as the "wid" attribute).
func window(withID wid: CGWindowID) -> RealWindow? {
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t,
          let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return windows(of: app).first { w in
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w.element, &id) == .success && id == wid
    }
}

/// Fallback when there's no window ID: same app, then title, tie-broken by aspect ratio.
func guessWindow(_ t: Thumbnail) -> RealWindow? {
    let ratio = t.frame.width / max(t.frame.height, 1)
    func score(_ w: RealWindow) -> CGFloat { abs(w.frame.width / max(w.frame.height, 1) - ratio) }

    var pool = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && (t.bundleID == nil || $0.bundleIdentifier == t.bundleID) }
        .flatMap(windows(of:))
    if t.bundleID != nil, pool.count == 1 { return pool[0] }
    var candidates = pool.filter { $0.title == t.title }
    if candidates.isEmpty, !t.title.isEmpty {
        candidates = pool.filter { !$0.title.isEmpty && t.title.contains($0.title) }
    }
    candidates.sort { score($0) < score($1) }
    pool = candidates
    guard let best = pool.first, score(best) < 0.15 else { return nil }
    // Refuse to guess when two candidates look the same (e.g. untitled windows).
    if pool.count > 1, score(pool[1]) - score(best) < 0.02 { return nil }
    return best
}

func match(_ t: Thumbnail) -> RealWindow? {
    if let wid = t.windowID { return window(withID: wid) }
    return guessWindow(t)
}

func closeWindow(_ w: RealWindow) -> Bool {
    if let btn = axAttr(w.element, kAXCloseButtonAttribute) {
        return AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) == .success
    }
    return false
}

// MARK: - Close button overlay

/// A round ✕, or — when `label` is set — a pill "✕ <window title>" used for stacked app groups.
final class CloseButtonView: NSView {
    var onClick: (() -> Void)?
    var label: String? { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }

    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var fill: NSColor {
        failed ? .systemGray : hovered ? .systemRed : NSColor(white: 0.15, alpha: 0.92)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let shape = label == nil ? NSBezierPath(ovalIn: r)
                                 : NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        fill.setFill(); shape.fill()
        NSColor(white: 1, alpha: 0.85).setStroke(); shape.lineWidth = 1.5; shape.stroke()

        // The ✕ glyph sits in the leading square.
        let sq = NSRect(x: r.minX, y: r.minY, width: r.height, height: r.height)
        let i = sq.width * 0.32
        let x = NSBezierPath()
        x.move(to: NSPoint(x: sq.minX + i, y: sq.minY + i)); x.line(to: NSPoint(x: sq.maxX - i, y: sq.maxY - i))
        x.move(to: NSPoint(x: sq.minX + i, y: sq.maxY - i)); x.line(to: NSPoint(x: sq.maxX - i, y: sq.minY + i))
        x.lineWidth = label == nil ? 2.2 : 1.8; x.lineCapStyle = .round
        NSColor.white.setStroke(); x.stroke()

        if let label {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: style]
            let h = Self.font.boundingRectForFont.height
            let textRect = NSRect(x: sq.maxX - 2, y: r.midY - h / 2 + 1, width: r.maxX - sq.maxX - 8, height: h)
            (label as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class CloseButtonPanel: NSPanel {
    static let size: CGFloat = 26
    static let pillHeight: CGFloat = 24
    static let pillMaxWidth: CGFloat = 320
    let button = CloseButtonView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    /// Index into Controller.thumbnails this panel currently closes.
    var thumbnailIndex = -1

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Round button, or a pill sized to fit `label`.
    func configure(label: String?) {
        if button.label != label { button.label = label }
    }

    static func size(for label: String?) -> NSSize {
        guard let label else { return NSSize(width: size, height: size) }
        let textW = (label as NSString).size(withAttributes: [.font: CloseButtonView.font]).width
        return NSSize(width: min(pillHeight + textW + 14, pillMaxWidth), height: pillHeight)
    }

    func place(_ rect: NSRect) {
        if frame != rect { setFrame(rect, display: true) }
        button.frame = NSRect(origin: .zero, size: rect.size)
    }
}

// MARK: - Controller

final class Controller {
    let mc = MissionControl()
    /// One panel per window, keyed by window ID, reused across refreshes.
    var panels: [String: CloseButtonPanel] = [:]
    var pollTimer: Timer?
    var tickTimer: Timer?
    var thumbnails: [Thumbnail] = []
    var openedAt = Date.distantPast
    var dumpedThisOpen = false

    /// Hide buttons while Mission Control animates in, so they don't trail the thumbnails.
    static let openAnimation: TimeInterval = 0.35

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard tickTimer == nil, mc.isOpen() else { return }
        mc.reloadConfig()
        openedAt = Date()
        dumpedThisOpen = false
        // Thumbnails animate and reflow after a close, so follow them closely.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func closed() {
        tickTimer?.invalidate(); tickTimer = nil
        thumbnails = []
        panels.values.forEach { $0.orderOut(nil) }
    }

    private func tick() {
        guard mc.isOpen() else { closed(); return }
        thumbnails = mc.thumbnails()
        if mc.config.dump, !dumpedThisOpen, Date().timeIntervalSince(openedAt) > 0.8 {
            dumpedThisOpen = true
            log("Thumbnails: \(thumbnails.map { "'\($0.title)' [\($0.bundleID ?? "-") wid=\($0.windowID.map(String.init) ?? "-")] \($0.frame)" })\nAX tree:\n" + mc.dumpAll())
        }
        layout(visible: Date().timeIntervalSince(openedAt) > Self.openAnimation)
    }

    /// Windows of one app that Mission Control draws as an overlapping stack. When hovered,
    /// the stack fans out but the AX frames don't change, so corner buttons can't follow it.
    private func stackedGroups(_ frames: [CGRect]) -> [[Int]] {
        var parent = Array(thumbnails.indices)
        func find(_ i: Int) -> Int { parent[i] == i ? i : find(parent[i]) }
        for i in thumbnails.indices {
            for j in thumbnails.indices where j > i {
                guard let b = thumbnails[i].bundleID, b == thumbnails[j].bundleID else { continue }
                let inter = frames[i].intersection(frames[j])
                let minArea = min(frames[i].width * frames[i].height, frames[j].width * frames[j].height)
                if !inter.isNull, inter.width * inter.height > 0.3 * minArea { parent[find(i)] = find(j) }
            }
        }
        return Dictionary(grouping: thumbnails.indices, by: find).values.map { $0.sorted() }
    }

    /// Stable key so a panel stays with its window across refreshes.
    private func key(_ i: Int) -> String {
        let t = thumbnails[i]
        return t.windowID.map { "wid:\($0)" } ?? "t:\(t.bundleID ?? ""):\(t.title):\(i)"
    }

    private func layout(visible: Bool) {
        guard visible else { panels.values.forEach { $0.orderOut(nil) }; return }

        let frames = thumbnails.map { toCocoa($0.frame) }
        let mouse = NSEvent.mouseLocation
        let s = CloseButtonPanel.size
        // Buttons shown for the thumbnail(s) under the mouse only.
        var placements: [(index: Int, label: String?, rect: NSRect)] = []

        for group in stackedGroups(frames) {
            if group.count == 1 {
                let i = group[0], f = frames[i], inset: CGFloat = 4
                // Round ✕ on the first corner no other thumbnail covers.
                let corners = [
                    NSPoint(x: f.minX + inset, y: f.maxY - inset), NSPoint(x: f.maxX - inset, y: f.maxY - inset),
                    NSPoint(x: f.minX + inset, y: f.minY + inset), NSPoint(x: f.maxX - inset, y: f.minY + inset),
                ]
                let others = frames.enumerated().filter { $0.offset != i }.map { $0.element.insetBy(dx: -s / 2, dy: -s / 2) }
                let c = corners.first { c in !others.contains { $0.contains(c) } } ?? corners[0]
                let rect = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
                // Topmost thumbnail under the mouse wins where lone thumbnails overlap.
                let under = frames.indices.last { frames[$0].contains(mouse) }
                if under == i || rect.contains(mouse) { placements.append((i, nil, rect)) }
            } else {
                // Stack: a column of "✕ title" pills just above it (or below if there's no room).
                let union = group.map { frames[$0] }.reduce(frames[group[0]]) { $0.union($1) }
                let screenTop = NSScreen.screens.first { $0.frame.intersects(union) }?.visibleFrame.maxY ?? .greatestFiniteMagnitude
                let step = CloseButtonPanel.pillHeight + 4
                let above = union.maxY + 6 + CGFloat(group.count) * step <= screenTop
                let ordered = group.sorted { thumbnails[$0].title.localizedCompare(thumbnails[$1].title) == .orderedAscending }
                let pills: [(Int, String, NSRect)] = ordered.enumerated().map { k, i in
                    let title = thumbnails[i].title.isEmpty ? "Ventana sin título" : thumbnails[i].title
                    let size = CloseButtonPanel.size(for: title)
                    let y = above ? union.maxY + 6 + CGFloat(k) * step : union.minY - 6 - CGFloat(k + 1) * step
                    return (i, title, NSRect(x: union.minX, y: y, width: size.width, height: size.height))
                }
                // Hovering fans the stack out beyond its AX frames, so use a generous hover area,
                // plus the pills themselves and the gap to them.
                let hoverArea = pills.map { $0.2 }.reduce(union) { $0.union($1) }
                    .insetBy(dx: -union.width * 0.25, dy: -union.height * 0.25)
                if hoverArea.contains(mouse) { placements += pills.map { ($0.0, $0.1, $0.2) } }
            }
        }

        var used = Set<String>()
        for pl in placements {
            let k = key(pl.index)
            used.insert(k)
            let p = panels[k] ?? makePanel(k)
            p.thumbnailIndex = pl.index
            p.configure(label: pl.label)
            p.place(pl.rect)
            let hovered = pl.rect.contains(mouse)
            if p.button.hovered != hovered { p.button.hovered = hovered }
            if !p.isVisible { p.button.failed = false; p.orderFrontRegardless() }
        }
        for (k, p) in panels where !used.contains(k) { p.orderOut(nil) }
    }

    private func makePanel(_ key: String) -> CloseButtonPanel {
        let p = CloseButtonPanel()
        p.button.onClick = { [weak self, weak p] in
            guard let self, let p, self.thumbnails.indices.contains(p.thumbnailIndex) else { return }
            self.close(self.thumbnails[p.thumbnailIndex], panel: p)
        }
        panels[key] = p
        return p
    }

    private func close(_ t: Thumbnail, panel: CloseButtonPanel) {
        guard let w = match(t), closeWindow(w) else {
            log("Could not match/close thumbnail '\(t.title)' [\(t.bundleID ?? "-") wid=\(t.windowID.map(String.init) ?? "-")] frame=\(t.frame)")
            panel.button.failed = true
            NSSound.beep()
            return
        }
        log("Closed '\(w.title)' of \(w.app.localizedName ?? "?")")
        panel.orderOut(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let controller = Controller()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: "Close from Exposé")
        let menu = NSMenu()
        menu.addItem(withTitle: "Close from Exposé activo", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        loginItem = menu.addItem(withTitle: "Abrir al iniciar sesión", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(withTitle: "Abrir log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        setUpLoginItem()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            log("Waiting for Accessibility permission")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.controller.start(); log("Started") }
            }
        } else {
            controller.start()
            log("Started")
        }

    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    // MARK: Login item

    var loginItem: NSMenuItem!

    /// Turn "open at login" on the first time the app runs; after that the menu toggle rules.
    func setUpLoginItem() {
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            setLoginItem(true)
        }
        refreshLoginItem()
    }

    @objc func toggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
        refreshLoginItem()
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("Login item \(on ? "enabled" : "disabled") for \(Bundle.main.bundlePath)")
        } catch {
            log("Login item change failed: \(error)")
        }
    }

    func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
