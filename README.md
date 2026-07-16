# BeamNG Race Manager by Phoenix

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live standings,
lap counts, best/last lap times, and real-time gaps for every driver on the server.

## Architecture

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state: validates waypoint reports, computes standings and gaps, broadcasts the leaderboard |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Detects waypoint trigger hits for the local player's vehicle, times its laps, reports to the server; relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Renders the live leaderboard; Start/Stop/Reset buttons send commands to the server |

Event flow: client hits `race_wp_N` trigger → `RM_WaypointHit` to server →
server updates standings → `RM_Update` broadcast to all clients → UI.

## Installation

### Server (BeamMP)

Copy `server/RaceManager/` into your BeamMP server's `Resources/Server/` folder:

```
Resources/Server/RaceManager/main.lua
```

### Client mod

Zip the `lua/` and `ui/` folders into a standard BeamNG mod and place it in
`Resources/Client/` on the server (BeamMP will push it to joining players):

```
Resources/Client/RaceManager.zip
  ├── lua/ge/extensions/raceManager.lua
  └── ui/modules/apps/RaceManager/{app.html,app.js,app.json}
```

### Track setup

Place `BeamNGTrigger` objects around the track named `race_wp_0`, `race_wp_1`,
`race_wp_2`, … in driving order. **`race_wp_0` is the start/finish line.**
The scenario waypoint system (`onRaceWaypointReached`) is also supported.

## Usage

1. Join the server, add the **Race Manager** app from the UI app menu (Gameplay category).
2. Any player presses **Start** to begin the race for everyone.
3. Standings, gaps, and lap times update live as drivers cross the gates.
4. **Stop** freezes the race; **Reset** clears all state.

Disconnecting mid-race marks a driver as DNF.
