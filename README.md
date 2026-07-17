# BeamNG Race Manager by Phoenix

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live standings,
lap counts, best/last lap times, and real-time gaps for every driver on the server.

## Architecture

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state machine: grid, countdown, one shared clock, finish timestamps, broadcasts the driver table |
| Mod entry point | `scripts/raceManager/modScript.lua` | In-game (runs at mod mount) | Loads the client bridge — BeamNG **never** auto-loads GE extensions shipped in a mod zip |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Waypoint editor, local finish-line detection (the server has no physics), relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Race controls, live driver table, waypoint editor panel |

Event flow: local car hits the finish → `RM_Finish` to server → server
timestamps it on its own clock → `RM_Update` broadcast to all clients → UI.

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

## Installation

### Server (BeamMP)

Copy `server/RaceManager/` into your BeamMP server's `Resources/Server/` folder:

```
Resources/Server/RaceManager/main.lua
```

### Client mod

Use `dist/RaceManager_Client.zip` (or zip the `scripts/`, `lua/` and `ui/`
folders yourself — they must sit at the **root** of the zip). Place it in
`Resources/Client/` on the server; BeamMP pushes it to joining players:

```
Resources/Client/RaceManager_Client.zip
  ├── scripts/raceManager/modScript.lua
  ├── lua/ge/extensions/raceManager.lua
  └── ui/modules/apps/RaceManager/{app.html,app.js,app.json,app.png}
```

For offline testing (waypoint editor only — racing needs BeamMP), drop the
same zip into your BeamNG user folder's `mods/` directory instead.

### Track setup

Open the app, press **Editor**, drive the route and drop a waypoint at each
gate with **+ Waypoint Here** — the last one placed is the finish line. Save
persists to `settings/raceManager/route.json`. Alternatively, a
`BeamNGTrigger` object named `race_finish` on the map works as the finish.

## Usage

1. Join the server, add the **Race Manager** app from the UI app menu
   (Racing / Info categories).
2. **Set Grid** snapshots connected players, then **Start Countdown** runs
   3-2-1-GO for everyone; **End Race** DNFs anyone still out; **Reset
   Leaderboard** clears state. Disconnecting mid-race marks a driver as DNF.

## Troubleshooting: the app doesn't show up

- The game only scans mods at startup — **restart BeamNG** after
  installing/updating, and if the app list is still stale, clear the cache
  (Launcher → *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/`, `scripts/` at its root (no extra
  top-level folder from zipping the parent directory).
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`) — if
  it's missing, the modScript never ran, meaning the zip wasn't mounted.
