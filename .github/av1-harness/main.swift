import AVFoundation
import Foundation

final class StubMessenger: NSObject, FlutterBinaryMessenger {}

var failures = 0

func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func waitFor(_ body: (@escaping () -> Void) -> Void, _ label: String) {
    var done = false
    body { done = true }
    let end = Date().addingTimeInterval(10)
    while !done && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if !done { print("FAIL \(label) completion timeout"); failures += 1 }
}

func expectAdvancing(_ player: AV1SoftwarePlayer, from minimum: Int64, _ label: String) {
    var samples: [Int64] = []
    for _ in 0..<8 {
        spin(0.5)
        samples.append(lastEventPosition)
    }
    print("INFO \(label) positions=\(samples) playing=\(player.isPlaying())")
    let advanced = samples.last! - samples.first! >= 2500
    if !advanced || samples.first! < minimum {
        print("FAIL \(label)")
        failures += 1
    } else {
        print("PASS \(label)")
    }
}

let api = NativeVideoPlayerApi(messenger: StubMessenger(), viewId: 1)
let player = AV1SoftwarePlayer(api: api)
let source = VideoSource(from: ["path": CommandLine.arguments[1], "type": "network", "headers": [String: String]()])!
guard player.tryOpen(source) else { print("FAIL tryOpen"); exit(1) }
api.delegate = player
player.loadVideoSource(videoSource: source)
player.play()
player.setPlaybackSpeed(speed: 1)
expectAdvancing(player, from: 0, "initial play")

// Gallery scrub: hold (pause), debounced seeks during drag, flush seek on release, play.
player.pause()
spin(0.3)
for target in [6000, 9000, 12000] as [Int64] {
    player.seekTo(position: target) {}
    spin(0.15)
}
waitFor({ player.seekTo(position: 13000, completion: $0) }, "release seek")
player.play()
player.setPlaybackSpeed(speed: 1)
expectAdvancing(player, from: 10000, "scrub while playing")

// Seek while playing, no pause.
waitFor({ player.seekTo(position: 2000, completion: $0) }, "plain seek")
expectAdvancing(player, from: 0, "plain seek")

// Paused seek, wait, then play.
player.pause()
spin(0.3)
waitFor({ player.seekTo(position: 11000, completion: $0) }, "paused seek")
spin(1)
print("INFO paused-seek position=\(player.getPlaybackPosition())")
player.play()
player.setPlaybackSpeed(speed: 1)
expectAdvancing(player, from: 9000, "paused seek then play")

// Pause and resume.
player.pause()
let paused = player.getPlaybackPosition()
spin(1)
print("INFO paused hold \(paused) -> \(player.getPlaybackPosition())")
player.play()
expectAdvancing(player, from: paused - 100, "resume")

player.invalidate()
print(failures == 0 ? "RESULT PASS" : "RESULT FAIL \(failures)")
exit(failures == 0 ? 0 : 1)
