---
name: deploy
description: Build the Race Manager package and install it on the local BeamMP server. Use when asked to deploy, install to the server, push the mod to the server, or update the running server with the current build.
---

# Deploy Race Manager to the BeamMP server

One script does all of it. Run from the repo root:

```bash
python3 tools/deploy.py
```

Useful flags: `--dry-run` (say what it would do, write nothing), `--build-only`
(just write `dist/` and `package/`), `--server PATH` (skip discovery),
`--tidy` (also move loose Race Manager files in the server root into `_attic`).

## Before deploying

Run the suites. A deploy that installs a broken build costs a server restart and
a round of confusing live behavior:

```bash
for f in tests/*.lua; do lua "$f" || echo "FAILED: $f"; done
```

## What the script guarantees

- **It writes exactly two paths**: `Resources/Client/RaceManager.zip` and
  `Resources/Server/RaceManager/main.lua`.
- **Everything else under `Resources/Server/RaceManager/` is live data the
  server owns** and is never touched: `layouts.json` is every track the admin
  has built, plus `cup.json`, `roster.json`, `garage.json`, `derbyArenas.json`
  and `results/`.
- **Replaced files are backed up** to `_attic/deploy-<timestamp>/` on the server
  first, and every write is verified by hash afterwards.
- **A file that is already identical is skipped**, so a deploy after a
  client-only change correctly reports the server plugin as unchanged.

## After deploying

**Tell the user to restart the server, and do not restart it yourself.** It may
have players connected, and stopping it is their call.

The restart matters for a reason worth repeating to them: BeamMP loads the
server plugin and hashes the client zip at startup, and `mods.json` still
advertises the *old* zip until then. Clients connecting in between can fail the
hash check.

## Things that have gone wrong here before

- **Two Race Manager plugins ran side by side for weeks.** BeamMP loads EVERY
  folder under `Resources/Server` as a plugin, so a folder called
  `deactivated_plugins` is not deactivated: its `main.lua` registered the same
  events, kept its own auth state, and took the admin login. End Session and
  Reset went to a plugin that was not running the race while the real one logged
  "unauthenticated". From the game it looked like dead buttons. `deploy.py`
  checks for this now and fails the deploy; if it reports one, move it out of
  `Resources/Server` and restart.

- **A stale file fails silently in this mod.** A button just stops doing
  anything, with no error anywhere. If the user reports a dead control right
  after a deploy, check that both halves actually landed before debugging code.
- **The client zip must have `ui/`, `lua/` and `scripts/` at its root.** An extra
  top-level folder means BeamNG mounts nothing.
- **Never deploy from a dirty tree without saying so.** Note the branch: shipping
  an unmerged feature branch to a live server is fine when deliberate, and worth
  stating plainly so the user knows what they are testing.
