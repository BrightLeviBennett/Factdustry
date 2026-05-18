# Factdustry — Project Overview

A Godot 4 factory / defense game in the spirit of Mindustry. The player
lands on a sector, harvests resources, builds production chains and
defense, and progresses through a tech tree across multiple sectors on
multiple planets.

This file is a quick orientation aid. Skim it before doing significant
work in the codebase.

---

## Tech / Engine

- **Engine:** Godot 4.6 (`config/features = ["4.6", "Mobile"]` in
  `project.godot`).
- **Renderer:** `gl_compatibility` (works on lower-end hardware).
- **Main scene:** `res://main/MainMenu.tscn`.
- **Aesthetic:** Mindustry-style — high-resolution source art with
  *linear* texture filtering (default), continuous camera zoom,
  mipmaps generated per import. The `[2d/snap]` pixel-snap settings
  are intentionally OFF; the camera never restricts to integer zoom
  stops. Source textures are 128 / 256 / 512 px.
- **`GRID_SIZE = 128`** (in `main.gd`). One in-world tile = 128 px.
  Source pixel art at 128×128 maps 1:1 at zoom 1.

## Top-level layout

```
res://
├─ main/                 — all gameplay scripts + scenes (.gd, .tscn)
├─ data/
│  └─ game/
│     ├─ manifest.json   — list of every .tres/data file to load
│     ├─ registry.gd     — autoload that loads & indexes all data
│     ├─ tarkon/         — first planet's blocks, units, fluids,
│     │                    items, tiles, sectors, status_effects, maps
│     ├─ yndora/         — second planet
│     └─ planets/        — top-level planet definitions
├─ textures/             — all sprites (organised by category)
├─ tools/                — editor / build helpers
├─ addons/               — manifest_builder & GitPlugin
└─ project.godot
```

Per-sector save data lives in `user://saves/<sector_id>.sector.json`;
campaign-wide tech-tree + per-sector resource pools live in
`user://saves/campaign.json`. Editor map templates live in
`user://maps/`.

## Autoloads (`[autoload]` in `project.godot`)

| Name           | Path                            | Role                                                                                   |
| -------------- | ------------------------------- | -------------------------------------------------------------------------------------- |
| `Registry`     | `data/game/registry.gd`         | Loads every `.tres` listed in `manifest.json`, indexes blocks / items / fluids / units / tiles by id, `class Registry`. |
| `SaveManager`  | `main/save_manager.gd`          | Sector + campaign save / load, autosave timer, sector-resource pool, offline accrual, defense-sim snapshots. |
| `TechTree`     | `main/tech_tree.gd`             | Tech graph definitions, research state, archive-decoded rule wiring, save data. |

## Core gameplay nodes (children of `Main`)

`Main.tscn` is the main gameplay scene. Inside it, these systems live as
direct children of `/root/Main`:

| Node                   | Script                          | What it owns                                                                       |
| ---------------------- | ------------------------------- | ---------------------------------------------------------------------------------- |
| `Main`                 | `main/main.gd`                  | Map state: `placed_buildings`, `building_origins`, `building_factions`, `building_rotation`, `building_health`, `placement_rotation`, `world_paused`, sector lifecycle, faction enum, `damage_building`, `try_place_building`, `_swap_building_in_place`, drag-place commit path. |
| `TerrainSystem`        | `main/terrain_system.gd`        | Floor/wall/ore tiles, water-depth BFS, multi-tile origins, paint mode.            |
| `BuildingSystem`       | `main/building_system.gd`       | All in-world drawing of placed buildings (PASS 1/2/2.5/3/4/5/6 in `_draw`), preview / drag / schematic / rebuild ghosts, drill & crusher heads, archive-scan overlay, faction-overlay sprites, link mode, world menus (sorter / constructor / refab / archive pickers), crane state machine, archive decoder ticking. |
| `LogisticsSystem`      | `main/logistics_system.gd`      | Conveyors, junctions, pipes (fluids), pumps (continuous output, depth + power-scaled), factories, refabricators, constructors, deconstructors, payload conveyors, payload loaders / unloaders, mass drivers (state + projectiles), belt unloaders, block storage, item / fluid pushing.  Items move on `_try_transfer_item`; buildings spawn items via `_try_push_item`. |
| `PowerSystem`          | `main/power_system.gd`          | Electrical networks (cable nodes, towers, links, faction-isolated), per-anchor dynamic power-use overrides (`set_dynamic_power_use`), `is_electrical_powered`, `get_electrical_efficiency`, 10-min rolling per-network and per-block history (`get_network_history`, `get_block_history`), uses HUD's `_network_graph_clock` so paused time doesn't shift the X-axis. |
| `CombatSystem`         | `main/combat_system.gd`         | Turrets (per-barrel cooldown / fire-flash / recoil / aim with toe-in), projectiles, drone combat (default mode shoots, heal mode auto-shoots), enemy ranged attacks, wall-collision (incl. diagonal-corner gap), targeting worker thread (`TargetingWorker`). |
| `UnitManager`          | `main/unit_manager.gd`          | Player units + enemy units, manual control of unit / turret / crane (Ctrl+click), unit-mode UI, pathfinding worker integration. |
| `PlayerDrone`          | `main/player_drone.gd`          | The player avatar — movement, mining, healing laser (auto-heals friendlies in default; auto-shoots in heal mode), mode toggle on `X`. |
| `WaveManager`          | `main/wave_manager.gd`          | Authored wave config / spawn points / runtime state, expand-and-tick, `waves_defeated` signal, save / load runtime. |
| `SectorScript`         | `main/sector_script.gd`         | Walkthrough / objectives / hint system. Steps with conditions + actions; supports `start_waves` / `stop_waves` / `capture_sector` / `draw_box` / `draw_text` / `pause` / hide-tiles / disable-buildings. |
| `HUD`                  | `main/hud.gd`                   | All in-game UI: portrait + objective panel, build menu, hover tooltip, build-cost panel, network info panel + per-row eff/power sparklines + 10-min network graph (with hover white-line + active-block icon stack), unlock-content notify, hint bubbles, escape menu, settings, schematic viewer. |
| `TechTreeUI`           | `main/tech_tree_ui.gd`          | Tech-tree window. Drag OR WASD pan (settings toggle). |
| `Camera2D`             | `main/camera_controller.gd`     | Continuous zoom, smooth follow, pan-rotate (trackpad), focus override, integer-rotation snap on Q. |

There are also separate scenes for the menus / map editor /
planet-select; those live in `main/MainMenu.tscn`,
`main/PlanetSelect.tscn`, `main/MapEditor.tscn`.

## Data model

Everything the player can place or own is a Resource asset under
`data/game/<planet>/`:

- **`BlockData`** (`data/game/tarkon/blocks/block_data.gd`) —
  buildings (drills, factories, walls, turrets, transport, payload,
  cores, refabricators, etc.). Common fields: `id`, `display_name`,
  `category` (enum), `tags` (PackedStringArray), `grid_size`,
  `max_health`, `build_cost`, `build_time`, `electrical_power_use`,
  `electrical_power_gen`, `requires_power`, `production_time`,
  `output_items`, `input_items`, `side_inputs`, `side_outputs`,
  `ammo_types` (Array[`AmmoType`]), `barrel_count`, `barrel_spacing`,
  `turret_head_sprite`, `turret_chassis_sprite`, `base_sprite`,
  `top_sprite`, `feed_overlay_*`, `ferox_overlay`, `derelict_overlay`,
  `lumina_overlay`, `is_aoe`, `aoe_radius`, `transport_speed`,
  `transports_fluid`, `max_payload_size`, `max_stored_items`,
  `liquid_capacity`, `crane_range`, `archive_id`, `produced_unit`,
  `attack_speed`, `attack_range`, etc. `is_turret()` returns true iff
  the block has at least one ammo type *and* a non-zero attack range.
- **`AmmoType`** — per-shot stats (damage, projectile speed, splash,
  pierce, knockback, status effect, trail colour, …).
- **`UnitData`** (`enemy_unit.gd` references it) — player + enemy
  units share the same script (`enemy_unit.gd`); player vs enemy is a
  `team` enum on `UnitData`. Categories include `BUILDER`, `COMBAT`,
  `MINER`. Holds `move_speed` (tiles/sec — converted to px/sec at
  spawn), `max_health`, `attack_speed`, `attack_range`, `damage`,
  `detection_range`, `body_turn_speed`, `tank_steering`,
  `movement_layer`, sprite refs.
- **`ItemData`** / **`FluidData`** / **`TerrainTileData`** /
  **`StatusEffectData`** — straightforward resource definitions.

Everything indexed by `Registry.get_block(id)` / `get_unit(id)` /
`get_item_or_fluid(id)` / etc.

## Conventions / gotchas

- **`.tres` files do NOT support `#` comments outside quoted strings.**
  Adding a comment block to a `.tres` will silently corrupt the
  resource (later fields will fail to load). Document `.tres`
  intent in code or docs only.
- **Multi-tile blocks register every cell of their footprint in
  `placed_buildings`.** `building_origins[cell] = anchor` maps each
  cell back to the anchor (top-left). Most systems iterate
  `placed_buildings`, dedupe via `processed[anchor]`, and key state
  by anchor (e.g. `mass_driver_state[anchor]`,
  `factory_buffers[anchor]`).
- **Linked pairs** (`PowerSystem.linked_pairs`, mass drivers, overhead
  belts) — link endpoints are NORMALISED to anchors when created
  (`BuildingSystem._handle_link_click`), AND the consumers
  (`logistics_system._update_mass_drivers`) defensively re-normalise
  pair endpoints to anchors at lookup time so legacy saves still
  match.
- **Faction split**: `Faction.LUMINA` (player), `Faction.FEROX`
  (enemy), `Faction.DERELICT` (neutral, faded). Power networks and
  unit AI are isolated by faction; cross-faction blocks don't transfer
  items or share electricity.
- **Archive overlay (purple box + sweeping line)** uses a fade dict
  (`_archive_scan_fade[anchor] = {alpha, scanner_rot, data}`) ticked
  in `_process` (only while world unpaused) so the visual smoothly
  fades in/out on scanner power changes / decode completion.
- **Drag-place rotations**:
  `BuildingSystem._compute_path_rotations(path, target_hint)`. Forward
  cells use `path[i+1] - path[i]`, last cell uses its own incoming
  step; if `target_hint` is one tile away the trailing belt faces it
  (drag-into-block then points belt INTO the block).
- **Two-stage right-click**: with a block selected for placement,
  RMB clears the selection first; the next RMB triggers demolish.
  See `BuildingSystem._unhandled_input`.
- **Off-screen / paused gate**: `main.world_paused` + `main.sector_lost`
  affect almost every per-frame system. Many sub-systems
  (`PowerSystem` history, MD cooldown, archive sweep phase, HUD
  network-graph clock) skip their internal time advance when paused
  so timelines stay aligned.
- **PowerSystem dynamic draw**: blocks with state-dependent power
  use (mass drivers, …) call
  `power_sys.set_dynamic_power_use(anchor, watts)` /
  `clear_dynamic_power_use(anchor)`; the network use total reads
  `_get_effective_elec_use(anchor, data)` (override → fall back to
  static `electrical_power_use`).
- **Mass driver weight formula** (
  `LogisticsSystem._mass_driver_power_for_payload`):
  `tile = 8w / tile`, `item = 0.5w / count`, `fluid = 1w / 1.0`,
  `power = floor(weight / 2)`. Plus 4 W chassis baseline. Cycle
  speed scales with network efficiency (no hard "powered" gate —
  brownouts slow the cycle, fully starved networks lock).
- **Save/load** (`save_manager.gd`): per-sector save covers placed
  buildings, terrain tiles, building rotation/factions/health,
  build progress, work order, paused queue, resources_consumed/refunded,
  player units, drone position, block storage, conveyor/junction
  items, pipe contents, factory buffers, payload items, constructor /
  deconstructor / refabricator / loader / unloader / mass driver
  states, in-flight mass-driver projectiles, belt unloader timers,
  crane states, archive holdings + decoder state, sorter filters,
  script steps + script runtime + hints runtime, waves bundle + waves
  runtime, sector_script runtime. Campaign save covers tech tree +
  per-sector resource pool (clamped to per-sector core caps; offline
  accrual gated on a recorded cap).
- **Worker threads**:
  - `PathfindingWorker` (`main/pathfinding_worker.gd`) — A* requests
	for units, async path return.
  - `TargetingWorker` (`main/targeting_worker.gd`) — turret + idle
	player-unit target scans, snapshot pushed once per frame.

## Tests / build

There's no automated test suite. Run the project from the Godot
editor (`Run → Play`) — `MainMenu.tscn` boots first, picks a planet,
launches a sector. The map editor (`MapEditor.tscn`) is a separate
flow used to author sector templates that get bundled into
`data/game/<planet>/maps/<id>.sector.json`.

`tools/` contains scripts referenced by the manifest builder addon —
they ensure all `.tres` referenced by `manifest.json` actually exist
when the project loads.

## Where to look first

- A new building behaviour → `BlockData` fields + the relevant
  `LogisticsSystem` / `BuildingSystem` / `CombatSystem` update loop.
- A new HUD widget → `hud.gd` (single big file — search for related
  field names; widget creation is in `_create_*_panel`, refresh in
  `_update_*_panel`).
- Save/load anything new → add serialiser in `save_manager.gd` per
  the existing dictionary entries, and a deserialiser block under the
  matching `if data.has(...)` branch.
- A new tech-tree entry → `tech_tree.gd::_add(...)` calls (search for
  `&"core_shard"` and follow).
- Sector scripting (objectives, walkthrough) → `sector_script.gd` for
  runtime, `script_editor.gd` for in-editor authoring.
