import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class AppModel: ObservableObject {
    @Published var status = "先开启 LocalDevVPN，再导入这台 iPad 的配对文件。"
    @Published var imported = false
    @Published var working = false
    @Published var running = false
    @Published var invite = ""
    @Published var screenSession = true
    @Published var orientation = 1
    @Published var history = [String]()
    private let engine = NativeEngine()
    private var server: LANServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTimer: Timer?
    private var cancelRequested = false
    private var closing = false
    private var pairURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pairing.plist")
    }
    init() { imported = FileManager.default.fileExists(atPath: pairURL.path) }
    func note(_ text: String) {
        status = text; history.append(text)
        if history.count > 30 { history.removeFirst(history.count-30) }
    }
    func importPair(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 2*1024*1024,
                  let record = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  record["HostID"] is String, record["SystemBUID"] is String,
                  record["HostPrivateKey"] is Data, record["DeviceCertificate"] is Data else {
                note("配对文件无效；请导入这台 iPad 的完整配对记录。"); return
            }
            try FileManager.default.createDirectory(at: pairURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: pairURL, options: [.atomic, .completeFileProtection])
            var privateURL = pairURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try privateURL.setResourceValues(values)
            imported = true; note("配对记录已保存在本机，可以启动。")
        } catch { note("导入失败：\(error.localizedDescription)") }
    }
    func start() {
        guard !working && !running && imported else { return }
        guard let ip = lanAddress() else { note("没有检测到 Wi-Fi 地址，请连接无线局域网。"); return }
        working = true; cancelRequested = false; closing = false; invite = ""
        note(screenSession ? "正在连接自身开发服务：LocalDevVPN → CoreDevice → 屏幕会话 → HID。" :
             "正在连接自身开发服务：LocalDevVPN → CoreDevice → HID（已跳过屏幕会话）。")
        let selectedOrientation = UInt32(orientation)
        engine.open(path: pairURL.path, media: screenSession) { [weak self] error in
            guard let self = self else { return }
            if self.cancelRequested { self.engine.close { self.finishStop() }; return }
            if let error = error {
                self.working = false
                self.note(error.hasPrefix("setup: screen session:") ?
                          error + "\n可以关闭“同时建立屏幕会话”测试 HID 连通性；连接成功仍需观察实际触控。" : error)
                self.endBackground(); return
            }
            let server = LANServer(engine: self.engine, orientation: selectedOrientation)
            self.server = server
            server.report = { [weak self] text in self?.note(text) }
            server.start(ip: ip) { [weak self] code, error in
                guard let self = self, !self.closing else { return }
                self.working = false
                if let error = error { self.note(error); self.stop(); return }
                self.invite = code ?? ""; self.running = true; UIApplication.shared.isIdleTimerDisabled = true
                self.note("HID 通道已连接；监听 \(ip):8798。需要实际触控确认系统是否接受输入。")
            }
        }
    }
    func stop() {
        guard !closing else { return }
        cancelRequested = true; closing = true; running = false; invite = ""
        note("正在停止连接并松开触控。")
        if let server = server { server.stop { [weak self] in self?.finishStop() } }
        else if !working { engine.close { [weak self] in self?.finishStop() } }
        // A pending open owns its handle until completion, then closes it itself.
    }
    private func finishStop() {
        server = nil; working = false; running = false; closing = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackground(); note("已停止；返回此处重新启动。")
    }
    func background() {
        guard running || working, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "finish-native-touch") { [weak self] in
            self?.stop()
        }
        guard backgroundTask != .invalid else { stop(); return }
        note("已切到后台：仅供短时验证，系统剩余时间不足时会主动停止。")
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let remaining = UIApplication.shared.backgroundTimeRemaining
            if remaining.isFinite && remaining < 10 { self?.stop() }
        }
    }
    func foreground() { endBackground() }
    private func endBackground() {
        backgroundTimer?.invalidate(); backgroundTimer = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}

@main struct TouchBridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var importing = false
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("纯 iPad 触控 · 实验版 0.1.1") {
                        Text("iPad 直接接收主控的按下、移动和松开，日常运行不需要被控端电脑。当前只验证同一 Wi-Fi 下的触控与短时后台运行。")
                        Text(model.status).foregroundStyle(.secondary)
                    }
                    Section("首次配置") {
                        Link("安装 LocalDevVPN", destination: URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!)
                        Text("先在 LocalDevVPN 中允许添加 VPN 配置并开启连接。开发者模式和本机配对记录也必须有效。")
                        Button(model.imported ? "重新导入配对文件" : "导入这台 iPad 的配对文件") { importing = true }
                            .disabled(model.working || model.running)
                        Text("配对文件只保存在这台设备，不会上传。不要导入别人的配对记录。签名安装和首次配对需要一次准备。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("连接设置") {
                        Toggle("同时建立屏幕会话（建议开启）", isOn: $model.screenSession)
                        Text("若启动提示 audio negotiation failed，先关闭此项检查 HID 连通性。部分系统仍需屏幕会话才能接受触控。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Picker("截图对应方向", selection: $model.orientation) {
                            Text("竖屏").tag(0); Text("横屏：主屏幕键 / 充电口在右").tag(1)
                            Text("横屏：主屏幕键 / 充电口在左").tag(2); Text("倒置竖屏").tag(3)
                        }
                        Text("启动前关闭其他镜像或自动化工具。先刷新画面确认方向，再进行触控测试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(model.working || model.running)
                    Section {
                        Button(model.working ? "正在连接…" : "启动 iPad 接收") { model.start() }
                            .disabled(!model.imported || model.working || model.running)
                        if model.working || model.running { Button("停止并松开", role: .destructive) { model.stop() } }
                        if !model.invite.isEmpty {
                            Button("复制连接码到主控") { UIPasteboard.general.string = model.invite }
                            Text("电脑打开 TouchBridge 无线 HID v12，选择主控，粘贴此连接码。只有这次启动的连接码有效。")
                            Text("连接码含控制凭证，请只交给自己的主控设备。局域网实验协议没有传输加密。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("验证方法") {
                        Text("连接后刷新一次画面。在安全位置按住、拖动、松开，观察 iPad 是否立即跟随。可以先用分屏保留本应用，再尝试切到游戏短时测试。后台长期运行和跨城市联网尚未完成。")
                        Text("发送成功只表示 HID 服务收到了消息；实际生效、悬浮提示和触控延迟都以设备实测为准。")
                        Button("复制诊断信息") { UIPasteboard.general.string = "TouchBridge Native 0.1.1 / iPadOS \(UIDevice.current.systemVersion)\n" + model.history.joined(separator: "\n") }
                        ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote) }
                    }
                }
                .navigationTitle("TouchBridge iPad")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.importPair(url) }
                    else if case .failure(let error) = result { model.note("文件选择失败：\(error.localizedDescription)") }
                }
            }
            .onChange(of: phase) { newPhase in
                if newPhase == .background { model.background() }
                else if newPhase == .active { model.foreground() }
            }
        }
    }
}
