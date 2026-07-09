import AppKit
import SwiftUI

// MARK: - Dock 偵測
// 零權限做法：CGWindowList 的 ownerName 與 bounds 不需要螢幕錄製權限。
// ponytail: 只支援主螢幕 + dock 在底部；dock 在左右或多螢幕時面板直接隱藏，需要再加。

func primaryDockFrame() -> NSRect? {
    guard let screen = NSScreen.screens.first else { return nil }
    let screenH = screen.frame.height
    let screenW = screen.frame.width
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]] else { return nil }

    var best: CGRect?
    for info in list where info[kCGWindowOwnerName as String] as? String == "Dock" {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
        // dock 本體：貼齊主螢幕底部、比螢幕窄、高度像個 dock
        // （排除同樣由 Dock process 持有的桌布、Mission Control 等視窗）
        guard abs(r.maxY - screenH) < 4,
              r.height > 20, r.height < 300,
              r.width < screenW else { continue }
        if best == nil || r.width > best!.width { best = r }
    }
    guard let cg = best else { return nil }
    // CG 座標（左上原點）→ AppKit（左下原點），僅主螢幕成立
    return NSRect(x: cg.minX, y: screenH - cg.maxY, width: cg.width, height: cg.height)
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
    func panelChrome() -> some View {
        padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 1) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
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
                .frame(width: 120)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Panel

final class SpacerPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 跟 dock 同一層，才會像 dock 一樣永遠看得到
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // ponytail: 點擊穿透 = 面板純顯示；要做可點的 widget（播放控制等）再拿掉
        ignoresMouseEvents = true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let leftPanel = SpacerPanel()
    private let rightPanel = SpacerPanel()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        leftPanel.contentView = NSHostingView(rootView: ClockView().panelChrome())
        rightPanel.contentView = NSHostingView(rootView: StatsView().panelChrome())
        setupStatusItem()
        layout()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.layout()  // dock 大小會隨 app 增減變動，用輪詢追
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.layout() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled",
                                     accessibilityDescription: "Spacer")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Spacer",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let reserved = screen.visibleFrame.minY - sf.minY  // dock 佔用的底部高度
        guard reserved > 24, let dock = primaryDockFrame() else {
            leftPanel.orderOut(nil)
            rightPanel.orderOut(nil)
            return  // dock 自動隱藏 / 在側邊 / 找不到 → 沒有死角空間可用
        }
        let gap: CGFloat = 14, inset: CGFloat = 6
        let y = sf.minY + inset
        let h = reserved - inset * 2
        place(leftPanel, zoneMinX: sf.minX + gap, zoneMaxX: dock.minX - gap, y: y, h: h)
        place(rightPanel, zoneMinX: dock.maxX + gap, zoneMaxX: sf.maxX - gap, y: y, h: h)
    }

    private func place(_ panel: NSPanel, zoneMinX: CGFloat, zoneMaxX: CGFloat,
                       y: CGFloat, h: CGFloat) {
        let maxW: CGFloat = 360, minW: CGFloat = 200
        let available = zoneMaxX - zoneMinX
        guard available >= minW, h > 30 else { panel.orderOut(nil); return }
        let w = min(available, maxW)
        let x = zoneMinX + (available - w) / 2  // 置中在死角區
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
