# Diggy — World-Core Prototype (Godot 4.6)

Diggy starts deliberately small: a robust **material world core** where `EARTH` is the dominant, blocking substance and `EMPTY` represents carved void.

This first milestone intentionally implements only:

- world data core
- procedural earth/void generation
- image-based material rendering
- camera controls
- debug overlay

No units, agents, genetics, colony, or gameplay systems are included in this phase.

## Vision

Build a clean foundation for a mutation-driven terrain simulation where frequent `EARTH -> EMPTY` changes are expected and must remain performant and debuggable.

## Architecture Principles

- `Main.gd` is wiring only (instantiation, setup, signal connections).
- World state and rendering are strictly separated.
- Terrain is treated as dense matter, not decorative background tiles.
- Material mutation is a first-class path in the API (`WorldModel.set_material`) and normalizes flags/variants for consistent `EARTH <-> EMPTY` transitions.
- Debug is mandatory from day one.

## Project Structure

```text
res://
  main/
    Main.tscn
    Main.gd

  core/
    Config.gd
    MaterialType.gd
    CellFlags.gd
    world/
      WorldModel.gd
      WorldGenerator.gd

  render/
    WorldMaterialRenderer.gd

  camera/
    CameraController.gd

  debug/
    DebugOverlay.tscn
    DebugOverlay.gd
```

## Rendering Strategy

Terrain uses an **image-based, cell-accurate renderer**:

- `Image` stores per-cell output color
- `ImageTexture` displays the image in-world
- dirty chunks are redrawn incrementally

This design aligns with dense earth matter and frequent future material mutations.

## Controls

- Move camera: `W A S D`
- Speed boost: `Shift`
- Zoom in/out: `Q / E` or mouse wheel
- Toggle debug overlay: `F3`

## Setup

1. Open the project folder in Godot 4.6.
2. Run the main scene (`res://main/Main.tscn`).
3. Observe generated earth mass with natural voids and active debug panel.

## Next-Phase Direction (not yet implemented)

- safe runtime material mutation tooling (dig operations)
- high-frequency dirty-chunk update tuning
- unit navigation against blocking earth
