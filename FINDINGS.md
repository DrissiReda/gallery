# FINDINGS — iOS AV1 software playback on the Gallery iOS fork

Working notes for the `ovh.redval.gallery` iOS sideload build: what we set out to
do, what actually broke, what we learned, and how the build pipeline works.

Scope: the Flutter app fork (`DrissiReda/gallery`) plus its iOS video plugin fork
(`DrissiReda/native_video_player`), built as an unsigned IPA for TrollStore.

## Current status — 2026-10-07

- AV1 decode, hardware selection, native-layer routing, and software position ticks
  live in `native_video_player`. Gallery's `video_viewer.widget.dart` and
  `video_player_provider.dart` match v5.6.0; no AV1 player/UI logic was added there.
- Gallery's existing `AppDelegate` already hands `URLSessionManager.cookieStorage`
  to the plugin. The plugin reuses that hook for authenticated network AV1.
- Plugin package minimum remains **iOS 9**. Software AV1 runs on **iOS 11+** because
  AVSampleBuffer audio/synchronizer and VideoToolbox APIs require iOS 11; iOS 9–10
  continue through AVPlayer.
- Current Gallery test pin: `pubspec.yaml` ref `av1-sw-decode-pr`, lock SHA
  `7d786355757234fed836d9387fa2902a357adeba`.
- `unsigned9` used plugin `788f5bc`; user confirmed it worked. `unsigned10` played and
  scrubbed but kept the spinner: Gallery's 1 s buffering timeout resets only on
  changed position callbacks, and software AV1 emitted none. Plugin commit `7d78635`
  adds a deduplicated 4 Hz software-clock poll in the iOS controller. It does not
  alter decoding or teardown. `unsigned11` contains this fix:
  `/data/filebrowser/files/admin/NoodleGallery-unsigned11.ipa`, 33,827,913 bytes,
  SHA256 `70df3997edef9582c2285889c7fe417a4e4c484b4c1a40a51a36a61117f1d57e`, built
  in Gallery CI run `37633392089`. Plugin engine/typecheck CI `37632870181` passed;
  unsigned11 device confirmation still pending.
- No production AV1 file logger or Gallery debug overlay remains. Gallery's player
  widget/provider are unchanged; only its test dependency pin differs.
- Draft plugin PRs #19 and #20 were closed at user's request; no PR currently open.
  Their packaging experiments and the external dependency asset are recorded in §10.

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
  └─ native_video_player (test git dep, branch av1-sw-decode-pr)
       ios/Classes/
          NativeVideoPlayerViewController.swift   AVPlayer path + backend selection
          NativeVideoPlayerView.swift             UIView hosting the layers
          AV1/AV1Capability.swift                 VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
          AV1/AV1SoftwarePlayer.swift             software backend (clock, renderer, audio)
          AV1/GAV1Player.{h,m}                    FFmpeg engine: demux + decode + NV12
          Plugin/SwiftNativeVideoPlayerPlugin.swift cookie-store bridge
          VideoProxyServer.swift                  localhost HTTP proxy (AVPlayer path only)
```

Selection: iOS 11+ hardware-AV1 devices stay on AVPlayer. Otherwise the plugin probes
off-main-thread; successfully opened AV1 uses the software backend, while non-AV1 and
open failures fall back to AVPlayer. iOS 9–10 always use AVPlayer.

Engine configuration (fixed at build time, vendored as static XCFrameworks):
FFmpeg 7.1.1 built `--disable-gpl --disable-nonfree` with
`--enable-decoder=libdav1d,aac,opus --enable-demuxer=mov,matroska
--enable-protocol=file --disable-network --disable-videotoolbox`, plus dav1d 1.5.4.
LGPL matters because this is a real app, not a personal build.

---

## 3. Defects found and fixed

Chronological findings. Some remedies below were later reverted; §3.6 and §10
describe the current implementation.

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

### 3.2 Plugin experiment: stop-as-EOF (not in current tree)

**Symptom:** every pause emitted `onPlaybackEnded`, and the next `play()` restarted
the video from 0; seeks emitted "ended" too.

**Cause:** `GAV1Player.m` reported `nil` from its completion handler whenever
`-requestStop` had been called, and `nil` meant "clean EOF" to the Swift backend.

**Attempted fix:** a distinct `GAV1ErrorStopped` sentinel (domain `GAV1Player`, code
`-1000`). It appeared in an intermediate commit but is absent from the current
plugin source restored to the last playback-good baseline.

### 3.3 Plugin experiment: verbose decode diagnostics (removed)

**Symptom:** any decode problem became a black picture with no diagnosis, and the UI
sat on a spinner.

**Cause:** `if (avcodec_send_packet(...) >= 0)` with no else; `receive_frame` and
`sws_scale` return values ignored; `onPlaybackReady` fired before a single frame
existed.

**Attempted fix:** temporary file logging, decoder counters, and a zero-frame error.
The file logger wrote media URLs/paths to `Documents/av1debug.log`; it was removed
from the PR candidate. Normal error callbacks remain; diagnostic file logging does not.

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

**Current fix:** the plugin controller polls `AV1SoftwarePlayer.getPlaybackPosition()`
at 4 Hz while the software backend is active, dedupes values, sends
`onPlaybackPositionChanged`, then stops polling on fallback or teardown. This feeds
Gallery's existing progress/buffering logic without changing Gallery player code or
the decoder lifecycle. Frame-gated ticks and a new buffering callback were tried,
then reverted because they broke playback.

### 3.5 Plugin experiment: accurate keyframe-floor seeks (not in current tree)

**Cause:** `avformat_seek_file(..., AVSEEK_FLAG_BACKWARD)` lands on a keyframe at or
before the requested time, and nothing discarded the frames in between, so the seek
bar walked backwards by up to a GOP (server `gopSize: 0` falls back to 256 frames
≈ 8.5 s).

**Attempted fix:** drop frames below the seek target before display. This seek-floor
change belonged to the reverted rework; current source uses its existing FFmpeg
keyframe seek behavior.

### 3.6 Plugin lifecycle rework: reverted after it stopped playback

**Attempt:** a stop/EOF sentinel, sequence-header resend, decoder error counters,
presented-frame positions, keyframe-floor seeks, stall gating and a buffering callback.

**Outcome:** playback stopped. The on-device log showed `sw invalidate` → `sw teardown`
→ `decode end video=0 audio=0 first=-1.000 stopped=1 failures=0`: teardown arrived
before the decoder produced a frame. Those state-machine changes were reverted;
they are not in current source.

**Final position fix:** after unsigned10 played and scrubbed but kept the spinner, the
plugin controller gained a deduplicated 4 Hz timer reading `getPlaybackPosition()`.
This reports the software player's host-clock position and leaves decoding, clock
control, and teardown untouched. It is less precise than presented-frame timing and
may advance during a decoder stall; the tradeoff avoids the regressions from the
larger rework. Shipped in plugin commit `7d78635` and unsigned11; device verification
of unsigned11 remains pending.

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

The stop/EOF sentinel and enhanced decode-failure reporting from that iteration
were later removed in the playback rollback; they are not in current source.

---

## 5. Hurdles that cost the most time

### 5.1 Four builds that changed nothing (`pubspec.lock`)

`pubspec.yaml` asks for the plugin by **branch ref** (`av1-sw-decode-pr`), but
`mobile/pubspec.lock` carries a `resolved-ref` SHA and `pub` honours the lock for git
dependencies. CI kept compiling the September plugin (`788f5bc`) for
`unsigned1`–`unsigned4` — four 15-minute builds, four identical binaries on the
device, and a whole round of "the fix didn't work" misdirected at the decoder.

**Rule:** after every plugin push, bump the lock:

```bash
NEW=$(git ls-remote git@github.com:DrissiReda/native_video_player.git refs/heads/av1-sw-decode-pr | cut -f1)
# mobile/pubspec.lock → native_video_player.description.resolved-ref = $NEW
```

Symptom to recognise: "the new build behaves exactly like the old one".

### 5.2 No way to see inside the phone (temporary diagnostics removed)

The plugin briefly wrote `Documents/av1debug.log`; Gallery temporarily enabled Files
sharing and displayed the log tail/readout on screen. The logger, overlays, and Files
sharing flags were removed before unsigned9. Do not re-add them to the production
player. The useful discovery was that changed position callbacks drive both the seek
bar and Gallery's inferred buffering state.

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

1. **A spinner is a protocol, not a decoration.** Gallery infers buffering from
   changed `onPlaybackPositionChanged` callbacks; the software backend must provide
   them for progress and buffering UI to work.
2. **Clock and presented-frame positions differ.** Frame progress is more accurate,
   but the frame-gated implementation broke playback and was reverted. Current code
   uses clock position for low-risk progress updates.
3. **Clock ticks can mask a real stall.** The timer clears the spinner while the
   software clock advances, even if frames stop. A future true buffering signal must
   be isolated from decode lifecycle changes and verified on device.
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
| Plugin test branch | `~/apps/forks/native_video_player`, `DrissiReda/native_video_player` @ `av1-sw-decode-pr` (pinned in Gallery's test build) |
| Vendor PR candidate | `av1-sw-decode-pr-single` @ `f8680fb`; PR #19 closed after review |
| Fetch-at-install PR candidate | `av1-pr-clean` @ `824a136`; PR #20 closed; podspec fetches release asset at install |
| Dependency bundle | release `av1-ios9-deps-v1` on the plugin fork; pinned ZIP + checksum in the clean candidate podspec |
| IPA workflow | `.github/workflows/build-unsigned-ipa.yml` |
| Delivered IPAs | `/data/filebrowser/files/admin/NoodleGallery-unsigned<N>.ipa` |
| Backup of deleted DB rows | `/data/artifacts/immich-stale-encodedvideo-20261005/` |
| Current test pin | plugin SHA `7d786355757234fed836d9387fa2902a357adeba` in `mobile/pubspec.lock` |

Related branches: `release/v5.6.0-stockplayer` (AVPlayer only, for comparison),
`ci/unsigned-ipa` (workflow default branch).

## 9. Open items

1. **Verify unsigned11 on the device** — confirm spinner clears while playback and
   scrubbing remain responsive. No on-screen/native debug logger is present now.
2. Apply `ffmpeg.transcode: never` to stop new H264 encodes for 10-bit AV1.
3. Client-side robustness: on a 404 from `/video/playback`, retry `/original`
   (Range-capable), and stop the silent `AVPlayer` fallback so failures surface as
   errors instead of spinners.
4. Known remaining races in the software backend: `displayLayer.flush()` from main
   versus enqueue on the enqueue queue; `close()` after a 2 s deadline can free the
   decoder while a network read is parked; no colour attachments on the pixel
   buffers (wrong colours, not black); FFmpeg XCFrameworks have no simulator slice.
5. `hwdec`-free 4K60 is too slow on A12–A15; cap software playback resolution if that
   matters.

---

## 10. Final scope, spinner fix, and PR packaging decisions

### What belongs where

- The AV1 decoder, hardware capability check, software render layer, audio rendering,
  authenticated AVIO requests, fallback routing, and position callback all live in
  `native_video_player`.
- `mobile/lib/presentation/widgets/asset_viewer/video_viewer.widget.dart` and
  `mobile/lib/providers/asset_viewer/video_player_provider.dart` are unchanged from
  Gallery v5.6.0. Gallery adds no AV1 player/UI state machine.
- Gallery's existing `AppDelegate` cookie-storage hookup is reused by the plugin.
  The `URLSessionManager` app-group fallback is a separate unsigned/TrollStore auth
  persistence fix, not an AV1 decoder change.
- Gallery's `pubspec.yaml`/lock pin to the plugin fork is only needed to test an
  unpublished plugin commit. After the plugin is accepted/released, use a normal
  dependency update; no Gallery AV1 implementation PR is needed.

### Spinner diagnosis and final behavior

The app resets a 1-second buffering timer only when it receives a **changed**
`onPlaybackPositionChanged` callback. Software decode initially emitted none because
activating the software layer removes AVPlayer's periodic observer. Thus frames could
play while Gallery displayed a spinner. Scrubbing still worked because seek commands
travel through a separate callback.

Plugin commit `7d78635` adds a deduplicated 4 Hz timer in
`NativeVideoPlayerViewController`, polling `AV1SoftwarePlayer.getPlaybackPosition()`
and emitting position callbacks. Timer stops on fallback/teardown; decoder loop,
clock control, and teardown state machine remain unchanged. Position is host-clock
based, not frame-presented: simple and stable, but can advance during a decoder stall.
`unsigned10` played and scrubbed but still showed spinner; `unsigned11` contains the
timer fix and awaits device confirmation.

### iOS minimum and decoder availability

`native_video_player.podspec` retains iOS 9.0. Software AV1 path is guarded for iOS
11+ (AVSampleBuffer audio/synchronizer and VideoToolbox API availability); iOS 9–10
keep the plugin's native AVPlayer fallback. Device FFmpeg/dav1d libraries were rebuilt
for iOS 9, with `mach_absolute_time` replacing `clock_gettime` on Darwin. The existing
single dav1d simulator slice was preserved, but the other FFmpeg libraries have no
simulator slices.

### Dependency options and PR status

- No maintained drop-in FFmpeg+dav1d package was found that supports iOS 9 and exposes
  the C API used by `GAV1Player`.
- `ffmpeg_kit_flutter_new_video` provides FFmpeg/dav1d but requires iOS 14+, changes
  the FFmpeg version/license terms, and brings a Flutter plugin dependency. It was not
  selected because the plugin keeps its iOS 9 package floor.
- Vendor-heavy PR #19 was closed. One-commit fetch-at-install PR #20 was also closed
  after the user asked to stop PR creation. Clean candidate branch `av1-pr-clean`
  (`824a136`) downloads a checksum-pinned XCFramework ZIP from the plugin fork's
  `av1-ios9-deps-v1` release during CocoaPods preparation. Asset:
  `native-video-player-ios9-deps-f8680fb.zip`, SHA256
  `00ece99276ed7a35fcbc142b9e317b7a5384d08fae53340dae31a8023b30f6a3`. The ZIP
  contains frameworks plus FFmpeg source/license material and iOS 9 patch; none are
  in the clean branch Git diff. That branch also excludes CI/workflows, builder
  scripts, tests, standalone license note, and `.gitattributes`. No PR is open.

- The full test branch `av1-sw-decode-pr` still vendors frameworks directly; Gallery's
  current test lock uses that branch. The clean fetch-at-install branch is a separate
  packaging experiment, not the app's current dependency.

### Build and test evidence

- Plugin branch `av1-sw-decode-pr` at `7d78635` passed engine/iOS9 availability test
  run `37632870181`. The iOS 9 framework rebuild passed minimum-version and
  `clock_gettime` symbol checks in run `37617023302`.
- Rebuilt six device archives total 4,996,648 bytes, down from 6,852,480 bytes
  (~27% smaller) after limiting FFmpeg demuxers/protocols and disabling debug symbols.
- Gallery unsigned11 was built from commit `2f4f7d7595b` with plugin SHA `7d78635`;
  CI run `37633392089` passed. It has not yet been verified on-device.
- The clean fetch-at-install candidate uses release `av1-ios9-deps-v1` in the same
  plugin fork. ZIP `native-video-player-ios9-deps-f8680fb.zip`, SHA256
  `00ece99276ed7a35fcbc142b9e317b7a5384d08fae53340dae31a8023b30f6a3`; it contains
  the six frameworks plus corresponding license/source patch. Podspec downloads it at
  install and extracts `XCFrameworks/` only. No upstream PR is open.

Current IPA pin remains the full test branch `av1-sw-decode-pr` at
`7d786355757234fed836d9387fa2902a357adeba`; unsigned11 is
`/data/filebrowser/files/admin/NoodleGallery-unsigned11.ipa` (SHA256
`70df3997edef9582c2285889c7fe417a4e4c484b4c1a40a51a36a61117f1d57e`).
