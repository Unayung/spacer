import AppKit
import Combine
import EventKit
import ServiceManagement
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

// 每個 widget 的文字縮放倍率，由 Config.textScale 經 environment 傳入
private struct WidgetScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var widgetScale: CGFloat {
        get { self[WidgetScaleKey.self] }
        set { self[WidgetScaleKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func panelChrome(glass: Bool = true, border: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let base = padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        Group {
            if !glass {
                base  // 關掉背景：widget 直接浮在桌布上
            } else if #available(macOS 26.0, *) {
                // 跟 Tahoe dock 同款 Liquid Glass（全強度，別再用 opacity 淡化）
                base.glassEffect(.clear, in: shape)
            } else {
                base.background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .overlay {
            if border {
                shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

struct ClockView: View {
    @Environment(\.widgetScale) private var ws

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 1) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 30 * ws, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue],
                                                    startPoint: .top, endPoint: .bottom))
                Text(ctx.date, format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.system(size: 11 * ws))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatsView: View {
    @Environment(\.widgetScale) private var ws
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
                .font(.system(size: 10 * ws, weight: .semibold))
                .frame(width: 34 * ws, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(value > 0.8 ? .red : value > 0.5 ? .orange : .green)
                .frame(width: 120)
            Text(label)
                .font(.system(size: 10 * ws).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct NetView: View {
    @Environment(\.widgetScale) private var ws
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
        .font(.system(size: 10 * ws).monospacedDigit())
        .onAppear { rates = sampler.rates(interval: 2) }
        .onReceive(tick) { _ in rates = sampler.rates(interval: 2) }
    }

    private func fmt(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB/s", b / 1_048_576)
                       : String(format: "%.0f KB/s", b / 1024)
    }
}

struct GitHubView: View {
    @Environment(\.widgetScale) private var ws
    @State private var text = "GH …"
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.system(size: 12 * ws).monospacedDigit())
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
    @Environment(\.widgetScale) private var ws
    @State private var text = "📅 行事曆…"
    @State private var store = EKEventStore()
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(.system(size: 12 * ws))
            .onAppear { refresh() }
            .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        store.requestFullAccessToEvents { granted, _ in
            guard granted else {
                DispatchQueue.main.async { text = "📅 行事曆未授權" }
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
                ? "📅 今天沒有行程了"
                : events.map {
                    "📅 \($0.startDate.formatted(date: .omitted, time: .shortened)) \($0.title ?? "")"
                }.joined(separator: "\n")
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
    var animating: Bool = true  // false = 停在原地不捲動（暫停時）
    @State private var textW: CGFloat = 0
    @State private var start = Date()
    private let gap: CGFloat = 36
    private let speed: Double = 30  // pt/s

    var body: some View {
        GeometryReader { geo in
            Group {
                if textW > geo.size.width && animating {
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
    @Environment(\.widgetScale) private var ws
    @State private var title: String?
    @State private var playing = false
    @State private var artwork: NSImage?
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            // 封面滿版當背景（不論播放/暫停），標題在上、控制在下並置中疊上。
            // 暫停時 marquee 停住。
            let titleW = max(60, min(280, geo.size.width - 40))
            Group {
                if let title {
                    VStack(spacing: 4) {
                        MarqueeText(text: title, animating: playing)
                            .font(.system(size: 10 * ws, weight: .semibold))
                            .frame(width: titleW, height: 14 * ws)
                        controlsRow
                    }
                    .shadow(radius: 4)  // 疊在圖上，加陰影保可讀
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background {
                        if let art = artwork {
                            Image(nsImage: art).resizable().scaledToFill()
                                // 薄薄一層毛玻璃（保留封面細節）+ 深色 scrim 讓字看得清
                                .overlay(Rectangle().fill(.ultraThinMaterial).opacity(0.35))
                                .overlay(Color.black.opacity(0.2))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text("♪ —")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { runDetached("open https://www.youtube.com") }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private var controlsRow: some View {
        HStack(spacing: 16 * ws) {
            controlButton("backward.fill", "previous-track")
            controlButton(playing ? "pause.fill" : "play.fill", "toggle-play-pause")
            controlButton("forward.fill", "next-track")
        }
    }

    private func controlButton(_ symbol: String, _ cmd: String) -> some View {
        Button {
            runDetached("media-control \(cmd)")
            if cmd == "toggle-play-pause" { playing.toggle() }  // 樂觀更新圖示
        } label: {
            Image(systemName: symbol).font(.system(size: 12 * ws, weight: .semibold))
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

// 遠端 herdr 的 agent 狀態看板。
// ponytail: host 與 herdr 路徑寫死 omarchy-outside；要換機器改這裡
struct HerdrView: View {
    @Environment(\.widgetScale) private var ws
    @State private var counts: [String: Int] = [:]
    @State private var reachable = false
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if reachable {
                let blocked = counts["blocked"] ?? 0
                let working = counts["working"] ?? 0
                let idle = (counts["idle"] ?? 0) + (counts["unknown"] ?? 0)
                if working > 0 || blocked > 0 {
                    // 有動靜才跑動畫 timeline，全 idle 時零開銷
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        board(working: working, blocked: blocked, idle: idle,
                              t: ctx.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    board(working: 0, blocked: 0, idle: idle, t: 0)
                }
            } else {
                Text("🤖 herdr —")
                    .font(.system(size: 11 * ws))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func board(working: Int, blocked: Int, idle: Int, t: Double) -> some View {
        HStack(spacing: 8 * ws) {
            Text("🤖").font(.system(size: 13 * ws))
            if blocked > 0 {
                // 等你回覆的 agent：紅色呼吸閃爍
                pill(.red, opacity: 0.55 + 0.45 * sin(t * 5)) {
                    Text("⚠ \(blocked)")
                }
            }
            if working > 0 {
                pill(.cyan) {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 9 * ws, weight: .bold))
                            .rotationEffect(.degrees(
                                (t * 120).truncatingRemainder(dividingBy: 360)))
                        Text("\(working)")
                    }
                }
            }
            pill(.gray) { Text("\(idle) idle") }
        }
    }

    private func pill<Content: View>(_ color: Color, opacity: Double = 1,
                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 10 * ws, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8 * ws)
            .padding(.vertical, 3 * ws)
            .background(Capsule().fill(color.opacity(0.16)))
            .opacity(opacity)
    }

    private func refresh() {
        DispatchQueue.global().async {
            // ControlMaster 讓 10 秒一次的輪詢重用連線，不用每次重新握手
            let cmd = "ssh -o BatchMode=yes -o ConnectTimeout=5 " +
                "-o ControlMaster=auto -o ControlPath=/tmp/spacer-ssh-%r@%h " +
                "-o ControlPersist=120 omarchy-outside " +
                "'~/.local/bin/herdr agent list'"
            guard let out = shell(cmd),
                  let data = out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let agents = result["agents"] as? [[String: Any]]
            else {
                DispatchQueue.main.async { reachable = false }
                return
            }
            var c: [String: Int] = [:]
            for a in agents {
                c[a["agent_status"] as? String ?? "unknown", default: 0] += 1
            }
            DispatchQueue.main.async {
                reachable = true
                counts = c
            }
        }
    }
}

struct PomodoroView: View {
    @Environment(\.widgetScale) private var ws
    @ObservedObject private var model = Pomodoro.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if let end = model.endDate {
                    let remain = Int(end.timeIntervalSince(ctx.date))
                    if remain <= 0 {
                        Text("🍅 Done!")
                            .font(.system(size: 20 * ws, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                    } else {
                        Text(String(format: "🍅 %d:%02d", remain / 60, remain % 60))
                            .font(.system(size: 20 * ws, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("🍅 —")
                        .font(.system(size: 13 * ws))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                model.endDate == nil ? model.start(minutes: 25) : model.stop()
            }
        }
    }
}

/// 非激活面板的第一下點擊預設被當成 activation 吃掉，要收 tap 必須接受 first mouse。
/// mouseDownCanMoveWindow=true 讓有開 isMovableByWindowBackground 的視窗（浮動面板）
/// 能拖背景移動；沒開的（dock 兩側面板）不受影響。SwiftUI 的按鈕仍可點。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
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
    // 第三塊可拖曳的浮動面板
    @Published var floatEnabled: Bool { didSet { d.set(floatEnabled, forKey: "floatEnabled") } }
    @Published var floatWidgets: [String] {
        didSet { d.set(floatWidgets, forKey: "floatWidgets") }
    }
    @Published var floatFrame: NSRect {
        didSet {
            d.set([floatFrame.minX, floatFrame.minY, floatFrame.width, floatFrame.height],
                  forKey: "floatFrame")
        }
    }
    // side: "left" / "right" / "float" 的統一存取
    func widgets(_ side: String) -> [String] {
        side == "left" ? leftWidgets : side == "right" ? rightWidgets : floatWidgets
    }
    func setWidgets(_ side: String, _ v: [String]) {
        switch side {
        case "left": leftWidgets = v
        case "right": rightWidgets = v
        default: floatWidgets = v
        }
    }
    func enabled(_ side: String) -> Bool {
        side == "left" ? leftEnabled : side == "right" ? rightEnabled : floatEnabled
    }
    func setEnabled(_ side: String, _ v: Bool) {
        switch side {
        case "left": leftEnabled = v
        case "right": rightEnabled = v
        default: floatEnabled = v
        }
    }
    // widget id → 文字縮放倍率（1 = 原始大小）
    @Published var textScale: [String: Double] {
        didSet { d.set(textScale, forKey: "textScale") }
    }
    // 面板玻璃背景開關
    @Published var glass: Bool { didSet { d.set(glass, forKey: "glass") } }
    // 面板外框線開關
    @Published var border: Bool { didSet { d.set(border, forKey: "border") } }

    func bumpScale(_ id: String, by delta: Double) {
        var t = textScale
        t[id] = min(1.8, max(0.6, (t[id] ?? 1) + delta))
        textScale = t
    }

    private init() {
        leftEnabled = d.object(forKey: "leftEnabled") as? Bool ?? true
        rightEnabled = d.object(forKey: "rightEnabled") as? Bool ?? true
        leftWidgets = d.stringArray(forKey: "leftWidgets") ?? ["calendar", "pomodoro"]
        rightWidgets = d.stringArray(forKey: "rightWidgets")
            ?? ["stats", "net", "github", "clock"]
        floatEnabled = d.object(forKey: "floatEnabled") as? Bool ?? false
        floatWidgets = d.stringArray(forKey: "floatWidgets") ?? ["clock"]
        if let f = d.array(forKey: "floatFrame") as? [Double], f.count == 4 {
            floatFrame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
        } else {
            floatFrame = NSRect(x: 300, y: 400, width: 320, height: 72)
        }
        textScale = d.dictionary(forKey: "textScale") as? [String: Double] ?? [:]
        glass = d.object(forKey: "glass") as? Bool ?? true
        border = d.object(forKey: "border") as? Bool ?? true
    }
}

/// 陣列裡把 id 往前/後移一格
func movedIds(_ arr: [String], _ id: String, by delta: Int) -> [String] {
    guard let i = arr.firstIndex(of: id) else { return arr }
    let j = i + delta
    guard j >= 0, j < arr.count else { return arr }
    var a = arr
    a.swapAt(i, j)
    return a
}

func runDetached(_ cmd: String) {
    DispatchQueue.global().async {
        if shell(cmd) == nil { NSLog("Spacer action failed: %@", cmd) }
    }
}

/// 點 herdr widget：已有 herdr 分頁 → 跳過去（用 terminal 前景 pid 認）；
/// Ghostty 開著但沒 herdr 分頁 → 前景視窗開新分頁（沒視窗就開新視窗）；
/// Ghostty 沒開 → 直接以 herdr 啟動
func openHerdrInGhostty() {
    let herdr = "\(NSHomeDirectory())/.local/bin/herdr --remote omarchy-outside"
    runDetached("""
    if [ "$(osascript -e 'application "Ghostty" is running')" != "true" ]; then
    open -na Ghostty --args -e \(herdr)
    exit 0
    fi
    pids=$(ps ax -o pid=,command= | awk '/[h]erdr --remote omarchy-outside/{printf ",%s", $1}')
    HERDR="\(herdr)"
    osascript <<APPLESCRIPT
    tell application "Ghostty"
    activate
    set herdrPids to {${pids#,}}
    repeat with w in windows
    repeat with t in tabs of w
    repeat with s in terminals of t
    if herdrPids contains (pid of s) then
    try
    activate window w
    end try
    select tab t
    return
    end if
    end repeat
    end repeat
    end repeat
    try
    new tab in front window with configuration {command:"$HERDR"}
    on error
    new window with configuration {command:"$HERDR"}
    end try
    end tell
    APPLESCRIPT
    """)
}

struct Widget {
    let id: String
    let title: String
    let minWidth: CGFloat  // 顯示所需的最小寬度，塞不下的 widget 直接不顯示
    let action: (() -> Void)?  // 點擊該區塊時做什麼；nil = widget 自己處理
    let make: () -> AnyView
}

let allWidgets: [Widget] = [
    Widget(id: "clock", title: "Clock", minWidth: 100,
           action: { runDetached("open -a Clock") }) { AnyView(ClockView()) },
    Widget(id: "stats", title: "CPU / RAM", minWidth: 240,
           action: { runDetached("open -a 'Activity Monitor'") }) { AnyView(StatsView()) },
    Widget(id: "net", title: "Network", minWidth: 110,
           action: { runDetached("open -a 'Activity Monitor'") }) { AnyView(NetView()) },
    Widget(id: "github", title: "GitHub", minWidth: 160,
           action: { runDetached("open https://github.com") }) {
        AnyView(GitHubView())
    },
    Widget(id: "nowplaying", title: "Now Playing", minWidth: 250, action: nil) {
        AnyView(NowPlayingView())
    },
    Widget(id: "calendar", title: "Calendar", minWidth: 230,
           action: { runDetached("open -a Calendar") }) { AnyView(CalendarView()) },
    Widget(id: "pomodoro", title: "Pomodoro", minWidth: 90, action: nil) {
        AnyView(PomodoroView())
    },
    Widget(id: "herdr", title: "herdr Agents", minWidth: 140,
           action: { openHerdrInGhostty() }) { AnyView(HerdrView()) },
]

struct PanelView: View {
    @ObservedObject var config = Config.shared
    let side: String  // "left" / "right" / "float"

    var body: some View {
        GeometryReader { geo in
            let ids = config.widgets(side)
            let all = ids.compactMap { id in allWidgets.first { $0.id == id } }
            let items = Self.fitting(all, in: geo.size.width - 36)
            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    if i > 0 { Divider().frame(height: 36) }
                    items[i].make()
                        .environment(\.widgetScale,
                                     CGFloat(config.textScale[items[i].id] ?? 1))
                        .frame(maxWidth: .infinity)  // 每個 widget 等寬均分
                        .contentShape(Rectangle())
                        .onTapGesture { items[i].action?() }
                        .contextMenu {
                            Button("← Move Left") { reorder(items[i].id, by: -1) }
                            Button("Move Right →") { reorder(items[i].id, by: 1) }
                            Divider()
                            Button("Text Larger") {
                                config.bumpScale(items[i].id, by: 0.1)
                            }
                            Button("Text Smaller") {
                                config.bumpScale(items[i].id, by: -0.1)
                            }
                            Divider()
                            let inactive = allWidgets.filter { !ids.contains($0.id) }
                            if !inactive.isEmpty {
                                Menu("Add Widget") {
                                    ForEach(inactive, id: \.id) { w in
                                        Button(w.title) { add(w.id) }
                                    }
                                }
                            }
                            Button("Remove") { remove(items[i].id) }
                        }
                }
            }
            .panelChrome(glass: config.glass, border: config.border)
        }
    }

    private func reorder(_ id: String, by delta: Int) {
        config.setWidgets(side, movedIds(config.widgets(side), id, by: delta))
    }

    private func remove(_ id: String) {
        config.setWidgets(side, config.widgets(side).filter { $0 != id })
    }

    private func add(_ id: String) {
        config.setWidgets(side, config.widgets(side) + [id])
    }

    // 等寬均分下，每格 ≥ 已納入者的最大 minWidth 才算塞得下；
    // 窄螢幕（dock 在內建螢幕）只顯示前面塞得下的幾個，至少一個
    static func fitting(_ all: [Widget], in width: CGFloat) -> [Widget] {
        guard let first = all.first else { return [] }
        var best = [first]
        for n in 1...all.count {
            let prefix = Array(all.prefix(n))
            let maxMin = prefix.map(\.minWidth).max() ?? 0
            if CGFloat(n) * maxMin <= width { best = prefix } else { break }
        }
        return best
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

/// 可拖曳、可水平縮放的浮動面板：位置與寬度由使用者決定，不參與 dock 排版。
final class FloatingPanel: NSPanel {
    static let panelHeight: CGFloat = 72

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true  // 拖背景即可移動
        ignoresMouseEvents = false
        minSize = NSSize(width: 120, height: Self.panelHeight)
        maxSize = NSSize(width: 4000, height: Self.panelHeight)
    }
}

/// 浮動面板左右邊緣的縮放握把。mouseDownCanMoveWindow=false 讓它「不」觸發背景拖移，
/// 自己用 mouseDragged 改視窗寬度（左握把移左緣、右握把移右緣）。
final class ResizeHandleView: NSView {
    enum Edge { case left, right }
    let edge: Edge
    static let width: CGFloat = 12

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let mx = NSEvent.mouseLocation.x  // 螢幕座標，跟 window.frame 同一系
        var f = win.frame
        if edge == .right {
            f.size.width = min(win.maxSize.width, max(win.minSize.width, mx - f.minX))
        } else {
            let maxX = f.maxX
            let minX = min(maxX - win.minSize.width, max(maxX - win.maxSize.width, mx))
            f.origin.x = minX
            f.size.width = maxX - minX
        }
        win.setFrame(f, display: true)
    }

    override func draw(_ rect: NSRect) {
        // 中央畫一條淡淡的直條，讓使用者看得到可以拖
        let bar = NSRect(x: bounds.midX - 1.5, y: bounds.midY - 11, width: 3, height: 22)
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// 浮動面板容器：glass hosting view 鋪滿，握把疊在左右緣。
/// hitTest 強制邊緣點擊落到握把（否則 SwiftUI host 會先吃掉、變成移動視窗）。
final class FloatContainer: NSView {
    var leftHandle: ResizeHandleView?
    var rightHandle: ResizeHandleView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let l = leftHandle, l.frame.contains(local) { return l }
        if let r = rightHandle, r.frame.contains(local) { return r }
        return super.hitTest(point)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let leftPanel = SpacerPanel()
    private let rightPanel = SpacerPanel()
    private let floatPanel = FloatingPanel()
    private var statusItem: NSStatusItem?
    private var lastApplied: (dock: NSRect, left: Bool, right: Bool, hover: Bool)?
    private var tickCount = 0
    private var configWatcher: AnyCancellable?
    private var restoringFloat = false  // 程式還原位置時別回存，免得抖

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
        // 首次啟動自動註冊開機啟動；之後由選單的 Launch at Login 控制
        if UserDefaults.standard.object(forKey: "didAutoRegisterLogin") == nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didAutoRegisterLogin")
        }
        leftPanel.contentView = FirstMouseHostingView(rootView: PanelView(side: "left"))
        rightPanel.contentView = FirstMouseHostingView(rootView: PanelView(side: "right"))
        setupFloatContent()
        floatPanel.delegate = self
        setupStatusItem()
        // 右鍵選單也會改 Config，狀態列選單跟著重建才不會顯示過期狀態
        configWatcher = Config.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
                self?.updateFloatPanel()
            }
        updateFloatPanel()
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
        menu.addItem(sideItem(title: "Left Panel", side: "left"))
        menu.addItem(sideItem(title: "Right Panel", side: "right"))
        menu.addItem(sideItem(title: "Floating Panel", side: "float"))
        menu.addItem(.separator())
        let glass = NSMenuItem(title: "Glass Background",
                               action: #selector(toggleGlass), keyEquivalent: "")
        glass.target = self
        glass.state = Config.shared.glass ? .on : .off
        menu.addItem(glass)
        let border = NSMenuItem(title: "Panel Border",
                                action: #selector(toggleBorder), keyEquivalent: "")
        border.target = self
        border.state = Config.shared.border ? .on : .off
        menu.addItem(border)
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Spacer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // tag: 0 = 左, 1 = 右, 2 = 浮動；representedObject = widget id
    private static let sides = ["left", "right", "float"]
    private func sideForTag(_ tag: Int) -> String { AppDelegate.sides[tag] }

    private func sideItem(title: String, side: String) -> NSMenuItem {
        let cfg = Config.shared
        let tag = AppDelegate.sides.firstIndex(of: side) ?? 0
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let enabled = NSMenuItem(title: "Enabled",
                                 action: #selector(toggleSide(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.tag = tag
        enabled.state = cfg.enabled(side) ? .on : .off
        sub.addItem(enabled)
        sub.addItem(.separator())
        // 已啟用的 widget 按顯示順序列出，每個帶移動 / 縮放 / 移除
        let ids = cfg.widgets(side)
        for (i, id) in ids.enumerated() {
            guard let w = allWidgets.first(where: { $0.id == id }) else { continue }
            let scale = cfg.textScale[id] ?? 1
            let suffix = scale == 1 ? "" : String(format: "  ·  %.0f%%", scale * 100)
            let mi = NSMenuItem(title: "\(i + 1)  \(w.title)\(suffix)",
                                action: nil, keyEquivalent: "")
            let ops = NSMenu()
            for (opTitle, sel) in [("← Move Left", #selector(moveWidgetUp(_:))),
                                   ("Move Right →", #selector(moveWidgetDown(_:))),
                                   ("Text Larger", #selector(textLarger(_:))),
                                   ("Text Smaller", #selector(textSmaller(_:))),
                                   ("Remove", #selector(removeWidget(_:)))] {
                let op = NSMenuItem(title: opTitle, action: sel, keyEquivalent: "")
                op.target = self
                op.tag = tag
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
            mi.tag = tag
            mi.representedObject = w.id
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func toggleGlass() {
        Config.shared.glass.toggle()
        rebuildMenu()
    }

    @objc private func toggleBorder() {
        Config.shared.border.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled {
            try? svc.unregister()
        } else {
            try? svc.register()
        }
        rebuildMenu()
    }

    @objc private func toggleSide(_ sender: NSMenuItem) {
        let cfg = Config.shared
        let side = sideForTag(sender.tag)
        cfg.setEnabled(side, !cfg.enabled(side))
        rebuildMenu()
        layout()
    }

    private func mutateWidgets(_ sender: NSMenuItem,
                               _ transform: ([String], String) -> [String]) {
        guard let id = sender.representedObject as? String else { return }
        let cfg = Config.shared
        let side = sideForTag(sender.tag)
        cfg.setWidgets(side, transform(cfg.widgets(side), id))
        rebuildMenu()
    }

    @objc private func addWidget(_ sender: NSMenuItem) {
        mutateWidgets(sender) { $0 + [$1] }
    }
    @objc private func removeWidget(_ sender: NSMenuItem) {
        mutateWidgets(sender) { arr, id in arr.filter { $0 != id } }
    }
    @objc private func moveWidgetUp(_ sender: NSMenuItem) {
        mutateWidgets(sender) { movedIds($0, $1, by: -1) }
    }
    @objc private func moveWidgetDown(_ sender: NSMenuItem) {
        mutateWidgets(sender) { movedIds($0, $1, by: 1) }
    }

    @objc private func textLarger(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Config.shared.bumpScale(id, by: 0.1)
        rebuildMenu()
    }
    @objc private func textSmaller(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Config.shared.bumpScale(id, by: -0.1)
        rebuildMenu()
    }

    @objc private func startPomodoro() { Pomodoro.shared.start(minutes: 25) }
    @objc private func stopPomodoro() { Pomodoro.shared.stop() }

    // 容器 = [glass hosting view 鋪滿] + [左右縮放握把疊在邊緣]，autoresizing 跟著寬度走
    private func setupFloatContent() {
        let container = FloatContainer(frame: NSRect(origin: .zero,
                                                     size: Config.shared.floatFrame.size))
        let host = FirstMouseHostingView(rootView: PanelView(side: "float"))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let hw = ResizeHandleView.width
        let left = ResizeHandleView(edge: .left)
        left.frame = NSRect(x: 0, y: 0, width: hw, height: container.bounds.height)
        left.autoresizingMask = [.height, .maxXMargin]
        let right = ResizeHandleView(edge: .right)
        right.frame = NSRect(x: container.bounds.width - hw, y: 0,
                             width: hw, height: container.bounds.height)
        right.autoresizingMask = [.minXMargin, .height]
        container.addSubview(left)
        container.addSubview(right)
        container.leftHandle = left
        container.rightHandle = right
        floatPanel.contentView = container
    }

    private func updateFloatPanel() {
        let cfg = Config.shared
        guard cfg.floatEnabled else { floatPanel.orderOut(nil); return }
        if floatPanel.frame != cfg.floatFrame {
            restoringFloat = true
            floatPanel.setFrame(cfg.floatFrame, display: true)
            restoringFloat = false
        }
        floatPanel.orderFrontRegardless()
    }

    // 使用者拖曳 / 縮放浮動面板後存位置與寬度
    func windowDidMove(_ notification: Notification) { saveFloatFrame(notification) }
    func windowDidResize(_ notification: Notification) { saveFloatFrame(notification) }

    private func saveFloatFrame(_ notification: Notification) {
        guard !restoringFloat, notification.object as? NSWindow === floatPanel else { return }
        Config.shared.floatFrame = floatPanel.frame
    }

    private func tick() {
        tickCount += 1
        // 滑鼠快速飛離 dock 時也要復原，所以 hover 中一律持續 layout
        if mouseNearDock() || lastApplied?.hover == true || tickCount % 60 == 0 { layout() }
    }

    private func mouseInDock(_ dock: NSRect) -> Bool {
        dock.insetBy(dx: -16, dy: 0).contains(NSEvent.mouseLocation)
    }

    // 這函式只在 dock 存在（reserved > 24）時被呼叫，所以一般最大化視窗會停在 dock 上緣、
    // 碰不到螢幕最底。fullscreen（含 Ghostty 的 non-native fullscreen）則從 menu bar 下方
    // 一路蓋到螢幕最底、佔滿整個寬度，蓋住面板所在的 dock 死角。用這個特徵分辨。
    private func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                  as? [[String: Any]] else { return false }
        let cgScreen = CGRect(x: screen.frame.minX,
                              y: primary.frame.height - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
        let menuBar: CGFloat = 40  // window 頂端最多離螢幕頂 menu bar 高度
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { continue }
            // 必須「剛好」貼齊這個螢幕：左右對齊、底部貼齊、頂端在 menu bar 內。
            // 只查左右底＋頂端範圍就能排掉比螢幕寬、或飄在螢幕外的 overlay（如 cua-driver）。
            let topInRange = (r.minY - cgScreen.minY) >= -2
                && (r.minY - cgScreen.minY) <= menuBar
            let bottomAligned = abs(r.maxY - cgScreen.maxY) < 2
            let leftAligned = abs(r.minX - cgScreen.minX) < 2
            let rightAligned = abs(r.maxX - cgScreen.maxX) < 2
            if topInRange, bottomAligned, leftAligned, rightAligned { return true }
        }
        return false
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
        // fullscreen 時讓路（dock 也是這樣）
        if hasFullscreenWindow(on: screen) {
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
        // 外側貼齊螢幕邊（跟最大化視窗的邊對齊），只在 dock 側留 gap
        if cfg.leftEnabled {
            place(leftPanel, zoneMinX: sf.minX, zoneMaxX: dock.minX - gap - retreat,
                  y: y, h: h)
        } else {
            leftPanel.orderOut(nil)
        }
        if cfg.rightEnabled {
            place(rightPanel, zoneMinX: dock.maxX + gap + retreat, zoneMaxX: sf.maxX,
                  y: y, h: h)
        } else {
            rightPanel.orderOut(nil)
        }
    }

    private func place(_ panel: NSPanel, zoneMinX: CGFloat, zoneMaxX: CGFloat,
                       y: CGFloat, h: CGFloat) {
        // 死角只要放得下最小的 widget（clock/pomodoro ~90-100pt）就顯示面板；
        // 塞得下幾個由 fitting() 決定。窄螢幕 dock 很寬時死角小，門檻高會整個藏掉。
        let minW: CGFloat = 120
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
