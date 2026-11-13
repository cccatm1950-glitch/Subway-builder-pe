# Project Plan

## Purpose

Build a mobile-first subway construction game with a stable, understandable codebase.

## Development rules

1. Implement one feature at a time.
2. Keep each system in its own scene or script.
3. Test every change in Godot before moving on.
4. Prefer built-in Godot features before adding plugins.
5. Record known issues instead of layering quick fixes over them.

## Milestones

### 1. Foundation
- [x] Create the Godot 4 project configuration.
- [x] Create a launch scene.
- [x] Set a portrait mobile viewport.
- [ ] Open and run the project in Godot Editor.

### 2. Map and camera
- Add a playable map surface.
- Add pan and zoom controls.
- Keep camera input separate from construction input.

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

### 6. Mobile delivery
- Touch-friendly interface.
- Android export.
- Test on real devices and adjust performance.

## Current architecture direction

Use Godot scenes and GDScript. Keep map rendering, railway geometry, simulation, and interface code separate. Do not add Kotlin or external map dependencies unless a concrete Android integration requirement calls for them.
