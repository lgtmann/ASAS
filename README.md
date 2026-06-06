# A Spade's A Spade (ASAS)

A **3D voxel deckbuilder roguelite** built in **Godot 4.4** (GDScript).

The joke flips the idiom "call a spade a spade": here the humble **spade** is the core
implement and becomes wildly versatile — dig, swing, throw, and a tree of head / shaft /
handle upgrades turn it into a grappling hook, a mortar, a pogo stick, and more.

## Run

Open the project in Godot 4.4 and press F5, or:

```
<godot> --path .
```

Right-drag to orbit the camera, wheel to zoom. Drive the selected operator with the HUD
buttons or hotkeys: **Q/E** turn, **W** move, **F** dig, **Space** swing, **T** throw,
**G** pick up, **Enter** end turn.

## Layout

- `scripts/` — `VoxelWorld`, `GameState`, `Unit`, `Spade`, `camera_rig`, `main`
- `scenes/main.tscn` — entry point (a single `Node3D`; everything is built in code)
- `CLAUDE.md` — conventions, self-test loop, architecture, and the design backlog

## Status

**Core sandbox** complete: a 10×10×9 voxel world (earth / air / gold) rendered as cubes
with an orbit camera; one operator holding a spade plus an enemy dummy; the four spade
actions (dig / swing / throw / special-stub) plus move / turn / pick-up; and a turn +
energy + minimal hand loop. Dead units drop their spades to be reclaimed.

Next: water flow, the real card categories (units / spades / upgrades), the spade and
operator upgrade trees, enemy AI, and win conditions.
