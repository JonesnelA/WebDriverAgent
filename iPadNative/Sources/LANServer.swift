import Foundation
import Network
import CryptoKit
import Security
import Darwin

func randomHex() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return bytes.map { String(format: "%02x", $0) }.joined()
}
func lanAddress() -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return nil }
    defer { freeifaddrs(first) }
    var item = first
    while let entry = item {
        defer { item = entry.pointee.ifa_next }
        guard String(cString: entry.pointee.ifa_name) == "en0", let address = entry.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: buffer)
        }
    }
    return nil
}
private final class Peer {
    let socket: NWConnection
    let nonce = randomHex()
    var buffer = Data()
    var channel: String?
    var pending = 0
    init(_ socket: NWConnection) { self.socket = socket }
    func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 8*1024*1024 else { return }
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4); packet.append(data)
        socket.send(content: packet, completion: .contentProcessed { _ in })
    }
}

/// The same framed JSON, HMAC challenge and invitation format as the Windows v12 client.
final class LANServer {
    private let queue = DispatchQueue(label: "touchbridge.network", qos: .userInteractive)
    private var listener: NWListener?
    private var peers: [Peer] = []
    private var controller: Peer?
    private var media: Peer?
    private var mediaKey = randomHex()
    private var watchdog: DispatchSourceTimer?
    private var gesture: String?
    private var sequence = -1
    private var lastSeen = 0.0
    private var takingFrame = false
    private let engine: NativeEngine
    private let orientation: UInt32
    private let key = randomHex()
    var report: ((String) -> Void)?
    init(engine: NativeEngine, orientation: UInt32) { self.engine = engine; self.orientation = orientation }
    func start(ip: String, completion: @escaping (String?, String?) -> Void) {
        queue.async {
            do {
                // Small touch acknowledgements and consecutive probes must not wait
                // behind an unacknowledged packet for Nagle/delayed-ACK coalescing.
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: 8798)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] socket in self?.accept(socket) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        let invite: [String: Any] = ["format": "TouchBridge/1", "hosts": [ip], "port": 8798,
                            "key": self.key, "network": "lan", "share_url": ""]
                        let data = try! JSONSerialization.data(withJSONObject: invite)
                        let code = "TB1-" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                        DispatchQueue.main.async { completion(code, nil) }
                    case .failed(let error): DispatchQueue.main.async { completion(nil, "局域网监听失败：\(error.localizedDescription)") }
                    default: break
                    }
                }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now()+0.25, repeating: 0.25)
                timer.setEventHandler { [weak self] in
                    guard let self = self, let id = self.gesture,
                          ProcessInfo.processInfo.systemUptime-self.lastSeen > 3 else { return }
                    self.cancelContact()
                    self.controller?.send(["type": "touch_result", "phase": "cancel", "gesture_id": id,
                                           "ok": false, "error": "按住续期超时，已尝试松开"])
                }
                self.watchdog = timer; timer.resume()
            } catch { DispatchQueue.main.async { completion(nil, error.localizedDescription) } }
        }
    }
    private func log(_ text: String) { DispatchQueue.main.async { self.report?(text) } }
    private func accept(_ socket: NWConnection) {
        guard peers.count < 4 else { socket.cancel(); return }
        let peer = Peer(socket); peers.append(peer)
        socket.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self = self, let peer = peer else { return }
            switch state {
            case .ready: peer.send(["type": "auth_challenge", "nonce": peer.nonce]); self.receive(peer)
            case .failed, .cancelled: self.remove(peer)
            default: break
            }
        }
        socket.start(queue: queue)
        queue.asyncAfter(deadline: .now()+10) { [weak peer] in if peer?.channel == nil { peer?.socket.cancel() } }
    }
    private func remove(_ peer: Peer) {
        if controller === peer {
            cancelContact(); controller = nil; media?.socket.cancel(); media = nil
            log("主控已断开，已尝试松开触控")
        }
        if media === peer { media = nil }
        peers.removeAll { $0 === peer }
    }
    private func receive(_ peer: Peer) {
        peer.socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, ended, error in
            guard let self = self, let peer = peer else { return }
            if let data = data { peer.buffer.append(data) }
            while peer.buffer.count >= 4 {
                let length = peer.buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= 65536 else { peer.socket.cancel(); return }
                if peer.buffer.count < length+4 { break }
                let start = peer.buffer.index(peer.buffer.startIndex, offsetBy: 4)
                let end = peer.buffer.index(start, offsetBy: length)
                let body = Data(peer.buffer[start..<end])
                // Data.removeFirst can retain a nonzero startIndex. Normalize the next frame.
                peer.buffer = Data(peer.buffer.dropFirst(4+length))
                guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { peer.socket.cancel(); return }
                self.handle(message, peer)
            }
            if ended || error != nil { self.remove(peer); peer.socket.cancel() }
            else { self.receive(peer) }
        }
    }
    private func authenticated(_ message: [String: Any], _ peer: Peer) -> Bool {
        guard message["type"] as? String == "hello", message["role"] as? String == "controller",
              let name = message["name"] as? String, name.count <= 100,
              let proof = message["proof"] as? String, proof.count == 64 else { return false }
        var bytes = [UInt8](); var index = proof.startIndex
        for _ in 0..<32 {
            let end = proof.index(index, offsetBy: 2)
            guard let value = UInt8(proof[index..<end], radix: 16) else { return false }
            bytes.append(value); index = end
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data("\(peer.nonce)|controller|\(name)".utf8), using: SymmetricKey(data: Data(key.utf8)))
    }
    private func handle(_ message: [String: Any], _ peer: Peer) {
        if peer.channel == nil {
            guard authenticated(message, peer) else { peer.socket.cancel(); return }
            if message["channel"] as? String == "media" {
                guard controller != nil, media == nil, message["parent_id"] as? Int == 1,
                      message["media_key"] as? String == mediaKey else { peer.socket.cancel(); return }
                media = peer; peer.channel = "media"; peer.send(["type": "welcome", "channel": "media"])
            } else {
                guard controller == nil else { peer.socket.cancel(); return }
                controller = peer; peer.channel = "control"; mediaKey = randomHex()
                peer.send(["type": "welcome", "port": 8798, "client_id": 1, "media_key": mediaKey,
                           "features": ["touch_events", "media_channel", "latency_probe"],
                           "peers": [["name": "纯 iPad 实验端", "role": "target", "addr": "on-device", "features": ["touch_events"]]]])
                log("主控已认证；触控在 iPad 内执行")
            }
            return
        }
        guard peer === controller else { return }
        switch message["type"] as? String {
        case "ping": peer.send(["type": "pong", "sent_at": message["sent_at"] ?? NSNull()])
        case "latency_probe": peer.send(["type": "latency_result", "sent_at": message["sent_at"] ?? NSNull(), "probe_id": message["probe_id"] ?? NSNull()])
        case "touch": touch(message, peer)
        case "frame_request": frame(message, peer)
        case "tap": peer.send(["type": "tap_result", "ok": false, "sent_at": message["sent_at"] ?? NSNull(), "error": "请使用 v12 主控的按下/松开模式"])
        default: break
        }
    }
    private func result(_ message: [String: Any], ok: Bool, ms: Double = 0, error: String = "") -> [String: Any] {
        return ["type": "touch_result", "phase": message["phase"] ?? "", "gesture_id": message["gesture_id"] ?? "",
                "sent_at": message["sent_at"] ?? NSNull(), "ok": ok, "send_ms": ms, "exec_ms": ms,
                "channel": "hid", "verified": false, "error": error]
    }
    private func touch(_ message: [String: Any], _ peer: Peer) {
        func reject(_ text: String) { peer.send(result(message, ok: false, error: text)) }
        guard let phase = message["phase"] as? String, let id = message["gesture_id"] as? String,
              !id.isEmpty, id.utf8.count <= 64, let seq = message["seq"] as? Int, seq >= 0 else { reject("无效触控事件"); return }
        var x = 0.0, y = 0.0
        if ["down", "move", "up"].contains(phase) {
            guard let px = message["x"] as? Double, let py = message["y"] as? Double,
                  px.isFinite, py.isFinite, px >= 0, px < 1, py >= 0, py < 1 else { reject("坐标超出画面"); return }
            x = px; y = py
        }
        if phase == "down" {
            guard gesture == nil else { reject("已有触控未松开"); return }
            gesture = id; sequence = seq
        } else {
            guard ["move", "up", "cancel", "hold"].contains(phase), gesture == id, seq > sequence else { reject("过期事件或触控所有者不匹配"); return }
            sequence = seq
        }
        lastSeen = ProcessInfo.processInfo.systemUptime
        if phase == "hold" { peer.send(result(message, ok: true)); return }
        if phase == "up" || phase == "cancel" { gesture = nil }
        guard peer.pending < 128 else { cancelContact(); reject("触控积压，已尝试松开"); peer.socket.cancel(); return }
        peer.pending += 1
        let number: UInt32 = phase == "down" ? 0 : phase == "move" ? 1 : phase == "up" ? 2 : 3
        engine.touch(phase: number, x: x, y: y, orientation: orientation) { [weak self, weak peer] ok, ms, error in
            guard let self = self, let peer = peer else { return }
            self.queue.async {
                peer.pending -= 1
                guard self.controller === peer else { return }
                if !ok && self.gesture == id { self.cancelContact() }
                peer.send(self.result(message, ok: ok, ms: ms, error: error))
                if !ok { self.log(error) }
            }
        }
    }
    private func cancelContact() {
        gesture = nil; sequence = -1
        engine.touch(phase: 3, orientation: orientation) { _, _, _ in }
    }
    private func frame(_ message: [String: Any], _ peer: Peer) {
        guard let channel = media else { peer.send(["type": "frame", "sent_at": message["sent_at"] ?? NSNull(), "error": "独立画面连接尚未就绪，请稍后刷新"]); return }
        guard !takingFrame else { channel.send(["type": "frame", "sent_at": message["sent_at"] ?? NSNull(), "error": "上一张截图尚未完成"]); return }
        takingFrame = true
        engine.screenshot { [weak self, weak peer, weak channel] fields in
            guard let self = self else { return }
            self.queue.async {
                self.takingFrame = false
                guard let peer = peer, let channel = channel, self.controller === peer, self.media === channel else { return }
                var response = fields; response["type"] = "frame"; response["sent_at"] = message["sent_at"] ?? NSNull()
                channel.send(response)
            }
        }
    }
    func stop(completion: @escaping () -> Void) {
        queue.async {
            self.watchdog?.cancel(); self.watchdog = nil; self.listener?.cancel(); self.listener = nil
            self.cancelContact(); for peer in self.peers { peer.socket.cancel() }
            self.peers = []; self.controller = nil; self.media = nil
            self.engine.close(completion: completion)
        }
    }
}
