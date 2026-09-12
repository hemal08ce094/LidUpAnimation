# Notice

Lid Up recreates the iPhone Duo folding animation on a MacBook lid. It is an
independent project and is not affiliated with Apple.

## Attribution

The lid angle sensor reader (`LidAngleSensor.swift`) follows the HID device
identifiers and feature-report layout documented by:

- Sam Henri Gold, [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor), Apache License 2.0.
- Makito, [Mac-Duo](https://github.com/sumimakito/Mac-Duo), Apache License 2.0. Copyright 2026 Makito.

The screen streaming, padded Gaussian-pyramid texture and full-screen overlay
window approach were studied from Mac-Duo and rewritten for this project.
The critically damped spring and the "anchored picture, moving glass"
optical model were informed by Mac-Duo and by
[DhananjayBhosale/MacDuo](https://github.com/DhananjayBhosale/MacDuo) (MIT).
[lqSky7/iphone-duo-macos-animation](https://github.com/lqSky7/iphone-duo-macos-animation)
was used as a visual reference.

No source files, binaries, artwork or videos from those projects are bundled.

## Privacy

The app reads the lid hinge angle through IOKit HID (no permission needed) and,
only while the lid is moving, streams the built-in display through
ScreenCaptureKit (Screen Recording permission). Frames live in GPU memory for
the duration of the fold and are never written to disk or sent anywhere.
