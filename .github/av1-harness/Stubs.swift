import Foundation

typealias FlutterResult = (Any?) -> Void

struct FlutterError: Error {
    let code: String
    let message: String?
    let details: Any?
}

struct FlutterMethodCall {
    let method: String
    let arguments: Any?
}

protocol FlutterBinaryMessenger {}

var lastEventPosition: Int64 = -1

class FlutterMethodChannel {
    init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
    func setMethodCallHandler(_ handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {}
    func invokeMethod(_ method: String, arguments: Any?) {
        if method == "onPlaybackPositionChanged", let p = arguments as? Int64 {
            lastEventPosition = p
        } else {
            print("EVENT \(method) \(arguments ?? "")")
        }
    }
}

let FlutterMethodNotImplemented: Any? = nil

enum SwiftNativeVideoPlayerPlugin {
    static var cookieStorage: HTTPCookieStorage?
}
