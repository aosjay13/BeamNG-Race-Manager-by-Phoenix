# Architecture

How Race Manager is put together, and why it is split the way it is.
For using the mod, see the [README](../README.md).

[← Back to the README](../README.md)

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state machine: grid, countdown, one shared clock, finish timestamps, broadcasts the driver table |
| Mod entry point | `scripts/raceManager/modScript.lua` | In-game (runs at mod mount) | Loads the client bridge - BeamNG **never** auto-loads GE extensions shipped in a mod zip |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Waypoint editor, local finish-line detection (the server has no physics), the drag christmas tree and its reaction timing, relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Race controls, live driver table, waypoint editor panel |
| Lights app | `ui/modules/apps/RaceManagerLights/` | In-game UI (Angular, no bindings) | Start lights, flags and the drag tree in a box of their own. Draws the one light `raceManager/lights.lua` pushes on change, which also plays the start sounds |
| Radar app | `ui/modules/apps/RaceManagerRadar/` | In-game UI (Angular, no bindings) | The cars around this driver's car, in its frame, with outline-to-outline gaps. `raceManager/radar.lua` scans four times a second alone and pushes twenty times a second only while a car is in range |

Event flow: local car crosses the start/finish gate → `RM_QualiLap`/`RM_Lap`
to server → server scores it on its own clock → `RM_Update` broadcast to all
clients → UI.

`RM_Update` is the timing push, sent about three times a second while a session
runs, so anything that changes rarely does not ride it. The Garage List goes out
as `RM_Garage` when it changes and to each client that asks for state, numbered
so a late copy cannot replace a newer one.

## What the server keeps

Everything durable lives beside the plugin in `Resources/Server/RaceManager/`,
written as JSON on every change through one small codec in `main.lua` (the
network payloads use BeamMP's `Util.JsonEncode`; persistence gets its own strict
one so the headless tests exercise the real file format).

| File | Holds | Cleared by |
|------|-------|-----------|
| `layouts.json` | Saved track layouts per map: gates, joker route, branch gates, starting grid | Overwriting a name |
| `derbyArenas.json` | Saved derby arenas per map | Deleting an arena |
| `dragLadder.json` | The drag tournament in progress: rules, entrants, records, every round drawn so far | Clear Ladder |
| `garage.json` | Approved vehicles/setups and the enforcement switch | Clear Garage |
| `roster.json` | Saved drivers: the display names an admin has assigned | Deleting a driver |
| `cup.json` | Cup scoring rules, standings, per-round breakdown, adjustments | End Cup |
| `results/*.txt` | One results file per finished session | Clear Results Cache |
| `mapSwitch.json` | A map switch waiting for its restart, so the next boot can say whether it took | The next boot |
| `mapNames.json` | Display names for maps, by level name | Renaming each map back |
| `Lap Records/<map>.json` | Each driver's best lap per saved layout on that map | Clear Board, or deleting the file |

`roster.json` and `cup.json` are deliberately **not** under `results/`: Clear
Results Cache deletes every `.txt` it finds there, and a championship that
routine housekeeping can destroy is not persistent in any sense that matters.

## Modules inside the server plugin

Six parts of the plugin are self-contained: **Demo Derby**, **drag racing**,
**map switching**, **lap records**, the **driver roster** and the **cup**. Each has its own
state tables, its own `RM_*` event namespace and its own broadcast channel, and
none of them is reachable from the racing state machine except through a
handful of named functions declared at the top of the file.

The first four are separate FILES (`derby.lua`, `drag.lua`, `maps.lua`,
`records.lua`) required as siblings; the other two are `do ... end` blocks
inside `main.lua`.
Same isolation either way, reached two different ways for the same reason:
Lua's 200-local ceiling.

**BeamMP runs every `.lua` in the plugin folder on its own**, alphabetically,
before `main.lua` requires any of them. `derby.lua` and `drag.lua` sort before
`main.lua`, so the copy `main.lua` initialises is the one whose global handlers
win. `maps.lua` and `records.lua` sort after, so they define nothing global at
file scope: their `RM_Map*` and `RM_Records*` handlers are installed by
`init()`, and `tests/maps_test.lua` and `tests/records_test.lua` check that
loading either file alone defines nothing. A new module must do the same
unless its name sorts before `main`.

**Map switching restarts the server**, because BeamMP reads its map and hashes
`Resources/Client` only at startup. The module moves map zips between
`custom_maps/` and `Resources/Client/` (the BeamMP Server Management Tool's
layout), rewrites only the `Map` value in `ServerConfig.toml`, and restarts by
whichever means is available: the Management Tool's config watch, a detached
helper that waits for this process to exit and starts it again, or `exit()` for
a service manager. See [Switching maps](REFERENCE.md#switching-maps).

**Lap records are a consumer of results, like the cup.** `finishSession` calls
them once per session through `race.recordsSession`, after the joker ruling.
The file on disk is the board: every read opens it and every write reads it
first, so a hand edit is never overwritten by a copy held in memory.

**Drag racing reads two things from the racing state and writes neither**:
`race.startPositions`, which is where the lanes are, and `race.slotCount`,
which is how it knows the loaded layout has a finish line. Both are properties
of the loaded TRACK rather than of a session. That is the whole reuse: a drag
strip is a point-to-point layout, its start positions are the lanes and its
last gate is the finish, so there is no second track editor and no second
layout store. Three names cross back the other way, and all three hang off
`race` rather than taking a local: `dragUnderWay`, `dragEntryChanged`,
`dragWarm`.

**Where the timing happens is split differently from everywhere else.** A
reaction time is decided in the third decimal place, so the christmas tree runs
on each CLIENT against its own clock -- the server sends the shape of the tree
and every client measures its own launch against its own green. A tree driven
from server ticks would measure the network. The server still owns the bracket,
the ranking and the result.

That is enforced rather than promised - the roster and cup live inside one
installer function, so the only names crossing the boundary are the ones
forward-declared outside it. (There is a second reason: Lua allows 200 locals
per function, and this chunk is close enough to that ceiling that a module
written at file level would not compile.)

The cup is a **consumer of results**. It is entered from exactly two places
the end of `finishSession` and the end of `finishDerby` - and reads the same
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
