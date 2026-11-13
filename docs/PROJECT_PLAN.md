# Project Plan

## Purpose

Build an Android-only, mobile-first subway construction game with a stable, understandable codebase.

## Platform decision

- **Supported platform:** Android phones and tablets.
- **Engine:** Godot 4.
- **Language:** GDScript.
- **Development editor:** Godot Editor on a computer.
- **Delivery:** Android APK for testing; release packaging can be decided later.
- Desktop and web exports are out of scope unless the project direction changes.

## Development rules

1. Design for touch input first; do not assume a mouse or keyboard.
2. Implement one feature at a time.
3. Keep each system in its own scene or script.
4. Test changes in the Godot editor, then validate Android builds on a device.
5. Prefer built-in Godot features before adding plugins.
6. Record known issues instead of layering quick fixes over them.

## Milestones

### 1. Foundation
- [x] Create the Godot 4 project configuration.
- [x] Create a launch scene.
- [x] Set a mobile portrait viewport as the initial layout baseline.
- [x] Define Android as the only target platform.
- [ ] Open and run the project in Godot Editor.
- [ ] Configure Android export tools and create a test APK.

### 2. Mobile map and camera
- Add a playable map surface.
- Add touch pan and pinch-zoom controls.
- Keep camera gestures separate from construction input.
- Handle safe areas and different Android screen sizes.

### 3. Railway basics
- Add a station node.
- Add a single-track segment.
- Add a placement preview and confirm/cancel flow.
- Validate track endpoints and geometry.

### 4. Advanced railway systems
- Parallel tracks.
- Curves and junctions.
- Platforms and station clearance.
- Track layers and crossings.

### 5. Simulation
- Service lines.
- Train movement.
- Passenger and operating systems.

### 6. Android delivery
- Touch-friendly interface and gestures.
- Android APK export.
- Test on real Android devices and adjust performance.
- Handle pause/resume, app lifecycle, and different screen densities.

## Current architecture direction

Use Godot scenes and GDScript. Keep map rendering, railway geometry, simulation, and interface code separate. Do not add Kotlin or external map dependencies unless a concrete Android integration requirement calls for them.
