import Foundation
import UIKit

/// Two queues keep screenshot work out of the input path. Close waits for both.
final class NativeEngine {
    private let input = DispatchQueue(label: "touchbridge.input", qos: .userInteractive)
    private let capture = DispatchQueue(label: "touchbridge.capture", qos: .utility)
    private var handle: OpaquePointer?
    static func lastError() -> String {
        guard let value = tb_last_error() else { return "开发服务未响应" }
        defer { tb_string_free(value) }
        return String(cString: value)
    }
    func open(path: String, media: Bool, completion: @escaping (String?) -> Void) {
        input.async {
            let pointer = path.withCString { tb_open($0, media ? 1 : 0) }
            self.capture.sync { self.handle = pointer }
            let error = pointer == nil ? Self.lastError() : nil
            DispatchQueue.main.async { completion(error) }
        }
    }
    func touch(phase: UInt32, x: Double = 0, y: Double = 0, orientation: UInt32,
               completion: @escaping (Bool, Double, String) -> Void) {
        input.async {
            let start = ProcessInfo.processInfo.systemUptime
            let result = tb_touch(self.handle, phase, x, y, orientation)
            let error = result == 0 ? "" : Self.lastError()
            completion(result == 0, (ProcessInfo.processInfo.systemUptime-start)*1000, error)
        }
    }
    func screenshot(completion: @escaping ([String: Any]) -> Void) {
        capture.async {
            let start = ProcessInfo.processInfo.systemUptime
            var length = 0
            guard let bytes = tb_screenshot(self.handle, &length) else {
                completion(["error": Self.lastError()]); return
            }
            let data = Data(bytes: bytes, count: length)
            tb_data_free(bytes, length)
            let captured = ProcessInfo.processInfo.systemUptime
            guard let image = UIImage(data: data) else { completion(["error": "截图格式无效"]); return }
            let scale = min(1, 960/max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width*scale).rounded(), height: (image.size.height*scale).rounded())
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = resized.jpegData(compressionQuality: 0.55) else { completion(["error": "截图压缩失败"]); return }
            completion(["image": jpeg.base64EncodedString(), "format": "jpeg", "width": Int(size.width),
                        "height": Int(size.height), "source_bytes": length, "capture_ms": (captured-start)*1000,
                        "encode_ms": (ProcessInfo.processInfo.systemUptime-captured)*1000])
        }
    }
    func close(completion: @escaping () -> Void) {
        input.async {
            self.capture.sync { if let h = self.handle { tb_close(h) }; self.handle = nil }
            DispatchQueue.main.async { completion() }
        }
    }
}
