import AppKit
import Combine
import EventKit
import ServiceManagement
import SwiftUI

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
    @Published var total: Double = 0  // 這輪總秒數，給進度環用
    private var timer: Timer?

    func start(minutes: Int) {
        total = Double(minutes) * 60
        endDate = Date().addingTimeInterval(total)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: total, repeats: false) { _ in
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
    func panelChrome(glass: Bool = true, border: Bool = false,
                     hPad: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let base = padding(.horizontal, hPad)
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

// MARK: - 共用視覺語彙（讓所有 widget 讀起來像同一組儀表）

extension Color {
    static let hud = Color(red: 0.91, green: 0.73, blue: 0.33)       // 訊號琥珀（app 招牌色）
    static let hudCool = Color(red: 0.44, green: 0.70, blue: 0.90)   // 下載冷藍
    /// 負載色階：綠 → 琥珀 → 紅，跟招牌色和諧
    static func load(_ v: Double) -> Color {
        v > 0.8 ? Color(red: 0.90, green: 0.40, blue: 0.36)
            : v > 0.5 ? .hud
            : Color(red: 0.38, green: 0.82, blue: 0.55)
    }
}

/// 微型大寫標籤——整組 widget 的共同語彙
struct MicroLabel: View {
    @Environment(\.widgetScale) private var ws
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5 * ws, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 統一的細長膠囊儀表（CPU / RAM）
struct Meter: View {
    @Environment(\.widgetScale) private var ws
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4 * ws)
    }
}

/// 膠囊藥丸——計數類（github / herdr）
struct Pill<Content: View>: View {
    @Environment(\.widgetScale) private var ws
    var tint: Color = .primary
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 8 * ws)
            .padding(.vertical, 3 * ws)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

/// 圖示 + 數值 + 微標籤 的小計數（放進 Pill 裡）
struct CountItem: View {
    @Environment(\.widgetScale) private var ws
    let systemImage: String
    let value: String
    let label: String
    var tint: Color = .primary
    var body: some View {
        HStack(spacing: 5 * ws) {
            Image(systemName: systemImage)
                .font(.system(size: 10 * ws, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 13 * ws, weight: .semibold, design: .rounded))
                .monospacedDigit()
            MicroLabel(text: label)
        }
    }
}

struct ClockView: View {
    @Environment(\.widgetScale) private var ws

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 3) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 30 * ws, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                MicroLabel(text: ctx.date.formatted(
                    .dateTime.weekday(.abbreviated).month(.abbreviated).day()))
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
        VStack(alignment: .leading, spacing: 9 * ws) {
            row("cpu", "cpu", value: cpu, readout: "\(Int(cpu * 100))%")
            row("memorychip", "ram", value: memUsed / memTotal,
                readout: String(format: "%.1fG", memUsed / 1_073_741_824))
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        cpu = sampler.usage()
        memUsed = memoryUsedBytes()
    }

    private func row(_ icon: String, _ label: String,
                     value: Double, readout: String) -> some View {
        HStack(spacing: 8 * ws) {
            Image(systemName: icon)
                .font(.system(size: 10 * ws, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 15 * ws)
            MicroLabel(text: label).frame(width: 28 * ws, alignment: .leading)
            Meter(value: value, tint: .load(value)).frame(width: 96 * ws)
            Text(readout)
                .font(.system(size: 11 * ws, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.load(value))
                .frame(width: 40 * ws, alignment: .trailing)
        }
    }
}

struct NetView: View {
    @Environment(\.widgetScale) private var ws
    @State private var rates = (rx: 0.0, tx: 0.0)
    @State private var sampler = NetSampler()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * ws) {
            row("arrow.down", rates.rx, tint: .hudCool)
            row("arrow.up", rates.tx, tint: .hud)
        }
        .onAppear { rates = sampler.rates(interval: 2) }
        .onReceive(tick) { _ in rates = sampler.rates(interval: 2) }
    }

    private func row(_ icon: String, _ bytes: Double, tint: Color) -> some View {
        let (num, unit) = parts(bytes)
        return HStack(spacing: 6 * ws) {
            Image(systemName: icon)
                .font(.system(size: 9 * ws, weight: .bold))
                .foregroundStyle(tint)
            Text(num)
                .font(.system(size: 13 * ws, weight: .semibold, design: .rounded))
                .monospacedDigit()
            MicroLabel(text: unit)
        }
    }

    private func parts(_ b: Double) -> (String, String) {
        b >= 1_048_576 ? (String(format: "%.1f", b / 1_048_576), "MB/s")
                       : (String(format: "%.0f", b / 1024), "KB/s")
    }
}

struct GitHubView: View {
    @Environment(\.widgetScale) private var ws
    @State private var prs: String?
    @State private var reviews: String?
    @State private var reachable = true
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if reachable {
                HStack(spacing: 8 * ws) {
                    Pill(tint: .hud) {
                        CountItem(systemImage: "arrow.triangle.branch",
                                  value: prs ?? "–", label: "prs", tint: .hud)
                    }
                    Pill(tint: .secondary) {
                        CountItem(systemImage: "eye",
                                  value: reviews ?? "–", label: "review")
                    }
                }
            } else {
                HStack(spacing: 5 * ws) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    MicroLabel(text: "GitHub —")
                }
                .foregroundStyle(.secondary)
                .font(.system(size: 11 * ws))
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let p = shell("gh search prs --author=@me --state=open --json number --jq length")
            let r = shell(
                "gh search prs --review-requested=@me --state=open --json number --jq length")
            DispatchQueue.main.async {
                reachable = !(p == nil && r == nil)
                prs = p; reviews = r
            }
        }
    }
}

struct CalEvent: Identifiable {
    let id = UUID()
    let time: String
    let title: String
}

struct CalendarView: View {
    @Environment(\.widgetScale) private var ws
    @State private var events: [CalEvent] = []
    @State private var status = "…"  // 空/未授權時的提示
    @State private var store = EKEventStore()
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if events.isEmpty {
                HStack(spacing: 6 * ws) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10 * ws, weight: .semibold))
                        .foregroundStyle(.secondary)
                    MicroLabel(text: status)
                }
            } else {
                VStack(alignment: .leading, spacing: 5 * ws) {
                    ForEach(events) { e in
                        HStack(spacing: 7 * ws) {
                            Text(e.time)
                                .font(.system(size: 10 * ws, weight: .semibold,
                                              design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.hud)
                                .frame(width: 44 * ws, alignment: .leading)
                            Text(e.title)
                                .font(.system(size: 11 * ws))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        store.requestFullAccessToEvents { granted, _ in
            guard granted else {
                DispatchQueue.main.async { events = []; status = "no access" }
                return
            }
            let now = Date()
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
            let predicate = store.predicateForEvents(withStart: now, end: endOfDay,
                                                     calendars: nil)
            let list = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(3)
                .map { CalEvent(
                    time: $0.startDate.formatted(date: .omitted, time: .shortened),
                    title: $0.title ?? "") }
            DispatchQueue.main.async {
                events = Array(list)
                status = "all clear today"
            }
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

// herdr widget 連的遠端主機（ssh host alias）。空字串 = 未設定。
// 從選單「Set herdr Host…」設定，或 `defaults write com.unayung.Spacer herdrHost <host>`。
// computed：每次讀 UserDefaults，改了下次輪詢就生效。
var herdrHost: String { UserDefaults.standard.string(forKey: "herdrHost") ?? "" }

// 遠端 herdr 的 agent 狀態看板（ssh 到 herdrHost 跑 `herdr agent list`）。
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
                HStack(spacing: 5 * ws) {
                    Image(systemName: "cpu").font(.system(size: 10 * ws, weight: .semibold))
                    MicroLabel(text: herdrHost.isEmpty ? "set herdrHost" : "herdr —")
                }
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func board(working: Int, blocked: Int, idle: Int, t: Double) -> some View {
        HStack(spacing: 8 * ws) {
            if blocked > 0 {
                // 等你回覆的 agent：紅色呼吸閃爍
                Pill(tint: .load(1)) {
                    CountItem(systemImage: "exclamationmark.triangle.fill",
                              value: "\(blocked)", label: "blocked", tint: .load(1))
                }
                .opacity(0.55 + 0.45 * sin(t * 5))
            }
            if working > 0 {
                Pill(tint: .hud) {
                    HStack(spacing: 5 * ws) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 10 * ws, weight: .bold))
                            .foregroundStyle(Color.hud)
                            .rotationEffect(.degrees(
                                (t * 120).truncatingRemainder(dividingBy: 360)))
                        Text("\(working)")
                            .font(.system(size: 13 * ws, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        MicroLabel(text: "run")
                    }
                }
            }
            Pill(tint: .secondary) {
                CountItem(systemImage: "moon.zzz", value: "\(idle)", label: "idle")
            }
        }
    }

    private func refresh() {
        guard !herdrHost.isEmpty else { return }  // 沒設主機就不連
        DispatchQueue.global().async {
            // ControlMaster 讓 10 秒一次的輪詢重用連線，不用每次重新握手
            let cmd = "ssh -o BatchMode=yes -o ConnectTimeout=5 " +
                "-o ControlMaster=auto -o ControlPath=/tmp/spacer-ssh-%r@%h " +
                "-o ControlPersist=120 \(herdrHost) " +
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

// 讀 dock 圖示上的紅點徽章（Spark / LINE / Slack …）。需要「輔助使用」權限。
struct UnreadView: View {
    @Environment(\.widgetScale) private var ws
    @State private var badges: [String: String] = [:]
    @State private var trusted = AXIsProcessTrusted()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    // (dock 標題, 微標籤, SF Symbol)
    private let apps: [(name: String, label: String, icon: String)] = [
        ("Spark", "mail", "envelope.fill"),
        ("LINE", "line", "bubble.left.fill"),
        ("Slack", "slack", "number"),
    ]

    var body: some View {
        Group {
            if !trusted {
                hint("lock.fill", "grant access") { requestAccess() }
            } else {
                let active = apps.filter { !(badges[$0.name] ?? "").isEmpty }
                if active.isEmpty {
                    hint("bell", "no unread", nil)
                } else {
                    HStack(spacing: 8 * ws) {
                        ForEach(active, id: \.name) { app in
                            Pill(tint: .hud) {
                                HStack(spacing: 5 * ws) {
                                    Image(systemName: app.icon)
                                        .font(.system(size: 10 * ws, weight: .semibold))
                                        .foregroundStyle(Color.hud)
                                    badgeValue(badges[app.name] ?? "")
                                    MicroLabel(text: app.label)
                                }
                            }
                            .contentShape(Capsule())
                            .onTapGesture { runDetached("open -a '\(app.name)'") }
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func hint(_ icon: String, _ text: String,
                      _ tap: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5 * ws) {
            Image(systemName: icon).font(.system(size: 10 * ws, weight: .semibold))
            MicroLabel(text: text)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { tap?() }
    }

    @ViewBuilder private func badgeValue(_ s: String) -> some View {
        if Int(s) != nil {
            Text(s).font(.system(size: 13 * ws, weight: .semibold, design: .rounded))
                .monospacedDigit()
        } else {  // Slack 的 "•" 之類：只有紅點沒數字
            Image(systemName: "circle.fill").font(.system(size: 6 * ws))
                .foregroundStyle(Color.hud)
        }
    }

    private func refresh() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        DispatchQueue.global().async {
            let b = Self.dockBadges()
            DispatchQueue.main.async { badges = b }
        }
    }

    private func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // 走訪 Dock 的 AX 樹，回傳 app 名 → 徽章文字
    static func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var r: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &r)
            return (r as? [AXUIElement]) ?? []
        }
        func str(_ e: AXUIElement, _ a: String) -> String? {
            var r: CFTypeRef?
            AXUIElementCopyAttributeValue(e, a as CFString, &r)
            return r as? String
        }
        var out: [String: String] = [:]
        for list in children(ax) {
            for item in children(list) {
                if let t = str(item, kAXTitleAttribute as String),
                   let b = str(item, "AXStatusLabel") {
                    out[t] = b
                }
            }
        }
        return out
    }
}

struct PomodoroView: View {
    @Environment(\.widgetScale) private var ws
    @ObservedObject private var model = Pomodoro.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remain = model.endDate.map { $0.timeIntervalSince(ctx.date) } ?? 0
            let running = model.endDate != nil && remain > 0
            let done = model.endDate != nil && remain <= 0
            let progress = model.total > 0 ? max(0, min(1, remain / model.total)) : 0
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.14), lineWidth: 3 * ws)
                Circle()
                    .trim(from: 0, to: running ? progress : (done ? 1 : 0))
                    .stroke(done ? Color.load(1) : .hud,
                            style: StrokeStyle(lineWidth: 3 * ws, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    if running {
                        Text(String(format: "%d:%02d", Int(remain) / 60, Int(remain) % 60))
                            .font(.system(size: 13 * ws, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Image(systemName: done ? "checkmark" : "timer")
                            .font(.system(size: 13 * ws, weight: .semibold))
                            .foregroundStyle(done ? Color.load(1) : Color(nsColor: .secondaryLabelColor))
                    }
                    MicroLabel(text: done ? "done" : "focus")
                }
            }
            .frame(width: 46 * ws, height: 46 * ws)
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

/// 一塊浮動面板：自己的 widget 清單、位置、是否釘住。
struct PanelConfig: Codable, Identifiable {
    var id: String
    var widgets: [String]
    var x: Double
    var y: Double
    var pinned: Bool
}

final class Config: ObservableObject {
    static let shared = Config()
    private let d = UserDefaults.standard

    @Published var panels: [PanelConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(panels) { d.set(data, forKey: "panels") }
        }
    }
    // widget id → 文字縮放倍率（1 = 原始大小）
    @Published var textScale: [String: Double] {
        didSet { d.set(textScale, forKey: "textScale") }
    }
    @Published var glass: Bool { didSet { d.set(glass, forKey: "glass") } }
    @Published var border: Bool { didSet { d.set(border, forKey: "border") } }

    func widgets(_ panelID: String) -> [String] {
        panels.first { $0.id == panelID }?.widgets ?? []
    }
    func setWidgets(_ panelID: String, _ v: [String]) {
        guard let i = panels.firstIndex(where: { $0.id == panelID }) else { return }
        panels[i].widgets = v
    }
    func setPosition(_ panelID: String, x: Double, y: Double) {
        guard let i = panels.firstIndex(where: { $0.id == panelID }) else { return }
        panels[i].x = x; panels[i].y = y
    }
    func togglePin(_ panelID: String) {
        guard let i = panels.firstIndex(where: { $0.id == panelID }) else { return }
        panels[i].pinned.toggle()
    }
    func addPanel() {
        // 每塊稍微錯開，才不會疊在一起
        let off = Double(panels.count) * 24
        panels.append(PanelConfig(id: UUID().uuidString, widgets: ["clock"],
                                  x: 300 + off, y: 400 - off, pinned: false))
    }
    func removePanel(_ panelID: String) {
        panels.removeAll { $0.id == panelID }
    }

    func bumpScale(_ id: String, by delta: Double) {
        var t = textScale
        t[id] = min(1.8, max(0.6, (t[id] ?? 1) + delta))
        textScale = t
    }

    private init() {
        if let data = d.data(forKey: "panels"),
           let p = try? JSONDecoder().decode([PanelConfig].self, from: data), !p.isEmpty {
            panels = p
        } else {
            panels = [PanelConfig(id: UUID().uuidString, widgets: ["clock"],
                                  x: 300, y: 400, pinned: false)]
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
    guard !herdrHost.isEmpty else { return }
    let herdr = "\(NSHomeDirectory())/.local/bin/herdr --remote \(herdrHost)"
    runDetached("""
    if [ "$(osascript -e 'application "Ghostty" is running')" != "true" ]; then
    open -na Ghostty --args -e \(herdr)
    exit 0
    fi
    pids=$(ps ax -o pid=,command= | awk '/[h]erdr --remote \(herdrHost)/{printf ",%s", $1}')
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
    Widget(id: "unread", title: "Unread", minWidth: 200,
           action: nil) { AnyView(UnreadView()) },
]

struct PanelView: View {
    @ObservedObject var config = Config.shared
    let panelID: String

    var body: some View {
        let ids = config.widgets(panelID)
        let all = ids.compactMap { id in allWidgets.first { $0.id == id } }
        // 每格固定 200 + 1px 分隔線，全部顯示（視窗寬度已配合）
        HStack(spacing: 0) {
            ForEach(all.indices, id: \.self) { i in
                if i > 0 {
                    Rectangle().fill(.primary.opacity(0.15))
                        .frame(width: FloatingPanel.separator, height: 40)
                }
                cell(all[i], ids: ids)
            }
        }
        .panelChrome(glass: config.glass, border: config.border, hPad: 0)
    }

    private func cell(_ w: Widget, ids: [String]) -> some View {
        w.make()
            .environment(\.widgetScale, CGFloat(config.textScale[w.id] ?? 1))
            .frame(width: FloatingPanel.widgetWidth)
            .contentShape(Rectangle())
            .onTapGesture { w.action?() }
            .contextMenu {
                Button("← Move Left") { reorder(w.id, by: -1) }
                Button("Move Right →") { reorder(w.id, by: 1) }
                Divider()
                Button("Text Larger") { config.bumpScale(w.id, by: 0.1) }
                Button("Text Smaller") { config.bumpScale(w.id, by: -0.1) }
                Divider()
                let inactive = allWidgets.filter { !ids.contains($0.id) }
                if !inactive.isEmpty {
                    Menu("Add Widget") {
                        ForEach(inactive, id: \.id) { ww in
                            Button(ww.title) { add(ww.id) }
                        }
                    }
                }
                Button("Remove") { remove(w.id) }
            }
    }

    private func reorder(_ id: String, by delta: Int) {
        config.setWidgets(panelID, movedIds(config.widgets(panelID), id, by: delta))
    }
    private func remove(_ id: String) {
        config.setWidgets(panelID, config.widgets(panelID).filter { $0 != id })
    }
    private func add(_ id: String) {
        config.setWidgets(panelID, config.widgets(panelID) + [id])
    }
}

// MARK: - Panel

/// 可拖曳的浮動面板：寬度由 widget 數決定（每格固定 200）。釘住時不可拖。
final class FloatingPanel: NSPanel {
    static let panelHeight: CGFloat = 72
    static let widgetWidth: CGFloat = 200
    static let separator: CGFloat = 1

    var panelID = ""

    /// n 個 widget 該有的面板寬度：200*n + 分隔線(n-1)
    static func width(for count: Int) -> CGFloat {
        let n = max(1, count)
        return CGFloat(n) * widgetWidth + CGFloat(n - 1) * separator
    }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true  // 拖背景即可移動
        ignoresMouseEvents = false
    }
}

// MARK: - App

/// 選單項目引用：哪塊面板、哪個 widget（widget 可為 nil 表示面板層級操作）
final class MenuRef: NSObject {
    let panel: String
    let widget: String?
    init(panel: String, widget: String? = nil) { self.panel = panel; self.widget = widget }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [String: FloatingPanel] = [:]  // panelID → 視窗
    private var statusItem: NSStatusItem?
    private var configWatcher: AnyCancellable?
    private var restoring = false  // 程式還原位置時別回存，免得抖

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 首次啟動自動註冊開機啟動；之後由選單的 Launch at Login 控制
        if UserDefaults.standard.object(forKey: "didAutoRegisterLogin") == nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didAutoRegisterLogin")
        }
        setupStatusItem()
        // 任何 Config 變動都重建選單並同步面板（加/移面板、加 widget 立刻反映）
        configWatcher = Config.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
                self?.syncPanels()
            }
        syncPanels()
    }

    // MARK: 面板管理

    /// 依 Config.panels 建立 / 移除 / 更新每塊浮動面板
    private func syncPanels() {
        let cfg = Config.shared
        let ids = Set(cfg.panels.map(\.id))
        for (id, win) in windows where !ids.contains(id) {  // config 沒了就關掉
            win.orderOut(nil)
            windows[id] = nil
        }
        for p in cfg.panels {
            let win = windows[p.id] ?? makePanel(p.id)
            windows[p.id] = win
            let frame = NSRect(x: p.x, y: p.y,
                               width: FloatingPanel.width(for: p.widgets.count),
                               height: FloatingPanel.panelHeight)
            if win.frame != frame {
                restoring = true
                win.setFrame(frame, display: true)
                restoring = false
            }
            win.isMovableByWindowBackground = !p.pinned  // 釘住 = 不能拖
            win.orderFrontRegardless()
        }
    }

    private func makePanel(_ id: String) -> FloatingPanel {
        let win = FloatingPanel()
        win.panelID = id
        win.delegate = self
        win.contentView = FirstMouseHostingView(rootView: PanelView(panelID: id))
        return win
    }

    // 拖曳後存位置（釘住的不會觸發，因為不能拖）
    func windowDidMove(_ notification: Notification) {
        guard !restoring, let win = notification.object as? FloatingPanel else { return }
        Config.shared.setPosition(win.panelID, x: win.frame.minX, y: win.frame.minY)
    }

    // MARK: 狀態列選單

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2",
                                     accessibilityDescription: "Spacer")
        statusItem = item
        rebuildMenu()
    }

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
        for (i, p) in Config.shared.panels.enumerated() {
            menu.addItem(panelItem(p, index: i))
        }
        let add = NSMenuItem(title: "Add Panel",
                             action: #selector(addPanel), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
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
        let hh = NSMenuItem(title: "Set herdr Host…",
                            action: #selector(setHerdrHost), keyEquivalent: "")
        hh.target = self
        menu.addItem(hh)
        menu.addItem(NSMenuItem(title: "Quit Spacer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func setHerdrHost() {
        let alert = NSAlert()
        alert.messageText = "herdr Host"
        alert.informativeText = "herdr Agents widget 要連的 SSH host（~/.ssh/config 的別名）。留空停用。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = herdrHost
        field.placeholderString = "e.g. my-remote"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)  // accessory app 要主動叫視窗到前面
        alert.window.makeFirstResponder(field)
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(
                field.stringValue.trimmingCharacters(in: .whitespaces), forKey: "herdrHost")
        }
    }

    private func panelItem(_ p: PanelConfig, index: Int) -> NSMenuItem {
        let cfg = Config.shared
        let item = NSMenuItem(title: "Panel \(index + 1)" + (p.pinned ? "  · pinned" : ""),
                              action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let pin = NSMenuItem(title: "Pinned",
                             action: #selector(togglePin(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = MenuRef(panel: p.id)
        pin.state = p.pinned ? .on : .off
        sub.addItem(pin)
        sub.addItem(.separator())
        for (i, id) in p.widgets.enumerated() {
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
                op.representedObject = MenuRef(panel: p.id, widget: id)
                ops.addItem(op)
            }
            mi.submenu = ops
            sub.addItem(mi)
        }
        let inactive = allWidgets.filter { !p.widgets.contains($0.id) }
        if !inactive.isEmpty { sub.addItem(.separator()) }
        for w in inactive {
            let mi = NSMenuItem(title: "Add \(w.title)",
                                action: #selector(addWidget(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = MenuRef(panel: p.id, widget: w.id)
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let remove = NSMenuItem(title: "Remove Panel",
                                action: #selector(removePanel(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = MenuRef(panel: p.id)
        sub.addItem(remove)
        item.submenu = sub
        return item
    }

    // MARK: 動作

    @objc private func addPanel() { Config.shared.addPanel() }

    @objc private func removePanel(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuRef else { return }
        Config.shared.removePanel(ref.panel)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuRef else { return }
        Config.shared.togglePin(ref.panel)
    }

    private func mutateWidgets(_ sender: NSMenuItem,
                               _ transform: ([String], String) -> [String]) {
        guard let ref = sender.representedObject as? MenuRef, let wid = ref.widget else { return }
        let cfg = Config.shared
        cfg.setWidgets(ref.panel, transform(cfg.widgets(ref.panel), wid))
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
        guard let ref = sender.representedObject as? MenuRef, let wid = ref.widget else { return }
        Config.shared.bumpScale(wid, by: 0.1)
    }
    @objc private func textSmaller(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuRef, let wid = ref.widget else { return }
        Config.shared.bumpScale(wid, by: -0.1)
    }

    @objc private func toggleGlass() { Config.shared.glass.toggle() }
    @objc private func toggleBorder() { Config.shared.border.toggle() }

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
        rebuildMenu()
    }

    @objc private func startPomodoro() { Pomodoro.shared.start(minutes: 25) }
    @objc private func stopPomodoro() { Pomodoro.shared.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
