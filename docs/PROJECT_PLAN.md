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
- [x] Configure Android export tools and create a test APK; first debug APK verified on a physical Android phone.
- [ ] Validate the new map scene in the Godot import/export pipeline and on the phone.

### 2. Mobile map and camera
- [x] Add a procedural grid map surface.
- [x] Add touch pan and pinch-zoom controls, plus on-screen zoom buttons.
- [x] Keep camera gestures in the map controller, separate from construction input.
- [x] Add a fixed screen-center crosshair and 32-unit coordinate snapping helper.
- [ ] Validate gestures and safe-area layout on multiple Android screen sizes.

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
