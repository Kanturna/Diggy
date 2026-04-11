# Lyra cavity target steering fix plan

This branch documents the concrete fix path for the current dig steering issue.

## Problem summary
The current digging behavior improves frontier quality, but creatures do not reliably steer toward nearby external hollows inside the visible perception radius.

### Root causes
1. `CaveRegionAnalysis._scan_general_hollow_proximity()` is frontier-centered instead of creature-centered.
2. The visible perception radius and the effective general hollow scan range are not aligned.
3. `DigPlanner` only receives a scalar `sensor_general_hollow_score`, not an explicit cavity target with direction.
4. The resulting sensor signal is too weak and not directional enough to override plain forward digging when an external hollow is clearly nearby.

## Intended fix
### 1. Creature-centered cavity target detection
Add a creature-centered scan in `core/world/CaveRegionAnalysis.gd`:

- New API: `scan_general_hollow_target(origin_cell: Vector2i) -> Dictionary`
- Search from the creature's current cell, not from each frontier cell.
- Restrict search to `Config.CREATURE_PERCEPTION_RADIUS_CELLS`.
- Only accept empty cells that are outside the current open region.
- Return:
  - `found`
  - `target_cell`
  - `direction`
  - `distance_cells`
  - `distance_score`
  - `reason`

### 2. Snapshot / planning handoff
In `units/Creature.gd`, when preparing a planning snapshot:
- fetch `general_cavity_target` once from `cave_analysis.scan_general_hollow_target(origin_cell)`
- attach it to the snapshot passed into `DigPlanner`

### 3. Directed steering in planner
In `units/DigPlanner.gd`:
- read `general_cavity_target` from snapshot
- calculate:
  - `cavity_target_alignment`
  - `cavity_target_direction_bonus`
- add that directional bonus into `sensor_score`
- keep frontier-based digging intact; do not add direct perfect pathing

Suggested interpretation:
- alignment should favor candidate dig directions that point toward the cavity target direction
- distance score should slightly amplify the bonus for closer targets

### 4. Debug visibility
Expose the new information in debug data:
- `has_cavity_target`
- `cavity_target_cell`
- `cavity_target_direction`
- `cavity_target_distance_cells`
- `cavity_target_reason`
- `cavity_target_direction_bonus`

Update `debug/DebugOverlay.gd` so the overlay shows whether a target exists and why not when none is found.

## Key files to update
- `core/world/CaveRegionAnalysis.gd`
- `units/Creature.gd`
- `units/DigPlanner.gd`
- `debug/DebugOverlay.gd`

## Guard rails
- Preserve frontier-based digging.
- Do not convert this into direct shortest-path tunneling toward hollows.
- Keep build score as the backbone; only strong nearby cavity targets should visibly bend the digging direction.
- Avoid broad global weight inflation; prefer a dedicated directional bonus.

## Validation checklist
- A creature with a clearly visible external hollow inside the perception radius should show a non-zero cavity target in debug.
- The chosen frontier candidate should receive a visible `cavity_target_direction_bonus` when aligned.
- The debug circle/radius and the actual search radius should match.
- If no hollow exists in radius, behavior should fall back to ordinary frontier scoring.
