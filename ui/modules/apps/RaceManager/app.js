angular.module('beamng.apps')

/**
 * Race Manager UI app (circuit edition).
 *
 * Receives session state via the native guihooks bridge ('RaceManagerUpdate',
 * 'RaceManagerCountdown', 'RaceManagerRoute') and renders host session
 * controls (Qualifying -> Generate Grid -> Race -> Countdown), race settings
 * (total laps, checkpoint gate width) and a driver table that switches
 * between a Qualifying view (Best Lap + provisional grid) and a Race view
 * (grid, current lap, best lap, laps led). The data originates on the BeamMP
 * server (server/RaceManager/main.lua) and is relayed by the client bridge
 * extension lua/ge/extensions/raceManager.lua. Reactive updates use
 * $scope.$evalAsync (guihooks events arrive outside Angular's digest cycle).
 */
.directive('raceManager', [function () {
  return {
    templateUrl: '/ui/modules/apps/RaceManager/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$element', '$interval', function ($scope, $element, $interval) {

      // ------------------------------------------------------------------
      // State
      // ------------------------------------------------------------------
      $scope.phase = 'waiting';   // waiting | grid | countdown | qualifying | racing | finished
      // 'race' | 'quali' — which session the phases above belong to. Qualifying
      // runs the same lifecycle a race does, so this is what tells them apart.
      $scope.sessionKind = 'race';
      $scope.sessionLaps = 0;     // lap target of the current session (0 = none)
      $scope.raceTime = 0;
      $scope.totalLaps = 5;
      $scope.countdown = null;    // null = hidden, 3..1 = number, 0 = GO!
      $scope.drivers = [];

      // Settings inputs (host).
      //
      // These live on an OBJECT, not as bare scope primitives, and that is not
      // cosmetic: every settings control sits inside `ng-if="isAdmin"`, and an
      // ng-if creates a child scope. Binding `ng-model="lapsInput"` there would
      // write the typed value onto the ng-if child scope, shadowing the
      // controller's own `lapsInput` — so "Set" would post the stale default to
      // the server and the server's echo back would never reach the input the
      // admin is looking at. Going through `settingsUi.*` resolves the object on
      // the controller scope and mutates it in place, so both directions work.
      $scope.settingsUi = {
        laps: 5,
        resets: -1,            // -1 unlimited, 0 none, N per driver per session
        width: 20,             // checkpoint rectangle: lateral span
        height: 10,            // checkpoint rectangle: vertical extent
        qualiLaps: 0,          // qualifying lap allowance (0 = unlimited)
        qualiMins: 0           // qualifying time limit in minutes (0 = none)
      };

      // ----------------------------------------------------------------
      // League regulations (Modules 1, 2 & 4)
      // ----------------------------------------------------------------
      // Vehicle resets: -1 unlimited, 0 none, N per driver per session.
      $scope.maxResets = -1;      // authoritative value mirrored from the server
      $scope.resetsUsed = 0;      // what THIS client has spent
      // What a legal reset does: repair in place, or respawn at the last
      // checkpoint the driver crossed. Mirrored from the server.
      $scope.resetMode = 'inplace';
      // Rallycross joker lap.
      $scope.jokerEnabled = false;
      $scope.jokerRoute = [];     // joker gates placed/loaded on this client
      $scope.jokerNext = 1;
      $scope.jokerTaken = false;
      $scope.jokerLap = null;
      // Which list the checkpoint editor appends to and shows. Three targets:
      // the main lap, the joker route and the starting grid. Anything else is
      // not a target the client Lua knows about, so it falls back to the main
      // lap — the same normalisation raceManager.setEditorTarget applies.
      var EDITOR_TARGETS = { main: true, joker: true, start: true };
      function editorTargetOf(value) {
        return EDITOR_TARGETS[value] ? value : 'main';
      }
      $scope.editorTarget = 'main';
      // Garage list (approved vehicles/setups).
      $scope.garage = [];             // [{ model, label }]
      $scope.garageEnforce = false;
      // Race entry (opt-in): players add themselves to the field instead of
      // every session on the server being assumed to be racing.
      $scope.entryMode = 'join';      // 'join' (opt-in) | 'all' (everyone races)
      $scope.joined = false;          // is THIS client in the field?
      $scope.entrants = 0;
      // Starting grid.
      $scope.gridMode = 'quali';      // quali | random | custom
      $scope.startSlots = 0;          // start positions the loaded track has
      $scope.startPositions = [];     // placed on this client
      $scope.gridSlot = null;         // the slot this client was given
      $scope.gridFrozen = false;      // held on the grid for the countdown
      // Custom grid entry boxes, keyed by driver id. Bound through an object
      // for the same ng-if child-scope reason every other input here is.
      $scope.gridUi = { slot: {} };
      // Qualifying rules.
      $scope.ghostQuali = false;
      $scope.qualiLapLimit = 0;
      $scope.qualiTimeLimit = 0;
      $scope.qualiLeft = null;        // seconds remaining, null = no limit
      $scope.finalLap  = false;       // quali clock expired: this lap is the last
      // Forced spectator mode.
      $scope.spectating = false;
      $scope.spectatorReason = null;
      // Transient banners: regulation notices and vehicle rejections.
      $scope.notice = null;           // { kind, msg }
      $scope.vehicleError = null;     // { message, detail }

      // Live position telemetry for THIS client (pushed by the client Lua at
      // the same ~3 Hz it reports to the server): distance to the next gate.
      $scope.progress = null;         // { lap, cp, dist }

      // ----------------------------------------------------------------
      // Own lap clock: live readout + post-lap hold
      // ----------------------------------------------------------------
      // How long a completed lap time stays on screen after the lap ends. Long
      // enough to read at racing speed without covering the new lap for long.
      var LAP_HOLD_MS = 3000;
      // Render cadence for the live readout. The bridge only pushes every
      // 250 ms; this ticks between pushes so the clock looks like a clock. The
      // displayed value is interpolated from the last push using the browser
      // clock, never accumulated, so it cannot drift away from the bridge.
      var LAP_TICK_MS = 100;
      // Very short lap while a hold is still showing: the newest time REPLACES
      // the held one immediately rather than queueing behind it. Queueing would
      // show a time for a lap the driver finished two laps ago and fall further
      // behind with every short lap -- on a short circuit the display would
      // never catch up to reality.
      $scope.lapLive = null;   // { elapsed, at, lap } — last push + when it landed
      $scope.lapHold = null;   // { lapTime, lap, until } — completed time on hold
      var lapTicker = null;

      function startLapTicker() {
        if (lapTicker) { return; }
        lapTicker = $interval(function () {
          // Expire the hold. Nothing else to do: the live readout is computed
          // on demand from lapLive, and this tick is what re-renders it.
          if ($scope.lapHold && Date.now() >= $scope.lapHold.until) {
            $scope.lapHold = null;
          }
          if (!$scope.lapLive && !$scope.lapHold) { stopLapTicker(); }
        }, LAP_TICK_MS);
      }
      function stopLapTicker() {
        if (lapTicker) { $interval.cancel(lapTicker); lapTicker = null; }
      }

      // Seconds on this lap right now: the bridge's last reading plus however
      // long ago it arrived.
      $scope.lapElapsed = function () {
        if (!$scope.lapLive) { return null; }
        return $scope.lapLive.elapsed + (Date.now() - $scope.lapLive.at) / 1000;
      };
      $scope.lapHolding = function () { return !!$scope.lapHold; };
      // Only worth showing when there is a clock running or a time being held.
      $scope.showLapTime = function () {
        return !!$scope.lapLive || !!$scope.lapHold;
      };

      // Live lap clock from the bridge (250 ms), interpolated between pushes.
      $scope.$on('RaceManagerLapTime', function (event, data) {
        $scope.$evalAsync(function () {
          if (!data || !data.running) {
            $scope.lapLive = null;
            if (!$scope.lapHold) { stopLapTicker(); }
            return;
          }
          $scope.lapLive = {
            elapsed: data.elapsed || 0,
            at: Date.now(),
            lap: data.lap || null
          };
          startLapTicker();
        });
      });

      // A lap just completed: hold its time on screen. The live clock above is
      // already counting the new lap — this only parks a copy of the old one.
      $scope.$on('RaceManagerLapDone', function (event, data) {
        if (!data || typeof data.lapTime !== 'number') { return; }
        $scope.$evalAsync(function () {
          $scope.lapHold = {
            lapTime: data.lapTime,
            lap: data.lap || null,
            until: Date.now() + LAP_HOLD_MS
          };
          startLapTicker();
        });
      });

      // Admin authentication. Every editor/admin control stays hidden until the
      // server confirms a login (RaceManagerAuth). authUi holds the two inputs.
      $scope.isAdmin = false;
      $scope.authUi = { password: '', newPassword: '' };
      $scope.authError = false;   // true after a rejected login attempt
      // Non-admins are spectators: they always see the live timing. showLogin
      // controls whether the login prompt is visible over the top.
      //   - No admin on the server yet: prompt shows (but can be dismissed).
      //   - An admin is already running things: auto-dismiss so spectators just
      //     watch, unless the user has explicitly pinned the login open.
      // A "Login" button in the header brings the prompt back at any time.
      $scope.adminPresent = false;   // does the server currently have any admin?
      $scope.showLogin = true;       // is the login prompt visible?
      $scope.loginPinned = false;    // user explicitly asked to see login
      $scope.pwMsg = null;           // transient confirmation after a password change

      // ----------------------------------------------------------------
      // Admin panel tabs
      // ----------------------------------------------------------------
      // Every admin panel used to render stacked, one under the other. That
      // overflowed the app window — .rm-root is overflow:hidden and only the
      // leaderboard scrolls, so anything past the bottom edge was unreachable,
      // and with the editor and derby panels both open it was most of them.
      // One panel shows at a time now; the tab body scrolls as a safety net so
      // a long gate list or a full derby table can't clip at a small size.
      var ADMIN_TABS = {
        race: true, quali: true, garage: true, editor: true, derby: true, admin: true
      };
      function adminTabOf(value) { return ADMIN_TABS[value] ? value : 'race'; }
      // Persisted so an admin returns to the panel they were working in.
      // (loadPref/savePref are declared further down; both are hoisted function
      // declarations, so calling them here is safe.)
      $scope.adminTab = adminTabOf(loadPref('adminTab', 'race'));
      $scope.isAdminTab = function (tab) { return $scope.adminTab === tab; };
      // The start-slot markers are drawn from Lua, which has no idea whether the
      // editor panel is on screen. Tell it, so that editor furniture stays in
      // the editor instead of being drawn for every racer on the grid.
      function pushEditorOpen() {
        var open = $scope.isAdmin && $scope.adminTab === 'editor';
        bngApi.engineLua('raceManager.setEditorOpen(' + (!!open) + ')');
      }
      $scope.selectAdminTab = function (tab) {
        $scope.adminTab = adminTabOf(tab);
        savePref('adminTab', $scope.adminTab);
        pushEditorOpen();
        // Two panels need a nudge as they re-enter the DOM: the track preview
        // canvas has to be drawn once it exists, and the derby module pulls its
        // state over its own channel.
        if ($scope.adminTab === 'editor') { schedulePreview(); }
        if ($scope.adminTab === 'derby') {
          bngApi.engineLua('raceManager.derbyRequestState()');
        }
      };

      // Checkpoint editor state
      $scope.routeWaypoints = [];
      $scope.nextWp = 1;
      $scope.visualize = true;
      $scope.editorMsg = null;
      // Per-checkpoint override editor: which gate (1-based) is selected, plus
      // its edit fields. Blank fields mean "use the global default".
      $scope.selectedCp = null;
      $scope.cpEdit = { width: '', height: '' };

      // Track layout state (server-side persistent layouts, current map only)
      $scope.layouts = [];              // [{ name, map, width, checkpoints }]
      $scope.layoutMap = '';            // map the server filtered the list by
      // Bound as an object ("dot rule") because these inputs live inside the
      // ng-if editor panel, whose child scope would shadow primitive bindings.
      $scope.layoutUi = { name: '', selected: '' };
      // The layout picker is a custom DOM dropdown, not a native <select>:
      // BeamNG's UI runs in Chromium Embedded Framework (CEF), where a native
      // <select> popup is a separate OS window that never renders over the game
      // surface — the box shows a value but clicking it does nothing. We open
      // and close this menu ourselves so it lives inside the app's own DOM.
      $scope.layoutDropdownOpen = false;

      // ----------------------------------------------------------------
      // DEMO DERBY (isolated module) — separate state, events and commands;
      // nothing here touches the circuit racing scope above.
      // ----------------------------------------------------------------
      $scope.derby = {
        phase: 'idle',        // idle | running | finished (server authoritative)
        time: 0,
        boundaryCount: 0,
        startCount: 0,        // derby starting grid slots placed
        // Who takes part: 'all' (every connected player, the historical
        // behaviour) or 'join' (only drivers who pressed Join Race).
        entryMode: 'all',
        entrants: 0,          // how many would be in a derby started right now
        maxResets: -1,        // resets per driver per derby (-1 = unlimited)
        visualize: true,      // boundary/grid visuals shown (client-local)
        winner: null,
        players: []           // { id, name, status, reason, elimTime, resets }
      };
      // Dot rule again: these inputs live inside the ng-if derby panel.
      $scope.derbyUi = { oob: 5, demo: 10, resets: -1, name: '', selected: '' };
      // Saved arenas for the hosted map (same workflow as track layouts).
      $scope.derbyLayouts = [];
      $scope.derbyLayoutMap = '';
      $scope.derbyDropdownOpen = false;
      // Last config values mirrored from the server. Broadcasts only overwrite
      // an input while it still shows the previous server value; an edit in
      // progress (field differs) survives marker drops and other rebroadcasts.
      var derbyCfgSeen = { oob: null, demo: null, resets: null };
      $scope.derbyWarning = null;  // { type: 'oob'|'stopped', remaining } or null

      var PHASE_LABELS = {
        waiting:    'Waiting',
        qualifying: 'Qualifying',
        grid:       'Grid Locked',
        countdown:  'Countdown',
        racing:     'Racing',
        finished:   'Race Over'
      };
      // The grid and the countdown are shared by both sessions, so on their own
      // they no longer say what is about to happen. An admin who has just
      // pressed Start Quali needs to see that the grid they are looking at is a
      // qualifying grid, not a race one.
      var QUALI_PHASE_LABELS = {
        grid:      'Quali Grid',
        countdown: 'Quali Countdown'
      };
      var STATUS_LABELS = {
        waiting:    'Waiting',
        qualifying: 'On Track',
        gridded:    'On Grid',
        racing:     'Racing',
        finished:   'Finished',
        dsq:        'Disqualified',
        dnf:        'DNF'
      };

      // ------------------------------------------------------------------
      // Display aliases (presentation only)
      // ------------------------------------------------------------------
      // The single resolution point on this side. Every table renders driver
      // names through this and nothing else; `row.id` stays the key everywhere
      // (ng-repeat track by, grid pinning, position tracking), so an alias can
      // never become a lookup. The server sends both fields, so a driver with no
      // alias falls back to their real guest name and can never render blank.
      $scope.driverName = function (row) {
        if (!row) { return ''; }
        return row.alias || row.name || '';
      };
      // Real name, shown to admins beside the alias so a renamed driver can
      // still be tied back to the guest session that set the lap times.
      $scope.realName = function (row) {
        return (row && row.alias) ? row.name : '';
      };
      // Admin-only alias editor inputs, keyed by driver id. Bound through an
      // object for the same ng-if child-scope reason every other input is.
      $scope.aliasUi = { input: {} };

      // ------------------------------------------------------------------
      // Build stamps
      // ------------------------------------------------------------------
      // This mod ships as three separately-deployed pieces and BeamNG caches UI
      // files, so any one of them can be older than the others. That failure is
      // silent in the worst way: Angular ignores a call to a scope function a
      // stale app.js does not have, so a button does nothing and no console
      // anywhere says a word. Showing all three makes it a glance instead of a
      // hunt. Bump this with main.lua and raceManager.lua.
      var APP_BUILD = '3.5.3-draw-cache';
      $scope.appBuild    = APP_BUILD;
      $scope.clientBuild = null;   // from the client bridge (RaceManagerRoute)
      $scope.serverBuild = null;   // from the server broadcast (RaceManagerUpdate)
      $scope.buildsMatch = function () {
        if (!$scope.clientBuild || !$scope.serverBuild) { return true; }  // unknown yet
        return $scope.appBuild === $scope.clientBuild
          && $scope.appBuild === $scope.serverBuild;
      };
      $scope.applyAlias = function (row) {
        if (!row) { return; }
        var v = $scope.aliasUi.input[row.id];
        bngApi.engineLua('raceManager.setAlias(' + row.id + ', '
          + luaStr(v === undefined || v === null ? '' : String(v)) + ')');
      };
      $scope.clearAlias = function (row) {
        if (!row) { return; }
        $scope.aliasUi.input[row.id] = '';
        bngApi.engineLua('raceManager.setAlias(' + row.id + ", '')");
      };

      $scope.phaseLabel = function () {
        if ($scope.sessionKind === 'quali' && QUALI_PHASE_LABELS[$scope.phase]) {
          return QUALI_PHASE_LABELS[$scope.phase];
        }
        return PHASE_LABELS[$scope.phase] || $scope.phase;
      };
      $scope.statusLabel = function (s) { return STATUS_LABELS[s] || s; };

      // Full text for a driver's status cell: the server's ruling reason wins
      // (e.g. "Disqualified - Missed Joker") so the live table matches the
      // exported results file exactly.
      $scope.outcomeLabel = function (row) {
        if (row.outReason) { return row.outReason; }
        return $scope.statusLabel(row.status);
      };

      // ------------------------------------------------------------------
      // Live positions
      // ------------------------------------------------------------------
      // The server sends the driver array already sorted leader-first with a
      // `position` integer on every row. The table still sorts by that integer
      // explicitly, so the view is correct even if a payload ever arrives out
      // of order — and combined with `track by row.id` in the ng-repeat,
      // Angular MOVES the existing <tr> nodes instead of rebuilding them, which
      // is what keeps the reordering smooth instead of flickering.
      $scope.positionOrder = function (row) {
        return (typeof row.position === 'number') ? row.position : 9999;
      };

      // Movement indicator: remembers the last position seen for each driver
      // and flags gains/losses for a few seconds.
      var POS_FLASH_MS = 2500;
      var lastPositions = {};   // id -> last position integer
      var posMoves = {};        // id -> { dir: 'up'|'down', at: timestamp }

      function trackPositionChanges(drivers) {
        var now = Date.now();
        drivers.forEach(function (row) {
          var prev = lastPositions[row.id];
          if (typeof row.position === 'number') {
            if (typeof prev === 'number' && prev !== row.position) {
              posMoves[row.id] = { dir: row.position < prev ? 'up' : 'down', at: now };
            }
            lastPositions[row.id] = row.position;
          }
        });
      }

      $scope.posMove = function (row) {
        var m = posMoves[row.id];
        if (!m || (Date.now() - m.at) > POS_FLASH_MS) { return ''; }
        return m.dir;
      };

      // Position cell text. Finishers keep their classified place; drivers who
      // are out show a dash rather than a misleading number.
      $scope.positionLabel = function (row) {
        if (row.status === 'dnf' || row.status === 'dsq') { return '—'; }
        return row.position ? ('P' + row.position) : '—';
      };

      // Metres to this client's next checkpoint, for the header readout.
      $scope.formatDistance = function (d) {
        if (d === null || d === undefined) { return ''; }
        return (d >= 1000) ? ((d / 1000).toFixed(2) + ' km') : (Math.round(d) + ' m');
      };

      // Joker cell for the race table.
      $scope.jokerLabel = function (row) {
        if (!$scope.jokerEnabled) { return '—'; }
        if (!row.jokerTaken) { return '—'; }
        if (row.jokerTaken > 1) { return '×' + row.jokerTaken + '!'; }
        return 'L' + (row.jokerLap || '?');
      };

      // Reset cell: used/allowed, or a dash when resets are unlimited.
      // (These helpers also keep raw comparison operators out of the template.)
      $scope.resetsLimited = function () { return $scope.maxResets >= 0; };
      // "2/3" — clamped so the counter can never exceed the limit or grow a
      // "+N" tail. Blocked attempts still reach the server and the exported
      // results file; the live counter only ever shows used/allowed.
      $scope.resetLabel = function (row) {
        if (!$scope.resetsLimited()) { return '∞'; }
        return Math.min(row.resets || 0, $scope.maxResets) + '/' + $scope.maxResets;
      };
      $scope.resetsLow = function (row) {
        return $scope.resetsLimited() && ($scope.maxResets - (row.resets || 0)) <= 0;
      };
      $scope.myResetsLow = function () {
        return $scope.resetsLimited() && ($scope.maxResets - $scope.resetsUsed) <= 0;
      };
      // Human-readable summary of the current reset ruleset.
      $scope.resetRuleLabel = function () {
        if (!$scope.resetsLimited()) { return 'unlimited'; }
        return $scope.maxResets === 0 ? 'none' : ($scope.maxResets + ' each');
      };

      // ------------------------------------------------------------------
      // Module 3: minimalist driver view
      // ------------------------------------------------------------------
      // A live session is anything a driver is actively taking part in.
      $scope.sessionLive = function () {
        return $scope.phase === 'qualifying' || $scope.phase === 'countdown'
          || $scope.phase === 'racing' || $scope.derby.phase === 'running';
      };
      // A session whose rules are locked: the field is standing on the grid or
      // running. Start Quali and Generate Grid are refused by the server from
      // here on, so the buttons say so rather than looking broken.
      $scope.sessionUnderWay = function () {
        return $scope.phase === 'countdown' || $scope.phase === 'racing'
          || $scope.phase === 'qualifying';
      };
      // Minimal mode: not logged in as an admin AND a session is live. The
      // whole chrome (header, session controls, editor, derby panel, login bar)
      // is removed from the DOM and only the leaderboard is left on screen.
      // Outside a live session the normal spectator UI comes back, so there is
      // always a way to reach the login prompt.
      $scope.minimalMode = function () {
        return !$scope.isAdmin && $scope.sessionLive();
      };
      // While a derby runs, a driver's leaderboard is the derby standings.
      $scope.derbyBoardOnly = function () {
        return !$scope.isAdmin && $scope.derby.phase === 'running';
      };

      // Qualifying view for the whole of a qualifying session — including its
      // grid and countdown, which a qualifying session now has just like a race
      // does — and in waiting, where a closed quali's provisional order is still
      // the useful thing to show if any times exist. Race view otherwise.
      $scope.isQualiView = function () {
        if ($scope.phase === 'waiting' || $scope.phase === 'finished') {
          return $scope.drivers.some(function (d) { return d.qualiBest != null; })
            && $scope.phase === 'waiting';
        }
        return $scope.sessionKind === 'quali';
      };

      // ------------------------------------------------------------------
      // Formatting helpers
      // ------------------------------------------------------------------
      function pad2(n) { return (n < 10 ? '0' : '') + n; }

      $scope.formatRaceTime = function (t) {
        if (!t || t < 0) { return '00:00'; }
        var m = Math.floor(t / 60);
        var s = Math.floor(t % 60);
        return pad2(m) + ':' + pad2(s);
      };

      $scope.formatLap = function (t) {
        if (t === null || t === undefined) { return '—'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3);
      };

      // Running lap clock: tenths, not thousandths. At a 100 ms render tick the
      // thousandths digit would be frozen noise, and the coarser precision also
      // sets the live readout apart from a held (official) time at a glance.
      $scope.formatLapLive = function (t) {
        if (t === null || t === undefined) { return '—'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(1);
      };

      $scope.formatFinish = function (row) {
        if (row.status === 'dnf') { return 'DNF'; }
        if (row.finishTime === null || row.finishTime === undefined) {
          return row.currentLap ? ('Lap ' + row.currentLap + '/' + $scope.totalLaps) : '—';
        }
        return $scope.formatLap(row.finishTime);
      };

      // ------------------------------------------------------------------
      // Bridge: LUA -> UI
      // ------------------------------------------------------------------
      $scope.$on('RaceManagerUpdate', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.phase = data.phase || 'waiting';
          // Which session the shared lifecycle is running. Qualifying and racing
          // go through the same phases now (grid -> countdown -> running ->
          // done), so the phase alone no longer says which one you are looking
          // at — this does, and it is what the qualifying/race view switches on.
          $scope.sessionKind = data.sessionKind === 'quali' ? 'quali' : 'race';
          if (typeof data.sessionLaps === 'number') { $scope.sessionLaps = data.sessionLaps; }
          $scope.raceTime = data.raceTime || 0;
          $scope.drivers = data.drivers || [];
          // Note gains/losses before the table re-renders, so the arrows in the
          // position column reflect this very update.
          trackPositionChanges($scope.drivers);
          // The server is authoritative for the race distance: whenever the
          // value it reports moves, re-seed the input box so it shows what the
          // session is actually running (including a value clamped server-side,
          // or one another admin set).
          if (typeof data.totalLaps === 'number') {
            if ($scope.totalLaps !== data.totalLaps) { $scope.settingsUi.laps = data.totalLaps; }
            $scope.totalLaps = data.totalLaps;
          }
          if ($scope.phase !== 'countdown') { $scope.countdown = null; }
          // League regulations mirrored from the server (Modules 1, 2 & 4).
          if (typeof data.maxResets === 'number') {
            if ($scope.maxResets !== data.maxResets) { $scope.settingsUi.resets = data.maxResets; }
            $scope.maxResets = data.maxResets;
          }
          if (data.resetMode === 'checkpoint' || data.resetMode === 'inplace') {
            $scope.resetMode = data.resetMode;
          }
          $scope.jokerEnabled = !!data.jokerEnabled;
          // Race entry + starting grid.
          $scope.entryMode = data.entryMode === 'all' ? 'all' : 'join';
          $scope.entrants = data.entrants || 0;
          $scope.gridMode = data.gridMode || 'quali';
          $scope.startSlots = data.startSlots || 0;
          // Qualifying rules. The inputs are re-seeded the same way the laps
          // and resets fields are: only when the server's value actually moved,
          // so an edit in progress is never yanked out from under the admin.
          $scope.ghostQuali = !!data.ghostQuali;
          if (typeof data.qualiLapLimit === 'number') {
            if ($scope.qualiLapLimit !== data.qualiLapLimit) {
              $scope.settingsUi.qualiLaps = data.qualiLapLimit;
            }
            $scope.qualiLapLimit = data.qualiLapLimit;
          }
          if (typeof data.qualiTimeLimit === 'number') {
            if ($scope.qualiTimeLimit !== data.qualiTimeLimit) {
              $scope.settingsUi.qualiMins = Math.round(data.qualiTimeLimit / 60);
            }
            $scope.qualiTimeLimit = data.qualiTimeLimit;
          }
          $scope.qualiLeft = (typeof data.qualiLeft === 'number') ? data.qualiLeft : null;
          // The qualifying clock has expired and everyone still out is on their
          // last lap. The session has NOT ended: drivers keep driving until they
          // cross the line, so the header says so rather than showing a clock
          // frozen on zero and nothing else.
          $scope.finalLap = data.finalLap === true;
          $scope.garage = toArray(data.garage);
          $scope.garageEnforce = !!data.garageEnforce;
          // Track whether an admin is running the session. When one appears and
          // we're just a spectator who hasn't pinned the login open, auto-hide
          // the prompt so the app is fully visible (a header Login button stays).
          if (typeof data.serverBuild === 'string') { $scope.serverBuild = data.serverBuild; }
          $scope.adminPresent = !!data.adminPresent;
          if ($scope.adminPresent && !$scope.isAdmin && !$scope.loginPinned) {
            $scope.showLogin = false;
          }
        });
      });

      // This client's own live telemetry (lap / checkpoints / distance to the
      // next gate), pushed on the same throttle as the server report.
      $scope.$on('RaceManagerProgress', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () { $scope.progress = data; });
      });

      // How long GO! stays up after the lights go out.
      //
      // A race clears this overlay as a side effect: the next state broadcast
      // arrives with a phase that is no longer 'countdown' and nulls it. A DERBY
      // never sends that broadcast -- it is an isolated module with its own
      // state channel -- so GO! sat on screen for the rest of the derby. Clearing
      // it on a timer instead makes the overlay own its own lifetime, and gives
      // GO! a readable beat in both modes rather than however long the next
      // broadcast happens to take.
      var GO_OVERLAY_MS = 1500;
      var goTimer = null;

      $scope.$on('RaceManagerCountdown', function (event, data) {
        $scope.$evalAsync(function () {
          // data.count: 3, 2, 1, 0 (GO!), -1 (hide overlay)
          var c = (data && typeof data.count === 'number') ? data.count : -1;
          $scope.countdown = c >= 0 ? c : null;
          if (goTimer) { clearTimeout(goTimer); goTimer = null; }
          if (c === 0) {
            goTimer = setTimeout(function () {
              $scope.$evalAsync(function () { $scope.countdown = null; });
            }, GO_OVERLAY_MS);
          }
        });
      });

      $scope.$on('RaceManagerRoute', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.routeWaypoints = data.waypoints || [];
          $scope.nextWp = data.nextWp || 1;
          $scope.visualize = data.visualize !== false;
          if (typeof data.clientBuild === 'string') { $scope.clientBuild = data.clientBuild; }
          // Admin session restored from the client bridge. This directive is
          // destroyed and rebuilt every time BeamNG tears down the HUD layer —
          // opening the pause menu does exactly that — so isAdmin cannot live
          // only in this scope, or every pause reads as a logout. The bridge
          // outlives the app and hands it back on the first route push.
          if (typeof data.isAdmin === 'boolean' && data.isAdmin !== $scope.isAdmin) {
            $scope.isAdmin = data.isAdmin;
            if (data.isAdmin) {
              $scope.showLogin = false;
              $scope.loginPinned = false;
              $scope.authError = false;
            }
            pushEditorOpen();
          }
          if (typeof data.width === 'number') { $scope.settingsUi.width = data.width; }
          if (typeof data.height === 'number') { $scope.settingsUi.height = data.height; }
          // Starting grid placed/loaded on this client.
          $scope.startPositions = toArray(data.startPositions);
          $scope.gridSlot = data.gridSlot || null;
          $scope.gridFrozen = !!data.gridFrozen;
          // Race entry state as this client knows it.
          if (typeof data.entryMode === 'string') { $scope.entryMode = data.entryMode; }
          if (typeof data.joined === 'boolean') { $scope.joined = data.joined; }
          // Joker route + reset allowance state pushed by the client Lua.
          $scope.jokerRoute = toArray(data.jokerRoute);
          $scope.jokerNext = data.jokerNext || 1;
          $scope.jokerTaken = !!data.jokerTaken;
          $scope.jokerLap = data.jokerLap || null;
          $scope.editorTarget = editorTargetOf(data.editorTarget);
          if (typeof data.resetsUsed === 'number') { $scope.resetsUsed = data.resetsUsed; }
          if (data.resetMode === 'checkpoint' || data.resetMode === 'inplace') {
            $scope.resetMode = data.resetMode;
          }
          if (typeof data.spectating === 'boolean') { $scope.spectating = data.spectating; }
          // Keep the override editor in sync (a gate may have been removed, or
          // its stored overrides changed by the last command).
          if ($scope.selectedCp != null && !$scope.editorWaypoints()[$scope.selectedCp - 1]) {
            $scope.selectedCp = null;
          }
        });
      });

      // The list the editor panel shows: main lap, joker route or starting
      // grid, whichever the editor is currently pointed at.
      $scope.editorWaypoints = function () {
        if ($scope.editorTarget === 'joker') { return $scope.jokerRoute; }
        if ($scope.editorTarget === 'start') { return $scope.startPositions; }
        return $scope.routeWaypoints;
      };

      // Start positions are placements, not gates: the width/height override
      // editor does not apply to them.
      $scope.editingGrid = function () { return $scope.editorTarget === 'start'; };

      // ------------------------------------------------------------------
      // Regulation notices, forced spectating and vehicle rejections
      // ------------------------------------------------------------------
      var noticeTimer = null;
      $scope.$on('RaceManagerNotice', function (event, data) {
        if (!data || !data.msg) { return; }
        $scope.$evalAsync(function () {
          $scope.notice = { kind: data.kind || 'info', msg: data.msg };
          if (noticeTimer) { clearTimeout(noticeTimer); }
          noticeTimer = setTimeout(function () {
            $scope.$evalAsync(function () { $scope.notice = null; });
          }, 6000);
        });
      });

      $scope.$on('RaceManagerSpectator', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.spectating = !!(data && data.spectating);
          $scope.spectatorReason = $scope.spectating ? (data.reason || null) : null;
        });
      });

      // "Vehicle/Setup not allowed in this session." — stays until dismissed or
      // superseded, because it explains why the player has no car.
      var vehErrTimer = null;
      $scope.$on('RaceManagerVehicleError', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.vehicleError = {
            message: (data && data.message) || 'Vehicle/Setup not allowed in this session.',
            detail: (data && data.detail) || ''
          };
          if (vehErrTimer) { clearTimeout(vehErrTimer); }
          vehErrTimer = setTimeout(function () {
            $scope.$evalAsync(function () { $scope.vehicleError = null; });
          }, 10000);
        });
      });

      $scope.dismissVehicleError = function () { $scope.vehicleError = null; };

      // Password change confirmed by the server — flash a short note in the
      // admin bar so the change is acknowledged even outside the editor panel.
      var pwMsgTimer = null;
      $scope.$on('RaceManagerPasswordChanged', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.pwMsg = '✓ Password updated' + (data && data.by ? ' by ' + data.by : '');
          if (pwMsgTimer) { clearTimeout(pwMsgTimer); }
          pwMsgTimer = setTimeout(function () {
            $scope.$evalAsync(function () { $scope.pwMsg = null; });
          }, 4000);
        });
      });

      // Admin auth result from the server (or an offline auto-grant). Success
      // reveals every admin/editor control; failure flags the login box.
      $scope.$on('RaceManagerAuth', function (event, data) {
        $scope.$evalAsync(function () {
          var ok = !!(data && data.success);
          // `restored` marks a session handed back by the client bridge or
          // re-confirmed by the server, rather than the answer to a password
          // somebody just typed. Only a real attempt can fail, so only a real
          // attempt lights the "Incorrect password" warning.
          var restored = !!(data && data.restored);
          $scope.isAdmin = ok;
          $scope.authError = !ok && !restored;
          if (ok) {
            $scope.authUi.password = '';
            $scope.showLogin = false;
            $scope.loginPinned = false;
          }
          // Admin status gates the editor, so the Lua-side flag moves with it.
          pushEditorOpen();
        });
      });

      // The Lua JSON encoder serializes EMPTY tables as {} rather than [],
      // so "no layouts" / "no checkpoints" can arrive as an object. Normalize
      // to a real array so .some/.length/ng-options and the canvas never
      // explode on a non-array. (Previously this threw a TypeError here,
      // which killed the handler before the preview was ever scheduled.)
      function toArray(v) {
        if (Array.isArray(v)) { return v; }
        if (v && typeof v === 'object') {
          return Object.keys(v).map(function (k) { return v[k]; });
        }
        return [];
      }

      $scope.$on('RaceManagerLayouts', function (event, data) {
        if (!data) {
          console.warn('[RaceManager] RaceManagerLayouts event with no data');
          return;
        }
        $scope.$evalAsync(function () {
          $scope.layouts = toArray(data.layouts);
          $scope.layouts.forEach(function (l) { l.checkpoints = toArray(l.checkpoints); });
          $scope.layoutMap = data.map || '';
          console.log('[RaceManager] Layout list received: ' + $scope.layouts.length
            + ' layout(s) for map "' + $scope.layoutMap + '"');
          // Keep the selection if the layout still exists after a refresh.
          if (!Array.isArray($scope.layouts)) { $scope.layouts = []; }
          var stillThere = $scope.layouts.some(function (l) {
            return l.name === $scope.layoutUi.selected;
          });
          if (!stillThere) { $scope.layoutUi.selected = ''; }
          // Nothing to pick from -> make sure the menu isn't left hanging open.
          if (!$scope.layouts.length) { $scope.layoutDropdownOpen = false; }
          schedulePreview();
        });
      });

      // ------------------------------------------------------------------
      // DEMO DERBY bridge + commands (isolated from the racing handlers)
      // ------------------------------------------------------------------
      $scope.$on('RaceManagerDerby', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.derby.phase = data.derbyPhase || 'idle';
          $scope.derby.entryMode = data.entryMode === 'join' ? 'join' : 'all';
          $scope.derby.entrants = data.entrants || 0;
          $scope.derby.time = data.derbyTime || 0;
          $scope.derby.winner = data.winner || null;
          $scope.derby.boundaryCount = toArray(data.boundary).length;
          $scope.derby.startCount = toArray(data.startPositions).length;
          $scope.derby.players = toArray(data.players);
          if (typeof data.maxResets === 'number') { $scope.derby.maxResets = data.maxResets; }
          if (typeof data.oobLimit === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.oob === null || Number($scope.derbyUi.oob) === derbyCfgSeen.oob) {
              $scope.derbyUi.oob = data.oobLimit;
            }
            derbyCfgSeen.oob = data.oobLimit;
          }
          if (typeof data.demoLimit === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.demo === null || Number($scope.derbyUi.demo) === derbyCfgSeen.demo) {
              $scope.derbyUi.demo = data.demoLimit;
            }
            derbyCfgSeen.demo = data.demoLimit;
          }
          if (typeof data.maxResets === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.resets === null || Number($scope.derbyUi.resets) === derbyCfgSeen.resets) {
              $scope.derbyUi.resets = data.maxResets;
            }
            derbyCfgSeen.resets = data.maxResets;
          }
          if ($scope.derby.phase !== 'running') { $scope.derbyWarning = null; }
        });
      });

      // Client-local Hide/Show toggle for the boundary + derby grid visuals.
      $scope.$on('RaceManagerDerbyVisual', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.derby.visualize = !(data && data.visualize === false);
        });
      });

      // Flashing full-screen warnings pushed every frame by the client Lua
      // while a countdown is active; { oob: null, stopped: null } clears them.
      $scope.$on('RaceManagerDerbyWarning', function (event, data) {
        $scope.$evalAsync(function () {
          if (data && typeof data.oob === 'number' && data.oob > 0) {
            $scope.derbyWarning = { type: 'oob', remaining: data.oob };
          } else if (data && typeof data.stopped === 'number' && data.stopped > 0) {
            $scope.derbyWarning = { type: 'stopped', remaining: data.stopped };
          } else {
            $scope.derbyWarning = null;
          }
        });
      });

      $scope.derbyStatusLabel = function (p) {
        if (p.status === 'winner') { return 'WINNER'; }
        if (p.status === 'alive') { return 'In Arena'; }
        return p.reason || 'Eliminated';
      };

      $scope.formatDerbyTime = function (t) {
        if (t === null || t === undefined) { return '—'; }
        var m = Math.floor(t / 60);
        var s = Math.floor(t % 60);
        return m + ':' + pad2(s);
      };

      $scope.derbyApplyConfig = function () {
        var oob = parseFloat($scope.derbyUi.oob);
        var demo = parseFloat($scope.derbyUi.demo);
        if (!isFinite(oob) || oob <= 0 || !isFinite(demo) || demo <= 0) { return; }
        // Resets mirror the race rule: blank or negative = unlimited, 0 = none.
        var resets = parseInt($scope.derbyUi.resets, 10);
        if (isNaN(resets) || resets < 0) { resets = -1; }
        bngApi.engineLua('raceManager.derbySetConfig(' + oob + ', ' + demo + ', ' + resets + ')');
      };
      $scope.derbyAddMarker = function () {
        bngApi.engineLua('raceManager.derbyAddMarker()');
      };
      $scope.derbyClearBoundary = function () {
        bngApi.engineLua('raceManager.derbyClearBoundary()');
      };
      // Derby starting grid: drive to each slot and place it; slot 1 first.
      $scope.derbyAddStart = function () {
        bngApi.engineLua('raceManager.derbyAddStartPosition()');
      };
      $scope.derbyClearStarts = function () {
        bngApi.engineLua('raceManager.derbyClearStartPositions()');
      };
      $scope.derbyToggleVisualize = function () {
        bngApi.engineLua('raceManager.derbyToggleVisualize()');
      };
      // Reset cell for the derby standings, clamped the same way the race
      // table's is: never over the limit, never a "+N" tail.
      $scope.derbyResetsLimited = function () { return $scope.derby.maxResets >= 0; };
      $scope.derbyResetLabel = function (p) {
        if (!$scope.derbyResetsLimited()) { return '∞'; }
        return Math.min(p.resets || 0, $scope.derby.maxResets) + '/' + $scope.derby.maxResets;
      };
      // A derby is under way from form-up onward, not just while running: the
      // field is standing on its slots and held, so the arena and the rules are
      // locked exactly as they are mid-derby.
      $scope.derbyActive = function () {
        return $scope.derby.phase === 'forming'
          || $scope.derby.phase === 'countdown'
          || $scope.derby.phase === 'running';
      };
      $scope.derbyPhaseLabel = function () {
        switch ($scope.derby.phase) {
          case 'running':   return 'LIVE — ' + $scope.formatDerbyTime($scope.derby.time);
          case 'forming':   return 'Formed up — held';
          case 'countdown': return 'Countdown';
          case 'finished':  return 'Finished';
          default:          return 'Setup';
        }
      };
      $scope.derbyFormUp = function () {
        // Push the timer/reset inputs first, so the derby forms up with what the
        // admin currently has on screen. This has to happen HERE rather than at
        // Start: once the field is formed the rules are locked, so a config sent
        // then would simply be refused.
        $scope.derbyApplyConfig();
        bngApi.engineLua('raceManager.derbyFormUp()');
      };

      // Derby entry: everyone connected, or only drivers who pressed Join Race.
      $scope.toggleDerbyEntryMode = function () {
        bngApi.engineLua('raceManager.derbySetEntryMode("'
          + ($scope.derby.entryMode === 'all' ? 'join' : 'all') + '")');
      };

      $scope.derbyStart = function () {
        // No config push here — the rules were sent at Form Up and are locked
        // from that point, so this is purely "release the field".
        bngApi.engineLua('raceManager.derbyStart()');
      };
      $scope.derbyEnd = function () {
        bngApi.engineLua('raceManager.derbyEnd()');
      };

      // --- Derby arena layouts (mirrors the track layout workflow) --------
      $scope.$on('RaceManagerDerbyLayouts', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.derbyLayouts = toArray(data.layouts);
          $scope.derbyLayouts.forEach(function (l) { l.boundary = toArray(l.boundary); });
          $scope.derbyLayoutMap = data.map || '';
          var stillThere = $scope.derbyLayouts.some(function (l) {
            return l.name === $scope.derbyUi.selected;
          });
          if (!stillThere) { $scope.derbyUi.selected = ''; }
          if (!$scope.derbyLayouts.length) { $scope.derbyDropdownOpen = false; }
        });
      });

      $scope.derbySaveLayout = function () {
        var name = ($scope.derbyUi.name || '').trim();
        if (!name) { return; }
        // Send the timer fields first so the arena is saved with what the admin
        // currently has on screen, not the last value the server saw.
        $scope.derbyApplyConfig();
        bngApi.engineLua('raceManager.derbySaveLayout(' + luaStr(name) + ')');
      };
      $scope.derbyLoadLayout = function () {
        if (!$scope.derbyUi.selected) { return; }
        bngApi.engineLua('raceManager.derbyLoadLayout(' + luaStr($scope.derbyUi.selected) + ')');
      };
      $scope.derbyDeleteLayout = function () {
        if (!$scope.derbyUi.selected) { return; }
        bngApi.engineLua('raceManager.derbyDeleteLayout(' + luaStr($scope.derbyUi.selected) + ')');
      };
      // Same custom-dropdown reasoning as the track layout picker: a native
      // <select> popup does not render in BeamNG's embedded browser.
      $scope.toggleDerbyDropdown = function () {
        if (!$scope.derbyLayouts.length) { $scope.derbyDropdownOpen = false; return; }
        $scope.derbyDropdownOpen = !$scope.derbyDropdownOpen;
        // Same scroll-container clipping guard as the track layout picker.
        if ($scope.derbyDropdownOpen) { revealDropdown('.rm-derby-layouts .rm-layout-menu'); }
      };
      $scope.selectDerbyLayout = function (l) {
        $scope.derbyUi.selected = l.name;
        $scope.derbyDropdownOpen = false;
      };
      $scope.selectedDerbyLabel = function () {
        if (!$scope.derbyLayouts.length) { return 'No arenas saved for this map'; }
        if (!$scope.derbyUi.selected) { return 'Select an arena…'; }
        for (var i = 0; i < $scope.derbyLayouts.length; i++) {
          if ($scope.derbyLayouts[i].name === $scope.derbyUi.selected) {
            return $scope.derbyLayouts[i].name
              + ' (' + $scope.derbyLayouts[i].boundary.length + ' markers)';
          }
        }
        return $scope.derbyUi.selected;
      };

      var editorMsgTimer = null;
      $scope.$on('RaceManagerEditorMsg', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.editorMsg = data && data.msg;
          if (editorMsgTimer) { clearTimeout(editorMsgTimer); }
          editorMsgTimer = setTimeout(function () {
            $scope.$evalAsync(function () { $scope.editorMsg = null; });
          }, 4000);
        });
      });

      // ------------------------------------------------------------------
      // UI -> LUA commands (admin authentication)
      // ------------------------------------------------------------------
      // Layout/password strings go through engineLua as Lua string literals.
      function luaStr(s) {
        return "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, ' ') + "'";
      }

      $scope.login = function () {
        $scope.authError = false;
        var p = $scope.authUi.password || '';
        bngApi.engineLua('extensions.load("raceManager"); raceManager.login(' + luaStr(p) + ')');
      };

      // Dismiss the login prompt and just watch (spectator). Available whether or
      // not an admin is present, so nobody is ever stuck on the login screen.
      $scope.spectate = function () {
        $scope.showLogin = false;
        $scope.loginPinned = false;
        $scope.authError = false;
        $scope.authUi.password = '';
      };

      // Bring the login prompt back at any time (header "Login" button). Pinned
      // so a subsequent state broadcast won't auto-hide it again.
      $scope.openLogin = function () {
        $scope.showLogin = true;
        $scope.loginPinned = true;
        $scope.authError = false;
      };

      // Admin logs out -> back to spectator + login prompt, and drop server auth.
      $scope.logout = function () {
        $scope.isAdmin = false;
        $scope.showLogin = true;
        $scope.loginPinned = true;
        // The admin tab is left where it was: every panel is behind ng-if
        // isAdmin anyway, and a logout shouldn't discard the remembered tab.
        pushEditorOpen();   // no admin, no editor: drop the start-slot markers
        bngApi.engineLua('raceManager.logout()');
      };

      $scope.changePassword = function () {
        var p = ($scope.authUi.newPassword || '').trim();
        if (!p) { return; }
        bngApi.engineLua('raceManager.changePassword(' + luaStr(p) + ')');
        $scope.authUi.newPassword = '';
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (session controls)
      // ------------------------------------------------------------------
      $scope.startQualifying = function () {
        bngApi.engineLua('extensions.load("raceManager"); raceManager.startQualifying()');
      };
      $scope.generateGrid = function () {
        bngApi.engineLua('raceManager.generateGrid()');
      };
      $scope.startCountdown = function () {
        bngApi.engineLua('raceManager.startCountdown()');
      };
      $scope.endRace = function () {
        bngApi.engineLua('raceManager.endRace()');
      };
      $scope.resetLeaderboard = function () {
        bngApi.engineLua('raceManager.resetLeaderboard()');
      };
      $scope.clearResults = function () {
        bngApi.engineLua('raceManager.clearResults()');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (race settings)
      // ------------------------------------------------------------------
      $scope.applyTotalLaps = function () {
        var n = parseInt($scope.settingsUi.laps, 10);
        if (!n || n < 1) { return; }
        bngApi.engineLua('raceManager.setTotalLaps(' + n + ')');
      };
      // Module 1: reset allowance. Blank or negative = unlimited, 0 = none.
      $scope.applyMaxResets = function () {
        var n = parseInt($scope.settingsUi.resets, 10);
        if (isNaN(n)) { n = -1; }
        if (n < 0) { n = -1; }
        bngApi.engineLua('raceManager.setMaxResets(' + n + ')');
      };

      // Module 1: what a legal reset does — repair in place or respawn at the
      // last checkpoint crossed.
      $scope.setResetMode = function (mode) {
        bngApi.engineLua('raceManager.setResetMode("'
          + (mode === 'checkpoint' ? 'checkpoint' : 'inplace') + '")');
      };

      // Module 2: arm/disarm the joker lap requirement.
      $scope.toggleJoker = function () {
        bngApi.engineLua('raceManager.setJokerEnabled(' + (!$scope.jokerEnabled) + ')');
      };

      // Module 4: capture the vehicle the admin is driving right now.
      $scope.whitelistCurrentVehicle = function () {
        bngApi.engineLua('raceManager.whitelistCurrentVehicle()');
      };
      $scope.clearGarage = function () {
        bngApi.engineLua('raceManager.clearGarage()');
      };
      $scope.removeGarageEntry = function (index) {
        bngApi.engineLua('raceManager.removeGarageEntry(' + (index + 1) + ')');
      };
      $scope.toggleGarageEnforce = function () {
        bngApi.engineLua('raceManager.setGarageEnforce(' + (!$scope.garageEnforce) + ')');
      };

      $scope.applyWidth = function () {
        var w = parseFloat($scope.settingsUi.width);
        if (!w || w <= 0) { return; }
        bngApi.engineLua('raceManager.setCheckpointWidth(' + w + ')');
      };
      $scope.applyHeight = function () {
        var h = parseFloat($scope.settingsUi.height);
        if (!h || h <= 0) { return; }
        bngApi.engineLua('raceManager.setCheckpointHeight(' + h + ')');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (race entry, grid and qualifying rules)
      // ------------------------------------------------------------------
      // Any player can enter or withdraw; this is not an admin control.
      $scope.joinRace = function () {
        bngApi.engineLua('extensions.load("raceManager"); raceManager.joinRace(true)');
      };
      $scope.leaveRace = function () {
        bngApi.engineLua('raceManager.joinRace(false)');
      };
      $scope.canJoin = function () {
        return $scope.phase !== 'countdown' && $scope.phase !== 'racing';
      };
      // Admin: opt-in entry vs "everyone on the server races".
      $scope.toggleEntryMode = function () {
        bngApi.engineLua('raceManager.setEntryMode("'
          + ($scope.entryMode === 'all' ? 'join' : 'all') + '")');
      };
      $scope.setGridMode = function (mode) {
        bngApi.engineLua('raceManager.setGridMode("' + mode + '")');
      };
      $scope.gridModeLabel = function () {
        if ($scope.gridMode === 'random') { return 'Random draw'; }
        if ($scope.gridMode === 'custom') { return 'Custom order'; }
        return 'Qualifying order';
      };
      // Custom grid: pin one driver to one slot.
      $scope.pinGridSlot = function (row) {
        var n = parseInt($scope.gridUi.slot[row.id], 10);
        if (!n || n < 1) { return; }
        bngApi.engineLua('raceManager.setDriverGridSlot(' + row.id + ', ' + n + ')');
      };
      // The custom-order boxes only make sense before the lights go out.
      $scope.canEditGrid = function () {
        return $scope.isAdmin && $scope.gridMode === 'custom'
          && $scope.phase !== 'countdown' && $scope.phase !== 'racing';
      };
      $scope.toggleGhostQuali = function () {
        bngApi.engineLua('raceManager.setGhostQuali(' + (!$scope.ghostQuali) + ')');
      };
      // Qualifying session length. Laps are per driver; the time limit is
      // entered in minutes and sent as seconds. 0 means unlimited for both.
      $scope.applyQualiLimits = function () {
        var laps = parseInt($scope.settingsUi.qualiLaps, 10);
        var mins = parseFloat($scope.settingsUi.qualiMins);
        if (isNaN(laps) || laps < 0) { laps = 0; }
        if (isNaN(mins) || mins < 0) { mins = 0; }
        bngApi.engineLua('raceManager.setQualiLimits('
          + laps + ', ' + Math.round(mins * 60) + ')');
      };
      // Remaining qualifying time for the header readout.
      $scope.qualiClock = function () {
        if ($scope.qualiLeft === null || $scope.qualiLeft === undefined) { return ''; }
        return $scope.formatRaceTime($scope.qualiLeft);
      };
      $scope.qualiLimitLabel = function () {
        var bits = [];
        if ($scope.qualiLapLimit > 0) { bits.push($scope.qualiLapLimit + ' laps'); }
        if ($scope.qualiTimeLimit > 0) { bits.push(Math.round($scope.qualiTimeLimit / 60) + ' min'); }
        return bits.length ? bits.join(' / ') : 'open';
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (starting grid editor)
      // ------------------------------------------------------------------
      // "Place Start Position Here" is the same editorAdd the checkpoint tabs
      // use — the editor target decides which list it lands in.
      $scope.moveStartPosition = function (index) {
        bngApi.engineLua('raceManager.moveStartPosition(' + index + ')');
      };
      $scope.removeStartPosition = function (index) {
        bngApi.engineLua('raceManager.removeStartPosition(' + index + ')');
      };
      $scope.previewStartPosition = function (index) {
        bngApi.engineLua('raceManager.previewStartPosition(' + index + ')');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (checkpoint editor)
      // ------------------------------------------------------------------
      $scope.editorAdd = function () {
        bngApi.engineLua('raceManager.editorAdd()');
      };
      $scope.editorUndo = function () {
        bngApi.engineLua('raceManager.editorUndo()');
      };
      $scope.editorClear = function () {
        bngApi.engineLua('raceManager.editorClear()');
      };
      $scope.editorSave = function () {
        bngApi.engineLua('raceManager.editorSave()');
      };
      $scope.editorLoad = function () {
        bngApi.engineLua('raceManager.editorLoad()');
      };
      $scope.editorToggleVisualize = function () {
        bngApi.engineLua('raceManager.editorToggleVisualize()');
      };

      // Switch the editor between the main lap, the joker route and the start
      // grid. Everything in the editor panel (+ Checkpoint Here, Undo, Clear,
      // the list below) follows this selection. The tab is applied locally as
      // well as sent on: the client's route broadcast echoes it back, but the
      // panel must not wait a frame (or a lost broadcast) to switch.
      $scope.setEditorTarget = function (target) {
        $scope.selectedCp = null;
        $scope.editorTarget = editorTargetOf(target);
        bngApi.engineLua('raceManager.setEditorTarget("' + $scope.editorTarget + '")');
      };

      // Per-checkpoint override editing: pick a placed gate (1-based) and load
      // its current overrides (blank = inheriting the global default) into the
      // edit fields. Clicking the selected gate again collapses the editor.
      $scope.selectCheckpoint = function (index) {
        if ($scope.selectedCp === index) { $scope.selectedCp = null; return; }
        $scope.selectedCp = index;
        var wp = $scope.editorWaypoints()[index - 1] || {};
        $scope.cpEdit = {
          width:  (typeof wp.width === 'number') ? wp.width : '',
          height: (typeof wp.height === 'number') ? wp.height : ''
        };
      };

      // Push the edit fields to the client. A blank field clears that override
      // (the gate falls back to the global default). 0 stands in for "blank".
      $scope.applyCheckpointOverride = function () {
        if (!$scope.selectedCp) { return; }
        var w = parseFloat($scope.cpEdit.width)  || 0;
        var h = parseFloat($scope.cpEdit.height) || 0;
        bngApi.engineLua('raceManager.setCheckpointOverride('
          + $scope.selectedCp + ', ' + w + ', ' + h + ')');
      };

      // Reset the selected gate back to the global defaults (clear all overrides).
      $scope.resetCheckpointOverride = function () {
        if (!$scope.selectedCp) { return; }
        $scope.cpEdit = { width: '', height: '' };
        bngApi.engineLua('raceManager.setCheckpointOverride(' + $scope.selectedCp + ', 0, 0)');
      };

      // Effective (displayed) dimension for a gate row: its override or the
      // global default the rectangle will actually use.
      $scope.cpDim = function (wp, field) {
        if (wp && typeof wp[field] === 'number') { return wp[field]; }
        if (field === 'width')  { return $scope.settingsUi.width; }
        return $scope.settingsUi.height;
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (track layouts)
      // ------------------------------------------------------------------
      // (luaStr defined above in the admin-authentication section.)
      $scope.saveLayout = function () {
        var name = ($scope.layoutUi.name || '').trim();
        console.log('Current layout name in scope:', $scope.layoutUi.name);
        if (!name) {
          console.warn('[RaceManager] Save Layout: no name entered, nothing sent');
          return;
        }
        if (!$scope.routeWaypoints.length) {
          console.warn('[RaceManager] Save Layout: no checkpoints placed, nothing sent');
          return;
        }
        console.log('[RaceManager] Save Layout "' + name + '": handing '
          + $scope.routeWaypoints.length + ' checkpoint(s) to client Lua');
        bngApi.engineLua('raceManager.saveLayout(' + luaStr(name) + ')');
      };

      $scope.loadLayout = function () {
        if (!$scope.layoutUi.selected) { return; }
        console.log('[RaceManager] Load Layout "' + $scope.layoutUi.selected + '" requested');
        bngApi.engineLua('raceManager.loadLayout(' + luaStr($scope.layoutUi.selected) + ')');
      };

      // The layout and arena pickers are absolutely positioned menus, and the
      // admin tab body is a scroll container — a menu opened near its bottom
      // edge would hang below the visible area. Scroll it into the scroller
      // once Angular has put it in the DOM (the same deferred pattern the
      // preview canvas uses).
      function revealDropdown(selector) {
        setTimeout(function () {
          var menu = $element[0].querySelector(selector);
          if (menu && menu.scrollIntoView) { menu.scrollIntoView({ block: 'nearest' }); }
        }, 0);
      }

      // Custom dropdown behaviour (see $scope.layoutDropdownOpen above for why
      // this isn't a native <select>). Opening only makes sense when there are
      // layouts to choose from; selecting an option mirrors the old
      // ng-model + ng-change pair (set the name, redraw the preview).
      $scope.toggleLayoutDropdown = function () {
        if (!$scope.layouts.length) { $scope.layoutDropdownOpen = false; return; }
        $scope.layoutDropdownOpen = !$scope.layoutDropdownOpen;
        if ($scope.layoutDropdownOpen) { revealDropdown('.rm-layouts .rm-layout-menu'); }
      };

      $scope.selectLayoutOption = function (l) {
        $scope.layoutUi.selected = l.name;
        $scope.layoutDropdownOpen = false;
        schedulePreview();
      };

      // Label shown on the closed dropdown button.
      $scope.selectedLayoutLabel = function () {
        if (!$scope.layouts.length) { return 'No layouts saved for this map'; }
        var sel = selectedLayout();
        if (!sel) { return 'Select a layout…'; }
        return sel.name + ' (' + toArray(sel.checkpoints).length + ' gates)';
      };

      // ------------------------------------------------------------------
      // 2D track preview (top-down minimap of the selected layout)
      // ------------------------------------------------------------------
      function selectedLayout() {
        for (var i = 0; i < $scope.layouts.length; i++) {
          if ($scope.layouts[i].name === $scope.layoutUi.selected) { return $scope.layouts[i]; }
        }
        return null;
      }

      // The canvas lives inside the ng-if editor panel, so drawing is deferred
      // a tick to run after Angular has (re)inserted it into the DOM.
      function schedulePreview() {
        setTimeout(function () {
          try {
            drawPreview();
          } catch (e) {
            console.error('[RaceManager] Track preview draw failed:', e);
          }
        }, 0);
      }

      function drawPreview() {
        var canvas = $element[0].querySelector('.rm-preview-canvas');
        if (!canvas) {
          console.log('[RaceManager] Preview: canvas not in the DOM (editor panel closed), skipping');
          return;
        }
        var ctx = canvas.getContext('2d');
        var W = canvas.width, H = canvas.height;
        ctx.clearRect(0, 0, W, H);

        var layout = selectedLayout();
        var raw = layout ? toArray(layout.checkpoints) : [];
        // Coerce and validate every coordinate: a single null/undefined/NaN
        // point would otherwise poison the bounding box and blank the map.
        var cps = [];
        raw.forEach(function (p, i) {
          var x = p && Number(p.x), y = p && Number(p.y);
          if (p == null || !isFinite(x) || !isFinite(y)) {
            console.warn('[RaceManager] Preview: checkpoint ' + (i + 1)
              + ' has invalid coordinates, skipping it:', p);
            return;
          }
          cps.push({ x: x, y: y, hx: Number(p.hx) || 0, hy: Number(p.hy) || 0 });
        });
        console.log('[RaceManager] Preview: layout "' + (layout ? layout.name : '(none selected)')
          + '", ' + cps.length + '/' + raw.length + ' drawable checkpoint(s)');

        if (!cps.length) {
          ctx.fillStyle = 'rgba(154, 160, 166, 0.7)';
          ctx.font = '11px "Noto Sans", sans-serif';
          ctx.textAlign = 'center';
          ctx.fillText($scope.layouts.length ? 'Select a layout to preview' : 'No saved layouts', W / 2, H / 2);
          return;
        }

        // Normalize world X/Y into the canvas: fit the track's bounding box,
        // preserve aspect ratio, center it, and flip Y (world north = up).
        var pad = 16;
        var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
        cps.forEach(function (p) {
          if (p.x < minX) { minX = p.x; }
          if (p.x > maxX) { maxX = p.x; }
          if (p.y < minY) { minY = p.y; }
          if (p.y > maxY) { maxY = p.y; }
        });
        var spanX = (maxX - minX) || 1;
        var spanY = (maxY - minY) || 1;
        var scale = Math.min((W - 2 * pad) / spanX, (H - 2 * pad) / spanY);
        if (!isFinite(scale) || scale <= 0) {
          console.error('[RaceManager] Preview: degenerate scale (' + scale
            + ') from bounds x[' + minX + ',' + maxX + '] y[' + minY + ',' + maxY + ']');
          return;
        }
        var ox = (W - spanX * scale) / 2;
        var oy = (H - spanY * scale) / 2;
        function px(p) { return ox + (p.x - minX) * scale; }
        function py(p) { return H - (oy + (p.y - minY) * scale); }

        // Track outline: connect the gates in driving order and close the lap
        // (the route is a circuit — after the last gate you cross gate 1 again).
        if (cps.length > 1) {
          ctx.beginPath();
          ctx.moveTo(px(cps[0]), py(cps[0]));
          for (var i = 1; i < cps.length; i++) { ctx.lineTo(px(cps[i]), py(cps[i])); }
          ctx.closePath();
          ctx.strokeStyle = 'rgba(232, 234, 237, 0.75)';
          ctx.lineWidth = 2;
          ctx.lineJoin = 'round';
          ctx.stroke();
        }

        // Regular checkpoints: orange dots. Last checkpoint = start/finish.
        for (var j = 0; j < cps.length - 1; j++) {
          ctx.beginPath();
          ctx.arc(px(cps[j]), py(cps[j]), 3, 0, Math.PI * 2);
          ctx.fillStyle = '#ff6600';
          ctx.fill();
        }

        // Start/finish gate: green line drawn perpendicular to the stored
        // heading, using the layout's real gate width (min length so it stays
        // visible on huge tracks). World-Y flip also mirrors the perpendicular.
        var sf = cps[cps.length - 1];
        var hx = sf.hx || 0, hy = sf.hy || 1;
        var half = Math.max(((layout.width || 20) / 2) * scale, 6);
        var rx = hy, ry = -hx;  // right-hand perpendicular in world XY
        ctx.beginPath();
        ctx.moveTo(px(sf) - rx * half, py(sf) + ry * half);
        ctx.lineTo(px(sf) + rx * half, py(sf) - ry * half);
        ctx.strokeStyle = '#34a853';
        ctx.lineWidth = 4;
        ctx.lineCap = 'round';
        ctx.stroke();

        // Gate count caption in the corner.
        ctx.fillStyle = 'rgba(154, 160, 166, 0.8)';
        ctx.font = '10px "Noto Sans", sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText(cps.length + ' gates · ' + (layout.map || ''), 6, H - 6);
      }

      // ------------------------------------------------------------------
      // Module 3: driver (non-admin) leaderboard ergonomics
      // ------------------------------------------------------------------
      // A driver who is not logged in sees the leaderboard and nothing else.
      // Because that panel now sits over the windscreen, they get two controls
      // the admin UI never needed: drag the bottom-right corner to resize it,
      // and a slider to fade its background out of the way. Both persist in
      // localStorage so the choice survives a session.
      function loadPref(key, def) {
        try {
          var raw = window.localStorage.getItem('raceManager.lb.' + key);
          return raw === null ? def : JSON.parse(raw);
        } catch (e) { return def; }
      }
      function savePref(key, value) {
        try {
          window.localStorage.setItem('raceManager.lb.' + key, JSON.stringify(value));
        } catch (e) { /* private mode / storage disabled: preferences are optional */ }
      }

      // Opacity is bound with ng-model from inside an ng-if (the driver bar), so
      // it has to hang off an object for the same reason the settings inputs do:
      // a bare primitive would be shadowed on the ng-if child scope, leaving the
      // slider moving a copy nothing else reads.
      $scope.lbUi = { opacity: loadPref('opacity', 0.85) };   // 0 (invisible) .. 1 (solid)
      $scope.lbWidth   = loadPref('width', null);     // px, null = follow the app window
      $scope.lbHeight  = loadPref('height', null);

      // Applied to the leaderboard container in minimal (driver) mode.
      $scope.lbStyle = function () {
        var style = { 'background-color': 'rgba(15, 17, 22, ' + Number($scope.lbUi.opacity) + ')' };
        if ($scope.lbWidth)  { style.width = $scope.lbWidth + 'px'; }
        if ($scope.lbHeight) {
          style.height = $scope.lbHeight + 'px';
          style['max-height'] = $scope.lbHeight + 'px';
        }
        return style;
      };

      $scope.applyOpacity = function () { savePref('opacity', Number($scope.lbUi.opacity)); };

      var resizeFrom = null;
      function onResizeMove(ev) {
        if (!resizeFrom) { return; }
        var w = Math.max(200, resizeFrom.w + (ev.clientX - resizeFrom.x));
        var h = Math.max(80,  resizeFrom.h + (ev.clientY - resizeFrom.y));
        $scope.$evalAsync(function () {
          $scope.lbWidth = Math.round(w);
          $scope.lbHeight = Math.round(h);
        });
      }
      function onResizeEnd() {
        document.removeEventListener('mousemove', onResizeMove);
        document.removeEventListener('mouseup', onResizeEnd);
        if (resizeFrom) {
          savePref('width', $scope.lbWidth);
          savePref('height', $scope.lbHeight);
        }
        resizeFrom = null;
      }
      // Grip in the bottom-right corner of the leaderboard. Listeners go on the
      // document so the drag keeps tracking even when the pointer leaves the
      // (small) grip element.
      $scope.startLeaderboardResize = function (ev) {
        var wrap = $element[0].querySelector('.rm-table-wrap');
        if (!wrap) { return; }
        ev.preventDefault();
        ev.stopPropagation();
        var rect = wrap.getBoundingClientRect();
        resizeFrom = { x: ev.clientX, y: ev.clientY, w: rect.width, h: rect.height };
        document.addEventListener('mousemove', onResizeMove);
        document.addEventListener('mouseup', onResizeEnd);
      };

      $scope.resetLeaderboardSize = function () {
        $scope.lbWidth = null;
        $scope.lbHeight = null;
        savePref('width', null);
        savePref('height', null);
      };

      $scope.$on('$destroy', function () {
        document.removeEventListener('mousemove', onResizeMove);
        document.removeEventListener('mouseup', onResizeEnd);
        if (noticeTimer) { clearTimeout(noticeTimer); }
        if (vehErrTimer) { clearTimeout(vehErrTimer); }
        if (goTimer) { clearTimeout(goTimer); }
        stopLapTicker();
        // The app is going away (HUD teardown, pause menu, app closed), so the
        // editor is not open any more. Without this the start-slot markers
        // would stay drawn in the world with no panel behind them.
        bngApi.engineLua('raceManager.setEditorOpen(false)');
      });

      // ------------------------------------------------------------------
      // Lifecycle: load the backend and pull current state immediately so the
      // window is never blank, even before the first server broadcast.
      // ------------------------------------------------------------------
      // requestState also pulls the map-filtered layout list from the server.
      bngApi.engineLua('extensions.load("raceManager"); raceManager.requestState()');
      // Demo Derby module: pull its state separately (isolated channel).
      bngApi.engineLua('raceManager.derbyRequestState()');
      // Re-assert the editor flag on mount. The admin tab is restored from
      // localStorage, so a rebuilt app can come straight back up on the Editor
      // tab -- and the Lua side was told "closed" when the old one was torn down.
      pushEditorOpen();
    }]
  };
}]);
