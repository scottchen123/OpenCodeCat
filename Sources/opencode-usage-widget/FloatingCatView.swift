import SwiftUI
import AppKit

// OpenCodeCat — 桌面浮标猫咪，用量监控
// 可拖动、悬停展开指标、点击查看详情

// MARK: - Data

/// 不同中转 API 字段不一定齐（有的缺 status/resetsAt、percent 给整数），解码时全部容错
struct UsageWindow: Codable, Equatable {
    var status: String = ""
    var percent: Double = 0
    var resetsAt: String = ""

    enum CodingKeys: String, CodingKey { case status, percent, resetsAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        if let d = try? c.decode(Double.self, forKey: .percent) {
            percent = d
        } else if let i = try? c.decode(Int.self, forKey: .percent) {
            percent = Double(i)
        }
        resetsAt = (try? c.decode(String.self, forKey: .resetsAt)) ?? ""
    }
}

struct UsageResponse: Codable {
    let usage: [String: UsageWindow]
}

/// 兼容多种回包形状：{"usage":{...}} / {"data":{"usage":{...}}} / 顶层直接就是各窗口
func parseUsage(_ data: Data) -> [String: UsageWindow]? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let dec = JSONDecoder()
    func windows(_ obj: Any?) -> [String: UsageWindow]? {
        guard let obj, JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let m = try? dec.decode([String: UsageWindow].self, from: d),
              !m.isEmpty else { return nil }
        return m
    }
    if let u = windows(json["usage"]) { return u }
    if let dataObj = json["data"] as? [String: Any], let u = windows(dataObj["usage"]) { return u }
    let keys = Set(json.keys)
    if keys.contains("rolling") || keys.contains("weekly") || keys.contains("monthly") {
        return windows(json)
    }
    return nil
}

@MainActor
final class UsageFetcher: ObservableObject, @unchecked Sendable {
    static let defaultName = "OpenCode Go"
    static let defaultEndpoint = "https://opencode.ai/zen/go/v1/usage"

    @Published var rolling: UsageWindow?
    @Published var weekly: UsageWindow?
    @Published var monthly: UsageWindow?
    @Published var error: String?
    @Published var lastUpdated: Date?
    /// 渠道名称 / 用量接口地址：详情面板 ⚙ 里可改，换中转 API 时改这里即可
    @Published var providerName: String = defaultName
    @Published var endpoint: String = defaultEndpoint

    private var timer: Timer?
    private let nameKey = "opencodecat.provider.name"
    private let endpointKey = "opencodecat.provider.endpoint"
    private let keyKey = "opencodecat.provider.apikey"

    init() {
        if let n = UserDefaults.standard.string(forKey: nameKey), !n.isEmpty { providerName = n }
        if let e = UserDefaults.standard.string(forKey: endpointKey), !e.isEmpty { endpoint = e }
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    /// key 优先级：面板设置 > 环境变量 > 旧 UserDefaults > ~/.opencode-usage-key（600 权限）
    var apiKey: String {
        if let s = UserDefaults.standard.string(forKey: keyKey), !s.isEmpty { return s }
        if let e = ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"], !e.isEmpty { return e }
        if let s = UserDefaults.standard.string(forKey: "opencode-usage.apikey"), !s.isEmpty { return s }
        let p = NSHomeDirectory() + "/.opencode-usage-key"
        return (try? String(contentsOfFile: p, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var endpointHost: String { URL(string: endpoint)?.host ?? "地址无效" }

    func fetch() {
        guard let url = URL(string: endpoint),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            self.error = "接口地址无效：\(endpoint)"
            self.lastUpdated = Date()
            return
        }
        let key = apiKey
        guard !key.isEmpty else {
            self.error = "未找到 key（点详情面板 ⚙ 填写，或写入 ~/.opencode-usage-key）"
            self.lastUpdated = Date()
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data,
                   let usage = parseUsage(data) {
                    self.rolling = usage["rolling"]
                    self.weekly = usage["weekly"]
                    self.monthly = usage["monthly"]
                    self.error = nil
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    self.error = err?.localizedDescription ?? "HTTP \(code)（\(self.endpointHost)）"
                }
                self.lastUpdated = Date()
            }
        }.resume()
    }

    /// 面板保存：名称/地址存 UserDefaults；key 非空则同步存 UserDefaults + 写回
    /// ~/.opencode-usage-key（600），为空则清除面板 key、回落到环境变量/文件
    func saveProvider(name: String, endpoint: String, key: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty {
            providerName = n
            UserDefaults.standard.set(n, forKey: nameKey)
        }
        if !e.isEmpty {
            guard let u = URL(string: e),
                  ["http", "https"].contains(u.scheme?.lowercased()) else {
                self.error = "接口地址无效：\(e)"
                return
            }
            self.endpoint = e
            UserDefaults.standard.set(e, forKey: endpointKey)
        }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty {
            UserDefaults.standard.set(k, forKey: keyKey)
            let p = NSHomeDirectory() + "/.opencode-usage-key"
            try? k.write(toFile: p, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
        } else {
            UserDefaults.standard.removeObject(forKey: keyKey)
        }
        // 换地址/key 后清旧数据重拉
        rolling = nil; weekly = nil; monthly = nil
        fetch()
    }

    func resetProvider() {
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: endpointKey)
        UserDefaults.standard.removeObject(forKey: keyKey)
        providerName = Self.defaultName
        endpoint = Self.defaultEndpoint
        rolling = nil; weekly = nil; monthly = nil
        fetch()
    }
}

func levelColor(_ p: Double) -> Color {
    p >= 90 ? .red : (p >= 70 ? .orange : (p >= 40 ? .yellow : .green))
}

/// 复用 formatter 实例，避免频繁创建
enum ResetsFormat {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static let rel: RelativeDateTimeFormatter = {
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .abbreviated
        r.locale = Locale(identifier: "zh_CN")
        return r
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

func resetsText(_ w: UsageWindow?) -> String {
    guard let w else { return "?" }
    guard let d = ResetsFormat.iso.date(from: w.resetsAt)
        ?? ResetsFormat.isoPlain.date(from: w.resetsAt) else { return "?" }
    let s = ResetsFormat.rel.localizedString(for: d, relativeTo: Date())
    if s.contains("天") { return ResetsFormat.day.string(from: d) }
    return s
}

// MARK: - Cat frames

func loadCatFrames() -> [NSImage] {
    var out: [NSImage] = []
    for i in 0...4 {
        let exe = CommandLine.arguments.first ?? ""
        let dir = (exe as NSString).deletingLastPathComponent
        for path in ["\(dir)/frame\(i).png", "\(dir)/CatFrames/frame\(i).png",
                     "\(dir)/../Resources/frame\(i).png"] {
            if let img = NSImage(contentsOfFile: path) { out.append(img); break }
        }
    }
    return out
}

// MARK: - Floating capsule widget (桌面浮标)

struct CatWidget: View {
    @ObservedObject var fetcher: UsageFetcher
    var frames: [NSImage]
    var onTap: () -> Void
    var onRefresh: () -> Void
    var onResetPosition: () -> Void
    var onHide: () -> Void
    var onQuit: () -> Void
    /// hover 状态变化时通知 Controller 做窗口展开/收起（避免内容被固定窗口裁掉）
    var onHoverSize: (Bool) -> Void
    /// 拖动总位移（SwiftUI global 坐标，y 向下为正）；Controller 按鼠标抓取偏移做绝对定位
    var onDragStarted: () -> Void
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: () -> Void

    @State private var hover = false
    @State private var frameIndex = 0
    /// 拖拽中标记：锁 hover 内容切换（避免窗口尺寸跳变吃位移），并用于区分点击/拖拽
    @State private var dragging = false
    @State private var dragMoved: CGFloat = 0
    /// 拖拽中强制按常态显示，hover 展开只在静止时生效
    private var effectiveHover: Bool { hover && !dragging }
    private let animTick = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                // 像素猫跑步动画
                Image(nsImage: currentFrame)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 36)
                // hover 展开全部指标，平时只显示月度（拖拽中锁常态，避免尺寸跳变）
                if effectiveHover {
                    VStack(alignment: .leading, spacing: 3) {
                        meterRow("5h", fetcher.rolling?.percent)
                        meterRow("周", fetcher.weekly?.percent)
                        meterRow("月", fetcher.monthly?.percent)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    if let m = fetcher.monthly?.percent {
                        Text((m >= 90 ? "⚠ " : "") + "\(Int(m))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(levelColor(m))
                            .transition(.opacity)
                    } else if fetcher.error != nil {
                        Text("⚠").font(.system(size: 13, weight: .bold))
                    } else {
                        Text("…").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 无底色无边框：猫 + 文字直接浮在桌面上（投影保证可读）
            // hover 右上角 ×：关闭浮标（退出程序，拖拽中不显示避免布局跳变抢手势）
            if effectiveHover {
                Button(action: { onQuit() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: -2, y: 2)
                .help("关闭浮标（退出程序）")
                .transition(.opacity)
            }
        }
        .onHover { h in
            // 轻量动画，避免卡顿
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            onHoverSize(h)
        }
        .onTapGesture {
            // 刚拖完（位移超阈值）不算点击，避免拖完误弹详情面板
            if dragMoved < 4 { onTap() }
            dragMoved = 0
        }
        // 拖动手势：绝对定位，保证跟手
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { v in
                    if !dragging {
                        dragging = true
                        onDragStarted()
                    }
                    dragMoved = max(dragMoved, abs(v.translation.width) + abs(v.translation.height))
                    onDragChanged(v.translation)
                }
                .onEnded { _ in
                    dragging = false
                    onDragEnded()
                }
        )
        .onReceive(animTick) { _ in
            if !frames.isEmpty { frameIndex = (frameIndex + 1) % frames.count }
        }
        .contextMenu {
            Button("显示 / 隐藏详情面板") { onTap() }
            Button("立即刷新") { onRefresh() }
            Button("放回右上角") { onResetPosition() }
            Button("隐藏浮标（可再开启）") { onHide() }
            Divider()
            Button("关闭浮标（退出）") { onQuit() }
        }
    }

    var currentFrame: NSImage {
        if frames.isEmpty { return NSImage() }
        return frames[frameIndex % frames.count]
    }

    @ViewBuilder
    private func meterRow(_ label: String, _ p: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let p {
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.08))
                        .frame(width: 44, height: 6)
                    Capsule().fill(levelColor(p))
                        .frame(width: max(3, 44 * p / 100), height: 6)
                }
                Text("\(Int(p))%").font(.caption2.bold()).foregroundColor(levelColor(p))
            } else {
                Text("?").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Detail panel (点击浮标展开)

struct UsageDetailPanel: View {
    @ObservedObject var fetcher: UsageFetcher
    var onRefresh: () -> Void
    var onQuit: () -> Void

    /// ⚙ 设置态：可改名称 / key / 用量接口地址（换中转时改这里）
    @State private var editing = false
    @State private var editName = ""
    @State private var editEndpoint = ""
    @State private var editKey = ""
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题栏
            HStack(spacing: 8) {
                Text("🐱").font(.system(size: 20))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.white.opacity(0.5)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(fetcher.providerName).font(.headline)
                    Text("\(fetcher.endpointHost) · 每 60 秒刷新").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: {
                    if !editing {
                        editName = fetcher.providerName
                        editEndpoint = fetcher.endpoint
                        // 预填 key（脱敏显示），留空则不更换
                        editKey = fetcher.apiKey
                        showKey = false
                    }
                    editing.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("设置：名称 / key / 接口地址")
                Circle()
                    .fill(fetcher.error != nil && fetcher.monthly == nil ? .red : .green)
                    .frame(width: 8, height: 8)
            }
            if editing {
                settingsCard
            } else if let e = fetcher.error, fetcher.monthly == nil {
                banner(icon: "wifi.exclamationmark", text: e, tint: .red)
            } else {
                card(icon: "timer", label: "5 小时窗口", w: fetcher.rolling)
                card(icon: "calendar", label: "本周", w: fetcher.weekly)
                card(icon: "chart.bar.fill", label: "本月", w: fetcher.monthly, highlight: true)
                if let m = fetcher.monthly?.percent, m >= 90 {
                    banner(icon: "exclamationmark.triangle.fill",
                           text: "月额度将用尽，请留意重置时间",
                           tint: .red)
                }
            }
            HStack {
                Text("更新于 \(fetcher.lastUpdated.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "-")")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("立即刷新") { onRefresh() }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("退出") { onQuit() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        // 外层留出投影边距，避免阴影被窗口边缘裁出硬角
        .padding(14)
    }

    /// 设置卡：名称 / key / 接口地址；保存后清旧数据重拉并收起
    @ViewBuilder
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("渠道设置").font(.subheadline.weight(.semibold))
            settingsField(icon: "tag", title: "名称", placeholder: "如 OpenCode Go / 某某中转",
                          text: $editName, secure: false)
            // 默认 SecureField（• 脱敏可直接编辑），点眼睛切明文查看全文
            settingsField(icon: "key.fill", title: "Key",
                          placeholder: "粘贴 key",
                          text: $editKey, secure: !showKey, trailingInset: 26)
            .overlay(alignment: .trailing) {
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            settingsField(icon: "link", title: "用量接口", placeholder: "https://…/v1/usage",
                          text: $editEndpoint, secure: false)
                .help("换中转 API 时把它的用量接口地址填这里，须返回 rolling/weekly/monthly 各自的 percent")
            HStack(spacing: 8) {
                Button("恢复默认") { fetcher.resetProvider(); editing = false }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).controlSize(.small)
                Spacer()
                Button("取消") { editing = false }
                    .buttonStyle(.borderless).controlSize(.small)
                Button("保存") {
                    fetcher.saveProvider(name: editName, endpoint: editEndpoint, key: editKey)
                    editing = false
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && editEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && editKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func settingsField(icon: String, title: String, placeholder: String,
                               text: Binding<String>, secure: Bool,
                               trailingInset: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .padding(.trailing, trailingInset)
        }
    }

    @ViewBuilder
    private func card(icon: String, label: String, w: UsageWindow?, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(resetsText(w)).font(.caption2).foregroundStyle(.secondary)
                Text(w.map { "\(Int($0.percent))%" } ?? "?")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(w.map { levelColor($0.percent) } ?? .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.08))
                    if let p = w?.percent {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [levelColor(p), levelColor(p).opacity(0.6)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * min(p, 100) / 100))
                    }
                }
            }
            .frame(height: 8)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay {
            if highlight, let p = w?.percent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(levelColor(p).opacity(0.4), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func banner(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

// 可获焦的浮窗子类，让详情面板可输入
final class KeyableFloatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Floating window controller

@MainActor
final class FloatController: NSObject {
    private var widgetWin: NSWindow!
    private var panelWin: NSWindow?
    private var fetcher: UsageFetcher!
    private var panelShown = false
    private var sigSrc: DispatchSourceSignal?

    private let posKey = "opencodecat.floatpos"
    /// 常态 / hover 展开两种窗口尺寸（hover 用真实窗口放大，保证指标不被裁掉）
    private let normalSize = NSSize(width: 150, height: 54)
    private let hoverSize = NSSize(width: 224, height: 84)
    /// 拖拽起始窗口原点 + 拖拽中标记（拖拽时锁 hover 缩放，避免窗口尺寸跳变吃掉位移）
    private var dragStartOrigin: NSPoint?
    private var dragging = false

    func setup(fetcher: UsageFetcher) {
        self.fetcher = fetcher
        let frames = loadCatFrames()

        let root = CatWidget(
            fetcher: fetcher,
            frames: frames,
            onTap: { [weak self] in Task { @MainActor in self?.togglePanel() } },
            onRefresh: { fetcher.fetch() },
            onResetPosition: { [weak self] in Task { @MainActor in self?.resetPosition() } },
            onHide: { [weak self] in Task { @MainActor in self?.hideWidget() } },
            onQuit: { NSApp.terminate(nil) },
            onHoverSize: { [weak self] h in self?.setHover(h) },
            onDragStarted: { [weak self] in self?.dragStarted() },
            onDragChanged: { [weak self] t in self?.dragChanged(translation: t) },
            onDragEnded: { [weak self] in self?.dragEnded() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(normalSize)

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: normalSize),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 只走 SwiftUI DragGesture 一条拖拽通道，避免系统背景拖拽和手势抢窗口
        win.isMovable = false
        win.isMovableByWindowBackground = false
        win.hasShadow = false
        self.widgetWin = win

        // 恢复上次位置，否则默认右上角
        if let saved = UserDefaults.standard.string(forKey: posKey) {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                win.setFrameOrigin(NSPoint(x: parts[0], y: parts[1]))
            } else {
                placeTopRight(win)
            }
        } else {
            placeTopRight(win)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePos), name: NSWindow.didMoveNotification, object: win)

        // SIGUSR1 翻转显示/隐藏（toggle-cat.sh 用，不杀进程）
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.toggleWidget() }
        }
        src.resume()
        sigSrc = src

        win.orderFrontRegardless()
    }

    private func placeTopRight(_ win: NSWindow) {
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            // 菜单栏下方一点
            win.setFrameTopLeftPoint(NSPoint(x: v.maxX - win.frame.width - 12, y: v.maxY - 8))
        }
    }

    @objc private func savePos(_ note: Notification) {
        let o = widgetWin.frame.origin
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: posKey)
    }

    /// 鼠标抓取偏移：按下瞬间鼠标在窗口内的相对位置（Cocoa 坐标），之后全程用它做绝对定位
    private var grabOffset: NSPoint = .zero

    /// hover 时真实放大窗口（猫的位置锚定不动，向右/向下展开并收进屏幕）；离开时缩回
    private func setHover(_ h: Bool) {
        // 拖拽中窗口尺寸冻结在常态
        if dragging { return }
        // 同尺寸重复调用直接跳过
        let want = h ? hoverSize : normalSize
        if widgetWin.frame.size == want { return }
        var f = widgetWin.frame
        let topLeft = NSPoint(x: f.minX, y: f.maxY)
        f.size = NSSize(width: want.width, height: want.height)
        f.origin = NSPoint(x: topLeft.x, y: topLeft.y - want.height)
        if let screen = widgetWin.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
            if f.minX < v.minX { f.origin.x = v.minX }
            if f.minY < v.minY { f.origin.y = v.minY }
            if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        }
        // 非动画直接设帧
        widgetWin.setFrame(f, display: true, animate: false)
    }

    /// 拖拽开始：按当前鼠标位置重新抓取偏移
    private func dragStarted() {
        dragging = true
        let mouse = NSEvent.mouseLocation
        let f = widgetWin.frame
        grabOffset = NSPoint(x: mouse.x - f.minX, y: mouse.y - f.minY)
        dragStartOrigin = nil
    }

    /// 拖拽：鼠标屏坐标 - 抓取偏移 = 窗口原点
    private func dragChanged(translation t: CGSize) {
        dragging = true
        // 兜底：万一 started 没接到（如极快点击拖），用起始原点 + 总位移
        if NSEvent.pressedMouseButtons == 0 { return }
        let mouse = NSEvent.mouseLocation
        var o: NSPoint
        if dragStartOrigin == nil && (grabOffset == .zero) {
            dragStartOrigin = widgetWin.frame.origin
        }
        if grabOffset != .zero {
            o = NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        } else {
            guard let start = dragStartOrigin else { return }
            // SwiftUI global 坐标 y 向下为正，Cocoa 窗口 y 向上为正，需取反
            o = NSPoint(x: start.x + t.width, y: start.y - t.height)
        }
        if let screen = widgetWin.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            let f = widgetWin.frame
            o.x = min(max(o.x, v.minX), v.maxX - f.width)
            o.y = min(max(o.y, v.minY), v.maxY - f.height)
        }
        widgetWin.setFrameOrigin(o)
    }

    private func dragEnded() {
        dragging = false
        dragStartOrigin = nil
        grabOffset = .zero
        // 拖完对齐一次窗口尺寸
        setHover(false)
        persistPos()
    }

    private func persistPos() {
        let o = widgetWin.frame.origin
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: posKey)
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: posKey)
        placeTopRight(widgetWin)
    }

    /// 隐藏浮标（进程保留，可用 toggle-cat.sh 或重跑 run-cat.sh 再开启）
    private func hideWidget() {
        hidePanel()
        widgetWin.orderOut(nil)
    }

    private func toggleWidget() {
        if widgetWin.isVisible { hideWidget() } else { widgetWin.orderFrontRegardless() }
    }

    private func togglePanel() {
        if panelShown { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        let panelHost = NSHostingView(rootView: UsageDetailPanel(
            fetcher: fetcher,
            onRefresh: { [weak self] in self?.fetcher.fetch() },
            onQuit: { NSApp.terminate(nil) }
        ))
        panelHost.setFrameSize(NSSize(width: 278, height: 420))
        let panel = KeyableFloatWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 278, height: 420)),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = panelHost
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false

        // 贴在浮标下方，超出屏幕则翻到上方
        var origin = widgetWin.frame.origin
        origin.y -= 428
        if let screen = widgetWin.screen, origin.y < screen.visibleFrame.minY {
            origin.y = widgetWin.frame.maxY + 8
        }
        // 水平方向收进屏幕
        if let screen = widgetWin.screen {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - 286)
        }
        panel.setFrameOrigin(origin)
        // 获焦并置前，保证可输入
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panelWin = panel
        panelShown = true
    }

    private func hidePanel() {
        panelWin?.orderOut(nil)
        panelWin = nil
        panelShown = false
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: FloatController?
    private var fetcher: UsageFetcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let f = UsageFetcher()
        let c = FloatController()
        MainActor.assumeIsolated {
            self.fetcher = f
            self.controller = c
            c.setup(fetcher: f)
        }
    }
}

@main
struct OpenCodeCatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// RunCat 像素猫贴图 © Kyome22 / menubar_runcat (MIT License)
// https://github.com/Kyome22/menubar_runcat
