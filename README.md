# Subway Builder Mobile Unofficial

An independent **Android-only** mobile subway-building game built with **Godot 4** and **GDScript**.

## Platform

- Target: Android phones and tablets only
- Development: Godot 4 Editor
- Language: GDScript
- Test delivery: Android APK
- Desktop and web releases are not planned at this stage

## Project status

Early foundation stage. The first milestone establishes a clean Godot project before railway construction systems are added.

## Open the project

1. Install Godot 4 on a development computer.
2. Clone or download this repository.
3. In Godot, choose **Import** and select the `project.godot` file.
4. Press **F5** to run the main scene in the editor for an early layout check.
5. Configure the Android export tools before creating an APK.

The editor run is only an early development check. The intended game experience must be validated on Android hardware.

## Development principles

- Design every game interaction for touch input.
- Make one focused change at a time.
- Test the project after each change.
- Keep gameplay systems separate from interface systems.
- Do not add external map services or API keys until the basic prototype works.

## Planned milestones

1. Android-focused project foundation and launch screen.
2. Touch camera controls and map surface.
3. Track geometry and station placement.
4. Junctions, parallel tracks, and platforms.
5. Service lines and train movement.
6. Map data and optional 3D presentation.
7. Android APK testing and optimization.

## Important

This is a clean rebuild. The previous Kotlin/Leaflet implementation is a reference only; its code is not copied into this project.
