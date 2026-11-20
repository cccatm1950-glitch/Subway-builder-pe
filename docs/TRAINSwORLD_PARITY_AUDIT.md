# Trainsworld Parity Audit — Initial Baseline

**Primary reference:** Trainsworld (free browser game)  
**Official playable game:** https://anita.garden/trainsworld/  
**Official documentation:** https://anita.garden/projects/trainsworld/  
**Audit baseline:** repository `main`, inspected 2026-11-20  
**Status:** initial static-code audit; not a complete live-game interaction audit.

## Scope and evidence rules

Trainsworld is the parity reference for the whole Subway Builder PE project: construction, network topology, stations, lines, trains, simulation, demand, economy, maps, and management UI. This replaces Subway Builder v1.6.0 as the primary parity target.

This document distinguishes:
- **Code-confirmed:** directly visible in the inspected repository files.
- **Documented reference behavior:** explicitly described by Trainsworld's official documentation.
- **Not yet audited:** cannot be classified as missing until the relevant repository systems and live reference behavior are inspected.
- **Not device-tested:** automated checks do not prove Android touch behavior or visual correctness.

Do not remove working systems just to imitate the reference. Preserve mobile-first interaction and existing glass styling where compatible with reference gameplay. Avoid broad rewrites until the relevant subsystem has an evidence-backed gap list and regression coverage.

## 1. Construction

### Trainsworld reference
- Seven track elevations, from -3 through +3.
- At-grade, viaduct (+1), and tunnel (-2) construction have different terrain/water/cost/maintenance behavior.
- Level changes use 200 m ramps; automatic ramps avoid same-level conflicts and cross water where needed.
- Automatic flyovers may be inserted at merges when space permits.
- Two-way and one-way single-track; default two-track stations allow trains to pass on two-way single-track.
- Normal and high-speed track/train types; tram track is separate and can snap to streets.
- Buses and ferries use non-rail infrastructure.
- Snap to real-world rail and snap beside existing track for fast corridor duplication/express routes.

### Subway Builder PE evidence
- **Code-confirmed:** free-standing track graph nodes and edges; straight and parallel construction; curve and parallel-curve construction; snapped world placement; explicit lane metadata; geometry offset helpers.
- **Code-confirmed:** the graph stores node adjacency and edge geometry; station records are modeled separately from the graph.
- **Not yet audited:** elevation/terrain model, bridges, tunnels, ramps, water/road crossing rules, costs, single-track operating semantics, track classes, tram/bus/ferry systems, real-world rail snapping, and snap-beside-track behavior.
- **Known caution:** current parallel centerline spacing is a fixed 48 world units in the inspected main script. Do not treat it as a real-world metric until the coordinate scale and Trainsworld equivalent are established.

## 2. Junctions and network topology

### Trainsworld reference
- Same-level intersections create delays.
- Automatic ramps and flyovers mitigate conflicts.
- Parallel route duplication and crossover rebuilding are recommended for overloaded tracks/merges.

### Subway Builder PE evidence
- **Code-confirmed:** canonical graph node/edge model with adjacency validation; separate geometry helpers; a junction helper for choosing a branch lane; curve transition paths and lane-group metadata exist in the main construction code.
- **Not yet audited:** robust crossover types, flyover placement, grade-separated conflict detection, route-level capacity, train movement through junctions, and conflict/delay simulation.
- **Regression priority:** single-to-parallel, parallel-to-parallel in both directions, parallel-to-single, shared-node branches, and junction lane continuity. The phantom center-node regression must remain covered.

## 3. Stations and infrastructure

### Trainsworld reference
- Two-track stations support passing on two-way single-track.
- Passing tracks at stations can help express/local service coexist.
- Terminal improvements can reduce excessive turning/terminal crowding.
- Bus stops can be automatic or manually placed; ferries connect ports/stations.

### Subway Builder PE evidence
- **Code-confirmed:** station records include center, platform length, platform width, rotation, and independently stored corridor footprint/contours; station geometry helpers calculate footprints, approach points, and track clearance.
- **Code-confirmed:** station placement does not automatically create station-owned track nodes in the inspected placement handler.
- **Not yet audited:** configurable station track counts, platform layouts, station-to-track topology, terminal improvements, passing tracks, transfers, bus stops, and ferry ports.

## 4. Lines and scheduling

### Trainsworld reference
- Select start and end stations, then quick-fill intermediate stops.
- Loop lines can be created by returning to the first stop.
- Trains can be allocated by low/medium/high time-of-day demand or target headways (for example, every four minutes).
- Copying a line creates a line group; groups support branches and short-turn patterns.
- Express and local services may share double track, with slowdowns; passing tracks can help.

### Subway Builder PE evidence
- **Not yet audited:** no line/scheduling subsystem was inspected in this initial pass. Do not assume it is absent from the whole repository.

## 5. Trains, simulation, demand, and pathfinding

### Trainsworld reference
- Static origin-destination demand includes work, leisure, errands, schools, medical, airports, attractions, weekends/holidays, and intercity travel.
- Passenger mode choice compares train, walking, and driving; intercity trips can use planes.
- Train generalized cost includes access/egress walking, fares/transfers, crowding, and waiting.
- Crowding above 70% capacity feels slower and redistributes passengers across parallel routes.

### Subway Builder PE evidence
- **Not yet audited:** train entities/movement, dispatching, passenger generation, route choice, capacity, crowding, timetable simulation, and performance at large network scale.

## 6. Economy and management

### Trainsworld reference
- Construction, track/station maintenance, and train running costs are modeled.
- In-game money runs at 100x speed relative to the reference real-world cost comparison.
- Advice for loss-making lines includes fewer or shorter trains.

### Subway Builder PE evidence
- **Not yet audited:** budget, construction/maintenance costs, fares, revenue, operating costs, and financial reports.

## 7. Maps and interface

### Trainsworld reference
- Real-world network snapping, terrain-aware track construction, simulation speed controls, line group diagrams, stop ordering, bulk selection/deletion, and community save sharing are documented.
- Official documentation describes the gameplay but does not fully specify every UI detail or mobile adaptation.

### Subway Builder PE evidence
- **Code-confirmed:** Godot 4 project, portrait 720x1280 viewport, canvas-items stretch, Camera2D, touch/mouse pan and pinch handling, fixed screen-center construction crosshair, and a HUD with station/track/parallel/curve controls and zoom buttons.
- **Known development diagnostic:** the inspected main/HUD code exposes input-status labels such as ROOT SCREEN TOUCH and GESTURE END. These are diagnostics, not player-facing features; their removal/gating should be handled separately after input regressions are covered.
- **Not yet audited:** full map/basemap implementation, terrain rendering, layer controls, simulation controls, line management panels, save/load, community sharing, accessibility, and final Android safe-area behavior.

## Implementation order

1. **Finish baseline audit:** inspect remaining repository subsystems and exercise the public Trainsworld game for UI/interaction details where accessible. Record evidence and screenshots; do not infer undocumented behavior.
2. **Construction parity:** define world scale and track/elevation data model; implement track classes and levels before terrain-dependent placement rules.
3. **Topology and junctions:** add explicit conflict/grade-separation semantics and robust turnout/crossover/flyover topology with automated regression cases.
4. **Stations:** define station track/platform configurations and topology links; add passing/terminal improvements.
5. **Lines and schedules:** route stop lists, loops, headways/timetables, line groups, branches, short-turn patterns.
6. **Trains and simulation:** movement/dispatching, capacity, passenger demand, pathfinding, crowding, and performance.
7. **Economy and management:** construction/maintenance/running costs, fares/revenue, financial feedback.
8. **Maps and mobile UI:** terrain/map parity, real-world snapping, management panels, save/load, and mobile interaction polish.

## Verification gates

For each phase:
- Add automated tests for model/geometry/topology rules before changing UI.
- Run the complete Godot headless test suite and Android export workflow.
- Review screenshots/video for visual and touch interaction changes.
- Mark device testing separately; CI success is not device validation.
- Preserve existing behavior unless a documented reference requirement and explicit regression test justify changing it.

## Current known CI checkpoint

PR #11's latest known Android debug workflow completed successfully and explicitly ran the free-placement track-node tests, in addition to graph topology, geometry, station-model tests, and Android export. This is an automated checkpoint only; no physical-device test is implied.
