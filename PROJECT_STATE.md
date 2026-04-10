# PROJECT_STATE

## Current Milestone

Milestone 1 foundation is in place:

- world material model with packed arrays
- earth-first procedural generation with organic voids
- image + texture renderer with dirty-chunk updates
- camera movement + keyboard/mouse-wheel zoom controls
- debug overlay with hover inspection

## Key Decisions

1. **Image-based terrain renderer** instead of TileMapLayer
   - better fit for dense material-space representation
   - simpler path for frequent cell mutations (`EARTH -> EMPTY`)
   - straightforward screenshot/debug correlation

2. **WorldModel as single source of truth**
   - no render-owned state
   - mutations route through world API
   - `set_material` now normalizes flags/variants for state consistency

3. **Strict small scope**
   - no unit/agent/genetic/colony systems or placeholders

## Open Risks / Watchpoints

- Godot API differences between 4.5/4.6 may require minor syntax adjustments.
- Large world sizes may need chunk-level texture upload optimization.
- Variant palette may need refinement for clarity at various zoom levels.

## Suggested Next Steps

1. Add targeted mutation API methods (`carve_circle`, `set_material_batch`).
2. Add lightweight profiling counters in debug overlay (dirty chunk count/frame).
3. Add repeatable seed presets and capture workflow for screenshot comparisons.
