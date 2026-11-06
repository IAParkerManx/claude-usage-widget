// ClaudeUsage — a macOS menu bar app (with optional floating overlay) that shows how much of
// your Claude Pro/Max plan limits is left, plus token activity from ~/.claude/projects.
//
// Plan limits come from Claude Code itself: run as `ClaudeUsage --statusline`, this binary is
// Claude Code's statusLine command, receives `rate_limits` on stdin after each response, and
// saves them to ~/.claude/usage-widget/limits.json for the app to display.

import Cocoa
import SwiftUI
import ServiceManagement

// MARK: - Plan limits

struct LimitWindow: Codable {
    var used_percentage: Double
    var resets_at: Double
    var resetsAt: Date { Date(timeIntervalSince1970: resets_at) }
}

struct Limits: Codable {
    var five_hour: LimitWindow?
    var seven_day: LimitWindow?
    var updated: Double
}

let limitsURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/usage-widget/limits.json")

func loadLimits() -> Limits? {
    guard let data = try? Data(contentsOf: limitsURL) else { return nil }
    return try? JSONDecoder().decode(Limits.self, from: data)
}

/// statusLine mode: record rate limits from Claude Code's stdin JSON and print a short status line.
func runStatusLine() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    let now = Date().timeIntervalSince1970
    var limits = loadLimits() ?? Limits(updated: 0)

    if let rl = obj["rate_limits"] as? [String: Any] {
        func window(_ key: String) -> LimitWindow? {
            guard let w = rl[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(used_percentage: used, resets_at: resets)
        }
        if let w = window("five_hour") { limits.five_hour = w }
        if let w = window("seven_day") { limits.seven_day = w }
        limits.updated = now
        try? FileManager.default.createDirectory(at: limitsURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(limits).write(to: limitsURL, options: .atomic)
    }

    var parts: [String] = []
    if let model = (obj["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    for (label, w) in [("5h", limits.five_hour), ("7d", limits.seven_day)] {
        if let w, w.resets_at > now { parts.append("\(label) \(percentLeft(w))% left") }
    }
    print(parts.joined(separator: " · "))
    exit(0)
}

/// Percent of the window remaining; a window whose reset time has passed is fully available again.
func percentLeft(_ w: LimitWindow, now: Date = Date()) -> Int {
    w.resetsAt <= now ? 100 : max(0, Int((100 - w.used_percentage).rounded()))
}

// MARK: - Token activity from session logs

struct Entry {
    let ts: Date
    let model: String
    let project: String
    let tokens: Int
    let output: Int
}

struct Totals {
    var tokens = 0, output = 0, messages = 0
    mutating func add(_ e: Entry) { tokens += e.tokens; output += e.output; messages += 1 }
}

final class LogScanner {
    private let roots: [URL]
    private let horizon: TimeInterval = 8 * 86400
    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:]   // keyed by message id + request id
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let iso = ISO8601DateFormatter()
    private let needle = Data("\"output_tokens\"".utf8)

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.insert(URL(fileURLWithPath: env).appendingPathComponent("projects"), at: 0)
        }
        roots = dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reads only bytes appended since the last scan, for files touched within the horizon.
    func scan() -> [Entry] {
        let cutoff = Date().addingTimeInterval(-horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = rv.contentModificationDate, mtime >= cutoff,
                      let size = rv.fileSize.map(UInt64.init) else { continue }
                var start = offsets[url.path] ?? 0
                if size < start { start = 0 }
                if size == start { continue }
                guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? fh.close() }
                try? fh.seek(toOffset: start)
                guard let data = try? fh.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { continue }
                let chunk = data[data.startIndex...lastNL]
                offsets[url.path] = start + UInt64(chunk.count)
                for line in chunk.split(separator: 0x0A) where line.range(of: needle) != nil {
                    parse(Data(line))
                }
            }
        }
        entries = entries.filter { $0.value.ts >= cutoff }
        return Array(entries.values)
    }

    private func parse(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let ts = isoFrac.date(from: tsString) ?? iso.date(from: tsString) else { return }
        let model = msg["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return }

        func int(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let output = int("output_tokens")
        let tokens = int("input_tokens") + output + int("cache_creation_input_tokens") + int("cache_read_input_tokens")

        let key = "\(msg["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"
        entries[key] = Entry(ts: ts, model: model, project: projectName(obj["cwd"] as? String),
                             tokens: tokens, output: output)
    }

    private func projectName(_ cwd: String?) -> String {
        guard let cwd else { return "unknown" }
        // Worktrees live at <repo>/.claude/worktrees/<name>; attribute them to the repo.
        if let r = cwd.range(of: "/.claude/worktrees/") {
            return (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Snapshot

struct DayTotal: Identifiable { let day: Date; let totals: Totals; var id: Date { day } }
struct Row: Identifiable { let name: String; let totals: Totals; var id: String { name } }

struct Snapshot {
    var today = Totals(), week = Totals()
    var days: [DayTotal] = []
    var projects: [Row] = []

    static func build(_ entries: [Entry], now: Date = Date()) -> Snapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        var s = Snapshot()
        var perDay: [Date: Totals] = [:], perProject: [String: Totals] = [:]
        for e in entries where e.ts >= weekStart {
            s.week.add(e)
            perDay[cal.startOfDay(for: e.ts), default: Totals()].add(e)
            if e.ts >= todayStart {
                s.today.add(e)
                perProject[e.project, default: Totals()].add(e)
            }
        }
        s.days = (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: weekStart)!
            return DayTotal(day: d, totals: perDay[d] ?? Totals())
        }
        s.projects = perProject.map { Row(name: $0.key, totals: $0.value) }.sorted { $0.totals.tokens > $1.totals.tokens }
        return s
    }
}

func fmtTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.0fK", Double(n) / 1e3)
    default: return "\(n)"
    }
}

func fmtDuration(_ t: TimeInterval) -> String {
    let m = max(0, Int(t / 60))
    if m >= 24 * 60 { return "\(m / 1440)d \((m % 1440) / 60)h" }
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

func fmtReset(_ d: Date) -> String {
    Calendar.current.isDateInToday(d)
        ? d.formatted(date: .omitted, time: .shortened)
        : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// Green while plenty is left, amber below 30%, red below 10%.
func levelColor(_ left: Int) -> Color {
    left < 10 ? .red : left < 30 ? .orange : .green
}

// MARK: - Model

enum DisplayMode: String, CaseIterable, Identifiable {
    case leftBoth = "% left — 5-hour & weekly", leftFiveHour = "% left — 5-hour only",
         usedBoth = "% used — 5-hour & weekly", resetCountdown = "Time until 5-hour reset",
         iconOnly = "Icon only"
    var id: String { rawValue }
}

final class UsageModel: ObservableObject {
    @Published var snap = Snapshot()
    @Published var limits: Limits?
    @Published var now = Date()
    @Published var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode"); onChange?() }
    }
    @Published var overlayVisible: Bool {
        didSet { UserDefaults.standard.set(overlayVisible, forKey: "overlayVisible"); onChange?() }
    }
    var onChange: (() -> Void)?

    private let scanner = LogScanner()
    private let queue = DispatchQueue(label: "claude-usage.scan", qos: .utility)
    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .leftBoth
        overlayVisible = d.bool(forKey: "overlayVisible")
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        limits = loadLimits()
        now = Date()
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            let snap = Snapshot.build(self.scanner.scan())
            DispatchQueue.main.async { self.snap = snap; self.onChange?() }
        }
    }

    var statusText: String {
        let five = limits?.five_hour, week = limits?.seven_day
        func left(_ w: LimitWindow?) -> String { w.map { "\(percentLeft($0, now: now))%" } ?? "–" }
        func used(_ w: LimitWindow?) -> String { w.map { "\(100 - percentLeft($0, now: now))%" } ?? "–" }
        // Some plans (e.g. Enterprise) only report the 5-hour window; omit the weekly part then.
        switch displayMode {
        case .leftBoth: return week == nil ? "5h \(left(five))" : "5h \(left(five)) · wk \(left(week))"
        case .leftFiveHour: return left(five)
        case .usedBoth: return week == nil ? "5h \(used(five))" : "5h \(used(five)) · wk \(used(week))"
        case .resetCountdown:
            guard let w = five, w.resetsAt > now else { return "–" }
            return fmtDuration(w.resetsAt.timeIntervalSince(now))
        case .iconOnly: return ""
        }
    }
}

// MARK: - Views

let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

struct DetailView: View {
    @ObservedObject var model: UsageModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude plan usage").font(.headline)
                if let l = model.limits, l.updated > 0 {
                    // Limits only change when a terminal Claude Code session gets a reply.
                    Text("Limits from \(Date(timeIntervalSince1970: l.updated).formatted(.relative(presentation: .named))) · update with each Claude Code reply in a terminal")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.limits?.five_hour == nil && model.limits?.seven_day == nil {
                Text("Waiting for limit data. It arrives with your next Claude Code response (Pro/Max plans only).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LimitCard(title: "5-hour limit", window: model.limits?.five_hour, now: model.now)
                if let week = model.limits?.seven_day {
                    LimitCard(title: "Weekly limit", window: week, now: model.now)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVITY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text("Today \(fmtTokens(s.today.tokens)) tokens · \(s.today.messages) msgs")
                    Spacer()
                    Text("7 days \(fmtTokens(s.week.tokens))").foregroundStyle(.secondary)
                }
                .font(.callout).lineLimit(1)
                WeekBars(days: s.days)
                if !s.projects.isEmpty { Breakdown(rows: Array(s.projects.prefix(3))) }
            }

            Divider()

            Picker("Menu bar shows", selection: $model.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Floating overlay", isOn: $model.overlayVisible)
            Toggle("Open at login", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { loginEnabled = SMAppService.mainApp.status == .enabled }
                }

            HStack {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Text("checked \(model.now.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 330)
    }
}

struct LimitCard: View {
    let title: String
    let window: LimitWindow?
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let w = window {
                let left = percentLeft(w, now: now)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(left)%").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("left").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(100 - left)% used").font(.caption).foregroundStyle(.secondary)
                }
                UsageBar(left: left)
                Text(w.resetsAt > now
                     ? "Resets \(fmtReset(w.resetsAt)) · in \(fmtDuration(w.resetsAt.timeIntervalSince(now)))"
                     : "Window has reset")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No data yet").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// Bar that drains as the limit is used up.
struct UsageBar: View {
    let left: Int
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(levelColor(left)).frame(width: g.size.width * CGFloat(left) / 100)
            }
        }
        .frame(height: height)
    }
}

struct WeekBars: View {
    let days: [DayTotal]
    var body: some View {
        let maxTokens = max(days.map(\.totals.tokens).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { d in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Calendar.current.isDateInToday(d.day) ? accent : accent.opacity(0.45))
                        .frame(height: max(2, 30 * CGFloat(d.totals.tokens) / CGFloat(maxTokens)))
                    Text(d.day.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(d.day.formatted(date: .abbreviated, time: .omitted)): \(fmtTokens(d.totals.tokens)) tokens")
            }
        }
        .frame(height: 44, alignment: .bottom)
    }
}

struct Breakdown: View {
    let rows: [Row]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { r in
                HStack {
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(fmtTokens(r.totals.tokens)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        HStack(spacing: 14) {
            column("5-HOUR", model.limits?.five_hour)
            if let week = model.limits?.seven_day {
                Divider().frame(height: 38)
                column("WEEKLY", week)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .fixedSize()
    }

    private func column(_ title: String, _ w: LimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            if let w {
                let left = percentLeft(w, now: model.now)
                Text("\(left)% left").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                UsageBar(left: left, height: 3)
                Text(w.resetsAt > model.now ? "resets in \(fmtDuration(w.resetsAt.timeIntervalSince(model.now)))" : "reset")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("–").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("waiting for data").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, alignment: .leading)
    }
}

// MARK: - Overlay window

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var contextMenu: NSMenu?
    override var mouseDownCanMoveWindow: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
}

final class OverlayPanel: NSPanel {
    let host: DraggableHostingView<OverlayView>

    init(model: UsageModel, menu: NSMenu) {
        host = DraggableHostingView(rootView: OverlayView(model: model))
        host.contextMenu = menu
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(radius: 12)
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur

        fitToContent()
        if !setFrameUsingName("ClaudeUsageOverlay"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            setFrameTopLeftPoint(NSPoint(x: v.maxX - frame.width - 16, y: v.maxY - 12))
        }
        setFrameAutosaveName("ClaudeUsageOverlay")
    }

    /// Resize to the SwiftUI content while keeping the top-left corner fixed.
    func fitToContent() {
        let size = host.fittingSize
        guard size != frame.size else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setContentSize(size)
        setFrameTopLeftPoint(topLeft)
    }

    override var canBecomeKey: Bool { false }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Details panel

/// Drop-down panel under the menu bar icon. Used instead of NSPopover, which drifts off the
/// top of the screen when its SwiftUI content changes size while shown.
final class DetailsPanel: NSPanel, NSWindowDelegate {
    let host: NSHostingView<DetailView>
    private var anchor: NSRect = .zero
    private(set) var lastClosed = Date.distantPast

    init(model: UsageModel) {
        host = NSHostingView(rootView: DetailView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 330, height: 400),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        delegate = self

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = OverlayPanel.roundedMask(radius: 12)
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
    }

    override var canBecomeKey: Bool { true }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    /// Size to the content and place it centred under the icon, kept fully on screen.
    func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = host.fittingSize
        let height = min(size.height, visible.height - 12)
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY - 4)
        setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: true)
    }

    func close(_ sender: Any?) {
        guard isVisible else { return }
        orderOut(sender)
        lastClosed = Date()
    }

    func windowDidResignKey(_ notification: Notification) { close(nil) }
    override func cancelOperation(_ sender: Any?) { close(sender) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var statusItem: NSStatusItem!
    var details: DetailsPanel!
    var overlay: OverlayPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        details = DetailsPanel(model: model)

        model.onChange = { [weak self] in self?.sync() }
        model.start()
        sync()
    }

    private func sync() {
        let text = model.statusText
        statusItem.button?.title = text.isEmpty ? "" : " \(text)"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        if model.overlayVisible {
            if overlay == nil { overlay = OverlayPanel(model: model, menu: overlayMenu()) }
            overlay?.fitToContent()
            overlay?.orderFrontRegardless()
        } else {
            overlay?.orderOut(nil)
        }
        if details.isVisible {
            // Let SwiftUI apply the new data before measuring.
            DispatchQueue.main.async { self.details.reposition() }
        }
    }

    private func overlayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show details", action: #selector(showPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Hide overlay", action: #selector(hideOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    @objc func togglePopover() {
        // Clicking the icon while the panel is open first closes it via resign-key; don't reopen.
        if details.isVisible || Date().timeIntervalSince(details.lastClosed) < 0.3 {
            details.close(nil)
        } else {
            showPopover()
        }
    }

    @objc func showPopover() {
        guard let button = statusItem.button else { return }
        model.refresh()
        details.show(below: button)
    }

    @objc func refresh() { model.refresh() }
    @objc func hideOverlay() { model.overlayVisible = false }
}

if CommandLine.arguments.contains("--statusline") { runStatusLine() }

// `ClaudeUsage --print` dumps the current numbers to stdout instead of starting the UI.
if CommandLine.arguments.contains("--print") {
    for (label, w) in [("5-hour", loadLimits()?.five_hour), ("weekly", loadLimits()?.seven_day)] {
        if let w { print("\(label): \(percentLeft(w))% left, resets \(w.resetsAt)") } else { print("\(label): no data") }
    }
    let s = Snapshot.build(LogScanner().scan())
    print("today: \(fmtTokens(s.today.tokens)) tok, \(s.today.messages) msgs · 7 days: \(fmtTokens(s.week.tokens)) tok")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
