# deepLeap

This is the manual written for the operator in March 2026. It came with a built copy of the app, which is not part of this repository. To build the app yourself, see [README.md](README.md).

Corrected against the source on 13 October 2026: the relock shortcuts are keys 1 and 2, and the OSC sender is recreated automatically, not by relocking. A note on the receiver that Ableton Live needs was added under System Overview.

deepLeap is a macOS application for live dance performance. It uses the computer's camera to track a dancer's body movements in real time and converts those movements into OSC messages, which are sent to Ableton Live to control sound.

---

## System Overview

The app is split into two independent zones: Zone 1 on the left and Zone 2 on the right. Each zone has its own camera input, control mode, and OSC output. The zones operate completely independently of each other.

OSC messages are sent via UDP to `127.0.0.1` on port `9000`.

Ableton Live needs a Max for Live device listening on that port to receive the messages. The production used [SM OSC Receiver v2](https://maxforlive.com/library/device/8632/sm-osc-receiver-v2), which is a separate download and not part of deepLeap.

---

## Installation

1. Copy `deepLeap.app` to your Applications folder
2. On first launch, macOS will block the app with an "unidentified developer" warning
3. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**
4. Confirm once. The app will open normally from that point on

---

## Interface

### Zone Controls (top bar)

Each zone has a top bar with the following controls from left to right:

- **On/Off toggle**: enables or disables OSC output for the zone. When off, the camera still runs but no messages are sent
- **Zone label**: Zone 1 (mint) and Zone 2 (orange)
- **Camera picker**: select which camera to use for this zone
- **Mode picker**: select the control mode (see Control Modes below)
- **View picker**: Crop or Full frame display
- **Connection status**: shows Connected, Disconnected, Connecting, or No camera selected

### Responsiveness Slider

Controls how smoothly the tracked values follow the dancer's movement.

- **Low values (left)**: heavy smoothing, slow to respond, very stable output
- **High values (right)**: fast response, follows movement closely, slightly more raw

A value around 0.5 is a good default. Reduce it if the OSC output feels jittery. Increase it if the tracking feels sluggish.

### Active Zone Toggle and Size Slider

When enabled, the Active Zone defines a square region of the camera frame that is used as the reference area for tracking. A white square is drawn on screen showing the active area.

- **Toggle**: enables or disables the Active Zone constraint
- **Size slider**: scales the square from 50% to 100% of the frame

---

## Control Modes

### Center (formerly Locked Hand)

Tracks a single locked hand. The OSC value represents the distance of the hand from the center of the Active Zone: `0.0` when the hand is at the center, `1.0` when it reaches the edge of the zone.

**How to use:**
1. The dancer steps into frame
2. The operator clicks directly on the dancer's hand in the video
3. The hand is now locked. A red circle appears around it
4. The app tracks that hand by proximity frame to frame
5. To relock to a different hand position, press the **Relock** button or use the keyboard shortcut

**OSC address:** `/zone1/Center` or `/zone2/Center`

---

### Top / Bottom (formerly Locked Hand Vertical)

Same locking behaviour as Center mode, but tracks only the **vertical position** of the locked hand within the Active Zone. Horizontal movement is ignored.

- `1.0` = hand at the top of the Active Zone
- `0.0` = hand at the bottom of the Active Zone

**How to use:** same as Center mode: click the hand to lock it.

**OSC address:** `/zone1/TopBottom` or `/zone2/TopBottom`

---

## Relock

When a hand is locked, a **Relock Hand** button appears below the zone controls. Pressing it releases the lock so you can click a new hand position.

After relocking, the OSC value ramps smoothly from its previous value to the new position over 3 seconds, preventing sudden jumps in the audio.

### Keyboard Shortcuts

- **1**: Relock Zone 1
- **2**: Relock Zone 2

Shortcuts only work when the deepLeap window is in focus.

---

## Proximity Sensitivity

A segmented control appears next to the Relock button when a hand is locked:

- **200px**: looser tracking, the hand can drift further before the lock is lost
- **100px**: tighter tracking, stays closer to the exact locked position

Use 200px if the dancer makes large movements. Use 100px if there are multiple people in frame and you need the lock to stay specific.

---

## OSC Reference

All values are floats in the range `0.0` to `1.0`.

| Zone | Mode | OSC Address |
|------|------|-------------|
| Zone 1 | Center | `/zone1/Center` |
| Zone 1 | Top / Bottom | `/zone1/TopBottom` |
| Zone 2 | Center | `/zone2/Center` |
| Zone 2 | Top / Bottom | `/zone2/TopBottom` |

Messages are sent at 30fps when the zone is active and a hand is locked. No messages are sent if the zone is toggled off or no hand is locked.

**Host:** `127.0.0.1`
**Port:** `9000`
**Protocol:** UDP

---

## Camera Setup

- **Zone 1**: iPhone via Continuity Camera (plug in via USB for best reliability)
- **Zone 2**: iPhone or external camera via a virtual camera app such as Camo or EpocCam (connects over USB and appears as a standard camera in the picker)

If a camera is disconnected during use, the zone shows a "Camera Disconnected" message and stops sending OSC. Reconnecting the camera restores the session automatically.

---

## Tips for Performance

- Lock the hands before the performance starts, not during
- Use the 3-second ramp to your advantage: relock during a quiet moment in the score so the transition is inaudible
- The app recreates its OSC sender automatically every 1,800 frames, about once a minute at 30 frames per second. This keeps OSC arriving in Ableton through a long run, and nothing has to be pressed for it. Relocking does not recreate the sender
- Keep deepLeap as the focused window during performance so keyboard shortcuts work reliably
