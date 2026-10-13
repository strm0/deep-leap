# Deep Leap

A Mac app that reads two dancers' hands from live camera and turns each hand's position into a number that controls sound. I built it for Lisa Janbell's dance piece Deep Leap, which played at MDT, Moderna Dansteatern in Stockholm, from 23 to 26 April 2026.

The pictures and the story are in the case study: https://oscarstrom.com/deep-leap/

## What it does

The app finds the dancers' bodies and hands in each video frame with Apple's Vision framework. It sends one number from 0 to 1 for each dancer, 30 times a second, as OSC messages over UDP. In the production the numbers went to Ableton Live through a Max for Live receiver, where they were mapped to effects.

The app makes no sound itself. Nothing is worn by the dancers, and the cameras are ordinary ones on tripods.

The window is split into two zones. Each zone has its own camera, its own lock and its own number, so two dancers can play at once.

The tracking is Apple's Vision framework. No model was trained for this app.

## The hand lock

Vision finds hands in every frame, but it keeps no memory of which hand is which from one frame to the next. When the app mixed two hands up, the dancer lost the feeling that their movement was causing the sound.

The lock solves this. The operator clicks on a hand once, a red ring appears on it, and from then on the app only looks for the hand nearest to where that hand just was.

The final version has two modes, and both are built on the lock:

| Mode | The number | OSC address |
|---|---|---|
| Center | Distance of the locked hand from the centre of the zone's square, 0 at the centre and 1 at the edge | `/zone1/Center`, `/zone2/Center` |
| Top / Bottom | Height of the locked hand in the square, 0 at the bottom and 1 at the top | `/zone1/TopBottom`, `/zone2/TopBottom` |

When a lock is moved to another hand, the number eases to its new value over 3 seconds, so the sound does not jump.

In February 2026 the app had six modes, four of them without the lock: the hands measured from the centre, from the shoulders or from the feet, and the distance between two dancers' heads. The final version keeps only the two built on the lock.

## Lasting a whole show

A show lasts far longer than a test, and two faults only appeared after a long run. The app slowly used more and more memory, and the receiving side in the music software went silent after 30 to 60 minutes. Both are handled by restarting the part in question while the app keeps running: the Vision request handler is recreated every 1,000 frames and the OSC sender every 1,800 frames.

## Built with

Swift, SwiftUI, Apple Vision, AVFoundation, and OSC over UDP written directly on BSD sockets. There are no external dependencies. All the code is in one file, `deepLeap/deepLeapApp.swift`.

## Build and run

You need:

- A Mac with macOS 13.5 or later
- Xcode 16 or later
- A camera: built in, external, or an iPhone through Continuity Camera
- Something listening for OSC on `127.0.0.1`, port `9000`. See "Receiving in Ableton Live" below

Then:

1. Open `deepLeap.xcodeproj` in Xcode.
2. Under Signing & Capabilities, choose your own team or "Sign to Run Locally".
3. Build and run, and allow camera access when macOS asks.

From the command line:

```bash
xcodebuild -project deepLeap.xcodeproj -scheme deepLeap -configuration Debug build
```

## Receiving in Ableton Live

The app only sends. Ableton Live does not read OSC by itself, so the system needs a Max for Live device in the Live set that listens on UDP port 9000, receives the numbers and maps them to parameters. Without a receiver the app runs and tracks, and nothing happens in Ableton.

The production used [SM OSC Receiver v2](https://maxforlive.com/library/device/8632/sm-osc-receiver-v2), from maxforlive.com. That device is not my work, so it is not part of this repository. Download it from its own page.

To check the app without Ableton, any OSC receiver on port 9000 will show the numbers.

## Manual

[MANUAL.md](MANUAL.md) is the manual I wrote for the operator in March 2026. It covers the interface, the two modes, relocking and the camera setup.

## Credits

The app, its design and its manual: Oscar Ström, software engineer on the production, November 2025 to April 2026.

Deep Leap, as [MDT credits it](https://mdtsthlm.se/deep-leap):

- Idea, concept and choreography: Lisa Janbell
- Co-creating dancers: Cajsa Godée and Rebecca Livaniou
- Sound design and composition: Adde Huumonen
- Sound art and sound engineering: Sade Kasiri, who also ran the app during the shows

The full credits for the production are on the [case study](https://oscarstrom.com/deep-leap/).

## Licence

MIT. See [LICENSE](LICENSE).
