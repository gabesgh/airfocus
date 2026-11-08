# AirFocus

AirFocus switches windows on your Mac based on where your head points. It reads head orientation from your AirPods, works out which window you're facing and gives that window keyboard focus. Turn toward another terminal, hold for about half a second, and you're typing in it. Your hands stay on the keyboard.

I built it for running several Claude Code agents in separate terminal windows. It works with any app.

It also does a few things with head gestures:

- Flick your head up to open Mission Control, then hold your head on a window for a second to pick it.
- Flick left or right to move one Desktop over.
- Look away from the screen for 5 seconds and the screen saver starts. Look back and the unlock prompt is waiting.

Nothing draws on screen while you work. AirFocus sits in the menu bar, and you can hide that icon too.

## Requirements

- A Mac with Apple silicon running macOS 26 Tahoe or later.
- AirPods with head tracking, meaning any AirPods Pro, AirPods 3 or 4, or AirPods Max. Beats Fit Pro should work too, though I haven't tried one. AirPods 1 and 2 have no motion sensor.
- The AirPods in your ears and selected as the sound output. Nothing has to be playing, but macOS only sends head motion from the current output device.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/gabesgh/airfocus/main/install.sh | bash
```

It downloads the latest release, checks it against its checksum and puts AirFocus in /Applications. Run the same line again to update. The script is short, so give [install.sh](install.sh) a read first if piping into bash makes you uneasy.

AirFocus isn't signed with a paid Apple Developer ID, so macOS blocks it when it comes from a browser. Files fetched with curl don't get that flag. If you'd still rather download `AirFocus.zip` from the [Releases page](https://github.com/gabesgh/airfocus/releases), macOS refuses to open it the first time. Go to System Settings › Privacy & Security, find the message about AirFocus and click Open Anyway.

macOS treats every release as a new app, so you grant the permissions again after each update. The installer clears the old entries so the prompts come back cleanly.

## First run

AirFocus asks for two permissions.

1. **Accessibility**, to focus windows in other apps and to notice when you're typing. It records when a key was pressed, never which key. Turn it on in System Settings › Privacy & Security › Accessibility.
2. **Motion & Fitness**, to read your head orientation. macOS asks the first time tracking starts with your AirPods connected.

It doesn't need Screen Recording. The window list macOS gives every app already has each window's position, size and stacking order.

Then calibrate.

## Calibrate

Press ⌃⌥⌘C. A dot appears in every window. Point your nose at the pulsing dot and hold still until its ring fills, then move on to the next one. Moving only your eyes won't register, because AirFocus can only see your head. Return captures a dot right away and Esc cancels. With fewer than three windows, AirFocus adds points at the centre and corners of the screen.

The banner at the end shows the average error. Under 2° is good. Above 3°, run it again and turn your head more deliberately.

AirFocus keeps one calibration per display arrangement, so plugging into a different set of monitors loads the matching one.

### Recenter

The AirPods' idea of straight ahead drifts. It also resets whenever the motion stream restarts, which happens at launch, when the AirPods reconnect and when the sound output changes. After a reset AirFocus pauses switching and the menu bar icon shows a pause badge.

To carry on, look at the middle of the focused window and press ⌃⌥⌘R. A dot shows there for a second, and AirFocus recenters on it when the ring fills. Typing in the focused window with your head still for a second or two does the same thing. Press ⌃⌥⌘R any time switching seems to aim a little off.

## Hotkeys

| Keys | What it does |
| --- | --- |
| ⌃⌥⌘T | Start or stop tracking |
| ⌃⌥⌘C | Calibrate |
| ⌃⌥⌘R | Recenter on the focused window |
| ⌃⌥⌘F | Focus the window you're facing, right now |
| Return, Esc | During calibration, capture the current dot or cancel |

## How switching works

Rest your head on a window and AirFocus focuses it after 450 ms. The Sensitivity slider in Settings › Tracking runs that from 800 ms at Calm to 250 ms at Snappy.

Typing into the wrong terminal is worse than a slow switch, so AirFocus holds off when:

- you typed in the last 0.7 s
- your head is still moving
- it switched less than 0.6 s ago
- you're only just past the edge of the current window
- you're looking down at the keyboard or off the screen

If you click a window or use ⌘-Tab, AirFocus goes along with it and doesn't pull focus back. Hotkey only mode, in Settings › Tracking, never switches by itself, and ⌃⌥⌘F focuses whatever you're facing.

By default nothing is drawn. Set Settings › Appearance › Overlay to Visible, or pick Show Overlay in the menu, to get a dot in each window, a border on the focused one and a pointer that follows your head. You can change the shape, colour and size of each.

## Head flicks

A flick is a sharp, short turn, much faster than looking at another window, so ordinary glances still just switch windows.

- **Flick up** to open Mission Control, and flick up again to close it. While it's open the head pointer stays visible, and holding it on a window for about a second brings that window forward.
- **Flick left or right** to move one Desktop. macOS has no public API for this, so AirFocus presses your Move left a space and Move right a space shortcuts, ⌃← and ⌃→ unless you changed them. If they're turned off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, AirFocus tells you.

A flick has to start while you're facing the screen, so looking up from the keyboard or turning back to the screen doesn't count. If flicks miss or fire by accident, move Flick strength in Settings › Tracking. Each gesture has its own switch there too.

## Look away

Turn more than 30° past the edge of your screen, or tilt your head 25° above it, and hold for 5 seconds. AirFocus starts the screen saver. Look back and hold still for half a second, and it wakes the display to the unlock prompt, where you unlock with your password or Touch ID as usual. Looking down never counts, because that's where your keyboard and phone are. Any key press or mouse movement during the countdown cancels it.

Whether the screen saver locks your Mac is up to System Settings › Lock Screen › Require password after screen saver begins. AirFocus shows that setting in its menu and never changes it. If you want a lock every time, turn on Settings › Look Away › Lock immediately.

The delay goes up to 60 seconds. Settings › Look Away also has Treat removing AirPods as away, which is off by default because people take AirPods out at their desks.

## Settings and the menu bar icon

Open Settings from the menu bar menu, or open AirFocus again from Spotlight. The second way matters if you hide the menu bar icon, which Settings › General lets you do. The choices are always shown, hidden 5 seconds after you leave AirFocus, or hidden. The hotkeys work either way.

Automatic switching pauses while the Settings window is in front, so your head can't pull focus away from a slider you're dragging.

## Privacy

Nothing leaves your Mac. AirFocus writes a log to `~/Library/Logs/AirFocus/AirFocus.log` with state changes, focus requests and look-away events. It never logs keystrokes or window titles.

Developer › Record Session Trace turns on a local recording for tuning the switching. It holds head angles, window positions, focus changes, when keys were pressed but not which keys, and where you clicked. It's off by default, files older than 14 days are deleted, and Developer › Delete Traces removes the rest.

## Troubleshooting

**No head motion.** Check that the AirPods are in your ears and are the current sound output. The menu says when they aren't and links to Sound settings. Then check System Settings › Privacy & Security › Motion & Fitness.

**Your iPhone took the AirPods.** Pick them again in Control Center › Sound. Turning off automatic switching for the AirPods on your other devices stops it happening.

**Focus doesn't switch.** Check that Accessibility is on and the menu bar icon has no pause badge. A few apps resist being focused from the background. The log says when a focus request didn't take.

**Permissions stop working after an update or rebuild.** macOS ties them to the app's signature. Remove AirFocus from the Accessibility list with the minus button, open it again and allow it.

**Windows jump around.** Stage Manager rearranges windows whenever focus changes, which fights AirFocus. Keep your terminals in one stage or turn Stage Manager off.

## Build from source

You need Xcode 26. It's a Swift package with a Makefile around it.

```sh
make test      # unit tests
make app       # builds build/AirFocus.app
make install   # quits any running copy and installs to ~/Applications
```

Builds are signed ad hoc unless you name a certificate. Put a certificate name or SHA-1 in `signing-identity.local`, which git ignores, or set `SIGN_IDENTITY`. With a real certificate your permissions survive rebuilds.

Start the app with `open` or from Finder. If you run the binary straight from Terminal, macOS charges the permissions to Terminal instead, and head motion never arrives.

## How it works

- CMHeadphoneMotionManager streams head orientation at 50 Hz. A One Euro filter smooths it, and the calibration maps it to a point on screen.
- CGWindowListCopyWindowInfo lists the windows, with no Screen Recording permission needed.
- Bringing another app's window to the front from the background uses SkyLight, a private framework, through the same calls AltTab makes. A public Accessibility path is the fallback. Private APIs can break in a macOS update.
- The screen saver starts through ScreenSaverEngine, and a wake request brings up the unlock prompt.

[docs/SPEC.md](docs/SPEC.md) describes every behaviour in detail, and [docs/RESEARCH.md](docs/RESEARCH.md) has the research behind it.

The Developer menu can drive AirFocus with the mouse instead of your head, which is handy without AirPods. The binary also takes command-line flags for diagnostics, offscreen renders and replaying session traces. Run `AirFocus.app/Contents/MacOS/AirFocus --help` for the list.

An experimental intent engine runs next to the normal switching in shadow mode. Instead of a fixed delay it weighs typing, deliberate turns and where you click, but it only logs what it would have done. `--replay-trace` compares the two on recorded traces.

## License

MIT. See [LICENSE](LICENSE).
