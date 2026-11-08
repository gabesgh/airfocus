# AirFocus: build spec (v1)

This spec covers the first version of AirFocus. The technical "how" lives in `docs/RESEARCH.md`, referred to below as R§n. When this spec and the research disagree, **this spec wins**. Where the spec says nothing, follow R§11, "Recommended architecture".

## 1. What it is

AirFocus is a macOS menu bar app (LSUIElement, with a Dock icon only while Settings is open) for macOS 26 and later on Apple silicon. It reads AirPods head orientation through `CMHeadphoneMotionManager`, works out which on-screen window the user's head is pointed at, and focuses that window, so the user can switch between several terminal windows (for example several Claude Code agents) without touching the mouse.

It also starts the screen saver when the user clearly looks away for 5 s (the default delay) or more, and wakes it to the standard unlock prompt when they look back.

## 2. User-facing behaviour

### 2.1 Menu bar item

- The icon is the user's AirPod-and-cursor art, `Support/MenuBarIcon.png`, used as a template image. `scripts/build-app.sh` copies it into Resources. At launch the app trims it to its ink and area-averages it into 1x and 2x bitmaps 18 pt tall. No timers and no colour.
  - tracking: the art, unmodified
  - off: the art at 45% opacity
  - paused or no motion (switching paused until a recenter, AirPods missing, a permission missing, not calibrated): a pause sign badge beside the cursor
  - calibrating: a target badge beside the cursor
  - away: a crescent badge beside the cursor
  - If the resource is missing, the old SF Symbols stand in. The tooltip and accessibility description name the state.
- The menu, top to bottom:
  1. **Status lines** (disabled items):
     - AirPods: `connected · 25 Hz · output: AirPods Pro`, `not the current audio output`, or `not connected`
     - Motion permission
     - Accessibility permission. When it's missing, the item becomes clickable and opens the relevant System Settings pane.
     - Calibration: `calibrated (N points, error X°)` or `not calibrated`
     - Screen lock: `locks immediately`, `locks after N min`, or `doesn't lock`
  2. **Start Tracking / Stop Tracking** (⌃⌥⌘T)
  3. **Calibrate…** (⌃⌥⌘C): full calibration using the current windows. Re-running it is "Recalibrate".
  4. **Recenter** (⌃⌥⌘R): quick drift fix. The user looks at the focused window's dot and presses it (R§8.6). In Hidden mode the dot appears for a second first (§2.2).
  5. **Reset & Recalibrate**: clears the stored calibration, restarts the motion stream, rescans windows and starts calibration. This is the "full reset" the user asked for.
  6. **Show Overlay**: a checkbox for the Overlay setting, on for Visible, off for Hidden (§2.2).
  7. **Settings…** (⌘,): opens the Settings window (§2.8). Disabled during calibration.
  8. **Developer** submenu:
      - **Simulate head with mouse** (§5)
      - **Open Log**
      - **Copy Diagnostics**
      - **Record Session Trace** (off by default), **Reveal Traces in Finder**, **Delete Traces…** (§2.10)
  9. **Quit AirFocus**

### 2.2 Overlay (R§5)

- Use one click-through, non-activating `NSPanel` per screen, set up exactly as in R§5. Rebuild the panels when the screen configuration changes.
- **Overlay mode**, Hidden or Visible, **Hidden by default** for everyone, existing installs included (no stored value means Hidden). The appearance settings stay stored and apply when Visible.
  - **Hidden** draws nothing during tracking: no window dots, focused or pending border, progress ring, head pointer or status banners (`status: true`). The dwell and everything else run exactly as in Visible; only the drawing stops, and with it the per-sample layer updates and the border's fade timer.
  - Still shown in Hidden: calibration, unchanged; essential banners (warnings, permission, errors, calibration); Mission Control's pointer and the thumbnail pick highlight, styled by the appearance settings; and the recenter cue below.
  - **The recenter cue.** ⌃⌥⌘R (and the menu's Recenter) in Hidden shows the focused window's dot, in the user's dot style, with a ring in the border colour that fills over 1.0 s (Core Animation; nothing ticks). At the end of that second it recenters with the pose at that moment, then fades the dot out over 0.35 s. Pressing again during the second starts it over. Stopping tracking or starting calibration cancels it. Settings' Recenter shows the same cue for its 2 s wait. In Visible, ⌃⌥⌘R recenters at once, as before.
  - The panels stay ordered in while tracking in either mode, so entering Mission Control works the same; in Hidden they hold nothing.
- **While tracking (Visible):**
  - Draw a **white dot** at the visible centre of every tracked window. Make it 14 pt across, with a subtle dark outline and shadow so it shows on white backgrounds.
  - The **target window** gets a highlight border: rounded, 4 pt, system accent colour.
    - **Pending** target (the dwell is running): a thinner dashed border, plus a progress ring around its dot.
    - **Current** target (just focused): a solid border that fades to a faint persistent outline after about 1 s, so it doesn't distract while typing.
  - **Head pointer:** a mark at the predicted point. By default, a 26 pt translucent circle.
  - These are the defaults. Settings (§2.8) can restyle or turn off each of them, live, including what is already on screen. The pending border keeps the focused border's hue at 85% alpha and 62.5% of its width. The ring keeps a 6 pt gap around the dot. A fill too dark for the dark rim gets a light rim.
- **While calibrating:**
  - Draw every dot dimmed. The active dot is large (about 28 pt), bright and pulsing, in the user's dot colour with a contrasting rim. Done and skipped dots keep their colours.
  - Show a capture progress ring.
  - Show a centred instruction banner: "Point your nose at the white dot and hold still · Esc to cancel". It says "pulsing dot" when the dot colour isn't white.
  - Turn finished dots green.
  - Afterwards, show a result banner for 3 s, e.g. "Calibrated · 4 points · average error 1.8°", or a warning suggesting a recalibration when the error is high (R§8.3).
- Calibration always shows its own dots, ring and banners. The Settings toggles only affect the runtime overlay.
- Hide all overlay panels while the screen saver is running or the screen is locked (R§9.2).

### 2.3 Calibration (R§8.3, with these decisions)

- **Calibration points:**
  - The visible centre of every tracked window, ordered left to right, then top to bottom.
  - **Supplementary screen points** are added when any of these apply:
    - fewer than 3 windows
    - the points are nearly collinear in either axis (spread under 15% of the screen extent)
    - a screen has no window
  - The supplementary points are the centre and the four corners inset 15%, on each screen that needs them.
  - Cap the total at 12 points.
- **Capture:**
  - Capture each point automatically: wait for the head to move 2° from where it was when the dot appeared (or 2.5 s if it doesn't, since the dot may be next to the last one; the first point always waits the 2.5 s), then wait for it to settle (gyro under 10°/s for 300 ms), average over 500 ms, and reject and retry if the standard deviation exceeds 1°.
  - **Return** captures the current point immediately. **Esc** cancels.
  - Register both as Carbon hotkeys only while calibration runs, and unregister them right after. If registering plain Esc or Return fails, fall back to ⌃⌥⌘Esc and ⌃⌥⌘Return, and say so in the banner.
- **Fit:** fit `AffineHeadMap` (R§8.2) with ridge regularisation. Persist the samples and the map in UserDefaults, keyed by display configuration. Load the matching calibration at launch and when displays change.
- **Window anchors:** keep them as well. Gap disambiguation uses them, picking the nearest calibrated dot within 4° (R§8.2).

### 2.4 Targeting (R§8.4–8.6)

- **Smoothing:** the 1€ filter, with the defaults from R§8.4.
- **`TargetSelector`:** use R§8.5 as written, plus these rejects:
  - keyboard glance
  - off-screen
  - typing guard of 700 ms, using a global `.keyDown` monitor that records timestamps only
  - cooldown of 600 ms at the default sensitivity
  - settled-head gate of 25°/s at the default sensitivity
  - hysteresis of max(40 pt, 8%) at the default sensitivity
- **Sensitivity:** one value from 0 (Calm) to 1 (Snappy) sets the dwell, gate, hysteresis, cooldown and pointer smoothing, by linear interpolation through these three points (`SensitivityTuning` in Core). The typing guard and look-away are not affected.

  | | Calm (0) | Default (0.5) | Snappy (1) |
  |---|---|---|---|
  | Dwell | 800 ms | 450 ms | 250 ms |
  | Settled-head gate | 18°/s | 25°/s | 40°/s |
  | Hysteresis | max(70 pt, 14%) | max(40 pt, 8%) | max(20 pt, 4%) |
  | Cooldown | 900 ms | 600 ms | 350 ms |
  | 1€ `minCutoff` | 0.7 Hz | 1.0 Hz | 1.6 Hz |
  | 1€ `β` | 0.03 | 0.05 | 0.12 |
  | 1€ `dCutoff` | 1.0 Hz | 1.0 Hz | 1.0 Hz |

  A `switchSpeed` stored by an earlier version migrates once at launch to the sensitivity with the same dwell (fast 0.875, normal 0.5, slow 0.143), then is removed.
- **Hit-testing:** check windows front to back against their visible region. Skip windows less than 15% visible.
- **Focus changes made elsewhere:** when the user focuses a window by click or ⌘-Tab, adopt it as `current` and feed implicit recentring (R§8.6, item 2). Ship that heuristic, but keep it conservative and behind a constant so it's easy to turn off.
- **After a stream restart or reference jump:** show a one-time banner, "Look at the highlighted window and press ⌃⌥⌘R to recenter". In Hidden mode there is no highlight, so the wording is "look at the middle of the focused window" (the banner is a status banner, so Hidden doesn't show it; ⌃⌥⌘F's essential version of the hint uses the same wording).
- **The decision path** (filter → map → selector, with the flick and Mission Control holds and the adoption of focus changes made elsewhere) is `LiveSwitcher` in Core. AppController keeps only the side effects, and `--replay-trace` runs the same type, so the two can't drift apart. A test drives it side by side with a line-for-line transcription of the pre-extraction AppController code through 120,000 randomized steps and requires identical decisions at every one.

### 2.5 Focusing (R§4.4)

- **Focus path:** SkyLight first (`dlsym`): `_SLPSSetFrontProcessWithOptions`, then the make-key event records placed off-window as AltTab does on macOS 26, then `AXRaise`. Fall back to public AX plus `NSRunningApplication.activate`.
- **Threading:** run it on a serial background queue, where the newest request wins.
- **Safety rules:**
  - **Never** post synthetic keystrokes.
  - **Never** post synthetic clicks that could land inside window content.
- **Verification:** after focusing, check that the frontmost app and window match, and log a mismatch.

### 2.6 Look-away screen saver (R§9; R§11.6, except the default is on)

Use the state machine from R§9.4 and R§9.5:

- **Trigger:** yaw more than 30° beyond the calibrated envelope, or pitch more than 25° above it, held for the delay (5 s by default; 5, 10, 20, 30 or 60 s). Brief returns under 0.3 s don't reset the timer. Looking down is ignored.
- **Veto:** any keyboard, mouse or trackpad input within the delay window.
- **Away:**
  - Start the screen saver (NSWorkspace → `SACScreenSaverStartNow`), or call `SACLockScreenImmediate` if the user opted in.
  - Hide the overlay.
  - Pause focusing.
  - On AC power only, hold `kIOPMAssertPreventUserIdleSystemSleep`.
- **Look back:**
  - Fires when the head is inside the envelope grown by 10° and settled for 0.6 s.
  - Wake at most once every 10 s, and **only if the app started this away episode**: IOPM user activity, then `SACScreenSaverStopNow`, then a zero-distance mouse move. **No** synthetic keys.
  - The user types their own password or uses Touch ID. The app never touches credentials or lock settings.
- **After unlock:** restore the overlay, release the sleep assertion and mark yaw for recentring.
- **If motion stops while away:** do nothing. If the stream restarted, use the pitch-only look-back test (R§9.3).

### 2.7 AirPods and permissions

- **First run:** prompt for Accessibility and poll for the grant (R§11.4). The Motion prompt appears on the first `startDeviceMotionUpdates`, so start the stream when tracking or calibration starts. **Never** request Screen Recording.
- **Disconnect:** auto-pause, and show "AirPods disconnected" in the menu and icon. **Reconnect:** auto-resume, and show the recentre banner.
- **Wrong audio output:** if the AirPods are connected but not the current output, show the hint "Select AirPods as the sound output" (R§1.7).
- **Stage Manager:** if it's on, show a one-time notice in the menu or a banner, and filter out its strip thumbnails (R§3.3).

### 2.8 Settings window

A small SwiftUI window inside the app process: an `NSWindow` hosting SwiftUI, with the AppKit `main.swift` lifecycle kept. There is no second app and no IPC.

- **Opening:** the **Settings…** menu item (⌘,), or reopening the app while it runs (`applicationShouldHandleReopen`). Never at launch, and not during calibration.
- **Lifetime:** the window, its hosting view, the model and the status timer are created on open and released on close, so a closed window costs nothing. While open the activation policy is `.regular`, with a small main menu so ⌘W, ⌘Q and paste work. On close it returns to `.accessory` and hands focus back to the previous app, unless the user already moved on. While `.regular`, the overlay may not sit above another app's full-screen Space (R§5).
- **Look:** Liquid Glass on controls and navigation only. A transparent full-size titlebar, a native segmented control for the sections, `.buttonStyle(.glass)` and `.glassProminent` buttons in `GlassEffectContainer`s, and a `.glassEffect` caption over the preview. A subtle accent gradient behind everything gives the glass something to refract. Reduce Transparency flattens the gradient and cards, and Increase Contrast strengthens their outlines. The window is only as tall as the section needs.
- **Every change** applies live and persists immediately. `AppSettings` is the only store.
- **Tracking:** the Sensitivity slider (§2.4), snapping to steps of 0.05 so 0.5 is exact, with a readout such as "switches after 450 ms". Focus mode: Automatic or Hotkey only. In both modes, ⌃⌥⌘F focuses immediately.
- **Appearance:** first the **Overlay** choice (Hidden / Visible, segmented) with a one-line explanation, then a live preview that always shows the Visible style (captioned "Preview of Visible" in Hidden), a note that the styling applies when Visible and to Mission Control's pointer, then:
  - **Window dots:** on/off, colour, size (8–24 pt)
  - **Focused window border:** on/off, colour, width (1–10 pt). Off removes the focused and pending borders.
  - **Head pointer:** on/off, shape (circle, ring, dot, crosshair), colour, size (8–48 pt, default 26)
  - **Switch progress ring:** on/off. Display only: the dwell runs the same.
  - **Status banners:** on/off for non-essential banners ("Recentered", "Anchored", the recenter hint, the Stage Manager notice). Calibration banners, and permission and error warnings, always show.

  The preview draws with the same `OverlayCanvas` as the real overlay, at real size, and is static.
- **Look Away:** on/off (greyed out, with the reason shown, while there is no calibration, tracking is off, or Accessibility is missing), delay, lock immediately (private API, R§9.1), treat removal as away, the screen lock status and a link to its System Settings pane.
- **General:** Launch at Login (`SMAppService.mainApp`), Menu bar icon (Always shown, the default; Hidden 5 seconds after you leave AirFocus, meaning once the app is inactive and its menu closed; or Hidden). The menu also has an Auto-hide Menu Bar Icon checkbox, which explains once how to get the icon back. Opening the app again brings up Settings, and the hotkeys work whatever the icon does, Recalibrate, Reset & Recalibrate, Recenter, a status row (tracking, AirPods, sample rate, calibration quality) refreshed at most twice a second, and a read-only list of the hotkeys.
- **Restore Defaults** resets appearance and sensitivity only. Focus mode, overlay mode, look-away, trace recording and calibrations stay.
- **Validation:** a corrupt or out-of-range colour, size or sensitivity falls back to its default. Colours are `StyleColor` values in Core: sRGB doubles plus a "follow system accent" state, stored as text. The `calibrations` key is never touched.

Rules that keep it from fighting the rest of the app:

- **Never a target.** Own windows are never tracked. While Settings is open, its window and the colour panel count as covering what's behind them, so no dot lands on them. A border or the head pointer can still draw over them, because the overlay sits above every window.
- **Holding switching.** While the Settings window or colour panel is key, automatic switching holds. The pointer and highlight keep drawing, with what's under the pointer shown as in hotkey-only mode. This hold is separate from `switchingPaused`, so the "yaw needs recenter" logic, its auto-anchor, ⌃⌥⌘F and look-away run as usual. Dwell progress doesn't carry over: switching resumes from zero.
- **Calibrating closes it.** Any path into calibration closes the window first and waits 200 ms, so the plain Esc and Return hotkeys and window enumeration behave as they do from the menu.
- **Recenter waits.** The user is looking at the button, and a recenter trusts where the head points. So the Settings button shows a banner, waits 2 s, then recenters on the focused window. The hotkey still acts at once.

### 2.9 Head flicks

A sharp head flick drives Mission Control and Desktops. `FlickDetector` is pure and sees raw poses, not filtered ones. Every burst at 100°/s or more goes in the log with its numbers, fired or not, so the thresholds below can be tuned from real flicks. They are first guesses.

- **Flick up:** opens Mission Control by launching `/System/Applications/Mission Control.app`, which needs no permission. Launching it again closes it, so a second flick up closes it.
- **Flick left or right:** moves one Desktop that way by posting the system's own "Move left/right a space" shortcut, read from `com.apple.symbolichotkeys`, with the numeric pad flag a real arrow key carries. If the shortcut is off, nothing is posted, because the key press would reach the focused app, and a banner says what to turn on. This needs Accessibility. It's the app's only synthetic key press, and it never happens while the screen is locked or the screen saver runs.
- **What counts as a flick:**
  - peak speed of at least 190°/s sideways or 130°/s upward
  - onset to peak within 160 ms, and over within 400 ms
  - 10–45° sideways or 8–40° upward: under that is a twitch, over that a turn
  - main axis at least twice the other, so no diagonals
  - raw gyro agrees with the rate, so attitude steps don't count
- **What keeps it from misfiring:**
  - An up flick must start no more than 3° below the screen and reach its top edge, so coming back up from the keyboard never counts.
  - A side flick must start within 8° of the screen, so coming back from looking away never counts, and it needs an anchored yaw.
  - Downward movement never fires.
  - Nothing fires within 250 ms of a key press.
  - After a flick, nothing fires for 1.2 s, because a Desktop takes about 1.05 s to arrive and the Dock drops keys until then. The opposite direction stays blocked for 1.8 s, so the head coming back isn't a flick.
- **Focus switching around a flick:** no automatic switching for 1.6 s after a flick, and any half-finished dwell is dropped.
- **Mission Control, however it was opened:** detected from the window list, where the Dock has a full-screen layer 18 window only while it's open. While open, only the head pointer stays on screen, because dots and borders would mark where windows used to be, and focus switching and adoption stop. The panel ignores clicks, so the pointer can't get in the way of Mission Control. On close, the app adopts whatever is frontmost and holds switching for 0.6 s.
- **Picking in Mission Control:** holding the head pointer on a thumbnail for twice the switching dwell (0.9 s at the default sensitivity) brings that window forward and closes Mission Control, the same as clicking it, at its normal size.
  - The thumbnails and their frames come from the Dock's Accessibility tree (`mc › mc.display › mc.windows`), and a pick is that button's `AXPress`, so the mouse doesn't move. Nothing else in the tree is used: the Desktop buttons beside them have a remove action.
  - Time only counts with the head settled, and any mouse, trackpad or key input in the last 0.5 s restarts it. The thumbnail shows the dashed border and progress ring while it fills, if those are on.
  - It needs an anchored yaw and Accessibility, and has its own toggle.
  - After Mission Control closes, by a pick or a click, the frontmost window is adopted with the external-focus hold, even if it was already in focus, because the head is still aimed where the thumbnail was.
- **Settings:** an independent toggle for each, where a direction that is off can't start the cooldown for the other, and a Flick strength slider. Firm asks for 35% more speed and minimum size, Light 30% less, and the midpoint is the numbers above. Mouse simulation never fires flicks.

### 2.10 Session traces

The data the intent engine learns from and is evaluated on. Recorded only while tracking is on, and only when **Developer › Record Session Trace** is on. It's off by default.

- **Where:** `~/Library/Application Support/AirFocus/Traces/`, one file per tracking session, split into numbered parts at each wall-clock hour: `2026-11-07T13-40-12-p1.aftrace`. Each part starts with a full header and a snapshot, so it replays on its own.
- **Format:** versioned, line-based text. A one-letter code, the host uptime (4 decimals), then fields separated by single spaces. Numbers are fixed-point, rounded once when the event is made, so the app's shadow engine and a replay of the file see bit-identical values. Lines starting with `#` are comments; unknown codes are skipped, so a newer format still replays.

  | code | event |
  |---|---|
  | `H` | header, JSON: format version, app version, launch and session ids, part, wall clock and uptime, display key and screen frames, the calibration in full (affine coefficients, samples, anchors), envelope, sample count, the relevant settings (sensitivity, focus mode, overlay mode, flicks, Mission Control pick, look-away) and the state (focused window, yaw anchored, Mission Control, Settings hold, away, obscured, calibrating) |
  | `s` | every head sample: host time, device time, raw yaw, pitch and gyro speed, the filtered yaw and pitch the live path used and its mapped point (`-` when calibrating or uncalibrated), flags (`g` gated by look-away/screen saver/lock, `c` calibrating, `n` no calibration) |
  | `w` | the tracked windows whenever the list changes: id, pid, bundle id, frame, visible fraction, target point, visible rects |
  | `p` | every window poll (8 Hz): the window in front (`own` for Settings, `-` for none) and whether Mission Control is open |
  | `f` | the front window changed: `req` (we asked for it) or `ext` |
  | `q`, `r` | live focus requests (`dwell` or `hotkey`) and their verify result |
  | `x` | the live selector's reject, when it changes |
  | `k` | a key-down time. Never which key. |
  | `m` | a left or right mouse-down: CG position and the tracked window under it |
  | `C` | a calibration change (`calibrated`, `recenter`, `nudge`, `anchor`, `reload`, `cleared`) with the window synced to and the new calibration in full, so a replay maps poses exactly as live did |
  | `S` | stream events: started, restarted, reference jump, connected, disconnected, yaw unanchored (with the reason) and anchored |
  | `M` | modes: away, obscured (screen saver or lock), Settings hold, calibrating, Mission Control, a pick, flick and Mission Control holds, overlay mode |
  | `g` | flick bursts as logged (fired, or rejected at 100°/s or more) |
  | `c` | the live configuration when it changes: sensitivity, automatic, paused, Settings hold, flick toggles and strength, simulated |
  | `T`, `D`, `i`, `E` | tracking start/stop, display change, the shadow intent engine's would-switch, clean end of file |

  Example:

  ```
  s 1349.664 1349.65969 -2.4741 -13.0261 3.22 -2.5184 -12.9524 1366.3 782.2 -
  q 1019.6342 12 dwell
  ```

- **Never recorded:** which key, window titles, app content, app names (the bundle id stands in), anything typed.
- **Storage:** lines are buffered on the main thread (formatting only) and handed to a utility queue every 3 s, on the hour, at the end of a session and at quit, where they are written; nothing touches the disk on the sample path. A closed part is gzipped (`.aftrace.gz`, standard gzip so `zcat` and `zgrep` work) after checking it decompresses; files a crash or quit left plain are compressed at the next launch. Then the oldest files go: anything over 14 days, then until the rest fit in 500 MB. Plain text runs about 14 MB per tracked hour at 50 Hz; gzip takes it to about 5 MB, so the cap holds roughly 100 tracked hours.
- **Menu:** Record Session Trace (applies at once, mid-session too), Reveal Traces in Finder, Delete Traces… (asks first; a session being recorded continues in a fresh file).

### 2.11 Intent engine, in shadow mode

`IntentEngine` (Core) is a pure, deterministic alternative to the dwell selector. It runs alongside the live path, fed by the very events the trace records (`IntentRunner` consumes `TraceEvent`s, in the app and in a replay alike), and **never focuses anything**. Its parameters, with the values tuned on synthetic traces (§2.12), are in `IntentEngine.Parameters`; `--replay-trace --set` overrides any of them.

- **Evidence instead of a dwell.** Each sample, every window's likelihood is Φ(−z), z the signed angular distance from the corrected head pointer to the window's visible region in units of σ (negative inside: its depth), converted from points to degrees through the inverse of the map's Jacobian (a1, a2; b1, b2). σ per axis = √(σ_noise² + jitter² + the head model's variance there). Each candidate accumulates dE/dt = rate · weight · (ln(L + 0.02) − ln(L_current + 0.02)) − E/leak, floored at −3, and wins at E ≥ threshold × typing × glance multipliers, at least 0.3 s after the last switch. rate 10/s, leak 2 s, threshold 15, σ starts at 2.5°.
- **Movement shape** (raw gyro speed): no evidence at 25°/s or more; a fixation after a deliberate shift (a burst peaking at 40°/s or more, at least 3°, then settled under 15°/s for 80 ms) counts fully, plus up to 2× more for a shift of 15° or more, fading to the settled weight over the second of its 2 s window; settled with no shift 0.4; slow creep (1°/s or more over 0.6 s without a burst) 0.15.
- **Typing:** 4× at a key-down, held 0.3 s, then falling back exponentially to about 1.15× at 3 s and 1× after. During a shift's fixation, a burst that starts after the turn (a gap over 0.6 s) doesn't count, so turning and then typing in the new window isn't held up, while typing straight through the turn is. In shadow mode, three or more keys that went into the candidate itself (because live already focused it) mean the user accepted it.
- **Reference glances:** for each pair (A, B), glances from A to B and back within 3 s while typing into A, with typing resuming within 2 s, and switches to B that the head undid the same way, build a habit (half-life 30 min) that raises the bar by up to 4× (2.5× after two). A switch to B that sticks, or the user switching to B, halves it.
- **The head model**, separate from the live calibration. Per axis, pose − c = α + β (gaze − c), c the screens' centre in map angles: α an offset that random-walks (1°/min), β the head's share of the turn (prior 1 ± 0.15, kept within 0.5–1.3), a two-state Kalman filter. A **click** is a strong measurement (σ 1.5°) from the median pose over the 300 ms before it, taken only with the head settled (under 20°/s) and rejected if the residual is over 8°. **Typing** into the focused window is weak and one-sided (σ 5°, at most once a second, head settled 0.5 s): it pulls α only when the pointer is outside that window, towards the nearest point well inside it. Live's nudges and anchors shift α by the same angle (the engine keeps its own estimate); a recenter resets α (σ 1°); a new calibration resets α but keeps β.
- **Unknown yaw:** a stream restart, reference jump or return from look-away (each `S unanchored`) makes α_yaw unknown. Until a settled click anchors it (logged: `[intent] a click anchored yaw`, a candidate replacement for ⌃⌥⌘R) or a typing burst does (3 keys in 2 s with a still head for 1 s, weakly), only pitch can tell windows apart.
- **Noise:** the jitter of the filtered pose over settled 300 ms windows sets a floor; click residuals, less what the model's uncertainty explains, update σ (EWMA 0.1, 1–5°).
- **The live gates:** Mission Control, flick holds (from recorded fired flicks), the 0.6 s hold after Mission Control, look-away, screen saver or lock, calibration, the Settings hold, hotkey-only mode, keyboard glances and off-screen (the live selector's thresholds, on the corrected pointer). Focus changes made elsewhere (`ext`), ⌃⌥⌘F and Mission Control picks are adopted; changes we made are not.
- **Shadow output:** `[intent] would switch to …` when it would switch, with whether live agrees (already there, or asked for it within a second); one summary line per ten minutes of tracking comparing switches, bounces and switches during typing; `[intent]` notes for yaw anchors. No per-sample logging.

### 2.12 Replay and evaluation

`--replay-trace FILE|DIR [--engine live|intent|both] [--set name=value,...]` replays traces (a directory: every trace in it, in name order; consecutive parts of a session carry state over; a new app launch starts a fresh intent engine) through `LiveSwitcher` and `IntentEngine` and prints a comparison. Deterministic: no clocks, no randomness, nothing that depends on dictionary order.

- Per engine: switches and switches per hour; **bounces** (a switch to B, then back to A within 3 s with no key-down and no click in B between); **switches during a typing burst** (a key-down within 1.5 s before, typed before the head settled on B and not already into B, and one within 1.5 s after); **late switches** (a key-down between the head settling on B and the switch, so keys went to the old window; live's typing guard turns most of these into missed switches instead); **probable missed switches** (a click, ⌘-Tab or ⌃⌥⌘F into a window the head had been mapped onto for 1 s or more without a switch); **median latency** from the head settling on the target (under 25°/s, inside it). Then agreement between the engines (switches to the same window within 1.5 s, one to one), the share of time they agree on the focused window, and a per-session table.
- **Fidelity:** the trace records what live actually decided, so the report compares replayed-live with recorded-live (dwell requests within 100 ms, the filtered pose and mapped point, fired flicks), and replayed-intent with the shadow decisions in the file.
- `--synthesize-trace FILE [--seed N] [--scenarios ...]` writes a synthetic trace for trying it: a simulated head (minimum-jerk turns that go 85% of the way, sway, sensor noise, drift, restarts), a simulated user (typing bursts, glances, clicks, clicking back after keys went astray) and the live path recording as the app records. Scenarios: typing in A while glancing at B, slow drift across a boundary while typing, clean switches then typing, jitter near a boundary, clicks with a drifted offset, a stream restart then a click, and turning to a window and reading without typing. Synthetic wins prove only that the engine does what it was designed to on what the simulation models.

## 3. Engineering

### 3.1 Layout and build

```
Package.swift                 # swift-tools 6.2; swiftLanguageMode(.v5); macOS 26
Sources/AirFocusCore/      # pure, testable logic: no AppKit side effects (CoreGraphics types OK)
  AffineHeadMap.swift, OneEuroFilter.swift, TargetSelector.swift, LookAwayDetector.swift,
  CalibrationPlan.swift (point generation + collinearity), CalibrationCapture.swift (settle/average/validate state machine),
  WindowFilter.swift (filters CGWindowList dictionaries -> TrackedWindow, Stage Manager rejects, visible-region math),
  Geometry.swift (CG<->AppKit conversion helpers, envelope), Settings keys/defaults,
  Sensitivity.swift (the slider's mapping), OverlayAppearance.swift (StyleColor and the overlay's look),
  LiveSwitcher.swift (the live decision path), IntentEngine.swift (shadow-mode intent switching),
  TraceFormat.swift (session trace events and lines), TraceReplay.swift (context, live replay, intent runner, metrics, report),
  TraceFile.swift (gzip, reading traces), TraceSynthesizer.swift (synthetic traces)
Sources/AirFocus/          # the app: AppDelegate/menu, HeadTracker, AudioRoute, WindowEnumerator, AX, WindowFocuser,
                              # Overlay, HotKeys, KeyActivity, ScreenSaverControl, SessionStateObserver, Logging, Simulator, CLI,
                              # SettingsWindow, SettingsView, MenuBarIcon, TraceRecorder (trace files + shadow intent)
Tests/AirFocusCoreTests/   # unit tests for everything in Core
Support/Info.plist            # R§7.2: CFBundleIdentifier com.gshimoon.airfocus, LSUIElement, NSMotionUsageDescription (says traces stay local), version 0.1.0
Support/MenuBarIcon.png       # the user's menu bar art
Support/AppIcon.icon          # the Liquid Glass app icon, an Icon Composer document (the AirPod and cursor as separate glass layers)
Support/AppIcon.icns          # full-resolution fallback for CFBundleIconFile
scripts/build-app.sh          # R§7.3; also compiles AppIcon.icon to Assets.car with actool and copies the icons
Makefile                      # build, test, app, run, install, reset-tcc, clean
README.md
```

- **Signing:**
  - The identity comes from the `SIGN_IDENTITY` environment variable, else from an untracked `signing-identity.local` file holding a certificate name or SHA-1, else ad hoc. Releases are ad hoc.
  - Ad hoc builds pin the designated requirement to the bundle id (R§7.4). If the named certificate is missing, the build falls back to ad hoc.
  - Use the hardened runtime. Add no entitlements.
- **`make install`:** copy the app to `~/Applications/AirFocus.app`.
- **`make run`:** build the app and launch it with `open`.

### 3.2 CLI flags (for diagnostics and headless verification)

Run these from the bundled binary, `build/AirFocus.app/Contents/MacOS/AirFocus <flag>`. Each prints and exits without starting the menu bar UI.

- `--diagnose` prints:
  - OS
  - motion availability and authorisation status
  - the default audio output name and transport
  - AX trust
  - screen-lock delay (from `sysadminctl`)
  - Stage Manager status
  - whether each private symbol resolves (SkyLight, `_AXUIElementGetWindow`, login.framework SAC*)
  - screens with frames
  - the stored calibration summary
- `--list-windows` prints the tracked windows after filtering: id, PID, app name, CG frame, visible fraction, and the dot position.
- `--overlay-preview [seconds]` shows the runtime overlay (dots on every tracked window, the frontmost one highlighted, and a sample pointer and banner) for N seconds, default 5, then exits. This one does draw on the real screen.
- `--render-overlay <png> [tracking|calibration] [--demo-windows] [--pointer-only] [--recenter-cue] [--style k=v,...]` draws the overlay offscreen, never ordering a panel onto the screen, and checks numerically that dots and borders landed with the right colour. It uses the stored settings (including the overlay mode, Hidden by default), or with `--style` the defaults plus those values. `--demo-windows` uses fixed windows so renders can be compared pixel for pixel. In Hidden mode it checks instead that no dot, border or pointer is drawn and that no pixel differs from the background except the reference outlines and, with `--recenter-cue`, the cue. `--pointer-only` checks that Mission Control's pointer and pick highlight draw and nothing else.
- `--render-settings <png> [--section tracking|appearance|lookAway|general] [--appearance light|dark] [--reduce-transparency] [--increase-contrast] [--style k=v,...]` builds the real Settings window with default settings, never ordered in, and also checks that closing releases it. This verifies layout and text only: Liquid Glass does not composite offscreen, so glass comes out flat and glass labels may take the wrong colour.
- `--render-menubar-icons <dir>` renders every icon state at actual size and 8×, on light and dark menu bars, plus a contact sheet.
- `--style` keys: `overlay showDots dotColor dotSize showBorder borderColor borderWidth showPointer pointerColor pointerShape pointerSize showRing showBanners sensitivity`. `overlay` is `hidden` or `visible`. Colours are `#RRGGBB` or `accent`.
- `--replay-trace` and `--synthesize-trace`: §2.12.
- The render flags write no preferences. An unknown `--` flag prints the help and exits rather than launching the menu bar app.

### 3.3 Mouse simulation mode

**Developer › Simulate head with mouse** replaces `HeadTracker` with a source that turns the mouse position into synthetic yaw and pitch:

- About 40 pt per degree around the main screen's centre.
- Rotation speed comes from the mouse velocity.

The rest of the pipeline is unchanged: calibration, filter, selector, focuser and overlay. This lets the whole app be exercised without AirPods. Look-away can't trigger in simulation mode, because mouse movement counts as input. That's fine.

### 3.4 Logging

- Write state changes to an `os.Logger` (subsystem `com.gshimoon.airfocus`) **and** to the file `~/Library/Logs/AirFocus/AirFocus.log`, rotating at 5 MB.
- Things to log:
  - motion start, stop, stall and restart
  - sample rate once a minute while tracking
  - reference jumps
  - calibration results
  - focus requests and the path used (SkyLight or fallback), with the verify result
  - look-away transitions
  - screen saver and lock notifications
- `[intent]`: the shadow engine's would-switch lines, yaw anchors and the ten-minute comparison (§2.11).
- Never log keystrokes or window titles. Log the app name and window id only.

### 3.5 Quality bar

- `swift build` produces **zero warnings** in our code. `swift test` passes.
- Unit tests in Core cover:
  - **affine fit:** an exact recovery test, a noisy-fit residual test, and the collinear-plus-supplement case
  - **recenter**
  - **envelope inversion**
  - **1€ filter:** convergence and lag
  - **TargetSelector:** dwell, hysteresis, cooldown, the typing guard, and the keyboard-glance and off-screen rejects
  - **LookAwayDetector:** trigger, veto, the 0.3 s flicker tolerance, look-back, the pitch-only mode after a restart, and wake rate limiting
  - **calibration capture:** settle, average, the standard-deviation reject and timeout
  - **calibration plan:** supplement rules and ordering
  - **window filtering:** synthetic window-list dictionaries, including Stage Manager thumbnails, own-window exclusion, and own windows occluding while Settings is open
  - **sensitivity:** the midpoint equals the original values exactly, every parameter is monotonic, out-of-range input is clamped
  - **settings:** the one-time `switchSpeed` migration, colour round trip, corrupt-value fallback, defaults matching the original look, and `calibrations` left alone
  - **coordinate conversion:** a two-monitor layout with a negative-origin second display
  - **live path extraction:** `LiveSwitcher` against a transcription of the pre-extraction AppController code, identical at every step of 120,000 randomized steps (samples, polls, flicks, Mission Control, focus failures, hotkeys, recenters, setting changes, keys)
  - **trace format:** fixed-point round trips bit for bit, every event's line round trips, the calibration survives exactly, no key identity or title, gzip with its CRC and other tools' name field
  - **intent engine:** far clean shifts within the 450 ms dwell, a boundary hover never switching, typing raising the bar without locking, creep counting little, glance habits per pair, the head model learning from clicks and ignoring clicks without looking, abstaining on unknown yaw until a click anchors it, pitch still working, the gates, determinism
  - **replay:** replayed-live equal to recorded-live and replayed-intent to the shadow decisions, determinism, and on synthetic traces of two seeds intent beating live on bounces and typing switches without being meaningfully slower on clean switches
  - **settings:** the overlay mode defaulting to Hidden, existing installs included, and surviving Restore Defaults
- Keep the main thread light. Motion arrives on a serial queue and hops to main. The window poll runs at 8 Hz only while tracking or calibrating, and nothing polls while the app is idle. The Settings status row refreshes at most twice a second, only while the window is open, and never at the sample rate. Session traces only format a line on the main thread; their disk work is on a utility queue, and they add no timer (flushing rides on the samples and the 1 Hz housekeeping).
- No force-unwrap crashes on missing private symbols. Every private API goes through `dlsym` and has a fallback.

## 4. Out of scope for v1

- Eye tracking with the camera.
- Per-app rules.
- Notarisation and DMG packaging.
- Quadratic maps.
