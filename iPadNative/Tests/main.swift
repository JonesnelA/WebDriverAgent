import Foundation

// Transport-only fixture: never injects input, never connects to a real device.
final class NativeEngine {
    func touch(phase: UInt32, x: Double = 0, y: Double = 0, orientation: UInt32,
               completion: @escaping (Bool, Double, String) -> Void) { completion(true, 0, "") }
    func screenshot(completion: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now()+1) { completion(["image": "", "width": 1, "height": 1]) }
    }
    func close(completion: @escaping () -> Void) { completion() }
}
let server = LANServer(engine: NativeEngine(), orientation: 1)
server.start(ip: "127.0.0.1") { code, error in
    if let error = error { fputs(error, stderr); exit(1) }
    print(code!); fflush(stdout)
}
dispatchMain()
