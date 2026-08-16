#!/usr/bin/env python3
"""Build the Race Manager package and deploy it to a BeamMP server.

    python3 tools/deploy.py                 build, then deploy to the server it finds
    python3 tools/deploy.py --build-only    just write dist/ and package/
    python3 tools/deploy.py --dry-run       say what it would do, write nothing
    python3 tools/deploy.py --server PATH   skip discovery, use this server
    python3 tools/deploy.py --tidy          also attic loose Race Manager files

Run from the repo root. Exit code is non-zero if anything failed.

Two rules this script will not break, because both have cost real work:

  * It writes exactly two paths: Resources/Client/RaceManager.zip and
    Resources/Server/RaceManager/main.lua. Everything else under
    Resources/Server/RaceManager is LIVE DATA the server owns: layouts.json is
    every track you have built, and cup.json, roster.json, garage.json,
    derbyArenas.json and results/ are the rest of a race night.

  * It backs up whatever it replaces first, and verifies by hash afterwards.
    A stale file fails silently in this mod: a button just stops working.
"""

import argparse
import datetime
import hashlib
import io
import os
import shutil
import sys
import zipfile

# What goes inside the client zip, at these exact paths. BeamNG mounts the zip
# and reads them from its root, so an extra top-level folder means nothing loads.
CLIENT_FILES = [
    'scripts/raceManager/modScript.lua',
    'lua/ge/extensions/raceManager.lua',
    'ui/modules/apps/RaceManager/app.html',
    'ui/modules/apps/RaceManager/app.js',
    'ui/modules/apps/RaceManager/app.json',
    'ui/modules/apps/RaceManager/app.png',
]
SERVER_PLUGIN = 'server/RaceManager/main.lua'
RELEASE_NAME = 'RaceManager-v0.8.0-branching-routes.zip'

# Loose Race Manager files that collect in a server root from hand-installs.
# Other mods' files are never in this list: tidying somebody else's install is
# not this script's business.
TIDY_ITEMS = ['app.html', 'app.js', 'app.json', 'app.zip', 'app(1).js',
              'raceManager.lua', 'raceManager(3).lua', 'RaceManager_wip']


def sha(data):
    return hashlib.sha256(data).hexdigest()[:16]


def sha_file(path):
    with open(path, 'rb') as f:
        return sha(f.read())


def build():
    """Write the client zip in memory, then dist/ and package/ from it."""
    missing = [f for f in CLIENT_FILES + [SERVER_PLUGIN] if not os.path.exists(f)]
    if missing:
        raise SystemExit('missing source files: ' + ', '.join(missing))

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        for f in CLIENT_FILES:
            z.write(f, f)
    client = buf.getvalue()

    os.makedirs('package/Client', exist_ok=True)
    os.makedirs('package/Server/RaceManager', exist_ok=True)
    os.makedirs('dist', exist_ok=True)
    with open('package/Client/RaceManager.zip', 'wb') as f:
        f.write(client)
    shutil.copyfile(SERVER_PLUGIN, 'package/Server/RaceManager/main.lua')

    release = os.path.join('dist', RELEASE_NAME)
    with zipfile.ZipFile(release, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write('LICENSE', 'LICENSE')
        z.writestr('Client/RaceManager.zip', client)
        z.write(SERVER_PLUGIN, 'Server/RaceManager/main.lua')

    print('built %s (%d bytes)' % (release, os.path.getsize(release)))
    print('  client zip %s  %d bytes' % (sha(client), len(client)))
    print('  server lua %s  %d bytes' % (sha_file(SERVER_PLUGIN),
                                         os.path.getsize(SERVER_PLUGIN)))
    return client


def find_server(explicit=None):
    """A BeamMP server is a directory with ServerConfig.toml and Resources/."""
    if explicit:
        if not os.path.isfile(os.path.join(explicit, 'ServerConfig.toml')):
            raise SystemExit('no ServerConfig.toml in ' + explicit)
        return explicit

    env = os.environ.get('RACEMANAGER_SERVER')
    if env:
        return find_server(env)

    seen = []
    for drive in ('C:\\', 'D:\\', 'E:\\'):
        if not os.path.isdir(drive):
            continue
        for root, dirs, files in os.walk(drive):
            # Depth cap: a server lives near the top of a drive, and walking a
            # whole disk to find one costs minutes.
            if root.count(os.sep) > 3:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if not d.startswith(('$', '.'))]
            if 'ServerConfig.toml' in files and os.path.isdir(os.path.join(root, 'Resources')):
                seen.append(root)
    if not seen:
        raise SystemExit('no BeamMP server found. Pass --server PATH or set '
                         'RACEMANAGER_SERVER.')
    if len(seen) > 1:
        raise SystemExit('several servers found, pass --server PATH:\n  '
                         + '\n  '.join(seen))
    return seen[0]


def rival_plugins(server):
    """Any OTHER Race Manager under Resources/Server.

    BeamMP loads EVERY folder under Resources/Server as a plugin, so a folder
    named "deactivated_plugins" is not deactivated in the slightest. One sat
    there for weeks holding a Race Manager from July, running beside the real
    one, registering the same events and keeping its own auth state. The admin
    logged in against the old copy, so End Session and Reset went to a plugin
    that was not running the race and the real one answered "unauthenticated".
    From the outside the buttons were simply dead.

    Nothing about that is visible in game, which is why it is checked here.
    """
    out = []
    base = os.path.join(server, 'Resources', 'Server')
    if not os.path.isdir(base):
        return out
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        if name == 'RaceManager' or not os.path.isdir(d):
            continue
        main = os.path.join(d, 'main.lua')
        if not os.path.isfile(main):
            continue
        try:
            head = open(main, encoding='utf-8', errors='ignore').read(4000)
        except OSError:
            continue
        if 'RaceManager' in head or 'RM_' in head:
            out.append(os.path.relpath(main, server))
    return out


def server_running():
    """Is BeamMP-Server up? Only ever reported, never acted on: stopping
    somebody's live server is their call, not a deploy script's."""
    try:
        import subprocess
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq BeamMP-Server.exe'],
                             capture_output=True, text=True, timeout=15).stdout
        return 'BeamMP-Server.exe' in out
    except Exception:
        return None


def deploy(server, client, dry_run=False):
    stamp = datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
    backup = os.path.join(server, '_attic', 'deploy-' + stamp)
    targets = [
        (client, os.path.join(server, 'Resources', 'Client', 'RaceManager.zip')),
        (open(SERVER_PLUGIN, 'rb').read(),
         os.path.join(server, 'Resources', 'Server', 'RaceManager', 'main.lua')),
    ]

    ok = True
    for data, dest in targets:
        rel = os.path.relpath(dest, server)
        if os.path.exists(dest) and sha_file(dest) == sha(data):
            print('  unchanged  %s' % rel)
            continue
        if dry_run:
            print('  WOULD write %s (%d bytes)' % (rel, len(data)))
            continue
        if os.path.exists(dest):
            os.makedirs(backup, exist_ok=True)
            shutil.copy2(dest, os.path.join(backup, os.path.basename(dest)))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            with open(dest, 'wb') as f:
                f.write(data)
        except PermissionError as e:
            print('  LOCKED     %s (%s)' % (rel, e))
            ok = False
            continue
        good = sha_file(dest) == sha(data)
        ok = ok and good
        print('  %s  %s  %d bytes' % ('written  ' if good else 'MISMATCH ', rel, len(data)))

    if os.path.isdir(backup):
        print('  replaced files backed up to %s' % os.path.relpath(backup, server))
    return ok


def tidy(server, dry_run=False):
    stamp = datetime.date.today().isoformat()
    attic = os.path.join(server, '_attic', stamp)
    moved = []
    for name in TIDY_ITEMS:
        src = os.path.join(server, name)
        if not os.path.exists(src):
            continue
        if dry_run:
            print('  WOULD attic %s' % name)
            continue
        os.makedirs(attic, exist_ok=True)
        shutil.move(src, os.path.join(attic, name))
        moved.append(name)
    if moved:
        print('  atticked %d loose file(s): %s' % (len(moved), ', '.join(moved)))
    elif not dry_run:
        print('  nothing loose to tidy')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--server', help='server directory (skips discovery)')
    ap.add_argument('--build-only', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--tidy', action='store_true',
                    help='also move loose Race Manager files into _attic')
    args = ap.parse_args()

    if not os.path.exists(SERVER_PLUGIN):
        raise SystemExit('run this from the repo root')

    client = build()
    if args.build_only:
        return 0

    server = find_server(args.server)
    print('\nserver: %s' % server)
    running = server_running()
    if running:
        print('  NOTE: BeamMP-Server is RUNNING. Files are replaced on disk, but '
              'the\n        plugin and the client zip are only picked up at '
              'startup, and\n        mods.json still advertises the old zip until '
              'then. RESTART IT.')

    ok = True
    rivals = rival_plugins(server)
    if rivals:
        print('\n  ANOTHER RACE MANAGER IS INSTALLED AS A PLUGIN:')
        for r in rivals:
            print('    ' + r)
        print('  BeamMP loads every folder under Resources/Server, so this'
              ' one is RUNNING: same events, its own auth state, taking'
              ' turns with the real plugin.')
        print('  It looks like dead buttons, not like a conflict. Move it out'
              ' of Resources/Server, then restart.')
        ok = False

    ok = deploy(server, client, args.dry_run) and ok
    if args.tidy:
        tidy(server, args.dry_run)

    print('\n%s' % ('dry run, nothing written' if args.dry_run
                    else ('done' if ok else 'FINISHED WITH ERRORS')))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
