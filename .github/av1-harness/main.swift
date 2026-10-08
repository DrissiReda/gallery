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

func dump(_ player: AV1SoftwarePlayer, _ label: String) {
    print("DBG \(label) primed=\(player.clockPrimed) pumping=\(player.pumping) stop=\(player.engine.stop) rate=\(player.rate) tbRate=\(CMTimebaseGetRate(player.videoTimebase)) tb=\(CMTimebaseGetTime(player.videoTimebase).seconds) vReady=\(player.displayLayer.isReadyForMoreMediaData) aReady=\(player.audioRenderer.isReadyForMoreMediaData)")
}

func expectAdvancing(_ player: AV1SoftwarePlayer, from minimum: Int64, _ label: String) {
    var samples: [Int64] = []
    for _ in 0..<8 {
        spin(0.5)
        samples.append(player.getPlaybackPosition())
        dump(player, label)
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
let source = VideoSource(from: ["path": CommandLine.arguments[1], "type": "file", "headers": [String: String]()])!
guard let player = AV1SoftwarePlayer(api: api, videoSource: source) else { print("FAIL open"); exit(1) }
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
expectAdvancing(player, from: 12900, "scrub while playing")

// Seek while playing, no pause.
waitFor({ player.seekTo(position: 2000, completion: $0) }, "plain seek")
expectAdvancing(player, from: 1900, "plain seek")

// Paused seek, wait, then play.
player.pause()
spin(0.3)
waitFor({ player.seekTo(position: 11000, completion: $0) }, "paused seek")
spin(1)
print("INFO paused-seek position=\(player.getPlaybackPosition())")
player.play()
player.setPlaybackSpeed(speed: 1)
expectAdvancing(player, from: 10900, "paused seek then play")

// Pause and resume.
player.pause()
let paused = player.getPlaybackPosition()
spin(1)
print("INFO paused hold \(paused) -> \(player.getPlaybackPosition())")
player.play()
expectAdvancing(player, from: paused - 100, "resume")

// Play to the end, then play again restarts from the beginning.
waitFor({ player.seekTo(position: 18500, completion: $0) }, "end seek")
spin(3)
player.play()
expectAdvancing(player, from: 0, "replay after end")

// Video without audio.
let silentSource = VideoSource(from: ["path": CommandLine.arguments[2], "type": "file", "headers": [String: String]()])!
let silentApi = NativeVideoPlayerApi(messenger: StubMessenger(), viewId: 2)
guard let silent = AV1SoftwarePlayer(api: silentApi, videoSource: silentSource) else { print("FAIL open silent"); exit(1) }
silentApi.delegate = silent
silent.loadVideoSource(videoSource: silentSource)
silent.play()
expectAdvancing(silent, from: 0, "no audio")
print(failures == 0 ? "RESULT PASS" : "RESULT FAIL \(failures)")
exit(failures == 0 ? 0 : 1)
