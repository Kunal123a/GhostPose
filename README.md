# GhostPose 📸

**Overlay. Match. Shoot.**

A Flutter camera app that helps you recreate any photo perfectly.

**Design:** modern, minimal, Apple Camera-inspired — full-bleed viewfinder, frosted-glass controls, an uppercase mode strip (GRID · TIMER · GHOST · PHOTO · FLIP) — GHOST is the primary mode, selected by default with the iOS-yellow accent, and the classic white-ring shutter.

Pick a picture from your gallery and it appears as a **transparent overlay on top of the live camera**. Line yourself (or your subject) up with the overlay — same pose, same angle, same framing — then tap the shutter for a perfect match.

## Features

- **Gallery pose overlay** — choose any photo from your gallery as a reference
- **Opacity slider** — make the overlay faint or solid (5%–100%)
- **Drag & pinch** — move the overlay with one finger, pinch to resize it
- **Mirror** — flip the overlay (perfect for selfie poses)
- **Fill / Fit** — stretch the reference to fill the frame, or show it whole
- **Lock** — freeze the overlay in place so taps don't move it while shooting
- **Show / Hide + Reset** — blink the overlay on/off to compare, reset its position in one tap
- **Aspect ratio** — FULL / 4:3 / 9:16 / 1:1 from the expandable top settings bar; the viewfinder frames the shot and the saved photo is cropped to match
- **HDR** — computational HDR processing (shadow lift, contrast, colour) applied to the saved photo, from the same settings bar
- **Front & back camera** switch
- **Flash** — off / auto / on / torch
- **Self-timer** — off / 3s / 5s / 10s with a big on-screen countdown
- **Rule-of-thirds grid**
- **Auto-save to gallery** — every shot is saved to a "GhostPose" album in your phone's gallery
- **Reuse a shot as a pose** — open any photo you just took and set it as the next overlay

> The overlay is only a guide — it is **never burned into your photo**. Your saved picture is always the clean camera shot.

## Run it

You need [Flutter](https://docs.flutter.dev/get-started/install) installed.

```bash
cd photo_pose_camera
flutter pub get
flutter run            # on a connected Android/iOS phone
```

Build an installable Android APK:

```bash
flutter build apk --release
# APK appears at: build/app/outputs/flutter-apk/app-release.apk
```

## How to use

1. Open the app and allow camera permission.
2. Tap the **gallery thumbnail** (bottom-left) and pick your pose photo.
3. Use the **opacity slider** so you can see both the overlay and the live camera.
4. Drag / pinch the overlay until it sits exactly where you want it. Tap **Lock** when it's perfect.
5. Match the pose to the overlay, set a **timer** if you're shooting yourself, and tap the big **shutter button**.
6. Your photo is saved to your gallery automatically. Tap the thumbnail (bottom-right) to see your shots.

## Permissions

| Permission | Why |
|---|---|
| Camera | To show the live camera and take photos |
| Photos / Gallery | To pick a pose reference and save your shots |

## Tech

- Flutter + Dart
- `camera` for the live preview & capture
- `image_picker` for gallery selection
- `gal` for saving to the device gallery
- `permission_handler`, `path_provider`

Verified with `flutter analyze` (no issues) and `flutter test` (passing) on Flutter 3.24.5.
