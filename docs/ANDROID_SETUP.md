# Android Development Setup

## Target

This project targets Android phones and tablets only.

## Required tools

1. Godot 4 Standard Editor.
2. Android SDK and platform tools.
3. Java Development Kit version supported by the installed Godot 4 release.
4. Godot Android export templates matching the exact Godot editor version.
5. An Android device with USB debugging enabled, or a way to transfer and install an APK.

Godot's official Android export documentation should be followed for the exact SDK, JDK, and Gradle requirements of the installed Godot version:
https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html

## First Android build checklist

- [ ] Install the matching Godot export templates.
- [ ] Install and configure the Android SDK.
- [ ] Configure the Java SDK path in Godot Editor.
- [ ] Configure the Android SDK path in Godot Editor.
- [ ] Add an Android export preset.
- [ ] Export a debug APK.
- [ ] Install the APK on an Android device.
- [ ] Confirm launch, touch input, screen layout, pause/resume, and performance.

## Important

Do not commit signing keys, passwords, private keystores, or local SDK paths to the repository. A debug APK is sufficient for early testing. Release signing can be configured separately when needed.
