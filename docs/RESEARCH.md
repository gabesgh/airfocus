# AirFocus: technical research

Research for a macOS menu bar agent that reads AirPods head orientation (`CMHeadphoneMotionManager`), works out which on-screen window the user is facing, and focuses that window.

- Target: macOS 26 on Apple silicon, built with SwiftPM from the command line.
- Research date: 2026-10-20.
- Build machine, checked locally: macOS 26.7.1 (25G241), Xcode 27.1 (27A9275), Swift 6.4, SDK `MacOSX27.0.sdk`, arm64.

Every Swift snippet in this document was compiled with `swift build` against that toolchain, in Swift 5 language mode (see §7.1), inside a scratch package. **None of them was run against real AirPods or real windows.** Items marked **UNVERIFIED** need a hardware test.

---

## 0. TL;DR: the gotchas that will bite

1. **Background delivery works.** Several shipping LSUIElement menu bar apps depend on `CMHeadphoneMotionManager` delivering while another app is frontmost: Nod (head-driven pointer), PodsControlMac (head scrolling), Dorso (posture, about 2.6k stars), PostureFix, Slouchless and others. No macOS report of foreground-only delivery turned up. The real conditions are listed in point 2.
2. **Motion only flows when all of the following hold. When any one fails, the stream goes quiet with no error:**
   - The app is a **bundled, signed `.app`** with `NSMotionUsageDescription`. A bare `swift build` or `swift run` binary "receives zero samples, forever, with no error".
   - Without `NSMotionUsageDescription`, the process crashes when it starts updates.
   - The AirPods are **connected to this Mac, in the ears, and selected as the current audio output**. Nothing has to be playing.
   - The user granted **Motion & Fitness**. The prompt appears on the first `startDeviceMotionUpdates`.
3. **Yaw is relative and unstable:**
   - It is gyro-integrated, so it drifts.
   - Its zero is arbitrary and is set when the stream starts.
   - A September 2026 forum report says it **re-centres when Spatial Audio playback starts** in another app.
   - The streaming bud can switch mid-session.
   - Pitch and roll are gravity-referenced and stable.
   - Design for recentring from day one.
4. **Focusing another app's window from a background agent:** public APIs are unreliable on macOS 14+. Activation is "a request" under cooperative activation, and `ignoringOtherApps` is ignored.
   - The reliable method, used today by AltTab, yabai and Hammerspoon-derived code, is the **private SkyLight sequence**: `_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)`, then a synthetic `SLPSPostEventRecordTo` "make key" record, then `AXRaise`.
   - Resolve the symbols with `dlsym`, and fall back to AX `kAXMain`, `kAXFrontmost` and `activate()`.
5. **Screen Recording is not needed.**
   - `CGWindowListCopyWindowInfo` returns bounds, PID, layer, alpha and z-order without it.
   - It does not return window titles, and on macOS 26 apparently not even owner names. Get names from the PID and titles from AX.
   - Asking for Screen Recording also brings Sequoia-era monthly re-consent nags. Don't request it.
6. **TCC and rebuilds.** An ad-hoc signature's designated requirement is a `cdhash`, so every rebuild loses the Accessibility and Motion grants. There are two fixes:
   - Sign with the **Apple Development identity already in this Mac's keychain**.
   - Or ad-hoc sign with an explicit `--requirements '=designated => identifier "<bundle id>"'`. Nod, Microsoft ZoomIt-Mac, Wox and cmux do this.
   - Either way, launch with `open`, not by exec'ing the binary from Terminal. Otherwise TCC charges the permissions to Terminal.
7. **This Mac has Stage Manager enabled** (`com.apple.WindowManager GloballyEnabled = 1`):
   - The window list contains Stage Manager strip thumbnails: layer 0 windows at negative X, owned by `WindowManager` or shrunken copies of real windows.
   - Focusing a window from another stage re-lays out the screen.
   - Filter those windows out, and warn the user, or recommend turning Stage Manager off.
8. **The overlay must be an `NSPanel`** with these settings, which Apple DTS confirmed on macOS 26:
   - `.nonactivatingPanel`, `level = .screenSaver`.
   - `[.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`.
   - `ignoresMouseEvents = true`.
   - Run the app as an accessory (LSUIElement).
9. **Carbon `RegisterEventHotKey` still works on macOS 26** and needs no permission. From macOS 15 on, a combination must include ⌘ or ⌃, not only ⌥ or ⌥⇧.
10. **Look-away lock (§9):**
    - Start the screen saver by launching `/System/Library/CoreServices/ScreenSaverEngine.app` through `NSWorkspace`, with private `SACScreenSaverStartNow` as a fallback.
    - Whether a password is then required depends only on the user's "Require password after screen saver begins…" setting. Read it with `sysadminctl -screenLock status`, which reports "immediate" on this Mac.
    - To make the unlock prompt appear:
      1. `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` turns the display on (documented).
      2. Private `SACScreenSaverStopNow` and a zero-distance synthetic mouse move dismiss the screen saver.
      3. Never post keys. BLEUnlock's Shift toggled input methods, and an Esc can reach the terminal agent.
    - **Whether head motion keeps flowing while the screen saver runs or the screen is locked is unverified.** Design for it to stop.

---

## 1. `CMHeadphoneMotionManager` on macOS

### 1.1 Availability and hardware

| Item | Finding | Source |
|---|---|---|
| macOS availability | `API_AVAILABLE(macos(14.0), ios(14.0), watchos(7.0))`, `API_UNAVAILABLE(visionos, tvos)`. The local macOS 27 SDK header and Apple's docs agree. | SDK `CoreMotion.framework/Headers/CMHeadphoneMotionManager.h`; [Apple docs](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager) |
| Announced | WWDC23, "What's new in Core Motion": "it's also coming to macOS 14" | [WWDC23 10179](https://developer.apple.com/videos/play/wwdc2023/10179) |
| Headphones | Models with "spatial audio with dynamic head tracking": AirPods Pro (all), AirPods 3, AirPods 4 (both variants per Nod; Dorso's product-ID table lists AirPods 4 non-ANC as having *no* motion sensor, **conflicting**), AirPods Max, Beats Fit Pro. AirPods 1/2 report `isDeviceMotionAvailable == false`. | [Nod README](https://github.com/ydisli/nod), [airtracker docs/MACOS.md](https://github.com/crippler95/airtracker/blob/main/docs/MACOS.md), [airpod-pose-estimate sensor notes](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md), [Dorso AirPodsPostureDetector.swift](https://github.com/tldev/dorso/blob/main/Sources/Detectors/AirPodsPostureDetector.swift) |
| Mac | Apple silicon. Nod: "Apple offers AirPods head tracking on Macs with Apple silicon". | [Nod README](https://github.com/ydisli/nod) |
| `isDeviceMotionAvailable` | "whether the **current device** supports the headphone motion manager". This is about the host Mac, not whether AirPods are connected. Use the delegate or the arrival of samples to detect connection. | [Apple docs](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/isdevicemotionavailable) |

The full API surface, from the macOS 27 SDK header:

```objc
+ (CMAuthorizationStatus)authorizationStatus;
@property(weak, nonatomic, nullable) id<CMHeadphoneMotionManagerDelegate> delegate;
@property(readonly, getter=isConnectionStatusActive) BOOL connectionStatusActive;
@property(readonly, getter=isDeviceMotionAvailable) BOOL deviceMotionAvailable;
@property(readonly, getter=isDeviceMotionActive) BOOL deviceMotionActive;
@property(readonly, nullable) CMDeviceMotion *deviceMotion;          // pull interface
- (void)startDeviceMotionUpdates;                                    // pull
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMHeadphoneDeviceMotionHandler)handler;
- (void)stopDeviceMotionUpdates;
- (void)startConnectionStatusUpdates;   // delegate events before/without motion
- (void)stopConnectionStatusUpdates;
// Delegate (both @optional):
- (void)headphoneMotionManagerDidConnect:(CMHeadphoneMotionManager *)manager;
- (void)headphoneMotionManagerDidDisconnect:(CMHeadphoneMotionManager *)manager;
```

The delegate header says callbacks run "on the operation queue used to deliver the device motion updates. The main thread is used if the queue was not specified."

Connect and disconnect fire on ear insertion and removal when Automatic Ear Detection is on. If the streaming bud is removed, the other bud takes over ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10179)).

### 1.2 Info.plist, entitlements and sandbox

- **`NSMotionUsageDescription` is required.** Apple's docs: "In iOS and macOS, include the NSMotionUsageDescription key in your app's Info.plist file. If this key is absent, the system crashes your app when you start device-motion updates." ([docs](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager))
- **No entitlement is needed.**
  - Every working macOS project examined uses only the plist key. Dorso's Mac App Store build is sandboxed and has no motion entitlement ([build.sh](https://github.com/tldev/dorso/blob/main/build.sh)).
  - PostureFix warns that adding a `com.apple.developer.headphone-motion` entitlement to an ad-hoc build "makes AMFI SIGKILL the app on launch" ([build.sh](https://github.com/chandansgowda/posture-fix/blob/main/build.sh)). No Apple documentation for that entitlement key was found. **Don't add it.**
  - The documented `com.apple.developer.coremotion.head-pose` entitlement belongs to PHASE head tracking, not to `CMHeadphoneMotionManager`.
- **Sandbox: none.** The app needs cross-process Accessibility and private SkyLight calls, which the App Sandbox does not allow. Ship unsandboxed, outside the Mac App Store.

### 1.3 Authorization

- `CMHeadphoneMotionManager.authorizationStatus()` returns `.notDetermined`, `.restricted`, `.denied` or `.authorized`.
- The system prompt appears on the **first `startDeviceMotionUpdates`** from a signed bundle. It appears under System Settings › Privacy & Security › **Motion & Fitness** ([airtracker HeadphoneMotionSource.swift](https://github.com/crippler95/airtracker/blob/main/Sources/AirTrackerCore/Motion/HeadphoneMotionSource.swift), [Dorso](https://github.com/tldev/dorso)).
- There is **no callback** for authorization changes.
  - Dorso re-checks when its app becomes active after the dialog.
  - An agent app never becomes active, so poll `authorizationStatus()` about once a second while it is `.notDetermined`.
- Denial surfaces as an `NSError` in the handler, with `CMErrorDomain` and code `CMErrorNotAuthorized` (or `CMErrorMotionActivityNotAuthorized`) ([Nod HeadphoneMotion.swift](https://github.com/ydisli/nod/blob/main/Sources/Nod/Tracking/HeadphoneMotion.swift)).
- Reset during development with `tccutil reset Motion <bundle-id>` ([airtracker Makefile](https://github.com/crippler95/airtracker), [Dorso CLAUDE.md](https://github.com/tldev/dorso)).

### 1.4 Update rate

- No API sets the rate.
- Several projects observe **about 25 Hz**:
  - [airpod-pose-estimate](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md): "fixed at roughly 25 Hz. There is no API to raise it".
  - [airtracker](https://github.com/crippler95/airtracker), [posture](https://github.com/einargudnig/posture) and [AirPods_Nod](https://github.com/kun-Jiang/AirPods_Nod) report the same.
- [Nod](https://github.com/ydisli/nod) states "about 50 times a second". The rate may depend on the model or firmware. **UNVERIFIED for the user's AirPods.**
- Rules that follow:
  - Measure the rate at runtime and show it in the menu.
  - Use `CMDeviceMotion.timestamp`, the device clock, for any rate maths.
  - Never assume a fixed `dt`.
- Bluetooth adds tens of milliseconds of variable latency ([sensor notes](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md)).

### 1.5 Reference frame and which angles to use

- **Axes** ([Apple illustration](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)): Z points up through the crown, and X and Y are horizontal.
- Projects using `attitude.yaw` and `attitude.pitch` directly report these conventions:
  - **yaw grows when turning left**
  - **pitch grows when looking up**
  - Nod's comment: "CoreMotion angles grow turning left and looking up". Dorso: "Looking down decreases pitch".
  - The consistent reading is X ear-to-ear, Y forward, Z up. **Verify the signs on hardware.**
- **Gravity-referenced:**
  - Pitch and roll are fused against gravity, "absolute and drift-free".
  - **Yaw is integrated from the gyroscope alone, so it wanders continuously** ([posture README](https://github.com/einargudnig/posture)).
  - This matches CoreMotion's `xArbitraryZVertical` frame. `CMDeviceMotion.heading` returns a negative value in that frame.
- **The zero is arbitrary and resets when the stream starts.** "CoreMotion picks its own reference frame when the stream starts -- it is not world-aligned and not repeatable between runs" ([sensor notes](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md)).
  - Treat absolute yaw as meaningless.
  - Treat every stop and start, reconnect, or bud swap as needing a recentre.
- **Euler or quaternion:**
  - For a screen-facing head pointer with small roll, Euler `yaw` (unwrapped) and `pitch` are enough. Nod and Dorso use them.
  - Under CoreMotion's Z-X-Y order, a pure head turn about world vertical changes only yaw.
  - Calibration (§8) absorbs how the bud sits in the ear.
  - Use the quaternion with `multiply(byInverseOf:)` (WWDC23's `startingPose` pattern), or slerp smoothing, only if large roll ever becomes a problem.
  - Unwrap yaw across ±180°, as Nod does.

### 1.6 Drift and reference jumps

| Phenomenon | Evidence | Mitigation |
|---|---|---|
| Slow yaw drift | Gyro-only yaw ([posture](https://github.com/einargudnig/posture)). No published figure in °/min was found. **Measure it** by logging yaw with the head still for 5 minutes. | Recentre hotkey (one-point offset) plus implicit recalibration from typing (§8.6). airtracker adds an optional "pull yaw back to centre at N °/s" ([OrientationPipeline.swift](https://github.com/crippler95/airtracker/blob/main/Sources/AirTrackerCore/Motion/OrientationPipeline.swift)). That is **not** suitable here, because users hold off-centre poses for minutes. |
| Yaw re-centres when Spatial Audio playback starts in another app | Forum post, Sep 2026, macOS, no replies: "when I start playing audio with Spatial Audio set to either Head Tracked or Fixed, the yaw appears to recenter as soon as I press play" ([thread 844940](https://developer.apple.com/forums/thread/844940)) | Detect a yaw step the gyro didn't see and re-base it (code in §1.8, **UNVERIFIED heuristic**), then prompt or auto-recentre. |
| Bud switch (left ↔ right) mid-session | Motion comes from one bud at a time (`sensorLocation`, [WWDC23](https://developer.apple.com/videos/play/wwdc2023/10179)). "Expect an orientation discontinuity; nothing tells you it happened" ([sensor notes](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md), **verify**) | Watch `motion.sensorLocation`. When it changes, re-base yaw **and** pitch offsets so the output stays continuous. |
| Stream silently stops | Output route changes, ears out, sleep and wake | Watchdog restart, as in airtracker's 3 s watchdog. Also restart motion on `didConnect` if nothing arrived. Nod: "a request made before the headphones connected may never start sending". |

### 1.7 Background, LSUIElement and the other critical conditions

**Does it keep delivering when the app is a background agent and not frontmost? Yes.** The evidence:

- [Nod](https://github.com/ydisli/nod), whose Info.plist has `LSUIElement=true`, moves the system pointer from head motion while other apps are frontmost. Its README measures CPU for "Tracking, no Nod window open".
- [PodsControlMac](https://github.com/sumionochi/PodsControlMac) scrolls whatever app is frontmost.
- [Dorso](https://github.com/tldev/dorso), [PostureFix](https://github.com/chandansgowda/posture-fix), [Slouchless](https://github.com/denislav-d/slouchless), [head-position-tracker](https://github.com/FujiwaraChoki/head-position-tracker), [poise](https://github.com/jx-grxf/poise), [PrivacyScreen](https://github.com/qn34uc59t/privacy_screen) and [airtracker](https://github.com/crippler95/airtracker) are all menu bar apps that monitor continuously while the user works in other apps.
- Developer Forums thread 844940 (Sep 2026) describes "an app that uses CMHeadphoneMotionManager on macOS **without playing any sound**".
- No project needed an App Nap workaround. Still, wrap active tracking in `ProcessInfo.beginActivity(options: [.userInitiated, .latencyCritical])`. It is cheap insurance, because an agent with only a status item and a transparent overlay is a candidate for App Nap timer throttling. **UNVERIFIED whether it's needed.**
- The iOS rule that background delivery needs an audio background mode or a location session does **not** apply on macOS.

**Conditions and known failure modes:**

| Condition | Evidence |
|---|---|
| **AirPods must be the active audio output.** "AirPods only report motion while they are the active audio output. Play any audio on the Mac, and disable automatic device switching so they do not hop to your iPhone." | [airtracker README and MACOS.md](https://github.com/crippler95/airtracker/blob/main/docs/MACOS.md) |
| "make sure they are the **selected audio output** (not just connected)"; "Samples stop arriving when the AirPods are not the active audio output. Nothing errors; the stream just goes quiet." | [airpod-pose-estimate](https://github.com/mattxh/airpod-pose-estimate) |
| "Ensure they show as your audio output device" | [PodsControlMac README](https://github.com/sumionochi/PodsControlMac) |
| "connected, in-ear, and selected as the audio output" | [tapq README](https://github.com/spaceamoeba-t/tapq) |
| **Audio does not need to be playing.** Forum 844940 runs "without playing any sound". airtracker's "play any audio" advice is a way to make the AirPods the active route. | [forum 844940](https://developer.apple.com/forums/thread/844940) |
| **Must be a bundled `.app`.** "macOS only shows that prompt for a bundled, signed app. A bare `swift build` binary receives zero samples, forever, with no error." | [airpod-pose-estimate README](https://github.com/mattxh/airpod-pose-estimate) |
| "Build through build.sh rather than swift run: the motion API only works inside the signed .app bundle that carries the NSMotionUsageDescription" | [head-position-tracker README](https://github.com/FujiwaraChoki/head-position-tracker) |
| "It has to be an app bundle: macOS only grants headphone-motion access to a process whose own Info.plist carries NSMotionUsageDescription." | [BlindSamurai headtracker/build.sh](https://github.com/MarkymarkLee/BlindSamurai) |
| **Ad-hoc signing works for Motion**, but it re-prompts after each rebuild unless the designated requirement is stable (§7) | airtracker, PostureFix, Nod, head-position-tracker, airpod-pose-estimate all ship ad-hoc builds |
| Ears out: the stream stops, and `didDisconnect` fires when ear detection is on | [WWDC23](https://developer.apple.com/videos/play/wwdc2023/10179), [Nod TrackingPipeline](https://github.com/ydisli/nod) ("AirPods send nothing when they leave the ears") |
| Starting before the AirPods connect may never begin streaming, so restart on connect | [Nod TrackingPipeline.swift](https://github.com/ydisli/nod/blob/main/Sources/Nod/Tracking/TrackingPipeline.swift) |
| Effect of the Control Center "Spatial Audio / Head Tracking" toggle on `CMHeadphoneMotionManager` | **UNKNOWN.** No source found. Test it. |

Showing the current output device in the menu helps a lot when diagnosing "0 Hz". The code is in §1.8.

### 1.8 Recommended motion code (compiles; hardware-untested)

```swift
import CoreMotion
import Foundation

/// Head pose in degrees. yaw > 0 = turned left, pitch > 0 = looking up (CoreMotion convention).
struct HeadPose { var yaw: Double; var pitch: Double; var roll: Double; var time: TimeInterval }

final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    enum Event { case pose(HeadPose), connected, disconnected, error(Error), referenceJump(dYaw: Double) }

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "headtracker.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    var onEvent: ((Event) -> Void)?          // called on `queue`; hop to main yourself

    private var lastRawYaw: Double?           // radians
    private var turns = 0.0                   // yaw unwrap counter
    private var yawOffset = 0.0, pitchOffset = 0.0   // degrees, accumulated jump compensation
    private var lastOut: (yaw: Double, pitch: Double)?
    private var lastTimestamp: TimeInterval?
    private var lastSensor: CMDeviceMotion.SensorLocation?
    private(set) var lastSampleUptime: TimeInterval = 0
    private var watchdog: Timer?

    static var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Call on the main thread (the watchdog timer needs the main run loop).
    func start() {
        manager.startConnectionStatusUpdates()     // delegate callbacks even before motion flows
        startMotion()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Samples stalled (AirPods not the active output, bud swap, sleep/wake): ask again.
            if self.manager.isDeviceMotionActive,
               ProcessInfo.processInfo.systemUptime - self.lastSampleUptime > 3.0 {
                self.restartMotion()
            }
        }
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
    }

    func restartMotion() {
        manager.stopDeviceMotionUpdates()
        startMotion()
    }

    private func startMotion() {
        lastRawYaw = nil; lastOut = nil; lastTimestamp = nil; lastSensor = nil
        guard manager.isDeviceMotionAvailable else { return }
        // The first call on a properly bundled + signed app triggers the Motion & Fitness prompt.
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error { self.onEvent?(.error(error)); return }
            guard let m = motion else { return }
            self.lastSampleUptime = ProcessInfo.processInfo.systemUptime
            self.ingest(m)
        }
    }

    private func ingest(_ m: CMDeviceMotion) {
        let a = m.attitude
        // Unwrap yaw so crossing ±180° doesn't look like a jump (pattern from ydisli/nod).
        if let last = lastRawYaw {
            let step = a.yaw - last
            if step > .pi { turns -= 1 } else if step < -.pi { turns += 1 }
        }
        lastRawYaw = a.yaw
        var yaw = (a.yaw + turns * 2 * .pi) * 180 / .pi + yawOffset
        var pitch = a.pitch * 180 / .pi + pitchOffset

        // Heuristic (UNVERIFIED on hardware): re-base when the reference jumps.
        //  - streaming bud changed (left <-> right): offset yaw AND pitch to stay continuous
        //  - big yaw step the gyro did not see (e.g. Spatial Audio playback re-centring yaw)
        if let prev = lastOut, let pt = lastTimestamp {
            let dt = max(m.timestamp - pt, 1e-3)
            let r = m.rotationRate
            let gyroDegPerSec = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180 / .pi
            let dYaw = yaw - prev.yaw
            if let s = lastSensor, s != m.sensorLocation {
                yawOffset -= dYaw; pitchOffset -= (pitch - prev.pitch)
                yaw = prev.yaw; pitch = prev.pitch
                onEvent?(.referenceJump(dYaw: dYaw))
            } else if abs(dYaw) > 10, abs(dYaw) > 3 * gyroDegPerSec * dt + 5 {
                yawOffset -= dYaw; yaw = prev.yaw
                onEvent?(.referenceJump(dYaw: dYaw))
            }
        }
        lastSensor = m.sensorLocation
        lastOut = (yaw, pitch)
        lastTimestamp = m.timestamp
        onEvent?(.pose(HeadPose(yaw: yaw, pitch: pitch, roll: a.roll * 180 / .pi, time: m.timestamp)))
    }

    // MARK: CMHeadphoneMotionManagerDelegate (delivered on the motion queue, or main if none)
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        onEvent?(.connected)
        // A request made before the headphones connected may never start sending (ydisli/nod).
        if ProcessInfo.processInfo.systemUptime - lastSampleUptime > 1 { restartMotion() }
    }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        onEvent?(.disconnected)
    }
}
```

The current output device, for the status menu ("AirPods are not the current output"):

```swift
import CoreAudio

func currentOutputDevice() -> (name: String, isBluetooth: Bool)? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return nil }

    var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var cfName: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    _ = AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &size, &cfName)

    var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
    var transport: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    _ = AudioObjectGetPropertyData(dev, &tAddr, 0, nil, &size, &transport)

    let name = cfName?.takeRetainedValue() as String? ?? "Unknown"
    let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    return (name, bt)
}
```

To react to route changes, add an `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultOutputDevice` and call `restartMotion()` when it changes. **UNVERIFIED whether a restart is required.**

---

## 2. Existing open-source projects (AirPods head motion on macOS)

All of these were cloned and read for this report.

| Repo | What it is | Patterns worth copying |
|---|---|---|
| [ydisli/nod](https://github.com/ydisli/nod) | Menu bar head-pointer (LSUIElement), SwiftPM plus a shell `.app` wrapper, macOS 14+ | Serial `OperationQueue` with `underlyingQueue`; `startConnectionStatusUpdates()`; restart motion on connect; yaw unwrap; sign flip to screen axes; 1€ filter; dwell detector (1.0 s, 28 pt radius); Carbon hotkeys (⌃⌥N, ⌃⌥C); **ad-hoc signing with an identifier-only designated requirement** ([build-app.sh](https://github.com/ydisli/nod/blob/main/scripts/build-app.sh)); "Direct" absolute-aim mode with head travel 0.35 rad × 0.22 rad (about 20° × 12.6°) spanning the display ([PointerEngine.swift](https://github.com/ydisli/nod/blob/main/Sources/NodCore/PointerEngine.swift)) |
| [crippler95/airtracker](https://github.com/crippler95/airtracker) | AirPods to OpenTrack UDP, menu bar app plus CLI | Quaternion pipeline; recentre with `qRef.inverse * q`; slerp smoothing; **3 s stall watchdog that restarts updates**; auto-recentre on reconnect; optional yaw drift pull (°/s); `make reset-tcc` → `tccutil reset Motion`; troubleshooting notes on the active audio output |
| [mattxh/airpod-pose-estimate](https://github.com/mattxh/airpod-pose-estimate) | Swift capture tool (Command Line Tools only) wrapped as a `.app`, plus Python | Clearest write-up of the gotchas: 25 Hz, bundle requirement, active output, reference resets per run, bud switching ([sensor-notes.md](https://github.com/mattxh/airpod-pose-estimate/blob/main/docs/sensor-notes.md)) |
| [sumionochi/PodsControlMac](https://github.com/sumionochi/PodsControlMac) | Head scroll and cursor in the menu bar (Xcode project) | Background operation driving other apps; neutral-pose calibration; pauses when the real mouse moves |
| [tldev/dorso](https://github.com/tldev/dorso) | Posture app, about 2.6k stars, App Store and direct builds | Permission flow (start updates to trigger the prompt, then re-check status); IOBluetooth product IDs for AirPods with motion; sandboxed build needs no motion entitlement |
| [einargudnig/posture](https://github.com/einargudnig/posture) | Posture menu bar app | Pitch is gravity-referenced and yaw drifts; explanation of signing identity and designated requirements |
| [chandansgowda/posture-fix](https://github.com/chandansgowda/posture-fix) | Posture menu bar app, SwiftPM plus build.sh | Ad-hoc signing **without** entitlements; warning about AMFI SIGKILL |
| [FujiwaraChoki/head-position-tracker](https://github.com/FujiwaraChoki/head-position-tracker) | Posture timer | "motion API only works inside the signed .app bundle" |
| [kun-Jiang/AirPods_Nod](https://github.com/kun-Jiang/AirPods_Nod) | Head gestures to keystrokes, aimed at approving Claude Code prompts | Allowlist of terminal apps (Terminal, iTerm2, Ghostty, Warp, Hyper, Alacritty); nod and shake detection over a 0.8 s window with hysteresis |
| [DanielRudrich/Headitude](https://github.com/DanielRudrich/Headitude) | AirPods to OSC for spatial audio | Wear-orientation calibration from gravity plus a nod |
| [denislav-d/slouchless](https://github.com/denislav-d/slouchless), [jx-grxf/poise](https://github.com/jx-grxf/poise), [qn34uc59t/privacy_screen](https://github.com/qn34uc59t/privacy_screen), [1bnjmn3/AG-SpatialPrivacy](https://github.com/1bnjmn3/AG-SpatialPrivacy), [YanjieZe/LookBack](https://github.com/YanjieZe/LookBack), [whyy9527/pods-input](https://github.com/whyy9527/pods-input), [spaceamoeba-t/tapq](https://github.com/spaceamoeba-t/tapq) | Other macOS menu bar or background uses | All confirm the same setup: queue, handler, NSMotionUsageDescription, bundle |

The common working pattern:

1. Create one `CMHeadphoneMotionManager` and keep it alive for the app's lifetime.
2. Set the `delegate`, then call `startConnectionStatusUpdates()`.
3. Call `startDeviceMotionUpdates(to: serialQueue)`.
4. In the handler, guard on `error` and `motion`, read `attitude` (Euler or quaternion), and hop to main for the UI.
5. Re-check `authorizationStatus()` and `isDeviceMotionAvailable` in the UI.
6. Add a watchdog and restart-on-connect.
7. Wrap the binary in a `.app` with `NSMotionUsageDescription`, codesign it, and launch it with `open`.

---

## 3. Window enumeration

### 3.1 API choice: `CGWindowListCopyWindowInfo`

- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` returns on-screen windows **ordered front to back** (SDK header: "List all on-screen windows in this user session, ordered from front to back").
- It is still `API_AVAILABLE(macos(10.5))` and not deprecated in the macOS 27 SDK. The image-capture functions `CGWindowListCreateImage*` are the deprecated part.
- Cost measured on this Mac: **0.67 ms per call** with 41 windows. Polling at 5–10 Hz while tracking is fine.

### 3.2 Which keys need Screen Recording

| Key | Without Screen Recording | Notes |
|---|---|---|
| `kCGWindowNumber` (CGWindowID), `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowBounds`, `kCGWindowAlpha`, `kCGWindowIsOnscreen`, `kCGWindowSharingState` | Available | Everything this app needs |
| `kCGWindowName` (title) | **nil** for other apps' windows | Apple DTS: certain properties, "most notably kCGWindowName", are only populated with the Screen Recording privilege ([via search on forum 839069](https://developer.apple.com/forums/thread/839069)); [Chromium permissions_utils.mm](https://chromium.googlesource.com/chromium/src/+/d4afc97b7/ui/base/cocoa/permissions_utils.mm) uses this as its permission heuristic |
| `kCGWindowOwnerName` | Reported **nil on macOS 26** for other apps without permission, and populated again on a macOS 27 beta | [Forum 839069](https://developer.apple.com/forums/thread/839069). DTS: which keys are gated "is undocumented and may change at any time" |

The recommendations follow:

- Use **`NSRunningApplication(processIdentifier:)?.localizedName`** for app names.
- Use **AX `kAXTitleAttribute`** for titles. It needs only Accessibility, which the app needs anyway for focusing.
- **Do not request Screen Recording.** Since Sequoia it brings recurring "Allow for one month" re-consent prompts ([9to5Mac](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/), [TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)).
- If permission state is ever needed, use `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()`, not the nil-title heuristic (DTS).

### 3.3 Filtering, with real data from this Mac

On this machine, with Stage Manager on, `optionOnScreenOnly` returned:

- Control Center status items at layer 25.
- The "Menubar" window owned by WindowServer at layer 24.
- A Screenshot overlay at layer 24.
- Notification Center at layer -2147483601.
- Layer 0 `WindowManager` windows (Stage Manager): "App Icon Window", "Gesture Blocking Overlay", and a batch of 1×1 windows at (1e9, 1e9).
- **Layer 0 iTerm2 and Messages windows at negative X with sizes like 75×98 and 94×161.** These are Stage Manager strip thumbnails reported as on-screen.
- One real window: Zen browser, 1280×1409 at (0, 31).

The filter rules that follow:

1. `layer == 0`. This drops the menu bar, Dock (layer 20), status items, the notification centre and screensaver-level overlays, including our own.
2. `ownerPID != getpid()`.
3. `alpha > 0.05`.
4. Minimum size about 160 × 100 pt.
5. Bundle ID not in `com.apple.WindowManager`, `com.apple.dock`, `com.apple.controlcenter`, `com.apple.notificationcenterui`.
6. At least 90% of the frame inside the union of screen rects. This removes Stage Manager strip thumbnails and parked windows.
7. **Occlusion.** Because the list is front to back, subtract earlier frames. Drop windows less than 15% visible. Put the dot at the **centroid of the visible part**, not the frame centre. Otherwise a partly covered window's dot can land on the window in front of it.

### 3.4 Coordinate systems (multi-monitor)

- **CG / Quartz and AX global space:**
  - Origin at the **upper-left corner of the main display**, with y pointing down ([kCGWindowBounds](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds), [CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:))).
  - AX `kAXPosition` and `kAXSize` use the same space ([mac-taskbar INSIGHTS](https://github.com/MeKo-Christian/mac-taskbar/blob/main/docs/INSIGHTS.md)).
- **AppKit global space:**
  - Origin at the **bottom-left of the primary screen**, with y pointing up.
  - `NSScreen.screens[0]` "is the screen that contains the menu bar and whose origin is at the point (0, 0)". It is **not** necessarily `NSScreen.main`.
  - Don't cache the array. Listen for `didChangeScreenParametersNotification` ([docs](https://developer.apple.com/documentation/appkit/nsscreen/screens)).
- Other displays can have negative coordinates in both spaces.
- `NSScreen.deviceDescription["NSScreenNumber"]` gives the `CGDirectDisplayID`.

```swift
var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

func cgRect(fromAppKit r: NSRect) -> CGRect {
    CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
}
func appKitRect(fromCG r: CGRect) -> NSRect {
    NSRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
}
func appKitPoint(fromCG p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryScreenHeight - p.y) }

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// True when Stage Manager is on (it re-lays windows out when focus changes).
func stageManagerEnabled() -> Bool {
    (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
}
```

### 3.5 Enumerator (compiles)

```swift
import AppKit
import CoreGraphics

struct TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let frameCG: CGRect          // global, top-left origin (CG / AX space)
    var visibleFraction: Double  // 0...1 after occlusion by windows in front
    var targetPointCG: CGPoint   // where to draw the dot: centre of the visible part
}

enum WindowEnumerator {
    static let minSize = CGSize(width: 160, height: 100)
    static let ignoredOwners: Set<String> = ["com.apple.WindowManager", "com.apple.dock",
                                             "com.apple.controlcenter", "com.apple.notificationcenterui"]

    /// Visible, normal (layer 0) windows of other apps, front-to-back.
    static func visibleWindows() -> [TrackedWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let screens = NSScreen.screens.map { cgRect(fromAppKit: $0.frame) }

        var result: [TrackedWindow] = []
        var occluders: [CGRect] = []            // frames of windows already seen (they are in front)
        for info in raw {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0.05, pid != myPID,
                  frame.width >= minSize.width, frame.height >= minSize.height else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            if let bid = app?.bundleIdentifier, ignoredOwners.contains(bid) { continue }
            // Stage Manager strip thumbnails and parked windows sit (partly) off every screen.
            let onScreenArea = screens.reduce(0.0) { $0 + area($1.intersection(frame)) }
            guard onScreenArea >= 0.9 * area(frame) else { occluders.append(frame); continue }

            let (fraction, point) = visibleCentre(of: frame, occludedBy: occluders)
            occluders.append(frame)
            guard fraction >= 0.15 else { continue }
            // kCGWindowOwnerName may be nil without Screen Recording on macOS 26: use the PID.
            let name = app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)"
            result.append(TrackedWindow(id: id, pid: pid, appName: name, frameCG: frame,
                                        visibleFraction: fraction, targetPointCG: point))
        }
        return result
    }

    /// Grid-sample the window; return visible fraction and centroid of visible samples.
    static func visibleCentre(of r: CGRect, occludedBy front: [CGRect], grid: Int = 16) -> (Double, CGPoint) {
        var hits = 0; var sx = 0.0; var sy = 0.0
        for i in 0..<grid { for j in 0..<grid {
            let p = CGPoint(x: r.minX + (Double(i) + 0.5) * r.width / Double(grid),
                            y: r.minY + (Double(j) + 0.5) * r.height / Double(grid))
            if !front.contains(where: { $0.contains(p) }) { hits += 1; sx += p.x; sy += p.y }
        }}
        guard hits > 0 else { return (0, CGPoint(x: r.midX, y: r.midY)) }
        return (Double(hits) / Double(grid * grid), CGPoint(x: sx / Double(hits), y: sy / Double(hits)))
    }

    static func area(_ r: CGRect) -> Double { r.isNull ? 0 : Double(r.width * r.height) }
}
```

### 3.6 ScreenCaptureKit `SCShareableContent`: worse for this app

- **Always requires Screen Recording.** That means a prompt, the monthly nags since Sequoia, and a TCC grant that is fragile across rebuilds.
- It is asynchronous and heavier.
- `SCWindow` offers `windowID`, `frame`, `title`, `owningApplication`, `windowLayer`, `isOnScreen` and `isActive` ([docs](https://developer.apple.com/documentation/screencapturekit/scwindow)). That adds nothing this app needs beyond titles, which AX provides.
- Front-to-back ordering is not documented for `SCShareableContent.windows`, and the app needs ordering for occlusion.
- DTS points to it as "the modern surface" for enumeration ([forum 839069](https://developer.apple.com/forums/thread/839069)), but it only makes sense if thumbnails are wanted.

**Verdict:** use `CGWindowListCopyWindowInfo` with AX for titles.

---

## 4. Focusing a specific window from a background agent (macOS 14, 15, 26)

### 4.1 Why public activation is not enough

- macOS 14 introduced **cooperative activation**. Activation is "a request", and the system weighs "the broader context of what the user is doing". `ignoringOtherApps` is ignored and deprecated. "Only the active application can influence the activation context" by calling `yieldActivation(to:)` ([WWDC23 "What's new in AppKit"](https://developer.apple.com/videos/play/wwdc2023/10054/); SDK `NSRunningApplication.h`: `NSApplicationActivateIgnoringOtherApps API_DEPRECATED("ignoringOtherApps is deprecated in macOS 14 and will have no effect.")`).
- `activate(from:options:)` "doesn't guarantee app activation" ([docs](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:))).
  - A head-tracking agent is never the active app and gets no user input at focus time, so it has no activation context to yield.
- Field reports:
  - AltTab's source (Oct 2026): "The public APIs alone don't move key focus across apps (macOS 14 downgraded NSRunningApplication.activate to an advisory 'request')" ([Window.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/switcher/state/Window.swift)).
  - opta: "Activation is asynchronous, and when it lands the application re-raises its own last key window. Chrome ignores accessibility writes to its main and focused window while it is inactive" ([WindowServerFocus.swift](https://github.com/romankhadka/opta/blob/main/Sources/Opta/WindowServerFocus.swift)).
  - [Developer Forums 739524](https://developer.apple.com/forums/thread/739524): `activateWithOptions` returns false on Sonoma. The accepted workaround is the deprecated Carbon `SetFrontProcessWithOptions`.
- **Conflicting evidence:**
  - Napoleon, an agent-app switcher, says "Since macOS 14, cooperative activation only lets background agents activate other apps" and focuses with public APIs only: unminimize, `AXRaise`, `AXMain=true`, then `NSRunningApplication.activate()`, "verified on macOS 26" ([README](https://github.com/ryekee/Napoleon), [WindowFocuser.swift](https://github.com/ryekee/Napoleon/blob/main/Sources/Napoleon/Windows/WindowFocuser.swift)).
  - mac-taskbar: "Bringing the app to front via AX [`kAXFrontmostAttribute`] works even though our panel never becomes active" ([WindowSource.swift](https://github.com/MeKo-Christian/mac-taskbar/blob/main/Sources/MacTaskbar/WindowSource.swift)).
  - Both are triggered by the user pressing a key or clicking in them. Whether this works with **no** user input to our process is **UNVERIFIED**, so treat it as the fallback.

### 4.2 Mapping CGWindowID to AXUIElement

- **Exact match:** use the private `_AXUIElementGetWindow(AXUIElementRef, CGWindowID *) -> AXError`.
  - Exported by HIServices, in the SDK's `.tbd`, since 10.x. Used by AltTab, Rectangle ([bridging header](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Rectangle-Bridging-Header.h)), Hammerspoon and yabai.
  - Caveat: "_AXUIElementGetWindow answers with the CONTAINING window's id for a descendant", so check `kAXRoleAttribute == kAXWindowRole` (AltTab).
- **Fallback:** match by frame. AX position and size, and CG bounds, share the top-left space, so use a tolerance of a few points.
- AX calls block for up to the messaging timeout on hung apps. Call `AXUIElementSetMessagingTimeout(app, 0.25)` and keep AX work **off the main thread** (AltTab; mac-taskbar INSIGHTS).
- AX sees only the current Space. Tabs share one AX window, so terminal tabs and panes are not separately focusable at window level.

```swift
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func attribute<T>(_ el: AXUIElement, _ name: String, as: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)       // never hang on a beachballing app
        return attribute(app, kAXWindowsAttribute, as: [AXUIElement].self) ?? []
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {   // AX frames are in CG (top-left) space
        guard let posV = attribute(el, kAXPositionAttribute, as: AXValue.self),
              let sizeV = attribute(el, kAXSizeAttribute, as: AXValue.self) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posV, .cgPoint, &p), AXValueGetValue(sizeV, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// CGWindowID -> AXUIElement: exact match via _AXUIElementGetWindow, else nearest frame.
    static func element(forWindow wid: CGWindowID, pid: pid_t, cgFrame: CGRect) -> AXUIElement? {
        let candidates = windows(ofPID: pid).filter {
            (attribute($0, kAXRoleAttribute, as: String.self) ?? "") == (kAXWindowRole as String)
        }
        if let exact = candidates.first(where: { windowID($0) == wid }) { return exact }
        return candidates.min { a, b in
            dist(frame(a), cgFrame) < dist(frame(b), cgFrame)
        }.flatMap { dist(frame($0), cgFrame) < 8 ? $0 : nil }
    }

    private static func dist(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    static func title(_ el: AXUIElement) -> String? { attribute(el, kAXTitleAttribute, as: String.self) }
}
```

### 4.3 How the established tools do it

- **yabai** (`window_manager_focus_window_with_raise`, [window_manager.c](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c)):
  1. `_SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated)`
  2. `window_manager_make_key_window`, which posts a 0xf8-byte record with `[0x04]=0xf8`, `[0x3a]=0x10`, the wid at `0x3c`, the point at `0x20` set to `0xff…` (NaN), and type `0x01` (down) then `0x02` (up) via `SLPSPostEventRecordTo`
  3. `AXUIElementPerformAction(window, kAXRaiseAction)`
  - Constants: `kCPSAllWindows 0x100`, `kCPSUserGenerated 0x200`, `kCPSNoWindows 0x400`. Declarations: `extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode); extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);`
  - yabai's daemon focuses windows from the background with no user input to itself, which is the closest match to this use case.
- **AltTab** (most up to date, Oct 2026, [SkyLight.framework.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/macos/api-wrappers/SkyLight.framework.swift), [Window.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/switcher/state/Window.swift)). It uses the same three steps, with fixes:
  - **Buffer size 0x100** instead of 0xf8, zeroed: "on macOS 14.7.4+ the WindowServer's CGSEncodeEventRecord reads past the record and would otherwise SIGABRT" ([paneru#123](https://github.com/karinushka/paneru/issues/123)).
  - **Mouse-down only**, no up: "measured on macOS 26.5 … the down alone makes the right window key".
  - **Click point (300000, 300000)** instead of NaN. Some apps sanitize NaN to (0,0) and click real content ("Wezterm's first pane", AltTab #5381, which matters for terminals). A point just off the frame hits the resize grab region on macOS 27 (#5900).
  - **Verify after about 150 ms:** "Steps 1 to 3 can all report success and still leave the previous app's window over the target (#6064) … A second raise brought the target forward every time."
  - Mode `0x200` (user-generated) only, so that only the target window comes forward.
- **Hammerspoon** `hs.window:focus()`: sets `AXMain=true` on the window, then calls the deprecated Carbon `SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly)` ([window.lua](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/window/window.lua), [HSuicore.m](https://github.com/Hammerspoon/hammerspoon/blob/master/Hammerspoon/HSuicore.m)). The make-key record trick originates in [Hammerspoon#370](https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468).
- **Rectangle** does not focus by ID. It uses `_AXUIElementGetWindow` and `kAXRaiseAction`.
- **Contexts** is closed source. Its site says it needs Accessibility, and its mechanism is unknown.

Swift-specific notes, checked locally:

- **`GetProcessForPID` and `SetFrontProcessWithOptions` are marked unavailable in Swift** ("APIs deprecated as of macOS 10.9 and earlier are unavailable in Swift"). Declare them with `@_silgen_name` or resolve them with `dlsym`.
- The SDK ships `PrivateFrameworks/SkyLight.framework/SkyLight.tbd` exporting both SLPS symbols, so linking with `-F$(SDK)/System/Library/PrivateFrameworks -framework SkyLight` is possible.
- **Prefer `dlopen`/`dlsym`** so that a missing symbol degrades instead of killing the process at load ([clawd-back](https://github.com/hazel-ocean/clawd-back) comment; opta).
- On this Mac (26.7.1), `dlsym` resolved `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo` and `_AXUIElementGetWindow` (RTLD_DEFAULT), and `GetProcessForPID` returned `noErr`. Resolution was checked only. No focus calls were executed.

### 4.4 Recommended focuser (compiles)

```swift
import AppKit
import ApplicationServices

// Deprecated Carbon call, marked unavailable in Swift; still exported (AltTab/opta use it).
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SkyLight {
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    static let kCPSUserGenerated: UInt32 = 0x200   // 0x100 = all windows, 0x400 = no windows

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let setFrontProcess: SetFrontProcessFn? = {
        guard let h = handle, let s = dlsym(h, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(s, to: SetFrontProcessFn.self)
    }()
    static let postEventRecord: PostEventRecordFn? = {
        guard let h = handle, let s = dlsym(h, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(s, to: PostEventRecordFn.self)
    }()

    /// Make `wid` the key window of its process (AltTab's current layout).
    static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        guard let post = postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8                 // record length
        bytes[0x08] = 0x01                 // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10                 // undocumented flag (yabai/Hammerspoon)
        var w = wid
        withUnsafeBytes(of: &w) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        var pt = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &pt) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        bytes.withUnsafeMutableBufferPointer { _ = post(&psn, $0.baseAddress!) }
    }
}

enum WindowFocuser {
    /// Call OFF the main thread (AX may block up to the messaging timeout).
    static func focus(wid: CGWindowID, pid: pid_t, cgFrame: CGRect) {
        let axWindow = AX.element(forWindow: wid, pid: pid, cgFrame: cgFrame)
        var psn = ProcessSerialNumber()
        if let setFront = SkyLight.setFrontProcess, GetProcessForPID(pid, &psn) == noErr {
            _ = setFront(&psn, wid, SkyLight.kCPSUserGenerated)   // 1. front process + only this window
            SkyLight.makeKeyWindow(&psn, wid)                      // 2. keyboard focus
            if let w = axWindow { AXUIElementPerformAction(w, kAXRaiseAction as CFString) } // 3. raise in app stack
        } else {
            publicFallback(axWindow: axWindow, pid: pid)
        }
        verify(wid: wid, pid: pid, axWindow: axWindow)
    }

    /// Public-API path (Napoleon / mac-taskbar style). Chrome-like apps ignore AX main/focus writes while inactive.
    static func publicFallback(axWindow: AXUIElement?, pid: pid_t) {
        if let w = axWindow {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])   // advisory since 14
    }

    /// AltTab #6064: re-raise once if after ~150 ms the target isn't frontmost/focused.
    static func verify(wid: CGWindowID, pid: pid_t, axWindow: AXUIElement?) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(150)) {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.25)
            let focused = AX.attribute(appEl, kAXFocusedWindowAttribute, as: AXUIElement.self)
            let focusedID = focused.flatMap(AX.windowID)
            if frontPID != pid || focusedID != wid {
                if let w = axWindow { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
                if frontPID != pid { publicFallback(axWindow: axWindow, pid: pid) }
            }
        }
    }
}
```

Notes:

- Run all focus operations on **one serial background queue**, and drop stale requests: if a newer target arrives, skip the older one, as AltTab's `FocusIntents` does.
- If the target app is already frontmost (switching between two iTerm2 windows), the same sequence works. `AXRaise` and `AXMain` alone are usually enough there.
- Accessibility is required for the AX parts and for the global key monitor. Whether the SLPS calls need Accessibility is unverified and doesn't matter, because the app requires Accessibility anyway.
- Private API risk: these symbols have been stable from 10.12 through 26.x, and AltTab tests them on 26.5 and the 27 betas. Keep the `dlsym` fallback.

---

## 5. Overlay window

Apple DTS answered exactly this on [Developer Forums 826308](https://developer.apple.com/forums/thread/826308) (May 2026, tested on macOS 26 over full-screen Safari, QuickTime and YouTube):

1. **Accessory activation policy** (LSUIElement or `setActivationPolicy(.accessory)`): "macOS doesn't layer regular foreground apps above other apps' full-screen Spaces."
2. **`NSPanel` with `.nonactivatingPanel`:** "An NSWindow activates its app when ordered front, which can cause a full-screen app to exit its Space."
3. `level = .screenSaver` (1000): "`.floating` (3) and `.statusBar` (25) both sit below full-screen content."
4. `collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]`. `canJoinAllApplications` is macOS 13+: "allowing it to join other apps' sets and full screen spaces when eligible" (SDK header).

For click-through, add `ignoresMouseEvents = true`. To avoid stealing focus, override `canBecomeKey` and `canBecomeMain` to return `false`, set `hidesOnDeactivate = false`, and use `orderFrontRegardless()`. Create one panel per `NSScreen` and rebuild on `NSApplication.didChangeScreenParametersNotification`.

```swift
import AppKit

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true                 // click-through
        level = .screenSaver                      // .floating/.statusBar sit below full-screen apps
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false                 // we are never the active app
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws highlight + dots. Windows are in CG global coords; convert per panel.
final class OverlayView: NSView {
    var windows: [TrackedWindow] = [] { didSet { needsDisplay = true } }
    var highlightedID: CGWindowID? { didSet { needsDisplay = true } }
    var headPointCG: CGPoint? { didSet { needsDisplay = true } }
    var showDots = true

    override func draw(_ dirtyRect: NSRect) {
        guard let win = window else { return }
        let origin = win.frame.origin                       // AppKit global origin of this panel
        func local(_ cg: CGRect) -> NSRect { appKitRect(fromCG: cg).offsetBy(dx: -origin.x, dy: -origin.y) }
        func local(_ cg: CGPoint) -> NSPoint {
            let p = appKitPoint(fromCG: cg); return NSPoint(x: p.x - origin.x, y: p.y - origin.y)
        }
        for w in windows {
            if w.id == highlightedID {
                let path = NSBezierPath(roundedRect: local(w.frameCG).insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
                path.lineWidth = 4
                NSColor.systemBlue.withAlphaComponent(0.9).setStroke(); path.stroke()
                NSColor.systemBlue.withAlphaComponent(0.08).setFill(); path.fill()
            }
            if showDots {   // white dot with dark rim so it shows on white backgrounds too
                let c = local(w.targetPointCG)
                let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
                NSColor.white.setFill(); dot.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke(); dot.lineWidth = 1.5; dot.stroke()
            }
        }
        if let h = headPointCG {   // live head reticle (feedback; helps users learn to aim with the head)
            let c = local(h)
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24))
            ring.lineWidth = 2; NSColor.systemOrange.setStroke(); ring.stroke()
        }
    }
}
```

Further overlay notes:

- Our panels appear in `CGWindowListCopyWindowInfo` at layer 1000 under our own PID. The enumerator drops them on both counts.
- Redraws: window geometry changes slowly, so redraw on window-list changes (5–10 Hz poll) and on reticle updates (cap at 30 Hz). For smoother rendering, draw the highlight and reticle with `CAShapeLayer`s instead of `draw(_:)`.
- Optionally set `sharingType = .none` so the overlay doesn't show in screen recordings. The header warns that it opts out of some system services.

---

## 6. Global hotkeys without Accessibility

- Carbon **`RegisterEventHotKey`** still works on macOS 26:
  - Nod, a macOS 14+ app, uses it.
  - The [go-macos/hotkey](https://pkg.go.dev/github.com/go-macos/hotkey) author reports registering on 26.6.2 "without any dialog or permission grant".
  - Apple DTS calls the API legacy ("can't honestly recommend it") but has not removed it ([forum 735223](https://developer.apple.com/forums/thread/735223)).
- **macOS 15 change:** "macOS Sequoia now requires that a hotkey registration use at least one modifier that is not shift or option" (Apple engineer, [forum 763878](https://developer.apple.com/forums/thread/763878?page=2)). It was reportedly relaxed in 15.2, with conflicting later reports. **Always include ⌘ or ⌃.**
- `RegisterEventHotKey` does **not** detect conflicts with system shortcuts. It returns `noErr` even if, say, Finder already owns ⌥⌘Space ([go-macos/hotkey](https://pkg.go.dev/github.com/go-macos/hotkey)).

```swift
import Carbon.HIToolbox

final class HotKeys {
    static let shared = HotKeys()
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4146_4F43), id: id) // 'AFOC'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref); actions[id] = action
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            DispatchQueue.main.async { HotKeys.shared.actions[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// ⌃⌥⌘T toggle tracking, ⌃⌥⌘R recentre (both include ⌘/⌃, so Sequoia+ accepts them).
let mods = controlKey | optionKey | cmdKey
HotKeys.shared.register(keyCode: kVK_ANSI_T, modifiers: mods) { /* toggle */ }
HotKeys.shared.register(keyCode: kVK_ANSI_R, modifiers: mods) { /* recentre */ }
```

Link the `Carbon` framework in Package.swift. A separate need: the "typing guard" in §8 watches every keystroke. `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` requires Accessibility, which the app already needs. It observes only and cannot modify events.

---

## 7. Packaging without the Xcode GUI, signing and TCC

### 7.1 SwiftPM layout

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirFocus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirFocus",
            swiftSettings: [.swiftLanguageMode(.v5)],   // see note
            linkerSettings: [
                .linkedFramework("AppKit"), .linkedFramework("CoreMotion"),
                .linkedFramework("Carbon"), .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreAudio"), .linkedFramework("IOKit"),   // IOKit: §9 IOPM calls
            ]
        ),
    ]
)
```

- The local toolchain is **Swift 6.4 with the macOS 27 SDK**. In Swift 6 language mode, the snippets above fail only on two "static property is not concurrency-safe" errors: `SkyLight.handle` and `HotKeys.shared`. Either mark them `nonisolated(unsafe)` or `@MainActor`, or use Swift 5 mode.
- Swift 5 mode compiled everything cleanly here.
- Create the app with `NSApplication.shared`, set `delegate`, and call `app.run()` in `main.swift`. Call `NSApp.setActivationPolicy(.accessory)` as well as setting LSUIElement.

### 7.2 Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.gshimoon.airfocus</string>
  <key>CFBundleName</key><string>AirFocus</string>
  <key>CFBundleDisplayName</key><string>AirFocus</string>
  <key>CFBundleExecutable</key><string>AirFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMotionUsageDescription</key>
  <string>AirFocus reads your AirPods head orientation to focus the window you are facing. Nothing is recorded or sent.</string>
</dict>
</plist>
```

- No Screen Recording key is needed.
- Accessibility has no usage-description key in TCC. The system shows its own dialog.

### 7.3 Build, bundle, sign and launch

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="com.gshimoon.airfocus"
APP="build/AirFocus.app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/AirFocus"
pkill -x AirFocus || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirFocus"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer a real identity (stable DR = identifier + Apple anchor + team), else ad-hoc with an explicit DR.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  codesign --force --options runtime --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP"          # print the designated requirement (must NOT be a cdhash)
open "$APP"                     # launch via LaunchServices so TCC attributes permissions to the app
```

### 7.4 The TCC problem and how to fix it

- TCC keys a grant to the app's **designated requirement** (DR):
  - An ad-hoc signature's DR is `cdhash H"…"`, which changes on every build.
  - The grant silently stops applying.
  - The toggle can still show as on.
  - Sources: [posture README](https://github.com/einargudnig/posture), [sunna#1](https://github.com/SunnyXdm/sunna/issues/1), [parley#75](https://github.com/pathorsAI/parley/issues/75).
  - Checked locally: plain `codesign -s -` produced `designated => cdhash H"5a92…"`, while `--requirements '=designated => identifier "…"'` produced `designated => identifier "…"`, and `codesign --verify --strict` passed.
- **Fixes, best first:**
  1. **Sign with the Apple Development identity already in this Mac's login keychain.** `security find-identity -v -p codesigning` lists 3 valid identities here, 2 of them "Apple Development". The DR becomes identifier plus Apple anchor plus team, which is stable across rebuilds ([sixthsense#29](https://github.com/LucasStop/sixthsense/pull/29), [memo-collector#31](https://github.com/ysogabe/memo-collector/pull/31)). No provisioning profile is needed, because the app uses no restricted entitlements.
  2. **Ad-hoc with an explicit identifier-only DR:** `codesign --force --sign - --requirements '=designated => identifier "<bundle id>"' App.app`. Used by [Nod](https://github.com/ydisli/nod/blob/main/scripts/build-app.sh) ("pin the requirement to the bundle identifier instead"), [Microsoft ZoomIt-Mac](https://github.com/microsoft/Zoomit-Mac) ("keeps local TCC grants stable across rebuilds without using a signing certificate"), [Wox](https://github.com/Wox-launcher/Wox) and [cmux](https://github.com/manaflow-ai/cmux). It is weaker, since any binary claiming that identifier passes, so use it only for local builds. Apple doesn't document it, but it is widely used.
  3. **Self-signed code-signing certificate**, created in Keychain Access › Certificate Assistant › Create a Certificate (type "Code Signing") or with `/usr/bin/openssl` plus `security import`. The DR becomes `identifier "<id>" and certificate leaf = H"…"` ([dotnix#238](https://github.com/NoSugarCoffee/dotnix/pull/238)). If importing a `.p12` made with Homebrew OpenSSL 3, use `-legacy`. macOS `security import` can't read OpenSSL 3's default PKCS#12 encryption. **UNVERIFIED here.**
- **Switching identity** invalidates existing grants once: `tccutil reset Accessibility <id>; tccutil reset Motion <id>` and re-grant. If System Settings shows the app enabled but it still isn't trusted, remove it with "−" and add it again (Nod README).
- **Launch with `open`.** If the binary inside the bundle is exec'd from Terminal or iTerm, TCC treats **the terminal** as the responsible process: prompts and grants go to iTerm or Terminal. `open` makes launchd the parent and the app responsible ([Qt blog, "The Curious Case of the Responsible Process"](https://www.qt.io/blog/the-curious-case-of-the-responsible-process)). This machine's terminal already has Screen Recording (`CGPreflightScreenCaptureAccess() == true` from a shell-run probe), which would mask permission bugs during testing.
- Keep the app at **one stable path**, e.g. `build/AirFocus.app` or `~/Applications`. Copying it around can create duplicate entries in Privacy settings.
- **Does Motion work for an ad-hoc bundle? Yes.** airtracker, airpod-pose-estimate, head-position-tracker, PostureFix, BlindSamurai and Nod all ship ad-hoc builds that get the Motion & Fitness prompt and data. Unbundled binaries get nothing.
- Poll `AXIsProcessTrusted()` about once a second after prompting, rather than assuming a relaunch. Offer a "Relaunch" menu item in case the trust state is cached. **UNVERIFIED on 26.**

---

## 8. Mapping head orientation to a target window

### 8.1 What the human and the sensor give you

- **Head motion is smaller than gaze shifts.** In eye-head coordination studies, the head "contributes little or nothing to gaze shifts smaller than about 20–25°". Above that, its share grows roughly linearly ([PMC1890377](https://pmc.ncbi.nlm.nih.gov/articles/PMC1890377), [PMC3191847](https://pmc.ncbi.nlm.nih.gov/articles/PMC3191847)).
  - A 27-inch display at 60 cm spans only about ±25°. Switching between adjacent terminals may involve just a few degrees of head yaw unless users deliberately aim "with the nose".
  - Nod's absolute-aim mode maps about **20° of yaw and 12.6° of pitch** to a full display (`headTravel = (0.35, 0.22)` rad), with vertical travel floored to `0.8 × aspect × horizontal`.
  - Consequences:
    - **Calibrate per user**, with the user deliberately pointing.
    - **Show a live head reticle** so users learn the gesture.
    - Expect a pitch range smaller than the yaw range.
- **Signal:** about 25 Hz (§1.4), with smooth fused attitude, small jitter and variable Bluetooth latency.

### 8.2 Per-window anchors with nearest neighbour, or a fitted map?

| Approach | Pros | Cons |
|---|---|---|
| Per-window anchor: store (yaw, pitch) per window, pick the nearest | Trivial; works with any non-linearity; good for a fixed set of terminals | **Breaks when windows move, resize, open or close**; needs recalibration per layout; ambiguous between anchors |
| **Fitted map from (yaw, pitch) to screen (x, y)** (affine least squares, optionally quadratic), then hit-test the visible windows | Survives layout changes and new windows; one-point recentring fixes drift; gives a reticle for feedback; works across monitors in one global CG space | Needs at least 3 non-collinear points (affine) or at least 6 (quadratic); about 10% non-linearity at ±30° (tan versus angle) |

**Recommendation:** fit an **affine map** from the window-dot calibration. Hit-test the predicted point against the visible windows, front to back. Use the per-window anchors only to disambiguate when the point falls in a gap (nearest dot within about 4° in angle space).

- If the calibration dots are nearly collinear vertically (all windows in a row, y spread under about 15% of the screen height), add a top-centre and a bottom-centre calibration point. Ridge regularisation keeps the fit stable either way.
- Upgrade to a quadratic fit only with 8 or more points and a cross-validated improvement.

```swift
struct CalibrationSample { let yaw: Double; let pitch: Double; let screen: CGPoint } // degrees, CG coords

/// Least-squares affine map: x = a0 + a1*yaw + a2*pitch, y = b0 + b1*yaw + b2*pitch
struct AffineHeadMap: Codable {
    var a: [Double]; var b: [Double]

    static func fit(_ s: [CalibrationSample], ridge: Double = 1e-6) -> AffineHeadMap? {
        guard s.count >= 3 else { return nil }
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var atx = [0.0, 0.0, 0.0], aty = [0.0, 0.0, 0.0]
        for p in s {
            let r = [1.0, p.yaw, p.pitch]
            for i in 0..<3 {
                for j in 0..<3 { ata[i][j] += r[i] * r[j] }
                atx[i] += r[i] * Double(p.screen.x); aty[i] += r[i] * Double(p.screen.y)
            }
        }
        for i in 1..<3 { ata[i][i] += ridge }
        guard let a = solve3(ata, atx), let b = solve3(ata, aty) else { return nil }
        return AffineHeadMap(a: a, b: b)
    }

    func point(yaw: Double, pitch: Double) -> CGPoint {
        CGPoint(x: a[0] + a[1] * yaw + a[2] * pitch, y: b[0] + b[1] * yaw + b[2] * pitch)
    }

    /// One-point recalibration (drift / after reconnect): shift so the current pose maps onto `target`.
    mutating func recenter(yaw: Double, pitch: Double, onto target: CGPoint) {
        let p = point(yaw: yaw, pitch: pitch)
        a[0] += Double(target.x - p.x); b[0] += Double(target.y - p.y)
    }

    private static func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
        var A = m, y = v
        for c in 0..<3 {
            guard let piv = (c..<3).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[piv][c]) > 1e-12 else { return nil }
            A.swapAt(c, piv); y.swapAt(c, piv)
            for r in 0..<3 where r != c {
                let f = A[r][c] / A[c][c]
                for k in c..<3 { A[r][k] -= f * A[c][k] }
                y[r] -= f * y[c]
            }
        }
        return (0..<3).map { y[$0] / A[$0][$0] }
    }
}
```

### 8.3 Calibration procedure

1. Snapshot the visible windows and freeze the layout during calibration. Show every dot dimmed and the current one bright, with a progress ring.
2. For each dot:
   1. Wait until the head has **settled**: gyro magnitude below 10°/s for 300 ms.
   2. **Average 500 ms** of yaw and pitch (about 12 samples at 25 Hz).
   3. Reject and retry if the standard deviation exceeds about 1°.
   4. Auto-advance.
   5. Also accept a hotkey to skip or confirm.
3. Fit `AffineHeadMap`. Report the residual RMS in points and in degrees. If the RMS is more than about 30% of the median window width, warn and suggest pointing "with your nose".
4. Persist the samples and the map in UserDefaults, keyed by display configuration (display IDs and frames).
5. **Recalibrate or Reset:** the menu offers "Recenter" (one point, on the focused window's dot) and "Reset" (clear the map and start full calibration).

### 8.4 Smoothing: the 1€ filter

- Use the 1€ filter on yaw and pitch in degrees ([Casiez et al., CHI 2012](https://gery.casiez.net/1euro/)). Tuning procedure: set β = 0, lower `minCutoff` until jitter at rest is acceptable, then raise β until fast moves don't lag.
- Defaults for this signal: **`minCutoff = 1.0 Hz`, `β = 0.05` per (°/s), range 0.02–0.2, `dCutoff = 1.0 Hz`**.
  - At rest this is about a 160 ms time constant at 25 Hz.
  - At a 40°/s turn the cutoff is about 3 Hz.
  - Nod's default ("smoothing 0.5") works out to `minCutoff ≈ 1.67 Hz` and `β ≈ 0.16 per °/s`, tuned for a fast pointer. Window targeting can afford heavier smoothing.
- Use the raw gyro `rotationRate` magnitude, not the filtered angle derivative, for "is the head moving" checks. It has lower latency.

```swift
struct OneEuroFilter {
    var minCutoff: Double, beta: Double, dCutoff: Double
    private var x: Double?, dx = 0.0, t: Double?
    init(minCutoff: Double = 1.0, beta: Double = 0.05, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }
    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double { let tau = 1 / (2 * .pi * cutoff); return 1 / (1 + tau / dt) }
    mutating func reset() { x = nil; t = nil; dx = 0 }
    mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let px = x, let pt = t else { x = value; t = time; return value }
        let dt = max(time - pt, 1e-3)
        dx += Self.alpha(dCutoff, dt) * ((value - px) / dt - dx)
        let out = px + Self.alpha(minCutoff + beta * abs(dx), dt) * (value - px)
        x = out; t = time
        return out
    }
}
```

### 8.5 Dwell, hysteresis, cooldown and the typing guard

Evidence on dwell:

- [Hansen, MacKenzie et al., ETRA 2018](https://www.yorku.ca/mack/etra2018.html) used a **300 ms dwell** for head pointing in a Fitts study. Head and gaze were equally fast, and dwell beat click activation. They did not sweep dwell times.
- Gaze typing performed best at **500 ms** ([JEMR](https://doaj.org/article/6d92a0b817294c339b2c8db859dd6dab)).
- **EyeWindows** (Fono and Vertegaal, CHI 2005, [record](https://api.openalex.org/works/doi:10.1145/1054972.1054994)) is the closest prior art: gaze-selected window focus during a typing task.
  - Automatic gaze activation was about 2× faster than mouse or hotkeys.
  - Key-activated gaze was about 72% faster than manual methods and **preferred by most participants**.
  - So offer both modes.

A wrong focus here sends keystrokes to the wrong agent, which costs more than a missed switch. Bias toward conservative defaults:

| Parameter | Default | Range | Rationale |
|---|---|---|---|
| Dwell (candidate must win continuously) | **450 ms** | 250–800 ms | Between 300 ms (head-pointing study) and 500 ms (gaze typing) |
| Settled-head gate | gyro < **25°/s** | 15–40 | Don't switch mid-turn (engineering estimate) |
| Hysteresis | current window's hit area **expanded by max(40 pt, 8% of its size)** | | Prevents flicker at shared edges |
| Cooldown between switches | **600 ms** | 300–1000 | Avoids ping-pong |
| Typing guard: no switch within … of the last keyDown | **700 ms** | 300–1500 | Never steal focus mid-word. Global `.keyDown` monitor (Accessibility). |
| Keyboard-glance reject | pitch **> 10° below the lowest calibrated pitch** → no target | | Looking down at the keys must not retarget. Nod notes glancing at the keyboard looks like a nod. |
| Off-screen reject | predicted point **> 150 pt outside every screen** → no target | | |
| Gap handling | nearest dot within **4°** (in angle space via the inverse map), else none | | |
| Manual mode | hotkey focuses the window under the reticle immediately | | EyeWindows' preferred mode |
| External focus change (click or ⌘-Tab) | adopt it as `current` | | `NSWorkspace.didActivateApplicationNotification` plus the AX focused window |

```swift
struct TargetSelector {
    var dwell: TimeInterval = 0.45
    var maxSpeedDegPerSec = 25.0
    var stickyInsetPoints: CGFloat = -40      // negative inset = grow current window's hit area
    var cooldown: TimeInterval = 0.6
    var typingHold: TimeInterval = 0.7

    private(set) var current: CGWindowID?
    private var candidate: CGWindowID?
    private var candidateSince: TimeInterval = 0
    private var lastSwitch: TimeInterval = -.infinity

    mutating func update(point: CGPoint, speed: Double, now: TimeInterval, lastKeyDown: TimeInterval,
                         windows: [TrackedWindow]) -> CGWindowID? {
        if let cur = current, let w = windows.first(where: { $0.id == cur }),
           w.frameCG.insetBy(dx: stickyInsetPoints, dy: stickyInsetPoints).contains(point) {
            candidate = nil; return nil
        }
        let hit = windows.first(where: { $0.frameCG.contains(point) })?.id   // front-to-back
        guard let hit, hit != current else { candidate = nil; return nil }
        if hit != candidate { candidate = hit; candidateSince = now; return nil }
        guard now - candidateSince >= dwell, speed <= maxSpeedDegPerSec,
              now - lastSwitch >= cooldown, now - lastKeyDown >= typingHold else { return nil }
        current = hit; lastSwitch = now; candidate = nil
        return hit
    }
    mutating func noteExternalFocus(_ id: CGWindowID?) { current = id }
}
```

### 8.6 Yaw drift and recentring strategy

1. **Explicit:** a hotkey (⌃⌥⌘R) runs `AffineHeadMap.recenter(…onto: focusedWindow.targetPointCG)`. The user looks at the focused window's dot and presses it. It is a one-point offset, so the layout calibration is kept.
2. **Implicit, self-calibration from interaction:** this follows WebGazer's "self-calibration from clicks and cursor movements" ([webgazer](https://webgazer.cs.brown.edu/)).
   - Trigger: the user is typing into the focused window W, the head has been settled for 1.5 s or more, and the predicted point lies outside W but within one window-width of it.
   - Action: nudge the offset 10–20% of the way toward W's dot, capped at about 0.5° per event.
   - This absorbs slow drift without user action. **UNVERIFIED heuristic.**
3. **After a reconnect, `referenceJump`, or `restartMotion()`:** the yaw zero is arbitrary again.
   - Mark the map "yaw-unanchored" and do a full yaw recentre (offset only) at the first implicit event above.
   - Or show a "Look at the highlighted window and press ⌃⌥⌘R" hint.
   - Pitch is gravity-referenced and usually survives, except across bud swaps, which §1.8 re-bases.
4. Don't use airtracker-style constant "pull to centre". It fights deliberate long holds on off-centre windows.
5. Measure the actual drift on the user's AirPods (°/min with the head still) before tuning items 2 and 3.

---

## 9. Look-away screen saver and wake-to-unlock

The feature:

- When the user clearly looks away from the screens for more than 5 s, start the screen saver.
- When they look back, wake the display so the **standard** macOS unlock prompt (password or Touch ID) appears.
- The user authenticates themselves. The app never types, stores or automates credentials, and never changes lock settings.

The closest open-source precedent is [BLEUnlock](https://github.com/ts1/BLEUnlock), which starts the screen saver or locks when a phone leaves and wakes the display when it returns. Its auto-typing of the password is exactly what this app must **not** do.

### 9.1 Starting the screen saver, locking, and the password setting

| Method | What it does | Status on macOS 26 | Verdict |
|---|---|---|---|
| `NSWorkspace.shared.openApplication(at: /System/Library/CoreServices/ScreenSaverEngine.app)` | LaunchServices starts the engine, which runs the user's chosen screen saver | The path exists on this Mac (bundle ID `com.apple.ScreenSaver.Engine`). BLEUnlock does the same through the deprecated `launchApplication("ScreenSaverEngine")` ([AppDelegate.swift](https://github.com/ts1/BLEUnlock/blob/master/BLEUnlock/AppDelegate.swift)). No Sonoma–Tahoe confirmation was found online, so **test it**. | **Primary.** Public and needs no permission. |
| `open -a ScreenSaverEngine` (via `Process`) | Same as above through `/usr/bin/open` | Same; a widely cited CLI ([gist](https://gist.github.com/hex2010/d7848d9912a608e11bce3146bcd4068e)) | Equivalent. Prefer the in-process `NSWorkspace` call. |
| `SACScreenSaverStartNow()`, private `login.framework` | Asks loginwindow to start the screen saver | Symbol resolves on 26.7.1 (`dlsym`, not called). Signature `OSStatus SACScreenSaverStartNow()` per [Chromium login_util.cc](https://github.com/chromium/chromium/blob/main/base/mac/login_util.cc) | Fallback if the launch fails |
| `SACLockScreenImmediate()`, private `login.framework` | **Locks now**, regardless of the password-delay setting. This is what the Apple menu's Lock Screen and Keychain Access call ([timac.org](https://blog.timac.org/2016/0605-programmatically-lock-the-screen/)). BLEUnlock uses it as `int SACLockScreenImmediate(void)` and checks `!= 0`. | Symbol resolves on 26.7.1 (not called). Used by [sindresorhus/macos-lock](https://github.com/sindresorhus/macos-lock) and BLEUnlock. | Reasonable as an **opt-in "Lock immediately when I look away"** option. It is private, so use `dlsym` and fall back to the screen saver. |
| `pmset displaysleepnow` | Turns the displays off; locking then follows the same "…or display is turned off" password rule | A user on Big Sur rejected it as "dependent on user preferences" ([forum 682918](https://developer.apple.com/forums/thread/682918)) | Not needed. Use it only if the user wants a dark screen instead of the screen saver. |
| AppleScript `tell application "System Events" to start current screen saver` | Same effect | Needs an Automation (Apple Events) TCC grant | Avoid. It adds another permission. |

**How the password setting decides whether a lock happens:**

- System Settings › Lock Screen › "**Require password after screen saver begins or display is turned off**" ("Lock your Mac when it's left in an idle state"). The user picks "the amount of time after the screen saver or sleep begins before a password is required" ([Apple Support](https://support.apple.com/guide/mac-help/change-lock-screen-settings-mh11784/mac)).
  - **Immediately:** starting the screen saver locks the session at once.
  - **A delay** (for example 5 minutes): looking back within the delay just dismisses the screen saver with no password.
  - **Never:** there is no lock at all.
- `SACLockScreenImmediate` ignores the delay.

**Can the app read the setting? Yes, two ways, both verified read-only on this Mac:**

1. `sysadminctl -screenLock status` is a public CLI and needs no admin rights. It prints, **on stderr**: `screenLock delay is immediate`. Other values are `… is N seconds`, or an "off" message whose exact wording is **unverified**. Setting the value requires a password, and the app must never set it.
2. Private `Boolean SACScreenLockEnabled()` returned `true` here ([Chromium](https://github.com/chromium/chromium/blob/main/base/mac/login_util.cc) uses it as `IsScreenLockEnabled()`).

The legacy `com.apple.screensaver askForPassword`/`askForPasswordDelay` defaults are **not** reliable since 10.13 ([SI tech blog](https://technology.siprep.org/askforpassword-and-askforpassworddelay-in-macos-10-13-high-sierra/)). The domain does not exist on this Mac.

**Product decision:** if the delay is not "immediately", look-away only hides the screen. Show this in the menu, e.g. "Screen locks after 5 min (System Settings)". Offer the opt-in `SACLockScreenImmediate` mode, and never modify the system setting.

### 9.2 Waking so the unlock prompt appears

| Method | Effect | Evidence | Use |
|---|---|---|---|
| `IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &id)` (= `caffeinate -u`) | "causes the display to power on and postpone display sleep… No special privileges are necessary" (SDK `IOPMLib.h`) | BLEUnlock's `wakeDisplay()`, retried every second until `screensDidWakeNotification` ([lowlevel.c](https://github.com/ts1/BLEUnlock/blob/master/BLEUnlock/lowlevel.c)); [sill#144](https://github.com/Saffsanity/sill/pull/144) | **Always**, for display sleep. Not documented to stop a running screen saver. |
| `SACScreenSaverStopNow()`, private | Asks loginwindow to stop the screen saver. If the session is locked, the unlock UI should take its place. | Signature `OSStatus SACScreenSaverStopNow()` per Chromium; resolves on 26.7.1. **UNVERIFIED** that it reveals the unlock UI. | **Yes**, when `SACScreenSaverIsRunning()` is true or the session is locked |
| Synthetic `CGEvent` **mouse move** to the current cursor position, posted at `.cghidEventTap` with a `.hidSystemState` source | Counts as user input, so the screen saver ends and loginwindow shows its prompt | BLEUnlock dismisses a running screen saver with a synthetic **key** posted at the HID tap "to show login panel"; its issue [#25](https://github.com/ts1/BLEUnlock/issues/25) proposes a mouse move as the side-effect-free variant. A very old [CocoaDev report](https://cocoadev.github.io/StopScreensaver/) says some synthetic moves did not stop the screen saver. Needs Accessibility, which the app already has. | **Yes**, as a belt-and-braces nudge. **UNVERIFIED on 26**, so test it. |
| Synthetic **key** (Shift, Esc) or `flagsChanged` | Dismisses the screen saver | BLEUnlock switched from Shift to Esc after Shift **toggled the CJK input method** ([#21](https://github.com/ts1/BLEUnlock/issues/21)). An Esc that arrives after the screen saver has already stopped goes to the frontmost app, and **Esc interrupts Claude Code**. | **No.** |
| `caffeinate -u` (CLI) | The same assertion as `IOPMAssertionDeclareUserActivity` | `caffeinate(8)` | Use the API directly instead |

**Once the session is locked and the loginwindow shield is up:**

- Our process keeps running; it is still the console session.
- Waking the display shows the normal lock screen with password and Touch ID. BLEUnlock relies on this.
- Synthetic events reach the screen saver and lock UI on at least older systems, which is how BLEUnlock types passwords. There are reports that this stopped working on Sequoia ([#140](https://github.com/ts1/BLEUnlock/issues/140)), which doesn't matter here because nothing is typed.
- The shield is above every app window level, so our overlay can't cover it.
- **But the overlay at `.screenSaver` level (1000) can draw *over a running screen saver*.** Hide the overlay panels on `com.apple.screensaver.didstart` and show them again after unlock.

### 9.3 Head motion during the screen saver and lock; detecting state

- **Motion delivery while the screen saver runs or the screen is locked: no source was found, so it is UNVERIFIED.**
  - Factors for: our process keeps running; Dorso had to pause its camera explicitly on lock ("Auto-pause when screen locks", [CHANGELOG](https://github.com/tldev/dorso/blob/main/CHANGELOG.md)), which shows apps keep running; and AirPods stay the audio route while locked.
  - Factors against:
    - The route can hop to the iPhone (auto-switching) while the Mac is idle.
    - **System sleep stops everything.** This Mac reports `pmset sleep 1`, though sleep is currently prevented by other assertions.
    - The stall watchdog restarts the stream, and a restart **resets the yaw reference**.
- **Design for motion stopping:**
  1. While "away", optionally hold `kIOPMAssertPreventUserIdleSystemSleep`, which keeps the Mac (not the display) awake so return detection can work. Make it a setting, default **on only on AC power**, and release it on unlock.
  2. If no samples arrive while away, do nothing. The user wakes the Mac the normal way (key, trackpad, Touch ID). Never treat "no data" as "looked back".
  3. If the stream restarted while away, the yaw zero is arbitrary. Mark yaw "unanchored" and use only the gravity-referenced **pitch** test (pitch inside the screen band, head settled) for "looked back", because a false wake only shows the lock screen. After unlock, require a recentre (§8.6).
  4. **Disable window focusing and synthetic events** whenever the screen saver is running or the session is locked, except for the single wake attempt.
- **Detecting state.** These distributed notifications are not documented API, but Chromium's current `ui/base/idle/idle_mac.mm` ([source](https://github.com/chromium/chromium/blob/main/ui/base/idle/idle_mac.mm)), BLEUnlock and Dorso all use them:
  - `com.apple.screensaver.didstart`, `com.apple.screensaver.didstop`
  - `com.apple.screenIsLocked`, `com.apple.screenIsUnlocked`
  - Public: `NSWorkspace.screensDidSleepNotification` and `screensDidWakeNotification`, `willSleepNotification` and `didWakeNotification`.
  - Polling:
    - `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` (public function, undocumented key, **absent when unlocked**, verified here).
    - Private `SACScreenSaverIsRunning()`, which returned `false` here.
    - `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` gives keyboard and mouse idle time (public, no permission).

### 9.4 What "clearly looking away" means

The aim is to catch walking off or turning to talk to someone, while ignoring glances at the keyboard, a phone, notes or a second, uncalibrated screen. The envelope below is the calibrated screen area in head angles: invert the affine map at every screen's corners and take the bounding box.

| Parameter | Default | Rationale |
|---|---|---|
| Sideways | yaw **> 30° beyond** the left or right envelope edge | Eye-head coordination: the head only does much of the work for gaze shifts above about 20–25° (§8.1). A 30° head turn past the edge means the gaze is far off-screen. It also absorbs a few degrees of yaw drift. |
| Up | pitch **> 25° above** the top edge | Looking at the ceiling or a person standing |
| Down | **ignored by default.** Optional: **> 45° below** the bottom edge **and** held 15 s | Asymmetric. Keyboard, phone and notes are all below the screen, and long downward reading is normal desk behaviour. |
| Hold | **5 s continuous** (the user's spec). Brief returns under 0.3 s don't reset the timer. | Filters quick glances |
| Input veto | **No keyboard, mouse or trackpad input in the last 5 s** | Someone typing while looking at notes or a side screen is present. This is the strongest false-positive guard, and it's cheap. |
| Look back | inside the envelope grown by **10°**, head settled (gyro < about 30°/s), for **0.6 s** | Deliberate return. A false wake costs only a lit lock screen. |
| Wake retries | at most once per **10 s**, and only while `displayAsleep \|\| screenSaverRunning` | Don't spam; the prompt may already be up |
| Second display | **Every display the user looks at must be inside the calibration** | Otherwise looking at the uncalibrated one counts as away. Warn when the calibration doesn't cover all `NSScreen.screens`. |
| AirPods disconnect or out of ear | **Not counted by default.** Option: "Treat removing AirPods as away", after 10 s, with the same input veto. | People take AirPods out at their desks. Reconnecting is **never** a wake trigger on its own: the yaw reference is new, so only the pitch test from §9.3 applies. |
| Prerequisites | Tracking running, calibrated map present, Accessibility granted (for the mouse nudge) | Otherwise disable the feature and show why |

The sequence:

1. Present.
2. Away: start the screen saver, hide the overlay, pause focusing, optionally prevent idle system sleep.
3. Look back: wake.
4. User unlocks (`com.apple.screenIsUnlocked`), or the screen saver stops with the session unlocked.
5. Reset the detector, restore the overlay, recentre or implicitly recalibrate yaw.

### 9.5 Code (compiles; hardware-untested)

```swift
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

// Private login.framework entry points (resolved at runtime; all optional).
// Signatures as documented in Chromium's base/mac/login_util.cc.
enum LoginFramework {
    typealias StatusFn = @convention(c) () -> OSStatus
    typealias BoolFn = @convention(c) () -> DarwinBoolean
    private static let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY)
    private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }
    static let screenSaverStartNow  = fn("SACScreenSaverStartNow", StatusFn.self)
    static let screenSaverStopNow   = fn("SACScreenSaverStopNow", StatusFn.self)
    static let screenSaverIsRunning = fn("SACScreenSaverIsRunning", BoolFn.self)
    static let screenLockEnabled    = fn("SACScreenLockEnabled", BoolFn.self)    // "require password" on?
    static let lockScreenImmediate  = fn("SACLockScreenImmediate", StatusFn.self) // optional "lock now"
}

enum ScreenSaverControl {
    static let engineURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    /// Public path first (LaunchServices launch of ScreenSaverEngine), private fallback.
    static func start() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: engineURL, configuration: cfg) { app, error in
            if app == nil { _ = LoginFramework.screenSaverStartNow?() }
        }
    }

    /// Optional, user-enabled: lock immediately regardless of the password-delay setting.
    static func lockNow() -> Bool { (LoginFramework.lockScreenImmediate?() ?? -1) == 0 }

    private static var activityAssertion: IOPMAssertionID = 0

    /// Wake the display and dismiss the screen saver so loginwindow shows its normal
    /// password / Touch ID prompt. NEVER types anything.
    static func wakeForUnlock() {
        // 1. Documented: "causes the display to power on". No special privileges needed.
        _ = IOPMAssertionDeclareUserActivity("AirFocus: user looked back" as CFString,
                                              kIOPMUserActiveLocal, &activityAssertion)
        // 2. Screen saver still animating? Ask loginwindow to stop it (private, optional) and
        //    nudge with a zero-distance synthetic mouse move (needs Accessibility, which we have).
        if isScreenSaverRunning || isScreenLocked {
            _ = LoginFramework.screenSaverStopNow?()
            let here = CGEvent(source: nil)?.location ?? .zero
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: here,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    static var isScreenSaverRunning: Bool { LoginFramework.screenSaverIsRunning?().boolValue ?? false }

    /// Public CGSession dictionary; the key is absent when unlocked (BLEUnlock pattern).
    static var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) == 1)
    }

    /// Seconds since the last keyboard/mouse/trackpad event in this session (public, no permission).
    static var secondsSinceUserInput: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// "Require password after screen saver begins or display is turned off".
    /// nil = unknown, 0 = immediately, n = seconds, .infinity = off. Run off the main thread.
    static func passwordDelaySeconds() -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        p.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        p.standardError = pipe          // sysadminctl logs via NSLog -> stderr
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("delay is immediate") { return 0 }
        if out.contains("screenLock is off") { return .infinity }       // exact "off" wording UNVERIFIED
        if let r = out.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) {
            return Double(out[r].split(separator: " ")[2])
        }
        return nil
    }
}

/// Screen saver / lock / display state from distributed + workspace notifications.
final class SessionStateObserver {
    private(set) var screenSaverRunning = false
    private(set) var screenLocked = false
    private(set) var displayAsleep = false
    var onChange: (() -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        add(dnc, "com.apple.screensaver.didstart") { $0.screenSaverRunning = true }
        add(dnc, "com.apple.screensaver.didstop")  { $0.screenSaverRunning = false }
        add(dnc, "com.apple.screenIsLocked")       { $0.screenLocked = true }
        add(dnc, "com.apple.screenIsUnlocked")     { $0.screenLocked = false }
        add(wnc, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displayAsleep = true }
        add(wnc, NSWorkspace.screensDidWakeNotification.rawValue)  { $0.displayAsleep = false }
        screenLocked = ScreenSaverControl.isScreenLocked
        screenSaverRunning = ScreenSaverControl.isScreenSaverRunning
    }

    private func add(_ nc: NotificationCenter, _ name: String, _ apply: @escaping (SessionStateObserver) -> Void) {
        let t = nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            apply(self); self.onChange?()
        }
        tokens.append((nc, t))
    }

    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }
}

/// The calibrated screen area expressed in head angles (degrees).
struct AngleEnvelope { var yawMin: Double; var yawMax: Double; var pitchMin: Double; var pitchMax: Double }

extension AffineHeadMap {
    /// Inverse of the affine map (§8.2): screen point -> (yaw, pitch).
    func angles(for p: CGPoint) -> (yaw: Double, pitch: Double)? {
        let det = a[1] * b[2] - a[2] * b[1]
        guard abs(det) > 1e-9 else { return nil }
        let x = Double(p.x) - a[0], y = Double(p.y) - b[0]
        return ((b[2] * x - a[2] * y) / det, (-b[1] * x + a[1] * y) / det)
    }

    /// Bounding box, in head angles, of every screen's corners (pass all NSScreen frames in CG space).
    func envelope(screensCG: [CGRect]) -> AngleEnvelope? {
        let corners = screensCG.flatMap { [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.minY),
                                           CGPoint(x: $0.minX, y: $0.maxY), CGPoint(x: $0.maxX, y: $0.maxY)] }
        let angs = corners.compactMap { angles(for: $0) }
        guard !angs.isEmpty else { return nil }
        return AngleEnvelope(yawMin: angs.map(\.yaw).min()!, yawMax: angs.map(\.yaw).max()!,
                             pitchMin: angs.map(\.pitch).min()!, pitchMax: angs.map(\.pitch).max()!)
    }
}

struct LookAwayDetector {
    enum Action { case startScreenSaver, wakeForUnlock }

    var yawMargin = 30.0                 // beyond left/right edge
    var pitchUpMargin = 25.0             // above top edge
    var countLookingDown = false         // looking down never counts by default
    var pitchDownMargin = 45.0           // only if countLookingDown
    var awayHold: TimeInterval = 5.0     // continuous
    var downAwayHold: TimeInterval = 15.0
    var flickerTolerance: TimeInterval = 0.3
    var minInputIdle: TimeInterval = 5.0 // any keyboard/mouse use in the last 5 s = present
    var backMargin = 10.0
    var backHold: TimeInterval = 0.6
    var wakeRetryInterval: TimeInterval = 10

    private(set) var isAway = false
    private var awaySince: TimeInterval?
    private var lastOutside: TimeInterval = -.infinity
    private var backSince: TimeInterval?
    private var lastWake: TimeInterval = -.infinity

    mutating func reset() { isAway = false; awaySince = nil; backSince = nil }

    /// Feed every filtered pose. `settled` = gyro < ~30°/s. `inputIdle` = ScreenSaverControl.secondsSinceUserInput.
    mutating func update(yaw: Double, pitch: Double, settled: Bool, now: TimeInterval,
                         env: AngleEnvelope, inputIdle: TimeInterval) -> Action? {
        let left = env.yawMin - yaw, right = yaw - env.yawMax
        let up = pitch - env.pitchMax, down = env.pitchMin - pitch
        let sideways = max(left, right) > yawMargin
        let upward = up > pitchUpMargin
        let downward = countLookingDown && down > pitchDownMargin

        if !isAway {
            if (sideways || upward || downward) && inputIdle >= minInputIdle {
                lastOutside = now
                if awaySince == nil { awaySince = now }
                let hold = (downward && !sideways && !upward) ? downAwayHold : awayHold
                if now - awaySince! >= hold {
                    isAway = true; awaySince = nil; backSince = nil
                    return .startScreenSaver
                }
            } else if now - lastOutside > flickerTolerance {
                awaySince = nil
            }
            return nil
        }

        let inside = yaw >= env.yawMin - backMargin && yaw <= env.yawMax + backMargin &&
                     pitch >= env.pitchMin - backMargin && pitch <= env.pitchMax + backMargin
        if inside && settled {
            if backSince == nil { backSince = now }
            if now - backSince! >= backHold, now - lastWake >= wakeRetryInterval {
                lastWake = now
                return .wakeForUnlock
            }
        } else {
            backSince = nil
        }
        return nil
    }

    /// Call on com.apple.screenIsUnlocked, or on screensaver didstop with the session unlocked.
    mutating func userReturned() { reset() }
}
```

The state machine was exercised in a scratch harness, using an envelope of ±15° yaw and −10…+5° pitch at 25 Hz:

| Input | Result |
|---|---|
| Facing the screen | Nothing |
| Looking down 50° for 8 s | Nothing (down is ignored) |
| Turned 60° for 3 s, back for 0.2 s, away again | Screen saver at exactly 5.0 s after the first turn |
| Looking back | Wake after 0.6 s |
| Still looking back | Retry 10 s later |
| Turned away while typing | Nothing |

Gate the wake action in the controller on `observer.displayAsleep || observer.screenSaverRunning || ScreenSaverControl.isScreenLocked`.

---

## 10. Facts about this machine (checked locally)

| Item | Value | Impact |
|---|---|---|
| OS | macOS 26.7.1 (25G241), arm64 | Target |
| Toolchain | Xcode 27.1, Swift 6.4, SDK `MacOSX27.0.sdk` (`MacOSX.sdk` symlinks) | Use Swift 5 language mode or fix 2 Sendable errors; `GetProcessForPID` and `SetFrontProcessWithOptions` are unavailable in Swift, so use `@_silgen_name` or `dlsym` |
| Stage Manager | **On** (`GloballyEnabled = 1`) | Strip thumbnails appear as layer 0 windows at negative X. Focusing changes stage and layout. Detect, filter, warn. |
| Signing identities | 3 valid, including 2 "Apple Development" | Use them for a stable DR |
| Terminal TCC | The shell's responsible process already has Screen Recording; AX not trusted | Always test via `open`, not from the terminal |
| SkyLight symbols | `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo` resolve via `dlsym`; `_AXUIElementGetWindow` resolves; `GetProcessForPID` works | Private path available |
| `CGWindowListCopyWindowInfo` cost | 0.67 ms per call (41 windows) | Poll at 5–10 Hz |
| Lock settings | `sysadminctl -screenLock status` gives "screenLock delay is immediate"; `SACScreenLockEnabled()` returns true; `pmset displaysleep 20` | Look-away locks immediately on this Mac |
| Screen saver and lock entry points | `/System/Library/CoreServices/ScreenSaverEngine.app` present; `SACScreenSaverStartNow`, `SACScreenSaverStopNow`, `SACScreenSaverIsRunning`, `SACLockScreenImmediate` and `SACScreenLockEnabled` all resolve via `dlsym` (only the two query functions were called) | §9 code paths available |
| `CGSessionCopyCurrentDictionary()` (unlocked) | No `CGSSessionScreenIsLocked` key; `kCGSSessionOnConsoleKey = 1` | The lock key appears only when locked |

---

## 11. Recommended architecture (decisions for the builder)

### 11.1 Process and packaging

1. **SwiftPM executable target `AirFocus`.**
   - `platforms: [.macOS(.v14)]`, `swiftLanguageMode(.v5)`.
   - Link AppKit, CoreMotion, Carbon, ApplicationServices and CoreAudio.
   - **No** SkyLight link flag: use `dlsym`.
2. **`scripts/build-app.sh`** wraps the binary into `build/AirFocus.app` with `Support/Info.plist` (§7.2).
   - Sign with the first "Apple Development" identity, falling back to ad-hoc plus `--requirements '=designated => identifier "com.gshimoon.airfocus"'`.
   - Verify with `codesign -d -r-`.
   - Launch with `open`.
   - Add `make app`, `make run` and `make reset-tcc` (`tccutil reset Accessibility|Motion <id>`).
3. **LSUIElement = true** and `NSApp.setActivationPolicy(.accessory)`. Unsandboxed. No entitlements. Hardened runtime is fine.
4. Wrap active tracking in **`ProcessInfo.beginActivity([.userInitiated, .latencyCritical])`**.

### 11.2 Modules

| File | Responsibility |
|---|---|
| `main.swift`, `AppDelegate.swift` | NSApplication bootstrap; `NSStatusItem` menu: **Start/Stop Tracking**, **Calibrate…**, **Recenter** (⌃⌥⌘R), **Reset Calibration**, status lines (Motion auth, AirPods connected, output device, sample rate Hz, Accessibility), Mode (Auto dwell / Hotkey), **Quit** |
| `HeadTracker.swift` | §1.8 as written: serial motion queue, connection updates, watchdog, yaw unwrap, reference-jump re-basing |
| `AudioRoute.swift` | Default output device name and transport; listener on changes |
| `WindowEnumerator.swift` | §3.5 filter, occlusion and visible-centre logic; 5–10 Hz timer on main while tracking or calibrating |
| `Coordinates.swift` | CG ↔ AppKit conversion, `displayID`, Stage Manager detection |
| `AX.swift` | Trust prompt and polling, AX window lookup, `_AXUIElementGetWindow`, titles |
| `WindowFocuser.swift` | §4.4 SkyLight path, public fallback and verify. **Serial background `DispatchQueue`**, newest request wins |
| `Overlay.swift` | §5: one `OverlayPanel` per screen; `OverlayView` draws highlight, dots and head reticle; rebuild on screen changes |
| `HotKeys.swift` | §6 Carbon hotkeys (⌃⌥⌘T toggle, ⌃⌥⌘R recentre, ⌃⌥⌘F manual "focus what I'm facing") |
| `OneEuroFilter.swift` | §8.4 |
| `HeadMap.swift` | `AffineHeadMap` fit, predict and recenter; persistence keyed by display configuration |
| `TargetSelector.swift` | §8.5 dwell, hysteresis, cooldown, typing guard, keyboard-glance and off-screen rejects |
| `CalibrationController.swift` | §8.3 state machine (settle, then average, then validate, then next), progress UI on the overlay |
| `KeyActivity.swift` | `NSEvent.addGlobalMonitorForEvents(.keyDown)` records the last keystroke time only. Never log keys. |
| `ScreenSaverControl.swift` | §9.5: `LoginFramework` (`dlsym`), start the screen saver (NSWorkspace, then the SAC fallback), optional `lockNow`, `wakeForUnlock` (IOPM user activity, SAC stop, zero-distance mouse move), lock-delay reader |
| `SessionStateObserver.swift` | §9.5: screen saver, lock and display-sleep state from distributed and workspace notifications plus `CGSession` polling |
| `LookAwayDetector.swift` | §9.4 and §9.5 state machine; envelope from `AffineHeadMap.envelope(screensCG:)` |

### 11.3 Runtime data flow

1. The motion queue receives a `HeadPose` and hops to main.
2. The 1€ filter (yaw and pitch) runs.
3. `AffineHeadMap.point` gives the reticle.
4. `TargetSelector.update(point, gyroSpeed, now, lastKeyDown, windows)`.
5. If it returns a window, the overlay highlights it immediately and `WindowFocuser.focus` is enqueued on the focus queue.
6. Observe `NSWorkspace.didActivateApplicationNotification` and read the AX focused window, then call `TargetSelector.noteExternalFocus`. Feed the implicit-recalibration hook (§8.6).

7. In parallel, each pose also feeds `LookAwayDetector.update(…, inputIdle: ScreenSaverControl.secondsSinceUserInput)`. It is evaluated before `TargetSelector`, and while the detector is away, `TargetSelector` is skipped.

### 11.4 Permission flow on first run

1. **Accessibility:** `AXIsProcessTrustedWithOptions(prompt: true)`. Poll every second and show the state in the menu.
2. **Motion:** call `HeadTracker.start()`, which shows the prompt with the AirPods in. Poll `authorizationStatus()` while it is `.notDetermined`.
3. **Never request Screen Recording.**

### 11.5 Defaults

- Dwell 450 ms.
- Settle under 25°/s.
- Hysteresis max(40 pt, 8%).
- Cooldown 600 ms.
- Typing hold 700 ms.
- 1€ filter (1.0 Hz, 0.05, 1.0).
- Calibration: settle under 10°/s for 300 ms, average 500 ms, standard deviation under 1°.
- Watchdog: restart after 3 s with no samples.
- Window poll 8 Hz.
- Minimum window size 160 × 100.
- Minimum visible fraction 15%.

- Look-away:
  - Yaw more than 30° beyond the envelope, or pitch more than 25° above it.
  - Looking down is ignored (optional: more than 45° for 15 s).
  - 5 s continuous hold, with 0.3 s flicker tolerance.
  - Veto if there was input in the last 5 s.
  - Look back: inside the envelope grown by 10°, settled, for 0.6 s.
  - Wake retries at most every 10 s.
  - AirPods removal does not count.
  - Prevent idle system sleep while away only on AC power.

### 11.6 Look-away lock decisions (§9)

1. **Opt-in menu toggle "Lock when I look away"**, enabled only when calibrated, tracking and AX-trusted. Show the system's password delay next to it, read once at launch and on toggle via `sysadminctl -screenLock status` off the main thread, e.g. "locks immediately" or "locks after 5 min".
2. **Start:** `ScreenSaverControl.start()`, which tries `NSWorkspace` then `SACScreenSaverStartNow`. If the user enabled "Lock immediately (uses a private API)", call `SACLockScreenImmediate` instead, falling back to the screen saver. **Never** change lock settings, store passwords, or post keystrokes.
3. **On `com.apple.screensaver.didstart` or `com.apple.screenIsLocked`:**
   - Order out the overlay panels.
   - Pause `TargetSelector` and `WindowFocuser`.
   - Optionally take `kIOPMAssertPreventUserIdleSystemSleep` on AC.
   - Keep the motion stream running, and don't restart it unless the watchdog fires.
4. **Wake:**
   - Only when the detector returns `.wakeForUnlock` **and** `displayAsleep || screenSaverRunning || isScreenLocked`, call `ScreenSaverControl.wakeForUnlock()`.
   - It uses IOPM user activity, then SAC stop, then a zero-distance mouse move.
   - Then stop. The user types their password or uses Touch ID.
5. **On `com.apple.screenIsUnlocked`** (or `didstop` while unlocked):
   - Restore the overlay.
   - Release the sleep assertion.
   - `detector.userReturned()`.
   - Mark yaw for recentre (implicit or hotkey, §8.6).
6. **Motion stalls while away:** do nothing, and let the normal macOS wake path happen. **Yaw re-anchored while away:** use the pitch-only look-back test.

### 11.7 UX safeguards

- The highlight shows the **pending** target during the dwell (a progress ring) and the **current** target solidly.
- Menu status line, for example "AirPods: connected · 25 Hz · output: AirPods Pro" or "**not the current output** → choose AirPods in Sound".
- When Stage Manager is on, show a one-time warning: "Stage Manager rearranges windows; put your terminals in one stage or turn it off."
- Pause automatically when the AirPods disconnect. Resume and prompt to recentre on connect.

### 11.8 Hardware test plan (things this research could not verify)

1. Rate on the user's AirPods (25 or 50 Hz), and yaw and pitch sign conventions.
2. Background delivery while iTerm2 or Ghostty is frontmost (expected yes), and after sleep and wake.
3. Whether motion continues when the AirPods are connected but **another** output is selected (expected: it stops).
4. Yaw jump when a Spatial Audio track starts in Music. Check that the `referenceJump` heuristic catches it without false positives during fast head turns.
5. Bud-switch discontinuity: take the streaming bud out.
6. SkyLight focus across iTerm2, Terminal, Ghostty, WezTerm, Alacritty and Warp: same app and cross-app. Confirm no stray click lands in the terminal content (AltTab's off-window point).
7. Whether the public fallback (AX frontmost plus `activate()`) works from a background agent with no user input.
8. TCC persistence: rebuild 3 times and confirm Accessibility and Motion survive, using both signing modes.
9. Overlay over a full-screen terminal Space and across 2 monitors with a negative-origin secondary display.
10. Drift rate in °/min with the head still.
11. Look-away (§9):
    - Does `NSWorkspace` launching ScreenSaverEngine start the screen saver on 26.x, and does it lock at once with the "immediately" setting?
    - Do motion samples keep arriving (a) during the screen saver, (b) after lock, (c) after display sleep? Log `lastSampleUptime` across each.
    - Which of IOPM user activity, `SACScreenSaverStopNow` and a zero-distance synthetic mouse move dismisses the screen saver and shows the password or Touch ID prompt, both while still animating and after display sleep?
    - Confirm no keystroke or click reaches the frontmost terminal.
    - Exact `sysadminctl` wording for the delay values and "off".

---

## Sources

**Apple**
- [CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)
- [isDeviceMotionAvailable](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager/isdevicemotionavailable)
- [WWDC23 10179, What's new in Core Motion](https://developer.apple.com/videos/play/wwdc2023/10179)
- [WWDC23 10054, What's new in AppKit](https://developer.apple.com/videos/play/wwdc2023/10054/)
- [activate(from:options:)](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:))
- [NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)
- [kCGWindowBounds](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds)
- [CGDisplayBounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:))
- [SCShareableContent](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)
- [SCWindow](https://developer.apple.com/documentation/screencapturekit/scwindow)
- Local SDK headers: `CMHeadphoneMotionManager.h`, `CMHeadphoneMotionManagerDelegate.h`, `CMDeviceMotion.h`, `CGWindow.h`, `NSRunningApplication.h`, `NSApplication.h`, `NSWindow.h`, `Processes.h`

**Apple Developer Forums**
- [844940, yaw re-centres with Spatial Audio](https://developer.apple.com/forums/thread/844940)
- [839069, CGWindowList owner name and permission](https://developer.apple.com/forums/thread/839069)
- [826308, overlay above full-screen (DTS)](https://developer.apple.com/forums/thread/826308)
- [739524, activateWithOptions on Sonoma](https://developer.apple.com/forums/thread/739524)
- [763878, Sequoia hotkey modifiers](https://developer.apple.com/forums/thread/763878?page=2)
- [735223, global hotkeys](https://developer.apple.com/forums/thread/735223)

**AirPods projects**
- [ydisli/nod](https://github.com/ydisli/nod)
- [crippler95/airtracker](https://github.com/crippler95/airtracker)
- [mattxh/airpod-pose-estimate](https://github.com/mattxh/airpod-pose-estimate)
- [sumionochi/PodsControlMac](https://github.com/sumionochi/PodsControlMac)
- [tldev/dorso](https://github.com/tldev/dorso)
- [einargudnig/posture](https://github.com/einargudnig/posture)
- [chandansgowda/posture-fix](https://github.com/chandansgowda/posture-fix)
- [FujiwaraChoki/head-position-tracker](https://github.com/FujiwaraChoki/head-position-tracker)
- [kun-Jiang/AirPods_Nod](https://github.com/kun-Jiang/AirPods_Nod)
- [DanielRudrich/Headitude](https://github.com/DanielRudrich/Headitude)
- [MarkymarkLee/BlindSamurai](https://github.com/MarkymarkLee/BlindSamurai)
- [spaceamoeba-t/tapq](https://github.com/spaceamoeba-t/tapq)
- [denislav-d/slouchless](https://github.com/denislav-d/slouchless)
- [jx-grxf/poise](https://github.com/jx-grxf/poise)
- [qn34uc59t/privacy_screen](https://github.com/qn34uc59t/privacy_screen)

**Window management**
- [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos)
- [koekeishiya/yabai](https://github.com/koekeishiya/yabai)
- [Hammerspoon](https://github.com/Hammerspoon/hammerspoon)
- [Hammerspoon#370](https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468)
- [rxhanson/Rectangle](https://github.com/rxhanson/Rectangle)
- [romankhadka/opta](https://github.com/romankhadka/opta)
- [hazel-ocean/clawd-back](https://github.com/hazel-ocean/clawd-back)
- [MeKo-Christian/mac-taskbar](https://github.com/MeKo-Christian/mac-taskbar)
- [ryekee/Napoleon](https://github.com/ryekee/Napoleon)
- [karinushka/paneru#123](https://github.com/karinushka/paneru/issues/123)

**Signing and TCC**
- [Qt, The Curious Case of the Responsible Process](https://www.qt.io/blog/the-curious-case-of-the-responsible-process)
- [NoSugarCoffee/dotnix#238](https://github.com/NoSugarCoffee/dotnix/pull/238)
- [LucasStop/sixthsense#29](https://github.com/LucasStop/sixthsense/pull/29)
- [SunnyXdm/sunna#1](https://github.com/SunnyXdm/sunna/issues/1)
- [pathorsAI/parley#75](https://github.com/pathorsAI/parley/issues/75)
- [microsoft/Zoomit-Mac](https://github.com/microsoft/Zoomit-Mac)
- [Wox-launcher/Wox](https://github.com/Wox-launcher/Wox)
- [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
- [9to5Mac, Sequoia monthly prompts](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/)
- [TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)
- [Chromium permissions_utils.mm](https://chromium.googlesource.com/chromium/src/+/d4afc97b7/ui/base/cocoa/permissions_utils.mm)
- [go-macos/hotkey](https://pkg.go.dev/github.com/go-macos/hotkey)

**Look-away screen saver and wake**
- [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock): [AppDelegate.swift](https://github.com/ts1/BLEUnlock/blob/master/BLEUnlock/AppDelegate.swift), [lowlevel.c](https://github.com/ts1/BLEUnlock/blob/master/BLEUnlock/lowlevel.c), [#21](https://github.com/ts1/BLEUnlock/issues/21), [#25](https://github.com/ts1/BLEUnlock/issues/25), [#140](https://github.com/ts1/BLEUnlock/issues/140)
- [Chromium base/mac/login_util.cc](https://github.com/chromium/chromium/blob/main/base/mac/login_util.cc)
- [Chromium ui/base/idle/idle_mac.mm](https://github.com/chromium/chromium/blob/main/ui/base/idle/idle_mac.mm)
- [timac.org, programmatically lock the screen](https://blog.timac.org/2016/0605-programmatically-lock-the-screen/)
- [sindresorhus/macos-lock](https://github.com/sindresorhus/macos-lock)
- [Apple Support, Lock Screen settings](https://support.apple.com/guide/mac-help/change-lock-screen-settings-mh11784/mac)
- [Developer Forums 682918](https://developer.apple.com/forums/thread/682918)
- [SI tech blog, askForPassword since 10.13](https://technology.siprep.org/askforpassword-and-askforpassworddelay-in-macos-10-13-high-sierra/)
- [CocoaDev StopScreensaver](https://cocoadev.github.io/StopScreensaver/)
- [sill#144](https://github.com/Saffsanity/sill/pull/144)
- [Dorso ScreenLockObserver and CHANGELOG](https://github.com/tldev/dorso)
- [hex2010 gist, open -a ScreenSaverEngine](https://gist.github.com/hex2010/d7848d9912a608e11bce3146bcd4068e)
- SDK `IOPMLib.h` (`IOPMAssertionDeclareUserActivity`)

**Human factors and filtering**
- [1€ filter](https://gery.casiez.net/1euro/)
- [Hansen et al. ETRA 2018](https://www.yorku.ca/mack/etra2018.html)
- [Gaze typing dwell, JEMR](https://doaj.org/article/6d92a0b817294c339b2c8db859dd6dab)
- [EyeWindows, CHI 2005](https://api.openalex.org/works/doi:10.1145/1054972.1054994)
- [Eye-head coordination, PMC1890377](https://pmc.ncbi.nlm.nih.gov/articles/PMC1890377)
- [PMC3191847](https://pmc.ncbi.nlm.nih.gov/articles/PMC3191847)
- [WebGazer](https://webgazer.cs.brown.edu/)
