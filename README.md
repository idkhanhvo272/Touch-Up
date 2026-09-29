# Touch-Up (fork with trackpad-style gestures)
**Universal user-level driver to support touchscreens on macOS**
<hr/>

This is a fork of [shueber/Touch-Up](https://github.com/shueber/Touch-Up). It adds trackpad-style multi-finger gestures, smooth scrolling with momentum, and support for SiS touch panels. For the original project, its notarized builds and its documentation, see the upstream repository.

Most current touchscreens work with Microsoft Windows out-of-the-box as they implement a standardized communication via USB HID. However, nothing happens when connecting these screens to a Mac. Touch Up is a user-space driver that reads the HID data of a touchscreen, turns it into touches, and posts pointer, scroll and gesture events to the system.

## What this fork adds

- **SiS touch panels** (USB `0x0457/0x0819`, sold as UPERFECT, WIMAXIT, EVICIV, Verbatim PMT-14 and others). These panels stay in single-point mouse emulation until the host switches them to multitouch, which Windows does and macOS does not. The fix comes from upstream PR #36 by Brian Peat.
- **Trackpad-style gestures**, listed below.
- **Smooth scrolling.** Scroll events carry the same phases as a trackpad's, so apps rubber-band at the edges, coast after a flick and swipe between pages. Events are posted once per display frame, with finger motion interpolated between digitizer reports. The momentum follows iOS deceleration, and faster flicks launch faster coasts.
- **Input Monitoring request.** The app asks for Input Monitoring itself, so it appears in System Settings without adding it by hand.
- **A one-command local build**: `scripts/install-local.sh`.

## Gestures

| Fingers | Gesture | Result |
|---|---|---|
| 1 | tap | click |
| 1 | drag | move the pointer, scroll, or point and click (Settings › On Finger Drag) |
| 1 | hold, then drag | drag (select text, move windows) |
| 2 | drag | scroll, with momentum and swiping between pages |
| 2 | pinch | zoom |
| 2 | rotate | rotate |
| 2 | tap | secondary click (after a 0.3 s wait for a possible double tap) |
| 2 | double tap | smart zoom |
| 2 | swipe in from the right edge | Notification Center |
| 3 or more | swipe left or right | switch Spaces, following the fingers |
| 3 or more | swipe up / down | Mission Control / App Exposé |
| 4 or more | pinch in / spread | Launchpad (Apps) / Show Desktop |
| 3 | tap | Look Up |

## Requirements

- macOS 13.1 or later.
- A touchscreen that works with Windows (a USB HID digitizer).
- Xcode, to build the app.
- A code signing identity. **A free Apple ID is enough**; no paid developer account is needed.

## Build and install

1. **Create a signing certificate** (once). Open Xcode › Settings › Accounts and add your Apple ID. Select the *Personal Team*, click *Manage Certificates…*, then *+* › *Apple Development*.
2. **Tell the script which identity to use.** List your identities with `security find-identity -v -p codesigning`, then save yours in `scripts/signing.local.env`:
   ```
   SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
   ```
   That file is gitignored, like certificates and provisioning profiles, so it never ends up in the repository.
3. **Build, sign and install:**
   ```
   scripts/install-local.sh
   ```
   This builds a Release build, installs it to `/Applications/Touch Up.app` and launches it.
4. **Grant permissions** in System Settings › Privacy & Security:
   - **Input Monitoring**, to read the touchscreen.
   - **Accessibility**, to post pointer, scroll and gesture events.

   Relaunch Touch Up afterwards.
5. Optionally, add Touch Up to System Settings › General › Login Items.

Why a real identity and not ad-hoc signing: with the hardened runtime, the app and `TouchUpCore.framework` must share one Team ID, or dyld refuses to load the framework. macOS also ties the permissions above to the signing identity. Keep using the same identity for every build and the grants carry over; switch identities and you have to grant them again.

## Privacy and permissions

The app runs in the App Sandbox. It has only three entitlements: USB device access, read access to files you pick, and the sandbox itself. **It has no network access.**

## Troubleshooting

- **Touch Up does not appear in a permission list.** Another copy with the same bundle ID, such as a build product, confuses System Settings. The install script unregisters its build product. For other copies, run `lsregister -u <path>` and then `tccutil reset All de.schafe.Touch-Up`.
- **Touch stops working after sleep while the picture stays.** The panel's touch controller has dropped off USB. Bus-powered portable monitors often cannot supply enough power, so give the monitor its own power supply.
- **Everything looks tiny on a high-resolution portable monitor.** The panel may report a bogus physical size, so macOS runs it at 1x. Pick a HiDPI mode such as "looks like 1260×840" for a 2520×1680 panel.
- **Debugging gestures.** Launch with logging to stderr:
  ```
  open --env TOUCHUP_DEBUG_GESTURES=1 --stderr /tmp/touchup.log "/Applications/Touch Up.app"
  ```

## Known limitations

- Gestures use undocumented CGEvent fields and private WindowServer functions, so a macOS update can break them. Dock swipes (Spaces, Mission Control, Launchpad, Show Desktop) use the event format from before macOS 27.
- Notification Center has no default shortcut. The first time it is opened, Touch Up binds it to a key code no keyboard produces.
- Dock swipes, Notification Center and Look Up are less tested than scrolling and zooming.

## The *TouchUpCore* Framework

Game developers, researchers, and others who need access to all touch data can integrate the TouchUpCore **framework** themselves. It provides simple access to all touches recognized on the touch surface, simplifying multitouch prototype development on macOS. The Touch Up app itself is an example of integrating it; see the *DebugView* for how to visualize touch points. Your app needs the USB entitlement if it runs in the Sandbox.

## Credits and licenses

- **Touch Up**, © 2024 Sebastian Hueber, MIT License (see [LICENSE](LICENSE)). This fork's changes are released under the same license.
- **SiS multitouch wake-up**, by Brian Peat, from [upstream PR #36](https://github.com/shueber/Touch-Up/pull/36).
- **Gesture event synthesis.** The trackpad scroll, dock swipe, smart zoom and symbolic hot key events are derived from the reverse engineering documented in [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) by Noah Nuebling. That work builds on natevw's CalfTrail Touch. The derived parts are subject to the [MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License), which requires derived works to state that they are derived from the MMF Source: **the gesture synthesis in `TouchUpCore/TUCCursorUtilities.m` is derived from the MMF Source.**
