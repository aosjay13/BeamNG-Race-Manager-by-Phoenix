# Architecture

How Race Manager is put together, and why it is split the way it is.
For using the mod, see the [README](../README.md).

[← Back to the README](../README.md)

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state machine: grid, countdown, one shared clock, finish timestamps, broadcasts the driver table |
| Mod entry point | `scripts/raceManager/modScript.lua` | In-game (runs at mod mount) | Loads the client bridge — BeamNG **never** auto-loads GE extensions shipped in a mod zip |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Waypoint editor, local finish-line detection (the server has no physics), relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Race controls, live driver table, waypoint editor panel |

Event flow: local car crosses the start/finish gate → `RM_QualiLap`/`RM_Lap`
to server → server scores it on its own clock → `RM_Update` broadcast to all
clients → UI.

## What the server keeps

Everything durable lives beside the plugin in `Resources/Server/RaceManager/`,
written as JSON on every change through one small codec in `main.lua` (the
network payloads use BeamMP's `Util.JsonEncode`; persistence gets its own strict
one so the headless tests exercise the real file format).

| File | Holds | Cleared by |
|------|-------|-----------|
| `layouts.json` | Saved track layouts per map: gates, joker route, branching lanes, starting grid | Overwriting a name |
| `derbyArenas.json` | Saved derby arenas per map | Deleting an arena |
| `garage.json` | Approved vehicles/setups and the enforcement switch | Clear Garage |
| `roster.json` | Saved drivers: the display names an admin has assigned | Deleting a driver |
| `cup.json` | Cup scoring rules, standings, per-round breakdown, adjustments | End Cup |
| `results/*.txt` | One results file per finished session | Clear Results Cache |

`roster.json` and `cup.json` are deliberately **not** under `results/`: Clear
Results Cache deletes every `.txt` it finds there, and a championship that
routine housekeeping can destroy is not persistent in any sense that matters.

## Modules inside the server plugin

Three parts of `main.lua` are self-contained: **Demo Derby**, the **driver
roster** and the **cup**. Each has its own state tables, its own `RM_*` event
namespace and its own broadcast channel, and none of them is reachable from the
racing state machine except through a handful of named functions declared at the
top of the file.

That is enforced rather than promised — the roster and cup live inside one
installer function, so the only names crossing the boundary are the ones
forward-declared outside it. (There is a second reason: Lua allows 200 locals
per function, and this chunk is close enough to that ceiling that a module
written at file level would not compile.)

The cup is a **consumer of results**. It is entered from exactly two places —
the end of `finishSession` and the end of `finishDerby` — and reads the same
classification the results file is built from. Nothing cup-shaped runs while
cars are on track, which `tests/stress_test.lua` asserts by counting messages
rather than by timing.

Client and server obey **different rules**:

- **Client (BeamNG.drive)**: mods are zips mounted into the virtual
  filesystem. A UI app requires all four files (`app.js`, `app.html`,
  `app.json`, `app.png`) or it won't appear in the app selector, and GE
  extensions only load if `scripts/<name>/modScript.lua` loads them.
  Events use `AddEventHandler(name, fn)` / `TriggerServerEvent(name, str)`.
- **Server (BeamMP)**: Lua 5.3, no game/physics access. Handlers must be
  **global** functions registered by name string via
  `MP.RegisterEvent(event, "fnName")`; broadcast with
  `MP.TriggerClientEvent(-1, event, jsonString)`.
