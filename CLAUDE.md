# ASAS — "A Spade's A Spade" — Claude Code context

A **3D voxel deckbuilder** in **Godot 4.4** (GDScript). The joke flips "call a spade a
spade": here the **spade** is an absurdly versatile core implement (dig / swing / throw /
special), upgraded via head/shaft/handle parts. Spun off from the `uprising` prototype
(2D iso deckbuilder); the turn/energy/hand patterns were ported, the board was rebuilt as
a true 3D voxel grid.

## Godot path (this machine)

```
/Applications/Godot.app/Contents/MacOS/Godot
```

## Self-test loop (run after EVERY code change)

```
# 1. Class-scan (required after adding a new class_name)
<godot> --path <project> --editor --headless --quit 2>&1
# 2. Parse check
<godot> --path <project> --headless --quit 2>&1
```

Clean = only the engine banner (ignore the harmless `progress_dialog` editor noise during
the class scan). Any `SCRIPT ERROR` / `Parse Error` is a real failure. Note: a `class_name`
script is only compiled when something reachable from the loaded scene references it — run a
headless **functional test** (`--script res://test_*.gd`, a `SceneTree`) to force-compile
and exercise logic, then delete it.

**GDScript gotcha:** `var x := obj.foo()` fails to infer when `obj`/its method is untyped
(Variant). Use explicit types (`var x: int = ...`) or plain `=` in tests and when reading
from untyped cross-refs.

## Entry point

`project.godot → res://scenes/main.tscn` (single `Node3D` "Main", `main.gd`). `main.gd`
builds everything in code: the world, a directional light + `WorldEnvironment`, an orbit
camera rig, unit/spade 3D views, and a `CanvasLayer` HUD.

## Files

| File | Class | Role |
|---|---|---|
| `scripts/main.gd` | *(none)* | Orchestrator: world + camera + lights + 3D views + HUD + input |
| `scripts/voxel_world.gd` | `VoxelWorld` | 3D grid data, cube rendering, materials, dig/queries |
| `scripts/game_state.gd` | `GameState` | Turn/energy/hand loop + spade actions (RefCounted) |
| `scripts/unit.gd` | `Unit` | Operator: team, grid, facing, hp, held spade (RefCounted) |
| `scripts/spade.gd` | `Spade` | The implement: stats + head/shaft/handle upgrade slots (RefCounted) |
| `scripts/camera_rig.gd` | *(none)* | Orbit camera (right-drag rotate, wheel zoom) |

## World (voxel_world.gd)

- Grid **10×10 footprint (x,z) × 9 tall (y, up)**; `y = 0..GROUND(4)` are solid earth, gold
  pockets scattered underground, everything above is air. World units == grid units.
- Materials enum `VoxelWorld.Mat { AIR, EARTH, WATER, GOLD }`. Air cells are **absent** from
  `cells` (a `Vector3i -> Mat` dict). Cubes are one `MeshInstance3D` per solid cell, updated
  incrementally on dig (`_refresh_cube`).
- `is_standable(p)` = in-bounds air with solid directly below (or floor). `surface_cell(x,z)`
  finds where a unit rests. `world_pos(p)` = cell bottom-center for placing nodes.

## Core sandbox (DONE — point-and-click)

- 3D world (earth/air/gold) + orbit camera (right-drag rotate, wheel zoom). Player has a
  **leader** (gold, taller, little crown — plays cards) plus an **operator** (blue, wields a
  spade); one **enemy dummy** (red, no AI yet).
- **Point-and-click**: left-click a unit to select it (math ray-vs-AABB pick against units),
  then click a **highlighted cell** to act. Highlights are **wireframe** line cubes
  (`_build_wire_mesh`, `no_depth_test` so the dig cell underground is visible) colored per
  mode (move=green, dig=orange, swing=red, throw=cyan); the tile color shows through.
- **Context HUD** by selection: the **leader** shows its **hand of cards** (no spade actions);
  an **operator** shows its **actions** (no hand). Selecting a player unit defaults to **move**
  mode and highlights reachable cells.
- **Action target sets** (`GameState.*_targets`) + cell-targeted actions: **Move** (BFS
  `MOVE_RANGE=4`, step ±1 height → `move_to`), **Dig** (only the cell below → `dig`, gold
  → +1 energy, descends), **Swing** (4 same-plane neighbours → `swing_at`: clear earth/gold
  or damage a unit), **Throw** (all cells within cube radius `THROW_RADIUS=2` that are air or
  hold a unit → `throw_at`: damage + drop the spade), **Pick Up**, **Special** (stub).
- **Turn/energy/hand**: `MAX_ENERGY=4`/turn, each action costs 1; minimal hand of `operator`
  (summon adjacent) / `spade` (grant) cards (the leader's). Dead units **drop their spade**.
- Picking lives in `main.gd` (`_pick_cell`/`_pick_unit` via `AABB.intersects_segment` against
  the camera ray); facing is now cosmetic (`_face_toward`). Verified with headless functional
  tests (actions + targeting + leader split) — since removed.

## Not yet built (design backlog)

- **Materials:** water (flows downhill on update), gold bonuses beyond +energy.
- **Cards as real categories:** units / spades / upgrades with a proper `CardData`+`Deck`
  (current hand is a minimal stand-in).
- **Spade upgrades** (one per slot): Head (Blade +swing-vs-enemy, Pick +swing-vs-wall, Tip
  +dig, Grappling Hook climb 3, Warhead area-throw, Pogostick move-2x, Metal Detector reveal
  metal), Shaft (Laser Rangefinder guided throw, Wings +3 throw, Double-barrel two heads,
  Dousing Rod reveal water), Handle (Propulsion launch, Boomerang return, Trigger act-twice).
- **Operator upgrades:** Dual-wield (2 spades), Endurance (2 actions/turn), Strength
  (+1 dig/swing/throw), Hand-eye (catch thrown spades).
- **Enemy AI**, win/lose conditions; richer movement costs; selecting/commanding multiple
  operators; leader card-play targeting in 3D (summon currently auto-places adjacent).
