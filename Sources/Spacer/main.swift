import AppKit
import EventKit
import SwiftUI

// MARK: - Dock 偵測
// 零權限做法：HIServices 私有 API CoreDockGetRect，直接回報 dock 真實 rect。
// macOS 26 起 CGWindowList 回報的 Dock 視窗變成全螢幕大小，舊的 bounds 過濾法失效。
// ponytail: 只支援 dock 在底部；dock 在左右側時面板直接隱藏，需要再加。

// 回傳值不可靠（實際簽名是 void），只能用 rect 本身判斷成功與否
private let coreDockGetRect: (@convention(c) (UnsafeMutablePointer<CGRect>) -> Void)? = {
    dlopen("/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/HIServices",
           RTLD_LAZY)
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CoreDockGetRect") else { return nil }
    return unsafeBitCast(
        sym, to: (@convention(c) (UnsafeMutablePointer<CGRect>) -> Void).self)
}()

/// dock 的 AppKit 座標 frame 與它所在的螢幕（dock 可能在任一螢幕）
func dockFrameAndScreen() -> (NSRect, NSScreen)? {
    guard let primary = NSScreen.screens.first, let fn = coreDockGetRect else { return nil }
    var cg = CGRect.zero
    fn(&cg)
    guard cg.width > 0, cg.height > 0 else { return nil }
    // CG 全域座標（主螢幕左上原點、y 向下）→ AppKit（主螢幕左下原點、y 向上）
    let rect = NSRect(x: cg.minX, y: primary.frame.height - cg.maxY,
                      width: cg.width, height: cg.height)
    guard let screen = NSScreen.screens.first(where: {
        $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY))
    }) else { return nil }
    return (rect, screen)
}

// MARK: - 系統數據

final class CPUSampler {
    private var prevIdle: UInt64 = 0
    private var prevTotal: UInt64 = 0

    func usage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let total = user + sys + idle + nice
        defer { prevIdle = idle; prevTotal = total }
        guard prevTotal > 0, total > prevTotal else { return 0 }
        let dTotal = total - prevTotal
        return Double(dTotal - (idle - prevIdle)) / Double(dTotal)
    }
}

final class NetSampler {
    private var prev: (rx: UInt64, tx: UInt64)?

    /// 全部 en* 介面的 bytes/s（下載, 上傳）
    func rates(interval: Double) -> (rx: Double, tx: Double) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: a.pointee.ifa_name).hasPrefix("en"),
                  let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            rx &+= UInt64(data.pointee.ifi_ibytes)
            tx &+= UInt64(data.pointee.ifi_obytes)
        }
        defer { prev = (rx, tx) }
        // ponytail: 32-bit counter 溢位時這一格顯示 0，下一格就恢復正確
        guard let pr = prev, rx >= pr.rx, tx >= pr.tx else { return (0, 0) }
        return (Double(rx - pr.rx) / interval, Double(tx - pr.tx) / interval)
    }
}

/// 跑 shell 指令，失敗回 nil。-l 讓 PATH 找得到 homebrew 的 gh
func shell(_ cmd: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Pomodoro（從選單列開始/停止，面板只負責顯示）

final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()
    @Published var endDate: Date?
    private var timer: Timer?

    func start(minutes: Int) {
        endDate = Date().addingTimeInterval(Double(minutes) * 60)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60,
                                     repeats: false) { _ in
            NSSound(named: "Glass")?.play()
        }
    }

    func stop() {
        endDate = nil
        timer?.invalidate()
    }
}

func memoryUsedBytes() -> Double {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let used = Double(stats.active_count) + Double(stats.wire_count)
             + Double(stats.compressor_page_count)
    return used * Double(vm_kernel_page_size)
}

// MARK: - Views

extension View {
    @ViewBuilder
    func panelChrome() -> some View {
        let base = padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        if #available(macOS 26.0, *) {
            // 跟 Tahoe dock 同款 Liquid Glass
            base.glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            base.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 1) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue],
                                                    startPoint: .top, endPoint: .bottom))
                Text(ctx.date, format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatsView: View {
    @State private var cpu = 0.0
    @State private var memUsed = 0.0
    @State private var sampler = CPUSampler()
    private let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("CPU", value: cpu, label: "\(Int(cpu * 100))%")
            row("RAM", value: memUsed / memTotal,
                label: String(format: "%.0f / %.0f GB",
                              memUsed / 1_073_741_824, memTotal / 1_073_741_824))
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        cpu = sampler.usage()
        memUsed = memoryUsedBytes()
    }

    private func row(_ title: String, value: Double, label: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 34, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(value > 0.8 ? .red : value > 0.5 ? .orange : .green)
                .frame(width: 120)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct NetView: View {
    @State private var rates = (rx: 0.0, tx: 0.0)
    @State private var sampler = NetSampler()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("↓ " + fmt(rates.rx))
                .foregroundStyle(.green)
            Text("↑ " + fmt(rates.tx))
                .foregroundStyle(.orange)
        }
        .font(.caption.monospacedDigit())
        .onAppear { rates = sampler.rates(interval: 2) }
        .onReceive(tick) { _ in rates = sampler.rates(interval: 2) }
    }

    private func fmt(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB/s", b / 1_048_576)
                       : String(format: "%.0f KB/s", b / 1024)
    }
}

struct GitHubView: View {
    @State private var text = "GH …"
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.purple)
            .onAppear { refresh() }
            .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let prs = shell("gh search prs --author=@me --state=open --json number --jq length")
            let reviews = shell(
                "gh search prs --review-requested=@me --state=open --json number --jq length")
            let s = (prs == nil && reviews == nil)
                ? "GH —"
                : "⑂ \(prs ?? "?") PRs · \(reviews ?? "?") reviews"
            DispatchQueue.main.async { text = s }
        }
    }
}

struct CalendarView: View {
    @State private var text = "行事曆…"
    @State private var store = EKEventStore()
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("📅 " + text)
            .font(.callout)
            .onAppear { refresh() }
            .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        store.requestFullAccessToEvents { granted, _ in
            guard granted else {
                DispatchQueue.main.async { text = "行事曆未授權" }
                return
            }
            let now = Date()
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
            let predicate = store.predicateForEvents(withStart: now, end: endOfDay,
                                                     calendars: nil)
            let events = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(2)
            let s = events.isEmpty
                ? "今天沒有行程了"
                : events.map {
                    "\($0.startDate.formatted(date: .omitted, time: .shortened)) \($0.title ?? "")"
                }.joined(separator: "  ·  ")
            DispatchQueue.main.async { text = s }
        }
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 塞得下就靜態靠左；塞不下就無縫循環跑馬燈
struct MarqueeText: View {
    let text: String
    @State private var textW: CGFloat = 0
    @State private var start = Date()
    private let gap: CGFloat = 36
    private let speed: Double = 30  // pt/s

    var body: some View {
        GeometryReader { geo in
            Group {
                if textW > geo.size.width {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let span = Double(textW + gap)
                        let phase = (ctx.date.timeIntervalSince(start) * speed)
                            .truncatingRemainder(dividingBy: span)
                        HStack(spacing: gap) {
                            measuringText
                            Text(text).fixedSize()
                        }
                        .offset(x: -CGFloat(phase))
                    }
                } else {
                    measuringText
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .onPreferenceChange(TextWidthKey.self) { textW = $0 }
        .onChange(of: text) { start = Date() }  // 換曲從頭開始跑
    }

    private var measuringText: some View {
        Text(text)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: TextWidthKey.self, value: g.size.width)
            })
    }
}

// 讀系統 Now Playing（YouTube 分頁、Spotify、Music 都會發布）。
// macOS 15.4+ 鎖了 MediaRemote 私有 API，走 media-control CLI（brew install media-control）
struct NowPlayingView: View {
    @State private var title: String?
    @State private var playing = false
    @State private var artwork: NSImage?
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let title {
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: title)
                        .font(.caption.weight(.semibold))
                        .frame(width: 170, height: 14)
                    HStack(spacing: 16) {
                        controlButton("backward.fill", "previous-track")
                        controlButton(playing ? "pause.fill" : "play.fill",
                                      "toggle-play-pause")
                        controlButton("forward.fill", "next-track")
                    }
                }
            } else {
                Text("♪ —")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { runDetached("open https://www.youtube.com") }
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func controlButton(_ symbol: String, _ cmd: String) -> some View {
        Button {
            runDetached("media-control \(cmd)")
            if cmd == "toggle-play-pause" { playing.toggle() }  // 樂觀更新圖示
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        DispatchQueue.global().async {
            guard let out = shell("media-control get"), out != "null",
                  let data = out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { title = nil; artwork = nil; playing = false }
                return
            }
            var img: NSImage?
            if let b64 = json["artworkData"] as? String,
               let d = Data(base64Encoded: b64) { img = NSImage(data: d) }
            DispatchQueue.main.async {
                title = json["title"] as? String
                playing = json["playing"] as? Bool ?? false
                artwork = img
            }
        }
    }
}

struct PomodoroView: View {
    @ObservedObject private var model = Pomodoro.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if let end = model.endDate {
                    let remain = Int(end.timeIntervalSince(ctx.date))
                    if remain <= 0 {
                        Text("🍅 Done!")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                    } else {
                        Text(String(format: "🍅 %d:%02d", remain / 60, remain % 60))
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("🍅 —").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.endDate == nil ? model.start(minutes: 25) : model.stop()
            }
        }
    }
}

/// 非激活面板的第一下點擊預設被當成 activation 吃掉，要收 tap 必須接受 first mouse
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 設定（widget 分配到哪側、面板開關），存 UserDefaults

final class Config: ObservableObject {
    static let shared = Config()
    private let d = UserDefaults.standard
    @Published var leftEnabled: Bool { didSet { d.set(leftEnabled, forKey: "leftEnabled") } }
    @Published var rightEnabled: Bool { didSet { d.set(rightEnabled, forKey: "rightEnabled") } }
    // 順序即顯示順序
    @Published var leftWidgets: [String] {
        didSet { d.set(leftWidgets, forKey: "leftWidgets") }
    }
    @Published var rightWidgets: [String] {
        didSet { d.set(rightWidgets, forKey: "rightWidgets") }
    }

    private init() {
        leftEnabled = d.object(forKey: "leftEnabled") as? Bool ?? true
        rightEnabled = d.object(forKey: "rightEnabled") as? Bool ?? true
        leftWidgets = d.stringArray(forKey: "leftWidgets") ?? ["calendar", "pomodoro"]
        rightWidgets = d.stringArray(forKey: "rightWidgets")
            ?? ["stats", "net", "github", "clock"]
    }
}

func runDetached(_ cmd: String) {
    DispatchQueue.global().async { _ = shell(cmd) }
}

struct Widget {
    let id: String
    let title: String
    let action: (() -> Void)?  // 點擊該區塊時做什麼；nil = widget 自己處理
    let make: () -> AnyView
}

let allWidgets: [Widget] = [
    Widget(id: "clock", title: "Clock",
           action: { runDetached("open -a Clock") }) { AnyView(ClockView()) },
    Widget(id: "stats", title: "CPU / RAM",
           action: { runDetached("open -a 'Activity Monitor'") }) { AnyView(StatsView()) },
    Widget(id: "net", title: "Network",
           action: { runDetached("open -a 'Activity Monitor'") }) { AnyView(NetView()) },
    Widget(id: "github", title: "GitHub",
           action: { runDetached("open https://github.com") }) {
        AnyView(GitHubView())
    },
    Widget(id: "nowplaying", title: "Now Playing", action: nil) {
        AnyView(NowPlayingView())
    },
    Widget(id: "calendar", title: "Calendar",
           action: { runDetached("open -a Calendar") }) { AnyView(CalendarView()) },
    Widget(id: "pomodoro", title: "Pomodoro", action: nil) { AnyView(PomodoroView()) },
]

struct PanelView: View {
    @ObservedObject var config = Config.shared
    let isLeft: Bool

    var body: some View {
        let ids = isLeft ? config.leftWidgets : config.rightWidgets
        let items = ids.compactMap { id in allWidgets.first { $0.id == id } }
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Divider().frame(height: 36) }
                items[i].make()
                    .frame(maxWidth: .infinity)  // 每個 widget 等寬均分
                    .contentShape(Rectangle())
                    .onTapGesture { items[i].action?() }
            }
        }
        .panelChrome()
    }
}

// MARK: - Panel

final class SpacerPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 比 dock 低一層：一樣永遠看得到，但 hover 放大的 dock 會畫在面板上面
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // 吃掉點擊：穿透會點到桌布，觸發 macOS「顯示桌面」把所有視窗趕跑。
        // .nonactivatingPanel 保證不搶焦點，點了沒反應但也不會出事。
        ignoresMouseEvents = false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let leftPanel = SpacerPanel()
    private let rightPanel = SpacerPanel()
    private var statusItem: NSStatusItem?
    private var lastApplied: (dock: NSRect, left: Bool, right: Bool, hover: Bool)?
    private var tickCount = 0

    // dock 放大時 CoreDockGetRect 不會變（實測），改用設定值估算讓位量來模仿
    // ponytail: 粗估單側讓位 = largesize - tilesize，不追精確放大幾何
    private let hoverRetreat: CGFloat = {
        let d = UserDefaults(suiteName: "com.apple.dock")
        guard d?.bool(forKey: "magnification") == true else { return 0 }
        let tile = d?.object(forKey: "tilesize") as? CGFloat ?? 64
        let large = d?.object(forKey: "largesize") as? CGFloat ?? 128
        return max(0, large - tile)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        leftPanel.contentView = FirstMouseHostingView(rootView: PanelView(isLeft: true))
        rightPanel.contentView = FirstMouseHostingView(rootView: PanelView(isLeft: false))
        setupStatusItem()
        layout()
        // 滑鼠靠近 dock 時以 30Hz 跟隨 hover 放大縮小；平常每 2 秒巡一次
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled",
                                     accessibilityDescription: "Spacer")
        statusItem = item
        rebuildMenu()
    }

    // 選單狀態（勾勾）直接反映 Config；每次改動整份重建，最省事
    private func rebuildMenu() {
        let menu = NSMenu()
        let start = NSMenuItem(title: "Start Pomodoro (25 min)",
                               action: #selector(startPomodoro), keyEquivalent: "p")
        start.target = self
        menu.addItem(start)
        let stop = NSMenuItem(title: "Stop Pomodoro",
                              action: #selector(stopPomodoro), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(sideItem(title: "Left Panel", isLeft: true))
        menu.addItem(sideItem(title: "Right Panel", isLeft: false))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Spacer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // tag: 0 = 左側, 1 = 右側；representedObject = widget id
    private func sideItem(title: String, isLeft: Bool) -> NSMenuItem {
        let cfg = Config.shared
        let side = isLeft ? 0 : 1
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let enabled = NSMenuItem(title: "Enabled",
                                 action: #selector(toggleSide(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.tag = side
        enabled.state = (isLeft ? cfg.leftEnabled : cfg.rightEnabled) ? .on : .off
        sub.addItem(enabled)
        sub.addItem(.separator())
        // 已啟用的 widget 按顯示順序列出，每個帶 Move Up / Move Down / Remove
        let ids = isLeft ? cfg.leftWidgets : cfg.rightWidgets
        for (i, id) in ids.enumerated() {
            guard let w = allWidgets.first(where: { $0.id == id }) else { continue }
            let mi = NSMenuItem(title: "\(i + 1)  \(w.title)", action: nil, keyEquivalent: "")
            let ops = NSMenu()
            for (opTitle, sel) in [("Move Up", #selector(moveWidgetUp(_:))),
                                   ("Move Down", #selector(moveWidgetDown(_:))),
                                   ("Remove", #selector(removeWidget(_:)))] {
                let op = NSMenuItem(title: opTitle, action: sel, keyEquivalent: "")
                op.target = self
                op.tag = side
                op.representedObject = id
                ops.addItem(op)
            }
            mi.submenu = ops
            sub.addItem(mi)
        }
        // 其餘 widget：點了加到最後
        let inactive = allWidgets.filter { !ids.contains($0.id) }
        if !inactive.isEmpty { sub.addItem(.separator()) }
        for w in inactive {
            let mi = NSMenuItem(title: "Add \(w.title)",
                                action: #selector(addWidget(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = side
            mi.representedObject = w.id
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func toggleSide(_ sender: NSMenuItem) {
        let cfg = Config.shared
        if sender.tag == 0 { cfg.leftEnabled.toggle() } else { cfg.rightEnabled.toggle() }
        rebuildMenu()
        layout()
    }

    private func mutateWidgets(_ sender: NSMenuItem,
                               _ transform: ([String], String) -> [String]) {
        guard let id = sender.representedObject as? String else { return }
        let cfg = Config.shared
        if sender.tag == 0 {
            cfg.leftWidgets = transform(cfg.leftWidgets, id)
        } else {
            cfg.rightWidgets = transform(cfg.rightWidgets, id)
        }
        rebuildMenu()
    }

    private func moved(_ arr: [String], _ id: String, by delta: Int) -> [String] {
        guard let i = arr.firstIndex(of: id) else { return arr }
        let j = i + delta
        guard j >= 0, j < arr.count else { return arr }
        var a = arr
        a.swapAt(i, j)
        return a
    }

    @objc private func addWidget(_ sender: NSMenuItem) {
        mutateWidgets(sender) { $0 + [$1] }
    }
    @objc private func removeWidget(_ sender: NSMenuItem) {
        mutateWidgets(sender) { arr, id in arr.filter { $0 != id } }
    }
    @objc private func moveWidgetUp(_ sender: NSMenuItem) {
        mutateWidgets(sender) { moved($0, $1, by: -1) }
    }
    @objc private func moveWidgetDown(_ sender: NSMenuItem) {
        mutateWidgets(sender) { moved($0, $1, by: 1) }
    }

    @objc private func startPomodoro() { Pomodoro.shared.start(minutes: 25) }
    @objc private func stopPomodoro() { Pomodoro.shared.stop() }

    private func tick() {
        tickCount += 1
        // 滑鼠快速飛離 dock 時也要復原，所以 hover 中一律持續 layout
        if mouseNearDock() || lastApplied?.hover == true || tickCount % 60 == 0 { layout() }
    }

    private func mouseInDock(_ dock: NSRect) -> Bool {
        dock.insetBy(dx: -16, dy: 0).contains(NSEvent.mouseLocation)
    }

    private func mouseNearDock() -> Bool {
        let m = NSEvent.mouseLocation
        for s in NSScreen.screens where s.frame.contains(m) {
            return m.y < s.frame.minY + 140
        }
        return false
    }

    private func layout() {
        guard let (dock, screen) = dockFrameAndScreen() else {
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            lastApplied = nil
            return
        }
        let cfg0 = Config.shared
        let hovering = hoverRetreat > 0 && mouseInDock(dock)
        // 沒變就不重排，避免 30Hz 下白做工
        if let last = lastApplied,
           last == (dock, cfg0.leftEnabled, cfg0.rightEnabled, hovering) { return }
        lastApplied = (dock, cfg0.leftEnabled, cfg0.rightEnabled, hovering)
        let sf = screen.frame
        let reserved = screen.visibleFrame.minY - sf.minY  // dock 佔用的底部高度
        guard reserved > 24 else {
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            lastApplied = nil
            return  // dock 自動隱藏 / 在側邊 → 沒有死角空間可用
        }
        // 對齊 dock 玻璃（實測 Tahoe：玻璃從底邊上方 4pt 起，頂到 reserved 上緣）
        let gap: CGFloat = 8
        let y = sf.minY + 4
        let h = reserved - 4
        let cfg = Config.shared
        let retreat: CGFloat = hovering ? hoverRetreat : 0  // hover 時模仿 dock 放大讓位
        if cfg.leftEnabled {
            place(leftPanel, zoneMinX: sf.minX + gap, zoneMaxX: dock.minX - gap - retreat,
                  y: y, h: h)
        } else {
            leftPanel.orderOut(nil)
        }
        if cfg.rightEnabled {
            place(rightPanel, zoneMinX: dock.maxX + gap + retreat, zoneMaxX: sf.maxX - gap,
                  y: y, h: h)
        } else {
            rightPanel.orderOut(nil)
        }
    }

    private func place(_ panel: NSPanel, zoneMinX: CGFloat, zoneMaxX: CGFloat,
                       y: CGFloat, h: CGFloat) {
        let minW: CGFloat = 200
        let available = zoneMaxX - zoneMinX
        guard available >= minW, h > 30 else { panel.orderOut(nil); return }
        let target = NSRect(x: zoneMinX, y: y, width: available, height: h)
        // 已顯示時用動畫過去，跟 dock 的伸縮一樣滑順；首次出現直接定位
        if panel.isVisible, panel.frame != target {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.orderFrontRegardless()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
