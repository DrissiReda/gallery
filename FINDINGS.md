# FINDINGS — iOS AV1 software playback on the Gallery iOS fork

Working notes for the `ovh.redval.gallery` iOS sideload build: what we set out to
do, what actually broke, what we learned, and how the build pipeline works.

Scope: the Flutter app fork (`DrissiReda/gallery`) plus its iOS video plugin fork
(`DrissiReda/native_video_player`), built as an unsigned IPA for TrollStore.

---

## 1. The problem we started from

The server transcodes the library to **AV1** (saving space and GPU), and the iOS
app serves that AV1 straight to the phone. iOS `AVPlayer` has **no software AV1
decoder** — hardware AV1 exists only on A17 Pro / M3 and newer. On the test phone
(iOS 15.4.1) AV1 playback was therefore impossible with the stock player.

Rejected alternatives before writing any code:

| Option | Cost | Verdict |
|---|---|---|
| Re-encode to H.264 for iOS clients | CPU/GPU time across the whole library | rejected — user: too costly |
| MobileVLCKit / VLCKit | 251 MB tarball for 3.7.2; separate `VLCMediaPlayer` view; re-implement all callbacks; lose PiP | rejected |
| media_kit / mpv | full rework of the player | rejected |
| **Ship an AV1 software decoder inside the plugin** | ~3.4 MB of LGPL FFmpeg + dav1d | chosen (already existed) |

**Key correction to the "just reuse VLC" premise:** VLC has no AV1 magic on iOS.
`modules/codec/dav1d.c` is the module (capability 10000); VLC's FFmpeg contrib is
built *without* `--enable-libdav1d`, so libavcodec's `av1` decoder errors out
("Your platform doesn't support hardware accelerated AV1 decoding"), and VLC's own
VideoToolbox module has no AV1 mapping at all. VLC's SW path is
`avformat → dav1d → sws → renderer` — exactly the path already implemented here.
There was nothing to copy except confirmation that the architecture was sane.

---

## 2. How the player is wired

```
Gallery Flutter app (mobile/)
  └─ native_video_player (git dep, branch av1-sw-decode)
       ios/Classes/
         NativeVideoPlayerViewController.swift   AVPlayer path + backend selection
         NativeVideoPlayerView.swift             UIView hosting the layers
         AV1/AV1Capability.swift                 VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
         AV1/AV1SoftwarePlayer.swift             software backend (clock, renderer, audio)
         AV1/GAV1Player.{h,m}                    FFmpeg engine: demux + decode + NV12
         AV1/GAV1FileLog.{h,m}                   on-device log → Documents/av1debug.log
         VideoProxyServer.swift                  localhost HTTP proxy (AVPlayer path only)
```

Selection: on hardware-AV1 devices nothing changes; otherwise the plugin opens the
source with the FFmpeg engine first and only falls back to the untouched `AVPlayer`
path if that fails.

Engine configuration (fixed at build time, vendored as static XCFrameworks):
FFmpeg 7.1.1 built `--disable-gpl --disable-nonfree` with
`--enable-decoder=libdav1d,aac,opus --enable-demuxer=mov,matroska
--enable-protocol=file --disable-network --disable-videotoolbox`, plus dav1d 1.5.4.
LGPL matters because this is a real app, not a personal build.

---

## 3. Defects found and fixed

Ordered as they were found. Each entry lists the symptom, the actual cause, and the
fix that shipped.

### 3.1 Server: `/video/playback` returned 404 (not a decoder problem)

**Symptom:** video "loads indefinitely"; the same file plays perfectly in VLC.

**Evidence:** envoy-gateway access log plus server logs —
`GET /api/assets/310b6b88-…/video/playback → 404`, and
`ENOENT …/upload/encoded-video/…/310b6b88-….mp4 at AssetMediaController.playAssetVideo`.
The server resolves `asset.encodedVideoPath || asset.originalPath` with **no
fallback**, so a row pointing at a deleted file 404s forever.

**Cause:** a manual encoded-video cleanup (Aug 2026) deleted files but left the DB
rows: **34,079 of 35,819 `asset_file` rows of type `encoded_video` pointed at
missing files**.

**Fix:** deleted exactly those rows (existence-checked on disk, in one transaction),
after backing every row up to
`/data/artifacts/immich-stale-encodedvideo-20261005/encoded_video_rows.psv`.
Verified live through the public gateway:
`GET …/video/playback` + `Range: bytes=0-1023` → `HTTP/2 206`,
`content-type: video/quicktime`, `accept-ranges: bytes`,
`content-range: bytes 0-1023/2423451`. 1,740 legitimate encoded rows kept.

**Prevention (not yet applied):** `ffmpeg.transcode=required` with
`acceptedVideoCodecs: [h264, av1]` still encodes any video whose pixel format is not
`420p` (`media.service.js:676-687`), which is why 10-bit AV1 (`yuv420p10le`) got
encoded rows at all. The user does not want H264 re-encodes, so
`ffmpeg.transcode: never` is the intended setting.

### 3.2 Plugin: a user stop was reported as end-of-stream

**Symptom:** every pause emitted `onPlaybackEnded`, and the next `play()` restarted
the video from 0; seeks emitted "ended" too.

**Cause:** `GAV1Player.m` reported `nil` from its completion handler whenever
`-requestStop` had been called, and `nil` meant "clean EOF" to the Swift backend.

**Fix:** a distinct `GAV1ErrorStopped` sentinel (domain `GAV1Player`, code `-1000`);
`AV1SoftwarePlayer` returns early on it — neither "ended" nor "error".

### 3.3 Plugin: decode failures were silently swallowed

**Symptom:** any decode problem became a black picture with no diagnosis, and the UI
sat on a spinner.

**Cause:** `if (avcodec_send_packet(...) >= 0)` with no else; `receive_frame` and
`sws_scale` return values ignored; `onPlaybackReady` fired before a single frame
existed.

**Fix:** failures are logged (`GAV1FileLog`, with `av_err2str`), and a run that ends
with zero frames reports `code -5 "decoder produced no frames (N decoder failures)"`
so the host receives `onError`.

### 3.4 App: spinner and seek bar driven by a guess, not by the player

**Symptom (after decode worked):** a spinner sat permanently over a playing video,
the seek bar stayed at 00:00, scrubbing did nothing.

**Cause:** the host has **no buffering callback**. It arms a 1-second timer
(`video_player_provider.dart:257 _startBufferingTimer`) and the *only* thing that
clears buffering is a **changed** `onPlaybackPositionChanged` tick
(`:218-224`); a tick equal to the current position is discarded (`:214`), and ticks
are ignored while a 150 ms seek timer is active (`:204`). The `AVPlayer` backend
emits that tick from a periodic time observer; the software backend emitted nothing
at all.

**Fix, in three steps:**
1. The software backend reports position at 4 Hz, deduped, re-armed on every path
   that can leave playback running (play, loop restart, seek completion, load,
   teardown).
2. Position comes from the **presentation time of the last frame that actually
   reached the display layer**, not from the host-clock timebase — the clock keeps
   advancing while a starved decoder produces no picture, which made a real stall
   look like smooth progress (moving seek bar, no spinner). Stall signalling then
   falls out for free: no frames, no ticks, and the host shows its buffering state.
3. A real buffering signal was added end to end (`onPlaybackBuffering`): `AVPlayer`
   reports `timeControlStatus == .waitingToPlayAtSpecifiedRate`, the software
   backend reports frame starvation. The app binds the spinner to it and keeps the
   1-second timeout only as a fallback.

### 3.5 App: seeks landed on the keyframe *before* the target

**Cause:** `avformat_seek_file(..., AVSEEK_FLAG_BACKWARD)` lands on a keyframe at or
before the requested time, and nothing discarded the frames in between, so the seek
bar walked backwards by up to a GOP (server `gopSize: 0` falls back to 256 frames
≈ 8.5 s).

**Fix:** frames below the seek target are dropped before they reach the display
layer — an accurate seek. Note the tempting alternative (clamp the reported position
to the target instead) is *worse*: frames between keyframe and target still play, so
the host sees a frozen position for seconds and shows a false spinner.

### 3.6 Plugin: a lifecycle race that killed playback

**Symptom:** rapid pause → play left a frozen frame with a running clock.

**Cause:** a pause/seek arriving while a decode was already winding down made
`startPump` see `pumping == true` and only move the clock; the decode then returned
"stopped" and nothing restarted. Also `displayLayerFailed` may be delivered on the
enqueue queue, where invalidating a main-run-loop `Timer` is undefined.

**Fix:** the pump completion restarts playback when the user still wants it
(`rate != 0 && !atEOF`), and the layer-failure handler hops to main first.

---

## 4. Reverted, and why

**Reverted: "resend the AV1 sequence header after flush" (`901d834`, undone in
`eaa3cb4`).**

The theory was sound in the abstract — `avcodec_flush_buffers()` makes dav1d drop its
sequence header, and dav1d then rejects every packet until a new one arrives
in-band, so seeking should produce zero frames. It was *proven* only on a synthetic
copy of a test file whose sequence-header OBU had been rewritten by hand. Real
output from our own compression pipeline repeats the header in every keyframe, and
playback demonstrably worked before the injection landed. Prepending `av1C`
configOBUs to a keyframe that already carries the header risks the decoder rejecting
the very first packet — exactly the "nothing plays at all" symptom seen in
`unsigned5`.105 lines of scanner/injection code plus its test were deleted rather
than kept "just in case".

**Kept from that commit:** the stop/EOF sentinel and decode-failure reporting.

---

## 5. Hurdles that cost the most time

### 5.1 Four builds that changed nothing (`pubspec.lock`)

`pubspec.yaml` asks for the plugin by **branch ref** (`av1-sw-decode`), but
`mobile/pubspec.lock` carries a `resolved-ref` SHA and `pub` honours the lock for git
dependencies. CI kept compiling the September plugin (`788f5bc`) for
`unsigned1`–`unsigned4` — four 15-minute builds, four identical binaries on the
device, and a whole round of "the fix didn't work" misdirected at the decoder.

**Rule:** after every plugin push, bump the lock:

```bash
NEW=$(git ls-remote git@github.com:DrissiReda/native_video_player.git refs/heads/av1-sw-decode | cut -f1)
# mobile/pubspec.lock → native_video_player.description.resolved-ref = $NEW
```

Symptom to recognise: "the new build behaves exactly like the old one".

### 5.2 No way to see inside the phone

The host has no Mac and the phone is not attached over USB, so `NSLog` is invisible.
The native side therefore writes `Documents/av1debug.log`, but extracting it through
the Files app was never done. After several blind iterations the log was rendered
**on screen** over the video (tail, refreshed every 3 s), next to a compact readout:
`pos=… ticks=… last=… age=…ms buf=… st=… dur=… err=…`.

That readout exists because position ticks are the app's *only* signal for both the
seek bar and buffering. Seeing them removes all inference.

### 5.3 Guessing instead of measuring

Three fixes in a row were plausible and unverified. Two independent review passes
(a review subagent per patch) caught real bugs before they ever reached a device:
loop restarts bypassing `play()` and silently killing the position timer, the seek
bar stepping backwards on resume, stall-gate holes, and the seek-floor issue.
Lesson kept: for anything touching playback state, get review *and* on-device
evidence, in that order.

### 5.4 The IPA build is the only compiler

No local `flutter`/`dart`, so every Dart or Swift mistake costs a ~15-minute CI
cycle. Errors caught this way: `onPlaybackBuffering` missing (lock file), and
`PlaybackInfo` being nullable in the plugin's Dart API. Two Dart mistakes of my own:
`const Utf8Decoder(...)` and `const Stream<void>.periodic(...)` are not const
constructors.

### 5.5 Server evidence beats client speculation

The decisive clue for §3.1 was not in the app at all: envoy-gateway's JSON access log
plus the server's `ENOENT` identified a 404 that no amount of client work could fix.
The phone is identifiable only by User-Agent (`immich-ios/5.6.0`,
`AppleCoreMedia/…iPhone OS 15_4_1`, `noodle-gallery/1 CFNetwork`) because the
MikroTik hairpin NAT hides the real client IP.

---

## 6. Lessons worth keeping

1. **A spinner is a protocol, not a decoration.** With no buffering callback, the app
   inferred buffering from absent position ticks. Any native backend added to this
   plugin must emit `onPlaybackPositionChanged`, or the UI invents a fault.
2. **Report what is true, not what is convenient.** The host-clock timebase looked
   like progress while the picture was frozen. Presented-frame progress cannot lie.
3. **Silence is a valid signal.** "No tick" is how the host detects buffering; a
   backend that keeps ticking through a stall destroys that signal.
4. **Check that the artifact contains the fix** before theorising about the device.
   A stale lock file made four correct fixes look like no-ops.
5. **Prove a theory on real content.** The sequence-header bug reproduced only in a
   hand-patched file; acting on it broke playback for real files.
6. **`AV_PKT_FLAG`/OBU bit layout is easy to get wrong.** First attempt masked
   `obu_forbidden_bit` as `0x02`; it is `0x80` (`0x02` is `obu_has_size_field`). Every
   real sequence header starts with `0x0a`, so the wrong mask made the scan silently
   return "not found" — caught only by a host-side unit test.
7. **Server-side data integrity is part of playback.** 95 % of encoded-video rows
   were dangling; deleting files without deleting rows turns into permanent 404s for
   clients.
8. **zsh aborts a command substitution on a failed glob**, which silently turned a
   "next free number" computation into `1` — overwriting a file. Use `find`, not globs,
   in runbooks.
9. **Push over SSH.** Both repos cloned with HTTPS URLs could not push
   (`could not read Username`); `git remote set-url origin git@github.com:…` fixed it.

---

## 7. How the IPA is built, and why

### Why a workflow instead of a local build

The host is Linux/AMD EPYC with no macOS, no Xcode and no signing identities. iOS
builds need macOS. GitHub Actions' `macos-15` runners provide it, so the unsigned
IPA is produced in CI and the artifact is downloaded here. No Apple certificates are
needed: the app is sideloaded with **TrollStore**, which re-signs on install.

### The workflow

`.github/workflows/build-unsigned-ipa.yml` (branch `release/v5.6.0-ipa`), triggered
manually (`workflow_dispatch`) with inputs `ref`, `version`, `build_mode`.

Steps and why each exists:

| Step | Why |
|---|---|
| Select newest Xcode | runner default may not be the one the pinned Flutter expects |
| Checkout `inputs.ref` | build a specific branch/tag without changing the default branch |
| `apply-branding` action | fork branding + version stamping; without it the app keeps Flutter's placeholder version and the server rejects it as incompatible |
| Java 17, `use-mise` | repo pins Flutter/pnpm/node/openapi-generator in `mise.toml` |
| `flutter config --no-enable-swift-package-manager` | CocoaPods must stay in charge of plugin integration on this project |
| `ruby/setup-ruby` + `bundler-cache` in `mobile/ios` | CocoaPods |
| `mise //mobile:install:ci` | dependencies from the lock file |
| codegen: `open-api-dart`, `codegen:dart`, `codegen:pigeon`, `codegen:translation`, `drift:migration` | every generator explicitly — on this branch `mise //mobile:codegen` is only an alias for `codegen:dart`, so `translations.g.dart` would be missing |
| `pod install` | plugin + vendored XCFrameworks |
| `xcodebuild -showBuildSettings` (dump) | makes the version chain visible in the log |
| `flutter build ipa --no-codesign --release` | `--no-codesign` stops after the `.xcarchive`; Flutter skips IPA packaging because the export step wants a provisioning profile |
| manual packaging | an IPA is a zip with `Payload/<App>.app` at the root; the workflow zips it by hand and logs bundle id, min OS and Mach-O header |
| `actions/upload-artifact` (`unsigned-ios-ipa`) | 30-day retention |

### Dispatch — the part that bites

```bash
gh workflow run build-unsigned-ipa.yml -R DrissiReda/gallery \
  --ref release/v5.6.0-ipa \
  -f ref=release/v5.6.0-ipa -f version=v5.6.0 -f build_mode=release
```

`gh workflow run` resolves the workflow **file from the default branch**. `main`'s
copy only runs `mise //mobile:codegen`, so without `--ref` the build dies in "Build
unsigned archive" with `Error when reading 'lib/generated/translations.g.dart'`.
`--ref` picks the branch's workflow definition; `-f ref=` picks what to build.
`version` must equal the **server** version: a newer app than server crashes at SSO
because the DTO carries fields (`clusterGroupId`) the older server omits.

### Fetching and publishing

```bash
gh run watch -R DrissiReda/gallery
gh run download -R DrissiReda/gallery -n unsigned-ios-ipa -D /tmp/ipa-dl
n=$(find /data/filebrowser/files/admin -maxdepth 1 -name 'NoodleGallery-unsigned*.ipa' \
      -printf '%f\n' 2>/dev/null | sed -E 's/[^0-9]//g' | sort -n | tail -1)
n=$(( ${n:-0} + 1 ))
install -m 0666 /tmp/ipa-dl/unsigned-gallery.ipa \
  "/data/filebrowser/files/admin/NoodleGallery-unsigned${n}.ipa"
```

`find`, not a glob: zsh aborts a command substitution when a glob matches nothing,
which silently yields `n=1` and overwrites an existing file. Delivery path is the
filebrowser `admin` share, which is how the IPA reaches the phone.

---

## 8. Repository and branch map

| Thing | Where |
|---|---|
| App fork | `~/apps/custom/gallery`, `DrissiReda/gallery` @ `release/v5.6.0-ipa` |
| Plugin fork | `~/apps/forks/native_video_player`, `DrissiReda/native_video_player` @ `av1-sw-decode` (pinned by ref in `mobile/pubspec.yaml`) |
| IPA workflow | `.github/workflows/build-unsigned-ipa.yml` |
| Delivered IPAs | `/data/filebrowser/files/admin/NoodleGallery-unsigned<N>.ipa` |
| Backup of deleted DB rows | `/data/artifacts/immich-stale-encodedvideo-20261005/` |
| On-device log | app `Documents/av1debug.log` (now also rendered on screen) |

Related branches: `release/v5.6.0-stockplayer` (AVPlayer only, for comparison),
`ci/unsigned-ipa` (workflow default branch).

## 9. Open items

1. **Verify the current build on the device** — with the on-screen log, playback and
   tick behaviour can be judged from evidence.
2. Remove the debug overlays (log tail + readout) once playback is confirmed.
3. Apply `ffmpeg.transcode: never` to stop new H264 encodes for 10-bit AV1.
4. Client-side robustness: on a 404 from `/video/playback`, retry `/original`
   (Range-capable), and stop the silent `AVPlayer` fallback so failures surface as
   errors instead of spinners.
5. Known remaining races in the software backend: `displayLayer.flush()` from main
   versus enqueue on the enqueue queue; `close()` after a 2 s deadline can free the
   decoder while a network read is parked; no colour attachments on the pixel
   buffers (wrong colours, not black); FFmpeg XCFrameworks have no simulator slice.
6. `hwdec`-free 4K60 is too slow on A12–A15; cap software playback resolution if that
   matters.