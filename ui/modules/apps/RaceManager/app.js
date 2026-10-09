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
      // The flag the field is racing under. NOT a phase: it rides alongside one,
      // because a caution does not change what the session is doing.
      $scope.flag = 'green';      // green | yellow, the SESSION's flag
      // The flag THIS driver is shown: green, yellow or white on their last lap.
      // Resolved by the client, which is the only half that knows their lap.
      $scope.driverFlag = 'green';
      // THE ENTRY DECISION: this player has taken themselves out of the field.
      // Durable, server-owned, and answered only by `youSpectating`. Distinct
      // from carTaken below, which is about the camera.
      $scope.spectating = false;
      // 'race' | 'quali' - which session the phases above belong to. Qualifying
      // runs the same lifecycle a race does, so this is what tells them apart.
      $scope.sessionKind = 'race';
      $scope.sessionLaps = 0;     // lap target of the current session (0 = none)
      $scope.raceTime = 0;
      $scope.totalLaps = 5;
      $scope.countdown = null;    // null = hidden, 3..1 = number, 0 = GO!
      $scope.drivers = [];

      // Settings inputs, on an OBJECT: they sit inside ng-if child scopes, where
      // a bare primitive ng-model would shadow the controller's value.
      $scope.settingsUi = {
        laps: 5,
        resets: -1,            // -1 unlimited, 0 none, N per driver per session
        width: 20,             // checkpoint rectangle: lateral span
        height: 8,             // meters the gate rises ABOVE where it was placed
        depth: 2,              // meters it drops BELOW; the two are independent
        qualiLaps: 0,          // qualifying lap allowance (0 = unlimited)
        qualiMins: 0,          // qualifying time limit in minutes (0 = none)
        raceMins: 0,           // race time limit in minutes (0 = run to laps)
        heats: 0,              // heats the night is split into (0 = no program)
        transfer: 0,           // drivers transferring out of each heat
        heatLaps: 0            // laps a heat runs (0 = the race distance)
      };

      // ----------------------------------------------------------------
      // League regulations (Modules 1, 2 & 4)
      // ----------------------------------------------------------------
      // Vehicle resets: -1 unlimited, 0 none, N per driver per session.
      // Timed races: the server's limit, the live countdown, and the two
      // post-expiry states. See raceEndState below for what the header says.
      $scope.raceMode = 'laps';   // 'laps' | 'timed' | 'endurance'
      $scope.raceTimeLimit = 0;   // seconds, 0 = the race runs to a lap count
      $scope.raceLeft = null;     // seconds remaining, null when not a timed race
      $scope.raceClock = null;    // race time from the green, held under red
      $scope.clockStopped = false; // a red flag is holding the race clock
      $scope.raceExpired = false; // clock out, waiting on the leader's crossing
      $scope.lastLapNum = null;   // the lap everyone still running finishes on
      $scope.maxResets = -1;      // authoritative value mirrored from the server
      $scope.resetsUsed = 0;      // what THIS client has spent
      // What a legal reset does: repair in place, or respawn at the last
      // checkpoint the driver crossed. Mirrored from the server.
      $scope.resetMode = 'inplace';
      // `paceLap` is the rule armed before the grid; `pacing` the formation lap
      // actually running.
      $scope.paceLap = false;
      $scope.pacing = false;
      // The caution. Separate from `flag === 'yellow'` on purpose: an advisory
      // yellow is a local hazard, a caution is a neutralised race with the
      // running order frozen, and the board has to say which it is showing.
      $scope.caution = false;
      $scope.cautionLaps = 0;
      // Called and not yet official: the field is racing back to the line and
      // the board is still live. A different thing to say from POSITIONS FROZEN.
      $scope.cautionPending = false;
      // A restart is called and the green falls on the leader's run to the line.
      $scope.restartPending = false;
      // The free pass: the rule, and the driver who took it this caution.
      $scope.luckyDog = false;
      $scope.cautionLucky = null;
      $scope.heatLaps = 0;
      $scope.heatDraw = 'quali';
      // Module 6: the heat program.
      $scope.heatCount = 0;
      $scope.heatTransfer = 0;
      $scope.heatCurrent = 0;
      $scope.heatsDrawn = false;
      // Rallycross joker lap.
      $scope.jokerEnabled = false;
      $scope.jokerGates = 0;      // joker gates the LOADED TRACK has (server's count)
      $scope.jokerRoute = [];     // joker gates placed/loaded on this client
      // The pit lane, as this client has it. Declared rather than left to the
      // first route state: the editor tabs read .length, and an ng-if on an
      // undefined shows the "no entry gate" warning before a track has loaded.
      $scope.pitRoute = [];
      $scope.pitEntry = [];
      $scope.pitExit  = [];
      $scope.jokerNext = 1;
      $scope.jokerTaken = false;
      $scope.jokerLap = null;
      // The checkpoint editor's targets, a WHITELIST: a tab missing here falls
      // back to the main route and silently appends to the lap. Adding a tab is
      // TWO edits (ui_bindings_test checks they agree). The last three are the
      // arena's: place mode is shared by both editors.
      var EDITOR_TARGETS = { main: true, joker: true, pit: true, start: true,
                             pitEntry: true, pitExit: true,
                             branch: true, marker: true, prop: true,
                             derbyMarker: true, derbyStart: true,
                             derbyCenter: true };
      function editorTargetOf(value) {
        return EDITOR_TARGETS[value] ? value : 'main';
      }
      $scope.editorTarget = 'main';
      $scope.nudgeOn = false;
      $scope.nudgeSel = null;
      // Branch gates: another way through an existing checkpoint, so no lane
      // arithmetic is needed anywhere.
      $scope.branches = [];        // [{ slot, x, y, z, ... }]
      // Direction markers: signage for long point-to-point stages. Non-functional
      // by design -- nothing arms them, nothing scores them.
      $scope.markers = [];         // [{ x, y, z, hx, hy, kind, ... }]
      $scope.markerKind = 'right'; // the symbol the next placed marker gets
      $scope.markerKinds = [];     // symbol keys, in the order the panel offers them
      $scope.markerLabels = {};    // key -> human label, both from the extension
      // Props: static scenery saved with the layout; the kinds come from the extension.
      $scope.props = [];           // [{ x, y, z, hx, hy, kind, solid }]
      $scope.propKind = 'cone';    // what the next placed prop is
      $scope.propKinds = [];
      $scope.propLabels = {};
      $scope.branchSlot = 1;       // checkpoint the next placed branch gate belongs to
      $scope.gridOffLine = false;  // grid is away from the line, so an out lap is owed
      $scope.hasBranches = false;  // mirrored from the server: any branch gates on this track?
      // Bound with ng-model from inside ng-if blocks, so every one of these has to
      // hang off an object: a bare primitive is shadowed on the child scope
      // Angular creates, leaving the control editing a copy nobody reads.
      $scope.laneUi = { menu: null };
      $scope.laneRange = { from: 1, to: 1 };   // the slot range Turn Around acts on
      $scope.gridGen = { count: 12, spacing: 8, stagger: 6, width: 2, from: 0 };
      $scope.gridGenerated = false;   // is there a generated grid the sliders may move?
      // Garage list (approved vehicles/setups).
      $scope.garage = [];             // [{ model, label, class, pc }]
      // The subset a driver can spawn: entries carrying a saved config path.
      $scope.garageSpawnable = [];
      // The class boxes, beside the list (`garage` is replaced on every
      // broadcast) and BEHIND A DOT (they sit in an ng-repeat child scope).
      $scope.garageClassUi = { input: [] };
      // The rename editor, kept apart from `garage` for the same reason.
      $scope.garageNameUi = { index: null, name: '', was: '', def: '', custom: false };
      $scope.garageEnforce = false;
      // 'parts' locks the parts, 'strict' the tuning too. The server owns it.
      $scope.garageMode = 'parts';
      // Saved garage sets: a series in a file. Names only; the cars come back
      // when one is loaded. `name` is the box to save under, `selected` is the
      // set the Load/Delete buttons act on.
      $scope.garageSets = [];
      $scope.garageSetUi = { name: '', selected: '' };
      // Behind a dot: the panel sits inside an ng-if (ui_bindings_test).
      $scope.garagePickUi = { open: false };
      $scope.resultsPath = '';   // the server's results folder, admins only
      // A mirror of the server's entry count until the first broadcast.
      $scope.entrants = 0;
      // Starting grid.
      $scope.gridMode = 'quali';      // quali | reverse | random | custom
      $scope.startSlots = 0;          // start positions the loaded track has
      $scope.startPositions = [];     // placed on this client
      $scope.gridSlot = null;         // the slot this client was given
      $scope.gridFrozen = false;      // held on the grid for the countdown
      // Custom grid entry boxes, keyed by driver id. Bound through an object
      // for the same ng-if child-scope reason every other input here is.
      $scope.gridUi = { slot: {} };
      // Qualifying rules.
      $scope.ghostQuali = false;
      // Put display names on BeamMP's nametags as well as on the board.
      // Server-owned so every client agrees; each client applies it locally,
      // because a nametag is drawn from that machine's own player list.
      $scope.nametags = false;
      $scope.qualiLapLimit = 0;
      $scope.qualiTimeLimit = 0;
      $scope.qualiLeft = null;        // seconds remaining, null = no limit
      $scope.finalLap  = false;       // quali clock expired: this lap is the last
      // Does the session open with an untimed out lap (a header badge)? Whether
      // THIS driver is on theirs comes from the lap clock feed, which is instant.
      $scope.qualiOutLap = false;
      // FORCED SPECTATOR (car removed, freecam). Never an entry decision: sharing
      // one variable once made Rejoin look broken.
      $scope.carTaken = false;
      $scope.spectatorReason = null;
      // Transient banners: regulation notices and vehicle rejections.
      // { kind, msg, sub, rank, flash, ms } or null. Set only by noticeAdvance;
      // everything else goes through noticePush and waits its turn.
      $scope.notice = null;
      $scope.vehicleError = null;     // { message, detail }

      // Live position telemetry for THIS client (pushed by the client Lua at
      // the same ~3 Hz it reports to the server): distance to the next gate.
      $scope.progress = null;         // { lap, cp, dist }

      // ----------------------------------------------------------------
      // Own lap clock: live readout + post-lap hold
      // ----------------------------------------------------------------
      // How long a completed lap time stays on screen.
      var LAP_HOLD_MS = 3000;
      // The readout ticks between the bridge's 250 ms pushes, interpolated from
      // the last push, so it cannot drift.
      var LAP_TICK_MS = 100;
      // A new lap time REPLACES a held one at once; queueing would fall behind
      // on a short circuit.
      $scope.lapLive = null;   // { elapsed, at, lap }: last push + when it landed
      $scope.lapHold = null;   // { lapTime, lap, delta, until }: completed time on hold
      var lapTicker = null;

      function startLapTicker() {
        if (lapTicker) { return; }
        lapTicker = $interval(function () {
          // Expire the hold. Nothing else to do: the live readout is computed
          // on demand from lapLive, and this tick is what re-renders it.
          if ($scope.lapHold && Date.now() >= $scope.lapHold.until) {
            $scope.lapHold = null;
          }
          if ($scope.sectorHold && Date.now() >= $scope.sectorHold.until) {
            $scope.sectorHold = null;
          }
          // The sector hold keeps the ticker alive too, or a sector time shown
          // between laps would sit on screen until something else happened to
          // start it again.
          if (!$scope.lapLive && !$scope.lapHold && !$scope.sectorHold) {
            stopLapTicker();
          }
        }, LAP_TICK_MS);
      }
      // THE PIT CLOCK RUNS HERE. pitLeft only arrives with the route state,
      // which is pushed as the stop starts and ends and not between, so the bar
      // sat on 5.0s for the whole stop. Each push re-anchors the end time.
      var pitTicker = null;
      $scope.pitEndsAt = 0;
      $scope.pitClock = function () {
        return Math.max(0, ($scope.pitEndsAt - Date.now()) / 1000);
      };
      function pitTickerOn(on) {
        if (on && !pitTicker) { pitTicker = $interval(function () {}, 100); }
        if (!on && pitTicker) { $interval.cancel(pitTicker); pitTicker = null; }
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
      // IS THERE A LIVE TIMING RUN TO DRAW? The run owns a whole line, so an
      // empty one is a blank row across the bar -- which is what the panel
      // looked like between sessions before this asked the question.
      $scope.showTiming = function () {
        return $scope.phase === 'racing' || $scope.phase === 'finished'
          || $scope.phase === 'qualifying' || $scope.showLapTime();
      };
      // Shown with a clock running or a time held. A held sector counts, or a
      // sector could only appear beside a lap time.
      $scope.showLapTime = function () {
        return !!$scope.lapLive || !!$scope.lapHold || !!$scope.sectorHold;
      };
      // On the out lap now? From the lap clock feed, which is instant (the driver
      // row is a broadcast behind).
      $scope.onOutLap = function () {
        return !!($scope.lapLive && $scope.lapLive.outLap);
      };
      // ...and the moment it ENDS, held on screen for a few seconds in place of
      // the lap time a scored lap would leave there.
      $scope.outLapDone = function () {
        return !!($scope.lapHold && $scope.lapHold.outLap);
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
            lap: data.lap || null,
            outLap: !!data.outLap
          };
          startLapTicker();
        });
      });

      // A lap completed: hold its time. An out lap arrives with NO time: a number
      // shown for it is one a driver will try to beat.
      $scope.$on('RaceManagerLapDone', function (event, data) {
        if (!data) { return; }
        if (!data.outLap && typeof data.lapTime !== 'number') { return; }
        $scope.$evalAsync(function () {
          $scope.lapHold = {
            lapTime: data.outLap ? null : data.lapTime,
            outLap: !!data.outLap,
            lap: data.lap || null,
            delta: (typeof data.delta === 'number') ? data.delta : null,
            until: Date.now() + LAP_HOLD_MS
          };
          startLapTicker();
          // Practice keeps its laps on screen (there is no board), session-local
          // and never sent. practiceComplete too: the target lap ends the run.
          if (($scope.practice || $scope.practiceComplete) && !data.outLap
              && typeof data.lapTime === 'number') {
            if ($scope.practiceBest === null || data.lapTime < $scope.practiceBest) {
              $scope.practiceBest = data.lapTime;
            }
            $scope.practiceLaps.unshift({
              lap: data.lap || ($scope.practiceLaps.length + 1),
              time: data.lapTime,
              delta: (typeof data.delta === 'number') ? data.delta : null
            });
            // Bounded, because this is a DRIVER's screen and every row is
            // watched. Ten laps is more than anybody reads at a glance and keeps
            // the panel off the low-end budget the rest of the client respects.
            if ($scope.practiceLaps.length > 10) { $scope.practiceLaps.pop(); }
          }
        });
      });

      // Sector times, held briefly, against this driver's BEST for the sector
      // (last lap swings on one corner). Local: no server round trip.
      var SECTOR_HOLD_MS = 4000;
      $scope.sectorHold = null;
      $scope.sectorHolding = function () { return !!$scope.sectorHold; };
      $scope.$on('RaceManagerSector', function (event, data) {
        if (!data || typeof data.time !== 'number') { return; }
        $scope.$evalAsync(function () {
          $scope.sectorHold = {
            sector: data.sector, count: data.count, time: data.time,
            // null on the first visit to a sector: nothing to compare against,
            // and a 0.000 would read as "dead level" rather than "no data".
            delta: (typeof data.delta === 'number') ? data.delta : null,
            best: data.best === true,
            until: Date.now() + SECTOR_HOLD_MS
          };
          startLapTicker();
        });
      });

      // Admin authentication. Every editor/admin control stays hidden until the
      // server confirms a login (RaceManagerAuth). authUi holds the two inputs.
      $scope.isAdmin = false;
      $scope.authUi = { password: '', newPassword: '', newModPassword: '' };
      $scope.authError = false;   // true after a rejected login attempt
      // WHICH TIER this login is worth: 'admin' or 'moderator'. isAdmin still
      // means "may run the night" and still gates every control it gated
      // before, because that is what both tiers are for.
      $scope.adminRole = null;
      // What a moderator may not do: change a password, clear results, delete a
      // layout. A null role (offline, or an older server) is the WIDER tier.
      $scope.isFullAdmin = function () {
        return $scope.isAdmin && $scope.adminRole !== 'moderator';
      };
      // For the panel's own explanation of why a control is missing.
      $scope.isModerator = function () {
        return $scope.isAdmin && $scope.adminRole === 'moderator';
      };
      // Non-admins always see live timing; the login prompt sits over it, and the
      // header Login button brings it back.
      $scope.adminPresent = false;   // does the server currently have any admin?
      // Closed until asked for (the lock buttons in the driver bar and header).
      $scope.showLogin = false;      // is the login prompt visible?
      $scope.loginPinned = false;    // user explicitly asked to see login
      $scope.pwMsg = null;           // transient confirmation after a password change

      // ----------------------------------------------------------------
      // Admin panel tabs
      // ----------------------------------------------------------------
      // One panel at a time (.rm-root is overflow:hidden), in ONE tab row; `mode`
      // is derived from the tab. A WHITELIST: an unknown tab falls back to Race,
      // so a new tab is TWO edits, the button and this.
      var TABS = { race: true, quali: true, grid: true, track: true, garage: true,
                   cup: true, derby: true, drag: true, admin: true };
      var DEFAULT_TAB = 'race';

      // The mode a tab puts the panel in. Derby and drag swap the board (`drivers`
      // still holds the last race); everything else is a race.
      var TAB_MODE = { derby: 'derby', drag: 'drag' };

      function tabOf(value) { return TABS[value] ? value : DEFAULT_TAB; }
      function modeForTab(tab) { return TAB_MODE[tab] || 'race'; }

      // Persisted so an admin returns to the panel they were working in. One
      // key now, not one per mode: there is one row to remember a place in.
      $scope.adminTab = tabOf(loadPref('adminTab', DEFAULT_TAB));
      $scope.mode = modeForTab($scope.adminTab);
      $scope.isMode = function (mode) { return $scope.mode === mode; };
      $scope.isAdminTab = function (tab) { return $scope.adminTab === tab; };

      // ------------------------------------------------------------------
      // The menu bar
      // ------------------------------------------------------------------
      // menu.open: null, 'tab' (adminTab), or a shared panel ('practice',
      // 'records', 'cup', 'garage', 'maps'); menu.group is the open dropdown. Not
      // remembered: the board is what to come back to.
      $scope.menu = { open: null, group: null };
      var TAB_TITLES = { race: 'Race rules', quali: 'Qualifying', grid: 'Grid and heats',
                         track: 'Track', garage: 'Garage List', cup: 'Cup',
                         derby: 'Demo Derby', drag: 'Drag racing', admin: 'Admin' };
      var PANEL_TITLES = { practice: 'Practice', records: 'Lap records',
                           cup: 'Cup standings', garage: 'Garage', maps: 'Map vote' };
      // STILL THERE TO SHOW. A panel can go away while open: a vote starts, the
      // cup is switched off, the admin logs out. Without this the board stays
      // hidden behind an empty panel.
      function menuAvailable(name) {
        switch (name) {
          case 'tab':      return $scope.isAdmin;
          case 'practice': return $scope.canPractice() || !!$scope.practice || !!$scope.practiceComplete;
          case 'records':  return true;
          case 'cup':      return !$scope.isAdmin && !!$scope.cup.enabled;
          case 'garage':   return !$scope.isAdmin && $scope.garageSpawnable.length > 0;
          case 'maps':     return !$scope.isAdmin && !!$scope.maps.voting && !$scope.maps.vote;
        }
        return false;
      }
      $scope.menuShowing = function () {
        var m = $scope.menu.open;
        return !!m && menuAvailable(m) && !$scope.minimalMode() && !$scope.broadcastMode();
      };
      $scope.menuIsTab = function (tab) {
        return $scope.menu.open === 'tab' && $scope.adminTab === tab;
      };
      $scope.menuInRaceGroup = function () {
        var t = $scope.adminTab;
        return $scope.menu.open === 'tab' && (t === 'race' || t === 'quali' || t === 'grid');
      };
      $scope.menuTitle = function () {
        return $scope.menu.open === 'tab' ? (TAB_TITLES[$scope.adminTab] || '')
          : (PANEL_TITLES[$scope.menu.open] || '');
      };
      $scope.menuToggleGroup = function (g) {
        $scope.menu.group = $scope.menu.group === g ? null : g;
      };
      // An admin tab. Pressing the open one again closes it.
      $scope.menuTab = function (tab) {
        $scope.menu.group = null;
        if ($scope.menuIsTab(tab)) { $scope.menuClose(); return; }
        var was = $scope.adminTab;
        $scope.menu.open = 'tab';
        $scope.selectAdminTab(tab);
        // Reopening the same tab is not a tab change, but its panel is new: the
        // preview canvas, the editor flag and the pulls all need doing again.
        if ($scope.adminTab === was) { afterTabChange(); }
      };
      $scope.menuPanel = function (name) {
        $scope.menu.group = null;
        if ($scope.menu.open === name) { $scope.menuClose(); return; }
        $scope.menu.open = name;
        // Each of these was a collapsed section that asked for its data as it
        // opened. They open with the panel now, and still ask.
        if (name === 'records') {
          $scope.recordsUi.open = true;
          $scope.recordsUi.menu = false;
          $scope.recordsRequest($scope.records.layout);
        } else if (name === 'garage') {
          $scope.garagePickUi.open = true;
        } else if (name === 'maps') {
          $scope.mapsUi.driverOpen = true;
          $scope.mapsRefresh();
        }
        pushEditorOpen();
      };
      $scope.menuClose = function () {
        $scope.menu.open = null;
        $scope.menu.group = null;
        $scope.recordsUi.open = false;
        pushEditorOpen();
      };
      // A session going live puts the board back, unless an admin pinned the
      // panel with Keep open (autoSlim off). A driver's HUD takes over anyway,
      // so theirs always closes.
      function menuSessionEdge() {
        if (!$scope.menu.open || !$scope.sessionLive()) { return; }
        if ($scope.isAdmin && !$scope.autoSlim) { return; }
        $scope.menuClose();
      }

      // ------------------------------------------------------------------
      // The Layouts menu
      // ------------------------------------------------------------------
      // Every saved track, strip and arena on this map, by kind. A dropdown, not
      // a panel: the board stays up and no editor opens, so loading never swaps
      // in the authoring visuals. A row loads for everyone.
      $scope.layoutKinds = [
        { key: 'race',  label: 'Race' },
        { key: 'p2p',   label: 'P2P' },
        { key: 'arena', label: 'Arenas' },
        { key: 'drag',  label: 'Drag Strip' }
      ];
      // Rebuilt when a list arrives, never per digest: ng-repeat over fresh rows
      // every digest never settles.
      $scope.layoutMenu = { race: [], p2p: [], arena: [], drag: [] };
      // What the server is on, for the LOADED tag. '' is nothing.
      $scope.loadedLayout = '';
      $scope.loadedArena  = '';
      var KIND_MODE = { race: 'race', p2p: 'race', drag: 'drag', arena: 'derby' };

      function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }
      function trackFacts(l, kind) {
        var gates = toArray(l.checkpoints).length;
        var grid  = toArray(l.startPositions).length;
        var out = kind === 'drag' ? [plural(grid, 'lane'), plural(gates, 'gate')]
                                  : [plural(gates, 'gate')];
        if (kind !== 'drag' && grid) { out.push(grid + ' grid'); }
        if (toArray(l.joker).length) { out.push('joker'); }
        if (toArray(l.pits).length) { out.push('pits'); }
        return out.join(', ');
      }
      function arenaFacts(a) {
        var out = [a.boundaryMode === 'rect' ? 'rectangle'
                                             : plural(toArray(a.boundary).length, 'marker')];
        var slots = toArray(a.startPositions).length;
        if (slots) { out.push(plural(slots, 'slot')); }
        return out.join(', ');
      }
      function rebuildLayoutMenu() {
        var m = { race: [], p2p: [], arena: [], drag: [] };
        $scope.layouts.forEach(function (l) {
          var kind = l.pointToPoint !== true ? 'race' : (l.drag === true ? 'drag' : 'p2p');
          m[kind].push({ kind: kind, name: l.name, facts: trackFacts(l, kind),
                         practice: l.practice === true });
        });
        $scope.derbyLayouts.forEach(function (a) {
          m.arena.push({ kind: 'arena', name: a.name, facts: arenaFacts(a) });
        });
        $scope.layoutMenu = m;
      }
      $scope.layoutCount = function () {
        return $scope.layouts.length + $scope.derbyLayouts.length;
      };
      $scope.isLoadedRow = function (r) {
        var on = r.kind === 'arena' ? $scope.loadedArena : $scope.loadedLayout;
        return !!on && on.toLowerCase() === r.name.toLowerCase();
      };
      // Why a row cannot load now, '' when it can. A live session of any kind
      // refuses them all: the panel would change mode under it.
      $scope.layoutsBlock = function (kind) {
        if ($scope.derbyActive()) { return 'Not during a derby'; }
        if ($scope.dragLive() && $scope.drag.phase !== 'complete') {
          return 'Not while a drag ladder runs';
        }
        if (kind === 'arena' ? $scope.sessionRunning() : !$scope.canSetRules()) {
          return 'Not during a session';
        }
        return '';
      };
      $scope.layoutsPick = function (r) {
        if ($scope.layoutsBlock(r.kind)) { return; }
        $scope.menu.group = null;
        if (r.kind === 'arena') {
          $scope.derbyUi.selected = r.name;
          $scope.derbyLoadLayout();
        } else {
          // Selected in the editor too, so Track > Overwrite targets it.
          $scope.layoutUi.selected = r.name;
          $scope.loadLayout();
          schedulePreview();
        }
        modeFollowsLoad(r.kind);
      };
      // The panel goes to the mode of what was loaded. An open admin panel closes
      // first: opening the Derby tab is what turns the derby editor on.
      function modeFollowsLoad(kind) {
        var mode = KIND_MODE[kind];
        if ($scope.mode === mode) { return; }
        if ($scope.menu.open === 'tab') { $scope.menuClose(); }
        $scope.selectAdminTab(mode === 'race' ? DEFAULT_TAB : mode);
      }

      // Running a race, or configuring one. These replace fourteen hand-written
      // phase tests that all missed qualifying. The markup asks what may be done;
      // Lua (edit.canConfigure) enforces it.
      $scope.sessionRunning = function () {
        return $scope.phase === 'grid' || $scope.phase === 'countdown'
            || $scope.phase === 'racing' || $scope.phase === 'qualifying';
      };
      // TWO GATES: canEdit is GEOMETRY (includes 'grid': nothing may move under a
      // parked car); canSetRules is the RULES, fine on a formed grid, as the
      // server's sessionUnderWay() has always agreed.
      $scope.canEdit = function () {
        return $scope.isAdmin && !$scope.sessionRunning();
      };
      $scope.canSetRules = function () {
        return $scope.isAdmin
          && $scope.phase !== 'countdown'
          && $scope.phase !== 'racing'
          && $scope.phase !== 'qualifying';
      };
      // Tell Lua whether an editor panel is on screen, so authoring furniture
      // stays in the editor. One per mode, never both.
      function pushEditorOpen() {
        // Only while its panel is open, and broadcast mode counts as closed (the
        // gates would stream over the race).
        var editing = $scope.isAdmin && !$scope.broadcastMode() && $scope.menu.open === 'tab';
        var race  = editing && $scope.adminTab === 'track';
        var derby = editing && $scope.adminTab === 'derby';
        bngApi.engineLua('raceManager.setEditorOpen(' + (!!race) + ')');
        bngApi.engineLua('raceManager.setDerbyEditorOpen(' + (!!derby) + ')');
      }
      // Panels that need a nudge as they re-enter the DOM: the track preview
      // canvas has to be drawn once it exists, and the derby module pulls its
      // state over its own channel.
      function afterTabChange() {
        pushEditorOpen();
        if ($scope.adminTab === 'track') { schedulePreview(); }
        if ($scope.mode === 'derby') {
          bngApi.engineLua('raceManager.derbyRequestState()');
        }
        // The ladder is pushed only when it changes, so a panel opened long
        // after the last pass would render an empty board until the next one.
        // Same pull, same reason as the derby's above.
        if ($scope.adminTab === 'drag') {
          bngApi.engineLua('raceManager.dragRequestState()');
        }
        // The cup is pushed on change only, so pull it on open. 'admin' too:
        // Display Names picks from the roster, which rides the cup broadcast.
        if ($scope.adminTab === 'cup' || $scope.adminTab === 'admin') {
          bngApi.engineLua('raceManager.cupRequestState()');
        }
        if ($scope.adminTab === 'admin') {
          bngApi.engineLua('raceManager.mapRequest()');
        }
      }
      // The one entry point. Kept named selectAdminTab because every caller in
      // the template already says that, and because what it selects IS the tab
      // -- the mode is a consequence.
      $scope.selectAdminTab = function (tab) {
        tab = tabOf(tab);
        if ($scope.adminTab === tab) { return; }
        $scope.adminTab = tab;
        $scope.mode = modeForTab(tab);
        savePref('adminTab', tab);
        afterTabChange();
      };
      // selectMode survives as a thin alias: a mode is now reached by opening
      // the tab that puts the panel in it. Kept rather than deleted because the
      // derby module and the console helpers both reach for it by name.
      $scope.selectMode = function (mode) {
        $scope.selectAdminTab(mode === 'derby' ? 'derby' : DEFAULT_TAB);
      };

      // Checkpoint editor state
      $scope.routeWaypoints = [];
      $scope.nextWp = 1;
      $scope.visualize = true;
      $scope.editorMsg = null;
      // Per-checkpoint override editor: which gate (1-based) is selected, plus
      // its edit fields. Blank fields mean "use the global default".
      $scope.selectedCp = null;
      $scope.cpEdit = { width: '', height: '', depth: '', length: '' };

      // Track layout state (server-side persistent layouts, current map only)
      $scope.layouts = [];              // [{ name, map, width, checkpoints }]
      $scope.layoutMap = '';            // map the server filtered the list by
      // Dot rule (ng-if child scope). `confirm` is the pending destructive action
      // { text, ok, action }, or null.
      $scope.layoutUi = { name: '', selected: '', confirm: null };
      // A DOM dropdown, not a <select>: in BeamNG's CEF a native popup is an OS
      // window that never renders over the game.
      $scope.layoutDropdownOpen = false;

      // ----------------------------------------------------------------
      // CUP / SERIES POINTS, mirrored from RM_CupUpdate. Read-only: the panel
      // renders the standings and sends edits; the server decides everything.
      // ----------------------------------------------------------------
      $scope.cup = {
        enabled: false,
        // A cup can EXIST while not scoring. Pausing clears `enabled` only, and
        // the panel used to be gated on that alone, which made a paused season
        // look exactly like no season at all.
        exists: false,
        name: '',
        round: 0,              // rounds scored so far; the next race is round + 1
        preset: '',            // key of the active preset, or 'custom'
        racePoints: [],        // position -> points; past the end scores nothing
        // Derbies score on a table of their own: a cup may be all races, all
        // derbies or a mixture, and lasting eight minutes in a banger is not
        // the same achievement as winning a ten-lap race.
        derbyPreset: '',
        derbyPoints: [],       // empty = derbies do not score
        // ...and drag gets a third. A ladder is a meeting rather than a race:
        // the winner made four passes and the driver knocked out first made
        // one, and what that is worth is a league's call.
        dragPreset: '',
        dragPoints: [],        // empty = drag racing does not score
        qualiPoints: [],       // empty = qualifying does not score
        // The preset and bonus lists come FROM the server rather than being
        // duplicated here, so adding a bonus or a preset later needs no change
        // in this file at all.
        presets: [],           // [{ key, label }]
        bonuses: [],           // [{ key, label, value }]
        fastestLapRequiresFinish: true,
        // What a DNF is worth: 'none' | 'classified' | 'held'.
        dnfScoring: 'none',
        pendingQuali: 0,       // drivers holding quali points for the next race
        // The saved drivers, and who is connected right now. The panel pairs
        // them up by hand because nothing else can: a guest name is reissued at
        // random on every join, so it identifies nobody.
        roster: [],            // [{ id, name, guest, provisional, boundPid }]
        connected: [],         // [{ pid, guest, alias, entryId }]
        standings: []          // [{ pos, name, rounds, racePts, ..., total }]
      };
      // Dot rule (ng-if). `points` and `quali` are edit buffers, re-seeded only
      // when not mid-edit (cupSeedEditors).
      $scope.cupUi = {
        name: '',
        // Name typed into "Save as". Initialized here so the object owns it
        // before any child scope can shadow it.
        saveName: '',
        preset: '',
        derbyPreset: '',
        dragPreset: '',
        points: [],
        derby: [],
        drag: [],
        quali: [],
        bonus: {},
        confirmReset: false,
        showScoring: false,
        showDrivers: false,
        // Which roster entry each connected driver is about to be assigned to,
        // keyed by pid. Bound through cupUi so the ng-if panel cannot shadow it.
        bindTo: {},
        // Which driver's adjustment panel is open, and what is being typed into
        // it. One at a time: an inline editor per standings row would put a
        // text box on every line of the table.
        adjustFor: null,       // entryId, or null
        adjustDelta: '',
        adjustReason: '',
        // Which standings table is on screen: three narrow ones fit a HUD.
        view: 'combined'       // combined | race | derby
      };
      // How many positions the editor offers. Long enough for any grid this mod
      // can hold and short enough to stay one screen; a position past the end of
      // the table scores nothing, which is what makes a shorter table legal.
      var CUP_EDIT_POSITIONS = 24;
      $scope.cupPositions = [];
      for (var cupPos = 1; cupPos <= CUP_EDIT_POSITIONS; cupPos++) {
        $scope.cupPositions.push(cupPos);
      }

      // True while a table the admin has typed differs from the server's, which
      // is what the Apply button keys off - and what stops a rebroadcast from
      // overwriting an edit in progress.
      function cupTableDiffers(buffer, authoritative) {
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) {
          var typed = Number(buffer[i] || 0);
          var live  = Number(authoritative[i] || 0);
          if (typed !== live) { return true; }
        }
        return false;
      }
      // "Differs from the server", for the Apply buttons; an unseeded buffer is
      // clean.
      $scope.cupPointsDirty = function () {
        return cupTableDiffers($scope.cupUi.points, $scope.cup.racePoints);
      };
      $scope.cupDerbyDirty = function () {
        return cupTableDiffers($scope.cupUi.derby, $scope.cup.derbyPoints);
      };
      $scope.cupDragDirty = function () {
        return cupTableDiffers($scope.cupUi.drag, $scope.cup.dragPoints);
      };
      $scope.cupQualiDirty = function () {
        return cupTableDiffers($scope.cupUi.quali, $scope.cup.qualiPoints);
      };

      // What the server last said for each table. A buffer differing from the
      // server is either typing (leave it) or a server change such as Load (the
      // boxes MUST follow); remembering the last value tells the two apart.
      var cupSeen = { race: null, derby: null, drag: null, quali: null,
                      bonus: null, preset: null, derbyPreset: null,
                      dragPreset: null };

      function cupSig(list) { return (list || []).join(','); }
      function cupBonusSig(list) {
        var parts = [];
        for (var i = 0; i < (list || []).length; i++) {
          parts.push(list[i].key + ':' + list[i].value);
        }
        return parts.join(',');
      }

      function cupFill(buffer, source) {
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) {
          buffer[i] = Number(source[i] || 0);
        }
      }

      // Called on every cup broadcast.
      function cupSeedEditors() {
        var sig;

        sig = cupSig($scope.cup.racePoints);
        if (cupSeen.race !== sig) {
          cupFill($scope.cupUi.points, $scope.cup.racePoints); cupSeen.race = sig;
          // The typed line follows the buffer whenever the SERVER reseeds it,
          // or a preset load would fill the boxes and leave the line showing
          // the table before it.
          $scope.cupSyncLine('race');
        }

        sig = cupSig($scope.cup.derbyPoints);
        if (cupSeen.derby !== sig) {
          cupFill($scope.cupUi.derby, $scope.cup.derbyPoints); cupSeen.derby = sig;
          $scope.cupSyncLine('derby');
        }

        sig = cupSig($scope.cup.dragPoints);
        if (cupSeen.drag !== sig) {
          cupFill($scope.cupUi.drag, $scope.cup.dragPoints); cupSeen.drag = sig;
          $scope.cupSyncLine('drag');
        }

        sig = cupSig($scope.cup.qualiPoints);
        if (cupSeen.quali !== sig) {
          cupFill($scope.cupUi.quali, $scope.cup.qualiPoints); cupSeen.quali = sig;
          $scope.cupSyncLine('quali');
        }

        sig = cupBonusSig($scope.cup.bonuses);
        if (cupSeen.bonus !== sig) {
          for (var i = 0; i < $scope.cup.bonuses.length; i++) {
            $scope.cupUi.bonus[$scope.cup.bonuses[i].key] =
              Number($scope.cup.bonuses[i].value || 0);
          }
          cupSeen.bonus = sig;
        }

        // The pending dropdown pick follows the same rule: a race being scored
        // must not throw away a preset somebody has chosen but not loaded yet.
        if (cupSeen.preset !== $scope.cup.preset) {
          $scope.cupUi.preset = $scope.cup.preset;
          cupSeen.preset = $scope.cup.preset;
        }
        if (cupSeen.derbyPreset !== $scope.cup.derbyPreset) {
          $scope.cupUi.derbyPreset = $scope.cup.derbyPreset;
          cupSeen.derbyPreset = $scope.cup.derbyPreset;
        }
        if (cupSeen.dragPreset !== $scope.cup.dragPreset) {
          $scope.cupUi.dragPreset = $scope.cup.dragPreset;
          cupSeen.dragPreset = $scope.cup.dragPreset;
        }
      }

      // Take the server's next answer for one table, discarding the box: loading
      // an already-active preset leaves the server value unchanged.
      function cupExpectReseed(which) { cupSeen[which] = null; }

      // Cup dropdowns: DOM menus, not <select> (see the layout picker). One flag
      // keyed by name, so one menu is open: 'race', 'derby' or 'bind:<pid>'.
      $scope.cupOpenMenu = null;
      $scope.cupMenuOpen = function (key) { return $scope.cupOpenMenu === key; };
      $scope.cupToggleMenu = function (key) {
        $scope.cupOpenMenu = ($scope.cupOpenMenu === key) ? null : key;
        if ($scope.cupOpenMenu) { revealDropdown('.rm-cup .rm-layout-menu'); }
      };
      $scope.cupPickPreset = function (which, preset) {
        if (which === 'derby')     { $scope.cupUi.derbyPreset = preset.key; }
        else if (which === 'drag') { $scope.cupUi.dragPreset = preset.key; }
        else { $scope.cupUi.preset = preset.key; }
        $scope.cupOpenMenu = null;
      };
      // Picking a driver only fills the box; Assign commits it. Assigning
      // merges a placeholder's points into the driver and retires it, which is
      // not something a stray click should be able to do.
      $scope.cupPickEntry = function (conn, entry) {
        $scope.cupUi.bindTo[conn.pid] = entry.id;
        $scope.cupOpenMenu = null;
      };
      $scope.cupBindLabel = function (conn) {
        var id = $scope.cupUi.bindTo[conn.pid];
        if (!id) { return 'pick a driver…'; }
        for (var i = 0; i < $scope.cup.roster.length; i++) {
          if ($scope.cup.roster[i].id === id) {
            var e = $scope.cup.roster[i];
            return e.provisional ? (e.name + ' (placeholder)') : e.name;
          }
        }
        return 'pick a driver…';
      };

      function cupLabelFor(key) {
        for (var i = 0; i < $scope.cup.presets.length; i++) {
          if ($scope.cup.presets[i].key === key) { return $scope.cup.presets[i].label; }
        }
        return 'Custom';
      }
      // *Label(): what the server scores with (the summary line).
      // *Pick():  what the dropdown has chosen (its closed box).
      $scope.cupPresetLabel = function () { return cupLabelFor($scope.cup.preset); };
      $scope.cupDerbyPresetLabel = function () { return cupLabelFor($scope.cup.derbyPreset); };
      $scope.cupPresetPick = function () {
        return cupLabelFor($scope.cupUi.preset || $scope.cup.preset);
      };
      $scope.cupDerbyPresetPick = function () {
        return cupLabelFor($scope.cupUi.derbyPreset || $scope.cup.derbyPreset);
      };
      $scope.cupDragPresetPick = function () {
        return cupLabelFor($scope.cupUi.dragPreset || $scope.cup.dragPreset);
      };
      // How deep each table actually pays, which is the one number an admin
      // needs to sanity-check a preset against their field size.
      $scope.cupScoringDepth = function () { return $scope.cup.racePoints.length; };
      $scope.cupDerbyDepth = function () { return $scope.cup.derbyPoints.length; };
      $scope.cupQualiEnabled = function () { return $scope.cup.qualiPoints.length > 0; };
      $scope.cupDerbyEnabled = function () { return $scope.cup.derbyPoints.length > 0; };
      $scope.cupDragEnabled = function () { return $scope.cup.dragPoints.length > 0; };
      $scope.cupNextRound = function () { return ($scope.cup.round || 0) + 1; };

      // Bonus rows for one discipline, so the panel can file them under the
      // table they belong to. The server says which is which; nothing here
      // knows what an individual bonus means.
      $scope.cupBonusesFor = function (kind) {
        var out = [];
        for (var i = 0; i < $scope.cup.bonuses.length; i++) {
          if ($scope.cup.bonuses[i].kind === kind) { out.push($scope.cup.bonuses[i]); }
        }
        return out;
      };

      // Which standings table, and its sort: the numbers and positions are the
      // server's.
      $scope.cupSetView = function (v) { $scope.cupUi.view = v; };
      $scope.cupIsView = function (v) { return $scope.cupUi.view === v; };
      // Has this cup actually seen this kind of event? A cup of nothing but
      // races has no reason to offer a derby table, and vice versa -- and a
      // discipline that has never run gets no column and no tab.
      $scope.cupHasRaces = function () {
        for (var i = 0; i < $scope.cup.standings.length; i++) {
          if ($scope.cup.standings[i].raceRounds > 0) { return true; }
        }
        return false;
      };
      $scope.cupHasDerbies = function () {
        for (var i = 0; i < $scope.cup.standings.length; i++) {
          if ($scope.cup.standings[i].derbyRounds > 0) { return true; }
        }
        return false;
      };
      $scope.cupHasDrags = function () {
        for (var i = 0; i < $scope.cup.standings.length; i++) {
          if ($scope.cup.standings[i].dragRounds > 0) { return true; }
        }
        return false;
      };
      // More than one discipline has run (any two of the three), so the standings
      // need per-discipline columns.
      $scope.cupIsMixed = function () {
        var kinds = 0;
        if ($scope.cupHasRaces()) { kinds++; }
        if ($scope.cupHasDerbies()) { kinds++; }
        if ($scope.cupHasDrags()) { kinds++; }
        return kinds > 1;
      };

      $scope.cupStart = function () {
        bngApi.engineLua('raceManager.cupStart("'
          + String($scope.cupUi.name || '').replace(/"/g, '') + '")');
        $scope.cupUi.confirmReset = false;
        $scope.cupUi.confirmReplace = false;
      };
      $scope.cupSetEnabled = function (on) {
        bngApi.engineLua('raceManager.cupSetEnabled(' + (!!on) + ')');
      };
      $scope.cupToggleEnabled = function () { $scope.cupSetEnabled(!$scope.cup.enabled); };
      // Two presses: one would destroy a season (starting over a paused cup is a
      // delete too). Behind a dot for the ng-if child scope.
      $scope.cupAskReplace = function () { $scope.cupUi.confirmReplace = true; };
      $scope.cupCancelReplace = function () { $scope.cupUi.confirmReplace = false; };
      $scope.cupAskReset = function () { $scope.cupUi.confirmReset = true; };
      $scope.cupCancelReset = function () { $scope.cupUi.confirmReset = false; };
      $scope.cupReset = function () {
        bngApi.engineLua('raceManager.cupReset()');
        $scope.cupUi.confirmReset = false;
      };
      $scope.cupApplyPreset = function () {
        if (!$scope.cupUi.preset) { return; }
        cupExpectReseed('race');
        bngApi.engineLua('raceManager.cupSetPreset("' + $scope.cupUi.preset + '", "race")');
      };
      $scope.cupApplyDerbyPreset = function () {
        if (!$scope.cupUi.derbyPreset) { return; }
        cupExpectReseed('derby');
        bngApi.engineLua('raceManager.cupSetPreset("' + $scope.cupUi.derbyPreset + '", "derby")');
      };
      $scope.cupApplyDragPreset = function () {
        if (!$scope.cupUi.dragPreset) { return; }
        cupExpectReseed('drag');
        bngApi.engineLua('raceManager.cupSetPreset("' + $scope.cupUi.dragPreset + '", "drag")');
      };
      // Save the race table as a named system, in the SAME picker as the built-ins
      // (the server flags its own for Delete). The name is on cupUi: a bare
      // ng-model in the ng-if child scope would leave Save sending nothing.
      $scope.cupSavePreset = function () {
        var name = ($scope.cupUi.saveName || '').trim();
        if (!name) { return; }
        cupExpectReseed('race');
        bngApi.engineLua('raceManager.cupSavePreset(' + luaStr(name) + ')');
        $scope.cupUi.saveName = '';
      };
      // Only the saved ones can go. The picker carries the flag from the server
      // so the button is absent on a built-in rather than refused after a click.
      $scope.cupSelectedIsSaved = function () {
        var list = $scope.cup.presets || [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].key === $scope.cupUi.preset) { return list[i].saved === true; }
        }
        return false;
      };
      $scope.cupDeletePreset = function () {
        if (!$scope.cupSelectedIsSaved()) { return; }
        bngApi.engineLua('raceManager.cupDeletePreset(' + luaStr($scope.cupUi.preset) + ')');
      };

      $scope.cupToggleScoring = function () {
        $scope.cupUi.showScoring = !$scope.cupUi.showScoring;
      };

      // A points table crosses to Lua as a comma-separated string (the bridge
      // parses it). Trailing zeroes are dropped: past the end scores nothing.
      function cupCsv(buffer) {
        var out = [];
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) {
          out.push(Math.max(0, Math.floor(Number(buffer[i]) || 0)));
        }
        while (out.length > 0 && out[out.length - 1] === 0) { out.pop(); }
        return out.join(',');
      }
      // ------------------------------------------------------------------
      // Typing a table instead of nudging twenty-four spinners
      // ------------------------------------------------------------------
      // Type a table as one line instead of twenty-four spinners. The line and
      // the boxes are the SAME buffer both ways; it is cupCsv's format, shown.
      function cupParseCsv(text, buffer) {
        var parts = String(text || '').split(/[^0-9]+/);
        var n = 0;
        for (var i = 0; i < parts.length && n < CUP_EDIT_POSITIONS; i++) {
          if (parts[i] !== '') { buffer[n++] = Math.min(9999, Math.floor(Number(parts[i]))); }
        }
        // Past the typed line scores nothing, or a longer old tail would pay
        // points nobody entered.
        while (n < CUP_EDIT_POSITIONS) { buffer[n++] = 0; }
      }

      // Split out so the three tables share one implementation rather than
      // three that drift. `which` names the buffer and the label only.
      var CUP_TABLES = { race: 'points', derby: 'derby', drag: 'drag',
                         quali: 'quali' };
      $scope.cupLine = { race: '', derby: '', drag: '', quali: '' };

      // Rebuild the visible line from the buffer. Called whenever a spinner
      // moves and whenever the server reseeds a table.
      $scope.cupSyncLine = function (which) {
        var buf = $scope.cupUi[CUP_TABLES[which]];
        $scope.cupLine[which] = cupCsv(buf);
      };
      $scope.cupLineChanged = function (which) {
        cupParseCsv($scope.cupLine[which], $scope.cupUi[CUP_TABLES[which]]);
      };
      // Every position to zero, in one press. The Apply button next to it is
      // what commits it, so a mis-click costs nothing until it is confirmed.
      $scope.cupClearTable = function (which) {
        var buf = $scope.cupUi[CUP_TABLES[which]];
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) { buf[i] = 0; }
        $scope.cupSyncLine(which);
      };
      // Qualifying and the derby, filled from the race table. A cup that pays
      // the same for a derby as for a race is a normal thing to want and was
      // twenty-four boxes of retyping.
      $scope.cupCopyFromRace = function (which) {
        if (which === 'race') { return; }
        var src = $scope.cupUi.points, dst = $scope.cupUi[CUP_TABLES[which]];
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) { dst[i] = Math.floor(Number(src[i]) || 0); }
        $scope.cupSyncLine(which);
      };
      $scope.cupTableEmpty = function (which) {
        var buf = $scope.cupUi[CUP_TABLES[which]];
        for (var i = 0; i < CUP_EDIT_POSITIONS; i++) {
          if (Math.floor(Number(buf[i]) || 0) > 0) { return false; }
        }
        return true;
      };

      $scope.cupApplyPoints = function () {
        bngApi.engineLua('raceManager.cupSetRacePoints("' + cupCsv($scope.cupUi.points) + '")');
      };
      $scope.cupApplyDerby = function () {
        bngApi.engineLua('raceManager.cupSetDerbyPoints("' + cupCsv($scope.cupUi.derby) + '")');
      };
      $scope.cupDisableDerby = function () {
        cupExpectReseed('derby');
        bngApi.engineLua('raceManager.cupSetDerbyPoints("")');
      };
      $scope.cupApplyDrag = function () {
        bngApi.engineLua('raceManager.cupSetDragPoints("' + cupCsv($scope.cupUi.drag) + '")');
      };
      $scope.cupDisableDrag = function () {
        cupExpectReseed('drag');
        bngApi.engineLua('raceManager.cupSetDragPoints("")');
      };
      $scope.cupApplyQuali = function () {
        bngApi.engineLua('raceManager.cupSetQualiPoints("' + cupCsv($scope.cupUi.quali) + '")');
      };
      // One Apply per bonus row; the rows come from the server's registry.
      $scope.cupApplyBonus = function (row) {
        if (!row) { return; }
        var value = Math.max(0, Math.floor(Number($scope.cupUi.bonus[row.key]) || 0));
        bngApi.engineLua('raceManager.cupSetBonus("' + row.key + '", ' + value + ')');
      };
      $scope.cupBonusRowDirty = function (row) {
        if (!row) { return false; }
        return Number($scope.cupUi.bonus[row.key] || 0) !== Number(row.value || 0);
      };
      // --- Driver identity -------------------------------------------------
      // Assigning a connection to a saved driver: an admin decision, since guest
      // names are random per join.
      $scope.cupToggleDrivers = function () {
        $scope.cupUi.showDrivers = !$scope.cupUi.showDrivers;
      };
      // The saved driver a connection is currently racing as, or null.
      $scope.cupEntryOf = function (conn) {
        for (var i = 0; i < $scope.cup.roster.length; i++) {
          if ($scope.cup.roster[i].id === conn.entryId) { return $scope.cup.roster[i]; }
        }
        return null;
      };
      // Entries free to assign (plus the driver's own, for the dropdown).
      // `boundPid == null`, NOT `!boundPid`: BeamMP ids start at 0.
      $scope.cupFreeEntries = function (conn) {
        var out = [];
        for (var i = 0; i < $scope.cup.roster.length; i++) {
          var e = $scope.cup.roster[i];
          if (e.boundPid == null || e.boundPid === conn.pid) { out.push(e); }
        }
        return out;
      };
      // What to show beside a connection: the driver they are assigned to. A
      // placeholder has no display name of its own, so the entry name is the
      // only honest thing to show.
      $scope.cupConnLabel = function (conn) {
        var e = $scope.cupEntryOf(conn);
        if (!e) { return null; }
        return e.provisional ? (e.name + ' (placeholder)') : e.name;
      };
      $scope.cupApplyBind = function (conn) {
        var id = Number($scope.cupUi.bindTo[conn.pid] || 0);
        bngApi.engineLua('raceManager.cupBindDriver(' + conn.pid + ', ' + id + ')');
      };
      $scope.cupUnbind = function (conn) {
        bngApi.engineLua('raceManager.cupBindDriver(' + conn.pid + ', 0)');
      };
      // --- Display Names: bind to a saved driver -------------------------
      // Offers the roster directly instead of retyping a name exactly. The race
      // rows carry no binding, so the cup broadcast's view of the connection is
      // used.
      function aliasConn(row) {
        if (!row) { return null; }
        for (var i = 0; i < $scope.cup.connected.length; i++) {
          if ($scope.cup.connected[i].pid === row.id) { return $scope.cup.connected[i]; }
        }
        return null;
      }
      $scope.aliasMenuOpen = function (row) {
        return $scope.cupOpenMenu === ('alias:' + (row && row.id));
      };
      $scope.aliasToggleMenu = function (row) {
        var key = 'alias:' + row.id;
        $scope.cupOpenMenu = ($scope.cupOpenMenu === key) ? null : key;
        // Its own selector: cupToggleMenu reveals inside .rm-cup, which never
        // matches this panel.
        if ($scope.cupOpenMenu) { revealDropdown('.rm-alias .rm-layout-menu'); }
      };
      // Saved drivers this connection may be given: free, or already theirs.
      // Evaluated only while the menu is open, which is what keeps it off the
      // digest for every row on the server.
      $scope.aliasRosterFree = function (row) {
        var conn = aliasConn(row);
        return conn ? $scope.cupFreeEntries(conn) : [];
      };
      // The saved driver they are currently racing as, or null.
      $scope.aliasBoundName = function (row) {
        var conn = aliasConn(row);
        return conn ? $scope.cupConnLabel(conn) : null;
      };
      $scope.aliasBindTo = function (row, e) {
        $scope.cupOpenMenu = null;
        if (!row || !e) { return; }
        bngApi.engineLua('raceManager.cupBindDriver(' + row.id + ', ' + e.id + ')');
      };
      $scope.aliasUnbind = function (row) {
        $scope.cupOpenMenu = null;
        if (!row) { return; }
        bngApi.engineLua('raceManager.cupBindDriver(' + row.id + ', 0)');
      };
      // Add a driver who is not here. The server owns the naming rules and
      // answers on RM_AliasResult, so this sends and lets the reply speak.
      $scope.rosterAdd = function () {
        var name = ($scope.aliasUi.newName || '').trim();
        if (!name) { return; }
        bngApi.engineLua('raceManager.rosterAdd(' + luaStr(name) + ')');
        $scope.aliasUi.newName = '';
      };
      // Roster entries nobody on the server is currently assigned to. Shown so
      // an admin can see the list they typed in and prune it, and so a name
      // that is already taken does not look missing.
      $scope.rosterUnclaimed = function () {
        var out = [];
        for (var i = 0; i < $scope.cup.roster.length; i++) {
          if ($scope.cup.roster[i].boundPid == null) { out.push($scope.cup.roster[i]); }
        }
        return out;
      };
      $scope.rosterForget = function (entry) {
        bngApi.engineLua('raceManager.cupForgetDriver(' + entry.id + ')');
      };

      $scope.cupForgetDriver = function (entry) {
        bngApi.engineLua('raceManager.cupForgetDriver(' + entry.id + ')');
      };
      // Connections nobody has identified yet -- unassigned, or parked on a
      // placeholder. Both mean the same thing to an admin: their points are
      // being kept somewhere that is not a real driver.
      $scope.cupUnclaimed = function () {
        var n = 0;
        for (var i = 0; i < $scope.cup.connected.length; i++) {
          var e = $scope.cupEntryOf($scope.cup.connected[i]);
          if (!e || e.provisional) { n++; }
        }
        return n;
      };

      // --- Manual adjustments ---------------------------------------------
      // Correcting a cup by hand. The ledger lives on the server; this only
      // opens an editor for one driver at a time and posts what was typed.
      $scope.cupOpenAdjust = function (row) {
        $scope.cupUi.adjustFor = ($scope.cupUi.adjustFor === row.entryId) ? null : row.entryId;
        $scope.cupUi.adjustDelta = '';
        $scope.cupUi.adjustReason = '';
      };
      $scope.cupAdjustOpen = function (row) {
        return $scope.cupUi.adjustFor === row.entryId;
      };
      $scope.cupAdjustValid = function () {
        var d = Number($scope.cupUi.adjustDelta);
        return !!d && isFinite(d);
      };
      $scope.cupApplyAdjust = function (row) {
        if (!$scope.cupAdjustValid()) { return; }
        var delta = Math.round(Number($scope.cupUi.adjustDelta));
        var reason = String($scope.cupUi.adjustReason || '').replace(/["\\]/g, '');
        bngApi.engineLua('raceManager.cupAdjust(' + row.entryId + ', ' + delta
          + ', "' + reason + '")');
        $scope.cupUi.adjustDelta = '';
        $scope.cupUi.adjustReason = '';
      };
      // Convenience for the common case: a flat penalty or credit with the
      // reason still typed in the box.
      $scope.cupQuickAdjust = function (row, delta) {
        var reason = String($scope.cupUi.adjustReason || '').replace(/["\\]/g, '');
        bngApi.engineLua('raceManager.cupAdjust(' + row.entryId + ', ' + delta
          + ', "' + reason + '")');
      };
      $scope.cupRemoveAdjust = function (row, index) {
        // The ledger is 1-based on the server (a Lua array); ng-repeat is 0-based.
        bngApi.engineLua('raceManager.cupRemoveAdjust(' + row.entryId + ', ' + (index + 1) + ')');
      };

      $scope.cupToggleFlRule = function () {
        bngApi.engineLua('raceManager.cupSetFastestLapRule('
          + (!$scope.cup.fastestLapRequiresFinish) + ')');
      };
      $scope.cupSetDnfScoring = function (mode) {
        bngApi.engineLua('raceManager.cupSetDnfScoring("' + mode + '")');
      };
      $scope.cupDnfIs = function (mode) { return $scope.cup.dnfScoring === mode; };
      // Turning qualifying points off is sending an EMPTY table, not a separate
      // flag: on the server the presence of a table is the switch, so there is
      // only one thing that can be true and nothing to keep in step.
      $scope.cupDisableQuali = function () {
        cupExpectReseed('quali');
        bngApi.engineLua('raceManager.cupSetQualiPoints("")');
      };

      // ----------------------------------------------------------------
      // DEMO DERBY (isolated module) - separate state, events and commands;
      // nothing here touches the circuit racing scope above.
      // ----------------------------------------------------------------
      $scope.derby = {
        phase: 'idle',        // idle | running | finished (server authoritative)
        time: 0,
        // The lives RULE in force this derby, mirrored from the server. 1 is the
        // behavior that has always existed: counted out once and you are out.
        lives: 1,
        // The arena itself, mirrored from the server so the setup panel can
        // list and edit it entry by entry. The counts are kept alongside
        // because the header and the disabled rules read them everywhere.
        boundary: [],         // [{ x, y, z }] in perimeter order
        startPositions: [],   // [{ x, y, z, hx, hy }], slot 1 first
        boundaryCount: 0,
        startCount: 0,        // derby starting grid slots placed
        // Which editor authored the polygon ('polygon' drive-and-place, 'rect'
        // from a center); gameplay reads `boundary` either way.
        boundaryMode: 'polygon',
        shape: null,          // { cx, cy, cz, halfW, halfL, rot } while 'rect'
        wallHeight: 6,        // how tall the arena walls are drawn (visual only)
        wallDepth: 1.5,       // how far they drop below the boundary (visual only)
        // Who takes part: 'all' (every connected player, the historical
        // behavior) or 'join' (only drivers who pressed Join Race).
        entrants: 0,          // how many would be in a derby started right now
        maxResets: -1,        // resets per driver per derby (-1 = unlimited)
        visualize: true,      // boundary/grid visuals shown (client-local)
        winner: null,
        players: []           // { id, name, status, reason, elimTime, resets }
      };
      // Dot rule again: these inputs live inside the ng-if derby panel.
      // `confirm` is the pending Replace / Overwrite / Delete question, the same
      // shape the track layouts use: null when nothing is being asked.
      $scope.derbyUi = { oob: 5, demo: 10, lives: 1, resets: -1, mode: 'lms',
                         name: '', selected: '', confirm: null };

      // ----------------------------------------------------------------
      // DRAG RACING (isolated module): the ladder, the strip and the tree.
      $scope.drag = {
        // idle | ready | staging | tree | running | result | complete
        phase: 'idle',
        format: 'single', lanes: 2, advance: 1, cut: 0, roundLimit: 3,
        tree: 'sportsman', seed: 'random',
        dialIn: false, breakout: true, timeout: 60,
        // How a car gets onto the line, and who drops the tree once it is
        // there. 'rollup' is the strip's own answer to both.
        stageMode: 'rollup', autoStart: true, stageWait: 45,
        // What the LOADED TRACK offers (lanes are its start positions, the
        // finish its last gate), so the panel can say why a build is refused.
        stripLanes: 0, stripGates: 0,
        round: 0, roundLabel: '', roundSide: 'w', roundCount: 0,
        passIndex: 0, passCount: 0,
        champion: null,
        // What is on the strip right now is a warm-up rather than a round of
        // the tournament. The controls look identical, so the panel says which.
        practice: false,
        finishOrder: [],
        entrants: [],     // the whole field, in seed order, with its records
        board: [],        // the ladder: rounds, each with its passes
        current: null     // the pass in front of you, lane by lane
      };
      // Dot rule: these inputs live inside the ng-if drag panel, so a bare
      // scalar would be shadowed on the child scope and the Apply button would
      // post the default. See the header of tests/ui_bindings_test.lua.
      $scope.dragUi = { format: 'single', lanes: 2, advance: 1, cut: 0,
                        rounds: 3, tree: 'sportsman', seed: 'random',
                        dialIn: false, breakout: true, timeout: 60, dial: '',
                        dialSeed: '', dialFor: '',
                        stageMode: 'rollup', autoStart: true, stageWait: 45 };
      // The tree, as this client's own lights, pushed by the Lua module (see
      // drag.lua). The stage bulbs are where the car stands, apart from the
      // ambers; under 'hold' both are lit on placement.
      $scope.dragLight = { stage: 'off', lane: null, delay: 0, dial: null,
                           prestaged: false, staged: false, rollup: false };
      // ...and this driver's own last pass, held on screen after the lights
      // have gone out. The board agrees a beat later; this is the number that
      // is already there when they look up.
      $scope.dragLast = { rt: null, et: null, speed: null, foul: false };
      // Last server config values: a broadcast overwrites an input only while it
      // still shows the previous one, so an edit in progress survives.
      var dragCfgSeen = { format: null, lanes: null, advance: null, cut: null,
                          rounds: null, tree: null, seed: null, timeout: null,
                          stageWait: null };

      // The rectangle sliders, as FULL spans in meters (Lua halves them).
      // `square` links width and length.
      $scope.rectUi = { width: 120, length: 120, rot: 0, wall: 6, wallDepth: 1.5, square: false };
      // Saved arenas for the hosted map (same workflow as track layouts).
      $scope.derbyLayouts = [];
      $scope.derbyLayoutMap = '';
      $scope.derbyDropdownOpen = false;
      // Last config values mirrored from the server. Broadcasts only overwrite
      // an input while it still shows the previous server value; an edit in
      // progress (field differs) survives marker drops and other rebroadcasts.
      var derbyCfgSeen = { oob: null, demo: null, lives: null, resets: null };
      // The same rule for the sliders, declared up here for the broadcast
      // handler. Every key syncRectField uses MUST be seeded null: undefined
      // matches neither branch, and the slider never follows again.
var rectSeen = { width: null, length: null, rot: null, wall: null, wallDepth: null };
      function syncRectField(key, value) {
        if (typeof value !== 'number') { return; }
        var rounded = Math.round(value * 10) / 10;
        if (rectSeen[key] === null || Number($scope.rectUi[key]) === rectSeen[key]) {
          $scope.rectUi[key] = rounded;
        }
        rectSeen[key] = rounded;
      }
      // Pull the sliders into line with the arena the server sent, except a value
      // mid-drag.
      function syncRectUi() {
        if ($scope.derby.wallHeight != null) {
          syncRectField('wall', $scope.derby.wallHeight);
        }
        if ($scope.derby.wallDepth != null) {
          syncRectField('wallDepth', $scope.derby.wallDepth);
        }
        var s = $scope.derby.shape;
        if (!s) { return; }
        syncRectField('width', s.halfW * 2);
        syncRectField('length', s.halfL * 2);
        syncRectField('rot', s.rot * 180 / Math.PI);
      }
      $scope.derbyWarning = null;  // { type: 'oob'|'stopped', remaining } or null
      // The open entry, 1-based, or null: one per list, since both show at once.
      // Only controller functions write them, so no child scope shadows one.
      $scope.derbySelMarker = null;
      $scope.derbySelStart = null;

      var PHASE_LABELS = {
        waiting:    'Waiting',
        qualifying: 'Qualifying',
        grid:       'Grid Locked',
        countdown:  'Countdown',
        racing:     'Racing',
        finished:   'Race Over'
      };
      // Grid and countdown are shared, so a qualifying one says so.
      var QUALI_PHASE_LABELS = {
        grid:      'Quali Grid',
        countdown: 'Quali Countdown'
      };
      var STATUS_LABELS = {
        waiting:    'Waiting',
        qualifying: 'On Track',
        gridded:    'On Grid',
        called:     'Not Ready',
        racing:     'Racing',
        finished:   'Finished',
        dsq:        'Disqualified',
        dnf:        'DNF'
      };

      // ------------------------------------------------------------------
      // Display aliases (presentation only)
      // ------------------------------------------------------------------
      // The single name resolution point; `row.id` stays the key everywhere, and
      // a missing alias falls back to the guest name.
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
      $scope.aliasUi = { input: {}, newName: '' };

      // ------------------------------------------------------------------
      // Build stamps
      // ------------------------------------------------------------------
      // Three separately deployed pieces, and BeamNG caches UI files: a stale
      // app.js just ignores a call, silently. Bump with main.lua, raceManager.lua
      // and app.json's "version" (wiring_test).
      var APP_BUILD = '0.18.5';
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

      // The lap a driver is on, not their crossings: an owed out lap read "3/2"
      // on the last lap. While it is owed, the cell says so.
      $scope.lapLabel = function (row) {
        if (!row || !row.currentLap) { return '-'; }
        // QUALIFYING gives its out lap away -- it is not one of the laps you were
        // promised, so it is not counted here either. A RACE's first lap counts
        // like any other; it simply sets no time.
        if ($scope.sessionKind === 'quali') {
          if (row.outLap) { return 'OUT'; }
          var q = row.currentLap - ($scope.qualiOutLap ? 1 : 0);
          if (q < 1) { q = 1; }
          return q + '/' + $scope.totalLaps;
        }
        // A FORMATION LAP IS NOT LAP 1, and it is the same give-away qualifying's
        // out lap is: it is driven, it is not scored, and it is not one of the
        // laps the race promised. While it is being run the cell says so.
        if ($scope.pacedRace() && row.outLap) { return 'PACE'; }
        // No target, no denominator (a timed race); once the leader is past, the
        // final lap number is the target.
        var target = $scope.raceLapTarget();
        var n = $scope.raceLapNumber(row);
        return target ? (n + '/' + target) : String(n);
      };

      // Progress through a point-to-point stage. Without the route yet, the count
      // alone (no invented total).
      $scope.stageProgress = function (row) {
        if (!row) { return '-'; }
        if (row.status === 'finished') { return 'done'; }
        var done = row.cpCleared || 0;
        // The loaded route's own length, which this panel already has: it is
        // what the Track tab counts. Read from here rather than asking the
        // server for slotCount, which is the same number twice on the wire.
        var total = ($scope.routeWaypoints || []).length;
        return total > 0 ? (done + '/' + total) : String(done);
      };

      // Run behind the pace car? The RULE, stable for the session (the server's
      // paceLapArmed).
      $scope.pacedRace = function () {
        return !!$scope.paceLap && $scope.sessionKind !== 'quali'
          && !$scope.pointToPoint;
      };

      // The racing lap, not crossings: behind the pace car the first crossing is
      // the formation lap ("6/5" at the flag).
      $scope.raceLapNumber = function (row) {
        var n = (row && row.currentLap) || 0;
        if ($scope.pacedRace()) {
          n = n - 1;
          if (n < 1) { n = 1; }
        }
        return n;
      };

      // The lap target, or null: the same rule as effectiveLapTarget and
      // sessionLapTarget. In racing laps (the pace lap comes out of lastLapNum),
      // and a heat's own distance.
      $scope.raceLapTarget = function () {
        var paced = $scope.pacedRace() ? 1 : 0;
        if ($scope.lastLapNum) {
          return Math.max(1, $scope.lastLapNum - paced);
        }
        if ($scope.raceMode === 'timed') { return null; }
        var laps = $scope.sessionRaceLaps();
        return laps > 0 ? laps : null;
      };

      // The distance the session on track is being run to. The server's
      // raceDistance, said here: a heat runs heatLaps when that is set, and
      // everything else runs the race's lap count.
      $scope.sessionRaceLaps = function () {
        if ($scope.heatCount > 0 && $scope.heatCurrent > 0 && $scope.heatLaps > 0) {
          return $scope.heatLaps;
        }
        return $scope.totalLaps;
      };

      $scope.phaseLabel = function () {
        if ($scope.sessionKind === 'quali' && QUALI_PHASE_LABELS[$scope.phase]) {
          return QUALI_PHASE_LABELS[$scope.phase];
        }
        return PHASE_LABELS[$scope.phase] || $scope.phase;
      };
      $scope.statusLabel = function (s) {
        // While a grid is being called, on the slot means Ready.
        if (s === 'gridded' && $scope.readyCheck && $scope.phase === 'grid') { return 'Ready'; }
        return STATUS_LABELS[s] || s;
      };

      // OUT LAP in the time cell only for a driver still in the session: the flag
      // stays set on a DNF.
      $scope.showOutLap = function (row) {
        if (!row || !row.outLap) { return false; }
        // QUALIFYING ONLY. A race gridded away from the line owes an out lap
        // too, so this put "OUT LAP" in the Best Lap column of every row on a
        // race grid, for a lap that a race scores like any other.
        if ($scope.sessionKind !== 'quali') { return false; }
        return row.status === 'qualifying' || row.status === 'gridded';
      };

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
      // Rendered in the order sent: the server stamps `position` while walking the
      // sorted array (stress_test pins it), so no re-sort per digest. `track by
      // row.id` moves the rows instead of rebuilding them.

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
        if (row.status === 'dnf' || row.status === 'dsq') { return '-'; }
        return row.position ? ('P' + row.position) : '-';
      };

      // Meters to this client's next checkpoint, for the header readout.
      $scope.formatDistance = function (d) {
        if (d === null || d === undefined) { return ''; }
        return (d >= 1000) ? ((d / 1000).toFixed(2) + ' km') : (Math.round(d) + ' m');
      };

      // Joker cell for the race table.
      $scope.jokerLabel = function (row) {
        if (!$scope.jokerEnabled) { return '-'; }
        if (!row.jokerTaken) { return '-'; }
        if (row.jokerTaken > 1) { return '×' + row.jokerTaken + '!'; }
        return 'L' + (row.jokerLap || '?');
      };

      // Reset cell: used/allowed, or a dash when resets are unlimited.
      // (These helpers also keep raw comparison operators out of the template.)
      $scope.resetsLimited = function () { return $scope.maxResets >= 0; };
      // "2/3" - clamped so the counter can never exceed the limit or grow a
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
      // A session the driver takes part in; a derby counts from FORM-UP.
      $scope.sessionLive = function () {
        return $scope.phase === 'qualifying' || $scope.phase === 'countdown'
          || $scope.phase === 'racing' || $scope.derbyActive();
      };
      // A session whose rules are locked: the field is standing on the grid or
      // running. Start Quali and Generate Grid are refused by the server from
      // here on, so the buttons say so rather than looking broken.
      $scope.sessionUnderWay = function () {
        return $scope.phase === 'countdown' || $scope.phase === 'racing'
          || $scope.phase === 'qualifying';
      };
      // Generate Grid is NOT gated on that: it supersedes qualifying (the
      // disabled button made it look like Start Quali). A live RACE is still
      // refused.
      $scope.raceUnderWay = function () {
        return $scope.phase === 'countdown' || $scope.phase === 'racing';
      };
      // Minimal mode: no admin and a live session; only the leaderboard is left.
      $scope.minimalMode = function () {
        return !$scope.isAdmin && $scope.sessionLive();
      };
      // Which board fills the leaderboard area: a DRIVER's follows the session (a
      // formed derby), an ADMIN's the mode they are in. `drivers` still holds the
      // last race during a derby.
      $scope.derbyBoardOnly = function () {
        return $scope.isAdmin ? $scope.isMode('derby') : $scope.derbyActive();
      };

      // Qualifying view for the whole quali session, and in waiting while its
      // provisional times exist.
      $scope.isQualiView = function () {
        if ($scope.phase === 'waiting' || $scope.phase === 'finished') {
          return $scope.drivers.some(function (d) { return d.qualiBest != null; })
            && $scope.phase === 'waiting';
        }
        return $scope.sessionKind === 'quali';
      };

      // ------------------------------------------------------------------
      // Module 5: the broadcast board
      // ------------------------------------------------------------------
      // A board for somebody WATCHING: the whole field, who is out and why, and a
      // camera. For anyone not in the field: pressed Spectate OR car taken (two
      // variables, deliberately).
      $scope.spectatorView = function () {
        return $scope.spectating === true || $scope.carTaken === true;
      };
      // Dot rule: the board's controls live inside its own ng-if, whose child
      // scope would shadow a bare primitive.
      $scope.broadcast = {
        on: loadPref('broadcast', false) === true,
        // race | points. Separate from the cup panel's own `view`, which is an
        // admin editing standings; this one is a stream graphic.
        view: loadPref('broadcastView', 'race') === 'points' ? 'points' : 'race',
        // Whose car the camera is actually on, reported back by the client Lua
        // rather than assumed from the click. A click that could not resolve a
        // car must not leave the board marking a row it never reached.
        watching: null
      };
      // ON is not enough: the board is only ever shown to somebody out of the
      // field. It is also not STICKY across spells -- see the watcher below.
      $scope.broadcastMode = function () {
        return $scope.broadcast.on && $scope.spectatorView();
      };
      $scope.broadcastView = function (v) { return $scope.broadcast.view === v; };
      // The cup is pushed only when it CHANGES, so a board opened an hour into a
      // race night would render an empty standings table until the next race
      // finished. Same pull the admin's cup tab does as it comes on screen.
      function pullCupState() {
        bngApi.engineLua('raceManager.cupRequestState()');
      }
      $scope.toggleBroadcast = function () {
        $scope.broadcast.on = !$scope.broadcast.on;
        savePref('broadcast', $scope.broadcast.on);
        // Lua knows nothing of this mode: re-push, or the editor furniture streams
        // over the race.
        pushEditorOpen();
        if ($scope.broadcast.on) { pullCupState(); }
      };
      $scope.setBroadcastView = function (v) {
        $scope.broadcast.view = (v === 'points') ? 'points' : 'race';
        savePref('broadcastView', $scope.broadcast.view);
        if ($scope.broadcast.view === 'points') { pullCupState(); }
      };

      // Put the camera on a driver. The row's `id` is the BeamMP player id, and
      // it is the only handle that means the same thing on every client - so it
      // is what goes to Lua, which resolves it to a local car.
      $scope.watchDriver = function (row) {
        if (!row || row.id === null || row.id === undefined) { return; }
        var pid = Number(row.id);
        if (!isFinite(pid)) { return; }
        bngApi.engineLua('raceManager.spectateDriver(' + pid + ')');
      };
      // Same, from a standings row: only an entry bound to a connected driver has
      // a car.
      $scope.watchEntry = function (row) {
        if (!row) { return; }
        var pid = $scope.cupPidOf[row.entryId];
        if (pid === undefined || pid === null) { return; }
        $scope.watchDriver({ id: pid });
      };
      $scope.canWatchEntry = function (row) {
        return !!row && $scope.cupPidOf[row.entryId] !== undefined;
      };
      $scope.isWatching = function (row) {
        return !!row && $scope.broadcast.watching !== null
          && String($scope.broadcast.watching) === String(row.id);
      };
      // The board does not outlive the spell that showed it: a finisher is a
      // spectator for a few seconds by accident, and a remembered preference threw
      // admins into the stream graphic at the flag. Cleared when the spell ENDS;
      // kept within one (a pause tears this directive down).
      $scope.$watch(function () { return $scope.spectatorView(); },
        function (out, wasOut) {
          if (!wasOut || out || !$scope.broadcast.on) { return; }
          $scope.broadcast.on = false;
          savePref('broadcast', false);
          // broadcastMode() has just changed without anybody pressing anything,
          // and the editor's world drawing is gated on it in Lua -- which only
          // hears about it when something says so.
          pushEditorOpen();
        });

      $scope.$on('RaceManagerWatch', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.broadcast.watching = (data && data.ok) ? data.pid : null;
        });
      });

      // Places gained or lost since the lights. It sits alongside the gap rather
      // than in place of it: one says how the race has moved, the other how far
      // away it is.
      $scope.gridDelta = function (row) {
        if (!row || !row.gridPos || !row.position) { return ''; }
        if (row.status === 'dnf' || row.status === 'dsq') { return ''; }
        var d = row.gridPos - row.position;
        if (d === 0) { return ''; }
        return (d > 0 ? '+' : '') + d;
      };
      $scope.gridDeltaClass = function (row) {
        var d = $scope.gridDelta(row);
        if (!d) { return ''; }
        return d.charAt(0) === '+' ? 'rm-bc-gain' : 'rm-bc-loss';
      };
      // The lap the RACE is on, which is the leader's - the number a commentator
      // says out loud. Blank in qualifying, where there is no single lap count
      // the field shares.
      $scope.broadcastLap = function () {
        if ($scope.derbyActive()) { return ''; }
        if ($scope.sessionKind === 'quali' || !$scope.bcRunning.length) { return ''; }
        var leader = $scope.bcRunning[0];
        if (!leader || !leader.currentLap) { return ''; }
        // Through the same two helpers the leaderboard counts on, so the number a
        // commentator reads out is the number on the board behind them. Saying
        // "lap 6 of 5" on stream is worse than saying it in a table.
        if ($scope.pacedRace() && leader.outLap) { return 'PACE'; }
        var total = $scope.raceLapTarget();
        var n = $scope.raceLapNumber(leader);
        return total ? (n + '/' + total) : String(n);
      };

      // ------------------------------------------------------------------
      // Time behind
      // ------------------------------------------------------------------
      // A race gap is the server's split subtraction (`gap`, `intv`); qualifying's
      // is between best laps. A lapped car shows laps, not seconds.
      $scope.lapsDown = function (row) {
        if (!row) { return 0; }
        // The classification leader, which is drivers[0] on every board: the
        // server sorts the array leader-first and every table renders it as it
        // arrived.
        var leader = $scope.drivers[0];
        if (!leader || !leader.currentLap || !row.currentLap) { return 0; }
        if (row.status === 'dnf' || row.status === 'dsq') { return 0; }
        // A finisher is not lapped, whatever the leader's counter reads: they
        // completed the distance and their gap is a real time.
        if (row.status === 'finished') { return 0; }
        var d = leader.currentLap - row.currentLap;
        return d > 0 ? d : 0;
      };
      // Seconds, to a tenth. Deliberately coarser than the three decimals on the
      // wire: the stamp carries the reporting client's ping, so a thousandths
      // digit here would be precision this cannot actually deliver.
      function formatBehind(t) {
        if (t === null || t === undefined) { return ''; }
        if (t < 60) { return '+' + t.toFixed(1); }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return '+' + m + ':' + (s < 10 ? '0' : '') + s.toFixed(1);
      }
      // Gap to the leader, for whichever board is asking.
      $scope.gapLabel = function (row) {
        if (!row || row.status === 'dnf' || row.status === 'dsq') { return ''; }
        if (row.position === 1) { return ''; }
        var down = $scope.lapsDown(row);
        if (down > 0) { return '+' + down + ' LAP' + (down > 1 ? 'S' : ''); }
        return formatBehind(row.gap);
      };
      // ...and to the car ahead, with the same lap rule: a split a lap apart means
      // nothing.
      $scope.intervalLabel = function (row) {
        if (!row || row.status === 'dnf' || row.status === 'dsq') { return ''; }
        if (row.position === 1) { return ''; }
        // drivers[position - 1] is this row, so the car ahead is one before it.
        var ahead = $scope.drivers[row.position - 2];
        if (ahead && ahead.currentLap && row.currentLap
            && row.status !== 'finished' && ahead.status !== 'finished') {
          var d = ahead.currentLap - row.currentLap;
          if (d > 0) { return '+' + d + ' LAP' + (d > 1 ? 'S' : ''); }
        }
        return formatBehind(row.intv);
      };
      // QUALIFYING: the difference between best laps, worked out here because
      // the server has no business ranking a lap time twice. A driver with no
      // time yet has no gap - not a gap to nothing.
      $scope.qualiGapLabel = function (row, index) {
        if (!row || !row.qualiBest) { return ''; }
        if (index === 0) { return ''; }
        var leader = $scope.drivers[0];
        if (!leader || !leader.qualiBest) { return ''; }
        return formatBehind(row.qualiBest - leader.qualiBest);
      };

      // The broadcast board's gap column, for both session kinds in one table:
      // gapLabel is blank in qualifying (the server sends no split gap), and
      // qualiGapLabel measures against drivers[0], which may have retired.
      $scope.bcGapLabel = function (row, index) {
        if ($scope.sessionKind !== 'quali') { return $scope.gapLabel(row); }
        if (!row || !row.qualiBest || index === 0) { return ''; }
        var leader = $scope.bcRunning[0];
        if (!leader || !leader.qualiBest) { return ''; }
        return formatBehind(row.qualiBest - leader.qualiBest);
      };

      // The one thing worth saying about a row beyond its numbers. Blank while a
      // driver is simply circulating: a column reading "Racing" on every line is
      // a column of noise, and a stream graphic has no room for one.
      $scope.bcNote = function (row) {
        if (!row) { return ''; }
        if (row.status === 'finished') { return $scope.formatLap(row.finishTime); }
        if ($scope.showOutLap(row)) { return 'OUT LAP'; }
        if (row.status === 'racing' || row.status === 'qualifying') { return ''; }
        return $scope.statusLabel(row.status);
      };

      // The field split for the board, once per broadcast (not per digest):
      //   running    - still in the session, in the server's order
      //   out        - retired and disqualified, with the ruling
      //   spectating - not in the field, counted rather than listed
      $scope.bcRunning  = [];
      $scope.bcOut      = [];
      $scope.bcWatchers = 0;
      $scope.bcFastest  = null;   // { name, time } of the session best, or null
      $scope.cupPidOf   = {};     // entryId -> pid, for click-to-watch in points view
      function splitField(list) {
        var running = [], out = [], watchers = 0, fastest = null;
        for (var i = 0; i < list.length; i++) {
          var row = list[i];
          if (row.id === $scope.bestLapPid) {
            var t = row.raceBest || row.qualiBest;
            if (t) { fastest = { name: $scope.driverName(row), time: t }; }
          }
          if (row.status === 'dnf' || row.status === 'dsq') { out.push(row); }
          else if (row.spectating) { watchers = watchers + 1; }
          else { running.push(row); }
        }
        $scope.bcRunning  = running;
        $scope.bcOut      = out;
        $scope.bcWatchers = watchers;
        $scope.bcFastest  = fastest;
      }

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

      // A DELTA IS ONLY WORTH SHOWING WITH ITS SIGN. Always three decimals and
      // always an explicit + or -, so the eye reads the direction before it
      // reads the number.
      $scope.formatDelta = function (d) {
        if (d === null || d === undefined) { return ''; }
        return (d >= 0 ? '+' : '-') + Math.abs(d).toFixed(3);
      };
      // Green is faster (a negative delta), red slower; an exact tie is neither.
      $scope.deltaClass = function (d) {
        if (d === null || d === undefined || d === 0) { return ''; }
        return d < 0 ? 'rm-delta-faster' : 'rm-delta-slower';
      };
      $scope.formatLap = function (t) {
        if (t === null || t === undefined) { return '-'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3);
      };

      // Running lap clock: tenths, not thousandths. At a 100 ms render tick the
      // thousandths digit would be frozen noise, and the coarser precision also
      // sets the live readout apart from a held (official) time at a glance.
      $scope.formatLapLive = function (t) {
        if (t === null || t === undefined) { return '-'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(1);
      };

      // ------------------------------------------------------------------
      // Bridge: LUA -> UI
      // ------------------------------------------------------------------
      $scope.$on('RaceManagerUpdate', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          var prevPhase = $scope.phase;
          $scope.phase = data.phase || 'waiting';
          if (prevPhase !== $scope.phase) { menuSessionEdge(); }
          // Lua keeps no preferences, so it hears the sound setting once a
          // server is talking to this panel, in case it loaded after the panel.
          if (!soundSent) { soundSent = true; pushSound(); }
          $scope.flag = (data.flag === 'yellow' || data.flag === 'red') ? data.flag : 'green';
          // Read here, on the broadcast that arrives on a clock (the route push
          // only fires at gates).
          if (data.driverFlag) { $scope.driverFlag = data.driverFlag; }
          // Which session the shared lifecycle is running (the view switches on
          // it).
          $scope.sessionKind = data.sessionKind === 'quali' ? 'quali' : 'race';
          if (typeof data.sessionLaps === 'number') { $scope.sessionLaps = data.sessionLaps; }
          $scope.raceTime = data.raceTime || 0;
          // The race clock, which is not raceTime: it starts at the green, not at
          // the release, and stands still under a red flag.
          $scope.raceClock = (typeof data.raceClock === 'number') ? data.raceClock : null;
          $scope.clockStopped = !!data.clockStopped;
          // Who holds the session's fastest lap. One id, compared per row when
          // the table renders - no scan, and no second sorted copy of the field.
          $scope.bestLapPid = (data.bestLapPid === undefined) ? null : data.bestLapPid;
          if (typeof data.pointToPoint === 'boolean') { $scope.pointToPoint = data.pointToPoint; }
          if (typeof data.dragStrip === 'boolean') { $scope.dragStrip = data.dragStrip; }
          if (typeof data.layoutName === 'string') { $scope.loadedLayout = data.layoutName; }
          $scope.drivers = data.drivers || [];
          // The broadcast board's buckets, cut once per broadcast.
          splitField($scope.drivers);
          // Note gains/losses before the table re-renders, so the arrows in the
          // position column reflect this very update.
          trackPositionChanges($scope.drivers);
          // Whether the class column exists at all, decided once per broadcast
          // rather than once per row per digest.
          refreshHasClasses($scope.drivers);
          // Re-seed the distance box when the server's value moves (clamped, or
          // set by another admin).
          if (typeof data.totalLaps === 'number') {
            if ($scope.totalLaps !== data.totalLaps) { $scope.settingsUi.laps = data.totalLaps; }
            $scope.totalLaps = data.totalLaps;
          }
          // ...but never GO, which owns its lifetime on a timer (a race's 3 Hz
          // broadcast wiped it). The counts still clear here.
          if ($scope.phase !== 'countdown' && $scope.countdown !== 0) {
            $scope.countdown = null;
          }
          // League regulations mirrored from the server (Modules 1, 2 & 4).
          if (typeof data.maxResets === 'number') {
            if ($scope.maxResets !== data.maxResets) { $scope.settingsUi.resets = data.maxResets; }
            $scope.maxResets = data.maxResets;
          }
          if (data.resetMode === 'checkpoint' || data.resetMode === 'inplace') {
            $scope.resetMode = data.resetMode;
          }
          $scope.jokerEnabled = !!data.jokerEnabled;
          $scope.paceLap = !!data.paceLap;
          $scope.pacing = !!data.pacing;
          $scope.greenReady = !!data.greenReady;
          $scope.caution = !!data.caution;
          $scope.cautionLaps = data.cautionLaps || 0;
          $scope.cautionPending = !!data.cautionPending;
          $scope.restartPending = !!data.restartPending;
          $scope.luckyDog = !!data.luckyDog;
          $scope.cautionLucky = data.cautionLucky || null;
          // Re-seeded only when the server's value MOVED, so typing survives.
          if ($scope.heatCount !== (data.heatCount || 0)) {
            $scope.settingsUi.heats = data.heatCount || 0;
          }
          if ($scope.heatTransfer !== (data.heatTransfer || 0)) {
            $scope.settingsUi.transfer = data.heatTransfer || 0;
          }
          $scope.heatCount = data.heatCount || 0;
          $scope.heatTransfer = data.heatTransfer || 0;
          $scope.heatCurrent = data.heatCurrent || 0;
          $scope.heatsDrawn = !!data.heatsDrawn;
          if ($scope.heatLaps !== (data.heatLaps || 0)) {
            $scope.settingsUi.heatLaps = data.heatLaps || 0;
          }
          $scope.heatLaps = data.heatLaps || 0;
          $scope.heatDraw = data.heatDraw || 'quali';
          // Does the loaded track have other lanes at all? Decides whether the
          // leaderboard shows a Line column - on an ordinary circuit it is a
          // column that would say the same thing on every row.
          $scope.hasBranches = !!data.hasBranches;
          // Joker gates the LOADED TRACK has, which is not the same as the ones
          // this client happens to have placed in its editor: the toggle has to
          // reflect what the server would actually enforce.
          $scope.jokerGates = data.jokerGates || 0;
          // Race entry + starting grid.
          $scope.entrants = data.entrants || 0;
          $scope.gridMode = data.gridMode || 'quali';
          $scope.startSlots = data.startSlots || 0;
          // The ready check. myStatus and myGridPos are this client's own row,
          // added by the extension, which is the one that knows its server id.
          $scope.readyCheck = data.readyCheck !== false;
          $scope.myStatus = data.myStatus || null;
          $scope.myGridPos = data.myGridPos || null;
          if (data.phase !== 'grid'
              && ($scope.readyUi.confirm === 'countdown' || $scope.readyUi.confirm === 'race')) {
            $scope.readyUi.confirm = null;
          }
          // Qualifying rules. The inputs are re-seeded the same way the laps
          // and resets fields are: only when the server's value actually moved,
          // so an edit in progress is never yanked out from under the admin.
          $scope.ghostQuali = !!data.ghostQuali;
          $scope.nametags = !!data.nametags;
          $scope.qualiOutLap = !!data.qualiOutLap;
          // A limit becoming non-zero picks the Laps/Timed toggle, keyed on the
          // value having MOVED, or the toggle would snap back before the echo.
          if (typeof data.qualiLapLimit === 'number') {
            if ($scope.qualiLapLimit !== data.qualiLapLimit) {
              $scope.settingsUi.qualiLaps = data.qualiLapLimit;
              if (data.qualiLapLimit > 0) { $scope.qualiUi.mode = 'laps'; }
            }
            $scope.qualiLapLimit = data.qualiLapLimit;
          }
          if (typeof data.qualiTimeLimit === 'number') {
            if ($scope.qualiTimeLimit !== data.qualiTimeLimit) {
              $scope.settingsUi.qualiMins = Math.round(data.qualiTimeLimit / 60);
              if (data.qualiTimeLimit > 0) { $scope.qualiUi.mode = 'timed'; }
            }
            $scope.qualiTimeLimit = data.qualiTimeLimit;
          }
          $scope.qualiLeft = (typeof data.qualiLeft === 'number') ? data.qualiLeft : null;
          // Qualifying time is up and everyone out is on their last lap: the
          // header says so.
          $scope.finalLap = data.finalLap === true;
          // Timed race. raceLeft is the countdown; raceExpired means the clock
          // is out and the field is waiting on the leader; lastLapNum is the lap
          // everyone still running finishes on once the leader has been past.
          $scope.raceLeft = (typeof data.raceLeft === 'number') ? data.raceLeft : null;
          if (typeof data.raceMode === 'string') { $scope.raceMode = data.raceMode; }
          $scope.raceExpired = data.raceExpired === true;
          $scope.lastLapNum = (typeof data.lastLapNum === 'number') ? data.lastLapNum : null;
          if (typeof data.raceTimeLimit === 'number'
              && $scope.raceTimeLimit !== data.raceTimeLimit) {
            $scope.raceTimeLimit = data.raceTimeLimit;
            // Follow the server, the same way the quali boxes do: an admin on a
            // second panel must not go on showing their own stale number.
            if (!$scope.raceUi || $scope.raceUi.mode !== 'timed' || data.raceTimeLimit > 0) {
              $scope.settingsUi.raceMins = Math.round(data.raceTimeLimit / 60);
            }
          }
          // The Garage List comes on RaceManagerGarage now. KEPT for a server
          // that still puts it here (race.garageOnUpdate).
          if (data.garage !== undefined) { applyGarage(data); }
          // Track whether an admin is running the session. When one appears and
          // we're just a spectator who hasn't pinned the login open, auto-hide
          // the prompt so the app is fully visible (a header Login button stays).
          if (typeof data.serverBuild === 'string') { $scope.serverBuild = data.serverBuild; }
          $scope.adminPresent = !!data.adminPresent;
          // Targeted admin sends only, so a non-admin never even sees the row.
          if (typeof data.resultsPath === 'string') { $scope.resultsPath = data.resultsPath; }
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

      // How long GO! stays up: the overlay owns its lifetime in both modes, and
      // GO outlasts the counts (it is the frame everybody looks at).
      var GO_OVERLAY_MS = 3000;
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

      // Circuit, sprint stage or drag strip. Owned by the loaded track, set in
      // the editor, and mirrored from both the route push and the state
      // broadcast. A strip is a sprint the Layouts menu files under Drag Strip.
      $scope.pointToPoint = false;
      $scope.dragStrip = false;
      $scope.trackKind = function () {
        if (!$scope.pointToPoint) { return 'race'; }
        return $scope.dragStrip ? 'drag' : 'p2p';
      };
      $scope.setTrackKind = function (kind) {
        $scope.pointToPoint = kind !== 'race';
        $scope.dragStrip = kind === 'drag';
        bngApi.engineLua('raceManager.setPointToPoint(' + $scope.pointToPoint
          + ', ' + $scope.dragStrip + ')');
      };

      $scope.$on('RaceManagerRoute', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.routeWaypoints = data.waypoints || [];
          // Through toArray, not `|| []`: an empty Lua table arrives as {}.
          $scope.pitRoute = toArray(data.pitRoute);
          // The lane's mouth and its exit. Both optional: with no entry gate
          // every stall is drawn all race, which is what tracks did before this.
          $scope.pitEntry = toArray(data.pitEntry);
          $scope.pitExit  = toArray(data.pitExit);
          $scope.pitActive = !!data.pitActive;
          $scope.pitLeft = data.pitLeft || 0;
          if ($scope.pitActive) { $scope.pitEndsAt = Date.now() + $scope.pitLeft * 1000; }
          pitTickerOn($scope.pitActive);
          $scope.nextWp = data.nextWp || 1;
          $scope.visualize = data.visualize !== false;
          // Free practice, mirrored (the client Lua owns it). Entering, leaving or
          // changing track empties the lap list, except a COMPLETED run, kept
          // until Close or a new start.
          var wasPractice = $scope.practice;
          var wasLayout   = $scope.practiceLayout;
          $scope.practice       = data.practice === true;
          $scope.practiceLayout = data.practiceLayout || null;
          $scope.practiceComplete = data.practiceComplete === true;
          var freshRun = $scope.practice && (!wasPractice || $scope.practiceLayout !== wasLayout);
          var leftRun  = !$scope.practice && !$scope.practiceComplete;
          if ((freshRun || leftRun) && ($scope.practiceLaps.length || $scope.practiceBest !== null)) {
            $scope.practiceLaps = [];
            $scope.practiceBest = null;
          }
          $scope.practiceDone   = data.practiceDone || 0;
          $scope.practiceLeft   = (typeof data.practiceLeft === 'number')
                                  ? data.practiceLeft : null;
          if (typeof data.pointToPoint === 'boolean') { $scope.pointToPoint = data.pointToPoint; }
          if (typeof data.dragStrip === 'boolean') { $scope.dragStrip = data.dragStrip; }
          if (typeof data.clientBuild === 'string') { $scope.clientBuild = data.clientBuild; }
          // Admin session restored from the bridge: this directive is rebuilt on
          // every pause, which must not read as a logout.
          if (typeof data.isAdmin === 'boolean' && data.isAdmin !== $scope.isAdmin) {
            $scope.isAdmin = data.isAdmin;
            if (data.isAdmin) {
              $scope.showLogin = false;
              $scope.loginPinned = false;
              $scope.authError = false;
            }
            pushEditorOpen();
          }
          // The tier can move without the flag (re-login as moderator), so it is
          // its own test.
          if (typeof data.isAdmin === 'boolean') {
            $scope.adminRole = data.isAdmin ? (data.role || null) : null;
          }
          if (typeof data.width === 'number') { $scope.settingsUi.width = data.width; }
          if (typeof data.height === 'number') { $scope.settingsUi.height = data.height; }
          if (typeof data.depth === 'number') { $scope.settingsUi.depth = data.depth; }
          // Starting grid placed/loaded on this client.
          $scope.startPositions = toArray(data.startPositions);
          $scope.gridSlot = data.gridSlot || null;
          $scope.gridFrozen = !!data.gridFrozen;
          // Race entry state as this client knows it.
          // Joker route + reset allowance state pushed by the client Lua.
          $scope.jokerRoute = toArray(data.jokerRoute);
          $scope.jokerNext = data.jokerNext || 1;
          $scope.jokerTaken = !!data.jokerTaken;
          $scope.jokerLap = data.jokerLap || null;
          $scope.editorTarget = editorTargetOf(data.editorTarget);
          if (data.driverFlag) { $scope.driverFlag = data.driverFlag; }
          if (typeof data.youSpectating === 'boolean') {
            $scope.spectating = data.youSpectating;
          }
          // A confirmation left hanging after the session ended would offer to
          // retire from nothing.
          if (!$scope.sessionUnderWay()) { $scope.retireUi.confirm = false; }
          // Nudge mode. The CLIENT owns whether it is on: it can end the mode by
          // itself when a session starts or the editor closes, and the button
          // has to follow that rather than what it last asked for.
          $scope.nudgeOn = data.nudgeOn === true;
          $scope.nudgeSel = data.nudgeSel || null;
          // Branch gates.
          $scope.branches = toArray(data.branches);
          $scope.markers = toArray(data.markers);
          if (data.markerKind) { $scope.markerKind = data.markerKind; }
          if (data.markerKinds) { $scope.markerKinds = toArray(data.markerKinds); }
          if (data.markerLabels) { $scope.markerLabels = data.markerLabels; }
          $scope.props = toArray(data.props);
          if (data.propKind) { $scope.propKind = data.propKind; }
          if (data.propKinds) { $scope.propKinds = toArray(data.propKinds); }
          if (data.propLabels) { $scope.propLabels = data.propLabels; }
          if (typeof data.branchSlot === 'number') { $scope.branchSlot = data.branchSlot; }
          $scope.gridOffLine = !!data.gridOffLine;
          // The spacing sliders are only offered while the generator owns a
          // block of slots; hand-placing, moving or dropping one lets go of it.
          $scope.gridGenerated = !!data.gridGenerated;
          if (!$scope.gridGenerated) {
            // Keep the inputs showing what the last generate used, so the next
            // one starts from the same numbers rather than snapping back.
            if (typeof data.gridSpacing === 'number') { $scope.gridGen.spacing = data.gridSpacing; }
            if (typeof data.gridStagger === 'number') { $scope.gridGen.stagger = data.gridStagger; }
            if (typeof data.gridWidth === 'number') { $scope.gridGen.width = data.gridWidth; }
          }
          if (typeof data.resetsUsed === 'number') { $scope.resetsUsed = data.resetsUsed; }
          if (data.resetMode === 'checkpoint' || data.resetMode === 'inplace') {
            $scope.resetMode = data.resetMode;
          }
          if (typeof data.carTaken === 'boolean') { $scope.carTaken = data.carTaken; }
          // Keep the override editor in sync (a gate may have been removed, or
          // its stored overrides changed by the last command).
          if ($scope.selectedCp != null && !$scope.editorWaypoints()[$scope.selectedCp - 1]) {
            $scope.selectedCp = null;
          }
        });
      });

      // The list the editor shows for its target. Every target needs a case: a
      // missing one falls through to the main route silently.
      $scope.editorWaypoints = function () {
        if ($scope.editorTarget === 'joker') { return $scope.jokerRoute; }
        if ($scope.editorTarget === 'pit')   { return $scope.pitRoute; }
        if ($scope.editorTarget === 'pitEntry') { return $scope.pitEntry; }
        if ($scope.editorTarget === 'pitExit')  { return $scope.pitExit; }
        if ($scope.editorTarget === 'start') { return $scope.startPositions; }
        if ($scope.editorTarget === 'branch') { return $scope.branches; }
        if ($scope.editorTarget === 'marker') { return $scope.markers; }
        if ($scope.editorTarget === 'prop') { return $scope.props; }
        // The arena's three, for the same reason.
        if ($scope.editorTarget === 'derbyMarker') { return $scope.derby.boundary; }
        if ($scope.editorTarget === 'derbyStart')  { return $scope.derby.startPositions; }
        // One element, or none before a rectangle exists: the center is a
        // single point and Place mode treats it as a list of one.
        if ($scope.editorTarget === 'derbyCenter') {
          return $scope.derby.shape ? [$scope.derby.shape] : [];
        }
        return $scope.routeWaypoints;
      };

      // ------------------------------------------------------------------
      // Dragging a gate to reorder the route
      // ------------------------------------------------------------------
      // MOUSE EVENTS, NOT HTML5 DRAG-AND-DROP: BeamNG's CEF never delivers the
      // drag events (nothing errors, nothing moves). Move and up listen on the
      // DOCUMENT so a drag leaving the list still ends; down is delegated because
      // ng-repeat rebuilds the rows. Lua's reorderCheckpoint does the rest.
      var dragFrom = null;

      function rowIndexOf(node) {
        while (node && node !== $element[0]) {
          if (node.hasAttribute && node.hasAttribute('data-wp-index')) {
            var n = parseInt(node.getAttribute('data-wp-index'), 10);
            return isNaN(n) ? null : n;
          }
          node = node.parentNode;
        }
        return null;
      }

      // The row under the pointer right now. elementFromPoint rather than
      // ev.target: the pointer is over whatever is being dragged past, and
      // during a drag the target is wherever the mouse went down.
      function rowIndexAt(x, y) {
        return rowIndexOf(document.elementFromPoint(x, y));
      }

      function onDragMove(ev) {
        if (dragFrom === null) { return; }
        // Stops the gesture selecting the row text as the pointer sweeps down
        // the list, which otherwise highlights half the editor blue.
        ev.preventDefault();
        var over = rowIndexAt(ev.clientX, ev.clientY);
        $scope.$evalAsync(function () { $scope.dragOverIndex = over; });
      }

      function onDragUp(ev) {
        if (dragFrom === null) { return; }
        var to = rowIndexAt(ev.clientX, ev.clientY);
        var from = dragFrom;
        dragFrom = null;
        document.removeEventListener('mousemove', onDragMove, true);
        document.removeEventListener('mouseup', onDragUp, true);
        $scope.$evalAsync(function () {
          $scope.dragOverIndex = null;
          // reorderCheckpoint is 1-based and moves the item AT `from` to
          // position `to`, which is exactly "dropped on that row".
          if (from !== null && to !== null && from !== to) {
            $scope.reorderCheckpoint(from + 1, to + 1);
          }
        });
      }

      function onDragDown(ev) {
        // The GRIP starts a drag, not the whole row: the row already has a click
        // that opens its size controls, and a row-wide drag would make opening
        // one a coin toss between the two.
        var onGrip = ev.target && ev.target.classList
          && ev.target.classList.contains('rm-editor-grip');
        if (!onGrip || ev.button !== 0) { return; }
        var idx = rowIndexOf(ev.target);
        if (idx === null) { return; }
        dragFrom = idx;
        ev.preventDefault();
        ev.stopPropagation();
        // Capture phase, so the drag owns the pointer even over controls inside
        // the rows it is passing across.
        document.addEventListener('mousemove', onDragMove, true);
        document.addEventListener('mouseup', onDragUp, true);
        $scope.$evalAsync(function () { $scope.dragOverIndex = idx; });
      }

      $scope.dragOverIndex = null;
      $element[0].addEventListener('mousedown', onDragDown);

      // ------------------------------------------------------------------
      // Branch gates (editor)
      // ------------------------------------------------------------------
      // One picker menu open at a time, so one key; a DOM dropdown (CEF).
      $scope.laneMenuOpen = function (key) { return $scope.laneUi.menu === key; };
      $scope.laneToggleMenu = function (key) {
        $scope.laneUi.menu = ($scope.laneUi.menu === key) ? null : key;
      };
      $scope.pickBranchSlot = function (s) {
        $scope.laneUi.menu = null;
        $scope.setBranchSlot(s);
      };
      $scope.pickGateSlot = function (index, s) {
        $scope.laneUi.menu = null;
        $scope.setBranchGateSlot(index, s);
      };
      $scope.setBranchSlot = function (slot) {
        bngApi.engineLua('raceManager.setBranchSlot(' + (parseInt(slot, 10) || 1) + ')');
      };
      $scope.setBranchGateSlot = function (index, slot) {
        bngApi.engineLua('raceManager.setBranchGateSlot(' + index + ', '
          + (parseInt(slot, 10) || 1) + ')');
      };
      $scope.removeBranchGate = function (index) {
        bngApi.engineLua('raceManager.removeBranchGate(' + (parseInt(index, 10) || 0) + ')');
      };
      // Every checkpoint on the main route, so the pickers can offer them by number.
      $scope.routeSlots = function () {
        var out = [];
        for (var i = 1; i <= $scope.routeWaypoints.length; i++) { out.push(i); }
        return out;
      };
      // How many other ways there are through a checkpoint - drawn beside the main
      // gate in the route list, so an admin can see which corners are taken two ways.
      $scope.slotBranchCount = function (slot) {
        var n = 0;
        for (var i = 0; i < $scope.branches.length; i++) {
          if ($scope.branches[i].slot === slot) { n++; }
        }
        return n;
      };

      // ------------------------------------------------------------------
      // Taking things back, and building a grid without driving it
      // ------------------------------------------------------------------
      $scope.removeCheckpoint = function (i) {
        bngApi.engineLua('raceManager.removeCheckpoint(' + i + ')');
      };
      $scope.insertCheckpoint = function (i) {
        bngApi.engineLua('raceManager.insertCheckpoint(' + i + ')');
      };
      // The symbol for the NEXT marker placed (no index) or one already down.
      $scope.setMarkerKind = function (kind, index) {
        if (!kind) { return; }
        bngApi.engineLua('raceManager.setMarkerKind(' + luaStr(kind)
          + (index === undefined || index === null ? '' : ', ' + index) + ')');
      };
      $scope.markerLabelOf = function (kind) {
        return $scope.markerLabels[kind] || kind || '';
      };
      // What the next prop is (no index), or swap a placed one.
      $scope.setPropKind = function (kind, index) {
        if (!kind) { return; }
        $scope.laneUi.menu = null;
        bngApi.engineLua('raceManager.setPropKind(' + luaStr(kind)
          + (index === undefined || index === null ? '' : ', ' + index) + ')');
      };
      $scope.propLabelOf = function (kind) {
        return $scope.propLabels[kind] || kind || '';
      };
      $scope.setPropSolid = function (index, on) {
        bngApi.engineLua('raceManager.setPropSolid(' + index + ', ' + (on ? 'true' : 'false') + ')');
      };
      $scope.flipProp = function (index) {
        bngApi.engineLua('raceManager.flipProp(' + index + ')');
      };
      // The glyph the BUTTON shows. Deliberately not the same drawing as the
      // one on the board: this is a 12px label in a row of seven, and the
      // in-world symbol is line geometry sized to read at two hundred meters.
      $scope.markerGlyph = function (kind) {
        return ({ right: '→', left: '←', up: '↑', down: '↓',
                  uturn: '↰', splitRight: '⤴', splitLeft: '⤳', pit: 'P' })[kind] || '?';
      };

      $scope.reorderCheckpoint = function (from, to) {
        var list = $scope.editorWaypoints();
        if (to < 1 || to > list.length) { return; }
        bngApi.engineLua('raceManager.reorderCheckpoint(' + from + ', ' + to + ')');
      };
      // NOT generateGrid: that key is the Generate Grid button further down, and
      // the later definition wins.
      $scope.generateStartPositions = function () {
        var g = $scope.gridGen;
        bngApi.engineLua('raceManager.generateStartPositions('
          + (parseInt(g.count, 10) || 0) + ', '
          + (parseFloat(g.spacing) || 8) + ', ' + (parseFloat(g.stagger) || 6) + ', '
          + (parseInt(g.from, 10) || 0) + ', ' + (parseInt(g.width, 10) || 2) + ')');
      };
      $scope.pickGridAnchor = function (slot) {
        $scope.laneUi.menu = null;
        $scope.gridGen.from = slot;
      };
      $scope.gridAnchorLabel = function () {
        return $scope.gridGen.from ? ('Slot P' + $scope.gridGen.from) : 'My car';
      };
      // Dragged live, so it goes straight to the client Lua on every change: the
      // grid moves under the slider rather than after it.
      $scope.respaceGrid = function () {
        var g = $scope.gridGen;
        bngApi.engineLua('raceManager.respaceGrid(' + (parseFloat(g.spacing) || 8)
          + ', ' + (parseFloat(g.stagger) || 6) + ', ' + (parseInt(g.width, 10) || 2) + ')');
      };
      // How many rows the generated block comes out as, so the width slider says
      // what it is actually doing to the grid.
      $scope.gridRows = function () {
        var w = parseInt($scope.gridGen.width, 10) || 1;
        return Math.ceil((parseInt($scope.gridGen.count, 10) || 0) / w);
      };
      $scope.flipStartPositions = function () {
        var r = $scope.laneRange;
        bngApi.engineLua('raceManager.flipStartPositions(' + (parseInt(r.from, 10) || 1) + ', '
          + (parseInt(r.to, 10) || $scope.startPositions.length) + ')');
      };

      // Adjust a placed gate: stand the car on it, or move it to the car.
      $scope.previewCheckpoint = function (i) {
        bngApi.engineLua('raceManager.previewCheckpoint(' + i + ')');
      };
      $scope.moveCheckpoint = function (i) {
        bngApi.engineLua('raceManager.moveCheckpoint(' + i + ')');
      };

      // Start positions are placements, not gates: the width/height override
      // editor does not apply to them.
      $scope.editingGrid = function () { return $scope.editorTarget === 'start'; };

      // --- the arena's half of Place mode ---------------------------------
      // Which arena list the mouse edits; the SAME editorTarget (one Place mode).
      $scope.derbyPlaceTarget = function (target) {
        $scope.setEditorTarget(target);
      };
      $scope.derbyPlacing = function () {
        return $scope.editorTarget === 'derbyMarker'
            || $scope.editorTarget === 'derbyStart'
            || $scope.editorTarget === 'derbyCenter';
      };
      // Turning Place on from the arena panel has to pick a list as well, or
      // the mode comes up still pointed at the race track's checkpoints and the
      // first click moves a gate on another tab.
      $scope.toggleDerbyNudge = function () {
        if (!$scope.nudgeOn && !$scope.derbyPlacing()) {
          $scope.setEditorTarget($scope.derby.boundaryMode === 'rect'
            ? 'derbyCenter' : 'derbyMarker');
        }
        $scope.toggleNudge();
      };

      // ------------------------------------------------------------------
      // Regulation notices, forced spectating and vehicle rejections
      // ------------------------------------------------------------------
      // ONE QUEUE for everything transient. Notices RANK: a higher one preempts
      // and the displaced one waits; equal ranks queue in order. Presentation is
      // per kind in NOTICE_STYLE, so a new notification is one row. Long: this is
      // the primary channel (no chat app), read at speed.
      var NOTICE_DEFAULT = { rank: 0, flash: false, ms: 9000, color: 'gray' };
      var NOTICE_STYLE = {
        // Flags outrank everything and flash in their own color. REPLACE: only
        // the latest flag is true.
        flag:     { rank: 40, flash: true,  ms: 4500, replace: true },
        // Being removed from the session, or having a car refused, is the other
        // class a driver cannot afford to miss.
        spectate: { rank: 30, flash: false, ms: 9000 },
        vehicle:  { rank: 30, flash: false, ms: 9000 },
        session:  { rank: 20, flash: false, ms: 9000 },
        // Out of resets flashes, amber (about one car, not the session).
        resetsout: { rank: 25, flash: true, ms: 4500, color: 'amber' },
        // A flash: the strip was nearly invisible over the road on a driver's
        // panel.
        fastest:  { rank: 10, flash: true,  ms: 4500, color: 'gold' },
        // Pit steps REPLACE each other (only the latest is true); above the
        // session notices.
        pit:      { rank: 22, flash: false, ms: 4000, replace: true },
        // Everything else (grid, joker, reset, ghost, finish, server) takes
        // NOTICE_DEFAULT. They are the running commentary.
      };
      function noticeStyle(kind) {
        var s = NOTICE_STYLE[kind] || NOTICE_DEFAULT;
        return {
          rank:   s.rank   !== undefined ? s.rank   : NOTICE_DEFAULT.rank,
          flash:  s.flash  !== undefined ? s.flash  : NOTICE_DEFAULT.flash,
          ms:     s.ms     !== undefined ? s.ms     : NOTICE_DEFAULT.ms,
          color: s.color !== undefined ? s.color : NOTICE_DEFAULT.color,
          replace: s.replace === true
        };
      }

      // How long a notice has to have been up before being preempted counts as
      // having been read. Under this it is requeued, over it is dropped.
      var NOTICE_MIN_SEEN = 700;
      var noticeTimer = null;
      var noticeQueue = [];

      function noticeClear() {
        if (noticeTimer) { clearTimeout(noticeTimer); noticeTimer = null; }
      }

      // Show the highest-ranked thing waiting, if anything is.
      function noticeAdvance() {
        noticeClear();
        if (!noticeQueue.length) { $scope.notice = null; return; }
        var best = 0;
        for (var i = 1; i < noticeQueue.length; i++) {
          if (noticeQueue[i].rank > noticeQueue[best].rank) { best = i; }
        }
        var next = noticeQueue.splice(best, 1)[0];
        next.shownAt = Date.now();
        $scope.notice = next;
        noticeTimer = setTimeout(function () {
          $scope.$evalAsync(noticeAdvance);
        }, next.ms);
      }

      // A cap (a spinning car floods resets): the OLDEST LOW-RANKED goes, never a
      // caution.
      var NOTICE_QUEUE_MAX = 8;
      function noticeTrim() {
        while (noticeQueue.length > NOTICE_QUEUE_MAX) {
          var worst = 0;
          for (var i = 1; i < noticeQueue.length; i++) {
            if (noticeQueue[i].rank < noticeQueue[worst].rank) { worst = i; }
          }
          noticeQueue.splice(worst, 1);
        }
      }

      // `color` is the notice's own, which a flag needs: every flag is kind
      // 'flag', and dropping this painted all of them the same gray.
      function noticePush(kind, msg, sub, color) {
        var st = noticeStyle(kind);
        var item = { kind: kind, msg: msg, sub: sub || null, rank: st.rank,
                     flash: st.flash, ms: st.ms, color: color || st.color };
        // A kind that replaces: drop anything of its kind still waiting, and if
        // one is up, take its place now rather than after it.
        if (st.replace) {
          noticeQueue = noticeQueue.filter(function (q) { return q.kind !== kind; });
          if ($scope.notice && $scope.notice.kind === kind) {
            noticeQueue.push(item);
            noticeAdvance();
            return;
          }
        }
        // Nothing showing: straight up.
        if (!$scope.notice) {
          noticeQueue.push(item);
          noticeAdvance();
          return;
        }
        // Outranks what is up: preempt it. The displaced notice is requeued ONLY
        // if not yet seen for MIN_SEEN, or a fastest lap replays after the flag.
        if (item.rank > $scope.notice.rank) {
          var seen = Date.now() - ($scope.notice.shownAt || 0);
          if (seen < NOTICE_MIN_SEEN) { noticeQueue.push($scope.notice); }
          noticeQueue.push(item);
          noticeTrim();
          noticeAdvance();
          return;
        }
        noticeQueue.push(item);
        noticeTrim();
      }
      // Reachable from the rest of the controller, and the only way in.
      $scope.pushNotice = noticePush;

      $scope.$on('RaceManagerNotice', function (event, data) {
        if (!data || !data.msg) { return; }
        $scope.$evalAsync(function () {
          noticePush(data.kind || 'info', data.msg, data.sub, data.color);
        });
      });

      // Reset ghosting countdown, pushed at ~10 Hz and interpolated. `blocked`:
      // time is up but a car is in the way, so "MOVE CLEAR" (no time limit).
      var ghostTicker = null;
      function stopGhostTicker() {
        if (ghostTicker) { clearInterval(ghostTicker); ghostTicker = null; }
      }
      $scope.$on('RaceManagerGhost', function (event, data) {
        $scope.$evalAsync(function () {
          if (!data || !data.active) {
            $scope.ghost = null;
            stopGhostTicker();
            return;
          }
          $scope.ghost = {
            left: data.left || 0,
            at: Date.now(),
            blocked: !!data.blocked,
            warn: !!data.warn
          };
          if (!ghostTicker) {
            ghostTicker = setInterval(function () {
              $scope.$evalAsync(function () {
                if (!$scope.ghost) { stopGhostTicker(); return; }
                if ($scope.ghost.blocked) { $scope.ghostLeft = 0; return; }
                var elapsed = (Date.now() - $scope.ghost.at) / 1000;
                $scope.ghostLeft = Math.max($scope.ghost.left - elapsed, 0);
              });
            }, 100);
          }
          $scope.ghostLeft = $scope.ghost.blocked ? 0 : $scope.ghost.left;
        });
      });
      $scope.$on('$destroy', stopGhostTicker);

      $scope.$on('RaceManagerSpectator', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.carTaken = !!(data && data.spectating);
          $scope.spectatorReason = $scope.carTaken ? (data.reason || null) : null;
        });
      });

      // "Vehicle/Setup not allowed in this session." - stays until dismissed or
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

      // Password change confirmed by the server - flash a short note in the
      // admin bar so the change is acknowledged even outside the editor panel.
      var pwMsgTimer = null;
      $scope.$on('RaceManagerPasswordChanged', function (event, data) {
        $scope.$evalAsync(function () {
          // WHICH password, because there are two of them now and "updated"
          // over the wrong one is worse than saying nothing.
          var which = (data && data.role === 'moderator')
            ? (data.cleared ? 'Moderator login turned off' : 'Moderator password updated')
            : 'Admin password updated';
          $scope.pwMsg = '✓ ' + which + (data && data.by ? ' by ' + data.by : '');
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
          // `restored`: handed back, not typed, so it cannot be a wrong password.
          var restored = !!(data && data.restored);
          // `lapsed`: the server refused a command as unauthenticated. Not a
          // wrong password, but the login comes to the admin.
          var lapsed = !!(data && data.lapsed);
          $scope.isAdmin = ok;
          // Absent means full admin, per isFullAdmin above. Cleared with the
          // flag so a rejected login cannot leave the last tier behind.
          $scope.adminRole = ok ? (data && data.role) || null : null;
          $scope.authError = !ok && !restored && !lapsed;
          if (lapsed) { $scope.showLogin = true; }
          if (ok) {
            $scope.authUi.password = '';
            $scope.showLogin = false;
            $scope.loginPinned = false;
          }
          // Admin status gates the editor, so the Lua-side flag moves with it.
          pushEditorOpen();
          // Logging in with the Admin tab already open changes no tab, so the
          // map list would never be asked for.
          if (ok && $scope.adminTab === 'admin') {
            bngApi.engineLua('raceManager.mapRequest()');
          }
        });
      });

      // The Lua encoder writes an EMPTY table as {}: normalize to an array.
      function toArray(v) {
        if (Array.isArray(v)) { return v; }
        if (v && typeof v === 'object') {
          return Object.keys(v).map(function (k) { return v[k]; });
        }
        return [];
      }

      // THE GARAGE LIST, sent on its own when it changes rather than with every
      // state push. `seq` drops a list that arrives after a newer one: a
      // broadcast and a reply to one client are not ordered against each other.
      var garageRev = { boot: null, seq: -1 };
      function applyGarage(data) {
        $scope.garage = toArray(data.garage);
        // Derived here, not per digest (it allocates). Only rows with a stored
        // car (`spawn`); a press names its row by INDEX and the car is fetched
        // then.
        $scope.garageSpawnable = [];
        for (var gsi = 0; gsi < $scope.garage.length; gsi++) {
          if (!$scope.garage[gsi]) { continue; }
          // On EVERY row: the admin's Garage tab Take button needs it too.
          $scope.garage[gsi].index = gsi + 1;     // Lua counts from one
          if ($scope.garage[gsi].spawn) {
            $scope.garageSpawnable.push($scope.garage[gsi]);
          }
        }
        // Seeded from the server, except a box being edited (debounced).
        for (var gi = 0; gi < $scope.garage.length; gi++) {
          var srv = $scope.garage[gi].class || '';
          if ($scope.garageClassUi.input[gi] === undefined) {
            $scope.garageClassUi.input[gi] = srv;
          }
        }
        $scope.garageClassUi.input.length = $scope.garage.length;
        $scope.garageEnforce = !!data.garageEnforce;
        if (data.garageMode === 'parts' || data.garageMode === 'strict') {
          $scope.garageMode = data.garageMode;
        }
        $scope.garageSets = toArray(data.garageSets);
        // A set deleted (or renamed) elsewhere must not stay selected, or
        // Load and Delete point at a file that is gone.
        if ($scope.garageSetUi.selected
            && $scope.garageSets.indexOf($scope.garageSetUi.selected) === -1) {
          $scope.garageSetUi.selected = '';
        }
      }
      $scope.$on('RaceManagerGarage', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          if (data.boot === garageRev.boot && data.seq < garageRev.seq) { return; }
          garageRev.boot = data.boot;
          garageRev.seq = data.seq;
          applyGarage(data);
        });
      });

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
          rebuildLayoutMenu();
          schedulePreview();
        });
      });

      // ------------------------------------------------------------------
      // DEMO DERBY bridge + commands (isolated from the racing handlers)
      // ------------------------------------------------------------------
      $scope.$on('RaceManagerCup', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.cup.enabled = !!data.cupEnabled;
          // Paused is not the same as absent: see cupExists on the server.
          $scope.cup.exists = !!data.cupExists;
          $scope.cup.name = data.cupName || '';
          $scope.cup.round = data.round || 0;
          $scope.cup.preset = data.preset || 'custom';
          $scope.cup.derbyPreset = data.derbyPreset || 'custom';
          $scope.cup.dragPreset = data.dragPreset || 'custom';
          $scope.cup.racePoints = toArray(data.racePoints);
          $scope.cup.derbyPoints = toArray(data.derbyPoints);
          $scope.cup.dragPoints = toArray(data.dragPoints);
          $scope.cup.qualiPoints = toArray(data.qualiPoints);
          $scope.cup.presets = toArray(data.presets);
          $scope.cup.bonuses = toArray(data.bonuses);
          $scope.cup.standings = toArray(data.standings);
          $scope.cup.roster = toArray(data.roster);
          $scope.cup.connected = toArray(data.connected);
          // entryId -> bound pid, so a standings row can hand the camera a car.
          var pidOf = {};
          for (var ci = 0; ci < $scope.cup.connected.length; ci++) {
            var conn = $scope.cup.connected[ci];
            if (conn && conn.entryId !== undefined && conn.entryId !== null
                && conn.pid !== undefined && conn.pid !== null) {
              pidOf[conn.entryId] = conn.pid;
            }
          }
          $scope.cupPidOf = pidOf;
          $scope.cup.pendingQuali = data.pendingQuali || 0;
          $scope.cup.fastestLapRequiresFinish = data.fastestLapRequiresFinish !== false;
          $scope.cup.dnfScoring = data.dnfScoring || 'none';
          // Re-seed the edit fields, skipping anything mid-edit. A broadcast
          // arriving between two keystrokes must not wipe a table being typed -
          // the same rule the derby config inputs follow.
          cupSeedEditors();
        });
      });

      $scope.$on('RaceManagerDerby', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          var derbyWas = $scope.derby.phase;
          $scope.derby.phase = data.derbyPhase || 'idle';
          if (derbyWas !== $scope.derby.phase) { menuSessionEdge(); }
          $scope.derby.entrants = data.entrants || 0;
          $scope.derby.time = data.derbyTime || 0;
          $scope.derby.winner = data.winner || null;
          // Absent once the arena is edited: it is no saved arena then.
          $scope.loadedArena = data.arena || '';
          $scope.derby.boundary = toArray(data.boundary);
          $scope.derby.startPositions = toArray(data.startPositions);
          $scope.derby.boundaryCount = $scope.derby.boundary.length;
          $scope.derby.startCount = $scope.derby.startPositions.length;
          $scope.derby.players = toArray(data.players);
          if ($scope.derby.phase !== 'forming' && $scope.readyUi.confirm === 'derby') {
            $scope.readyUi.confirm = null;
          }
          $scope.derby.boundaryMode = data.boundaryMode === 'rect' ? 'rect' : 'polygon';
          $scope.derby.shape = (data.shape && typeof data.shape === 'object')
            ? data.shape : null;
          if (typeof data.wallHeight === 'number') {
            $scope.derby.wallHeight = data.wallHeight;
          }
          if (typeof data.wallDepth === 'number') {
            $scope.derby.wallDepth = data.wallDepth;
          }
          syncRectUi();
          // Keep the edit controls on an entry that exists; a live derby closes
          // them.
          syncDerbySelection();
          if (typeof data.maxResets === 'number') { $scope.derby.maxResets = data.maxResets; }
          // The RULE in force, which is what decides whether the Lives column is
          // worth a place on the board. Distinct from derbyUi.lives, which is
          // what the admin is typing and may not have applied yet.
          if (typeof data.lives === 'number') { $scope.derby.lives = data.lives; }
          if (typeof data.oobLimit === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.oob === null || Number($scope.derbyUi.oob) === derbyCfgSeen.oob) {
              $scope.derbyUi.oob = data.oobLimit;
            }
            derbyCfgSeen.oob = data.oobLimit;
          }
          if (typeof data.lives === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.lives === null || Number($scope.derbyUi.lives) === derbyCfgSeen.lives) {
              $scope.derbyUi.lives = data.lives;
            }
            derbyCfgSeen.lives = data.lives;
          }
          if (typeof data.demoLimit === 'number' && $scope.derby.phase !== 'running') {
            if (derbyCfgSeen.demo === null || Number($scope.derbyUi.demo) === derbyCfgSeen.demo) {
              $scope.derbyUi.demo = data.demoLimit;
            }
            derbyCfgSeen.demo = data.demoLimit;
          }
          if ((data.derbyMode === 'lms' || data.derbyMode === 'dm')
              && $scope.derby.phase !== 'running') {
            $scope.derbyUi.mode = data.derbyMode;
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
        // Forming up under the ready check: who is on their slot.
        if ($scope.readyCheck && $scope.derby.phase === 'forming') {
          return p.ready === false ? 'Not Ready' : 'Ready';
        }
        if (p.status === 'alive') { return 'In Arena'; }
        return p.reason || 'Eliminated';
      };

      $scope.formatDerbyTime = function (t) {
        if (t === null || t === undefined) { return '-'; }
        var m = Math.floor(t / 60);
        var s = Math.floor(t % 60);
        return m + ':' + pad2(s);
      };

      // Only worth a column when the derby is actually running lives. At 1 the
      // column would read "1" for everyone alive and tell nobody anything.
      $scope.derbyLivesOn = function () {
        return Number($scope.derby.lives) > 1;
      };

      // Applied as changed (debounced in the markup); the server refuses all of
      // it while a derby is active.
      $scope.derbyApplyConfig = function () {
        var oob = parseFloat($scope.derbyUi.oob);
        var demo = parseFloat($scope.derbyUi.demo);
        if (!isFinite(oob) || oob <= 0 || !isFinite(demo) || demo <= 0) { return; }
        // Resets are blocked for a derby; 0 is still sent so an older server
        // allows none rather than its unlimited default.
        var resets = 0;
        // Lives floor at 1: nought lives would knock the whole field out on the
        // first stopped timer, which is not a derby.
        var lives = parseInt($scope.derbyUi.lives, 10);
        if (isNaN(lives) || lives < 1) { lives = 1; }
        bngApi.engineLua('raceManager.derbySetConfig(' + oob + ', ' + demo + ', '
          + resets + ', ' + lives + ", '" + ($scope.derbyUi.mode || 'lms') + "')");
      };

      // ----------------------------------------------------------------
      // DRAG RACING: broadcasts in, commands out
      // ----------------------------------------------------------------
      // Overwrite an input only while it still shows the last server value
      // `seen` (eight inputs, hence the helper).
      function dragSeed(key, uiKey, value) {
        if (value === undefined || value === null) { return; }
        if (dragCfgSeen[key] === null || $scope.dragUi[uiKey] === dragCfgSeen[key]
            || Number($scope.dragUi[uiKey]) === dragCfgSeen[key]) {
          $scope.dragUi[uiKey] = value;
        }
        dragCfgSeen[key] = value;
      }

      $scope.$on('RaceManagerDrag', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          var d = $scope.drag;
          // Absent is not empty: a lane report leaves the ladder, entrants and
          // rules out, so only fields that arrived are written.
          function take(key, target, fallback) {
            if (data[key] === undefined || data[key] === null) { return; }
            d[target || key] = data[key];
            if (fallback !== undefined && d[target || key] === null) {
              d[target || key] = fallback;
            }
          }
          d.phase = data.dragPhase || 'idle';
          if (d.phase !== 'staging' && $scope.readyUi.confirm === 'drag') {
            $scope.readyUi.confirm = null;
          }
          take('format'); take('lanes'); take('advance'); take('cut');
          take('roundLimit'); take('tree'); take('seed'); take('timeout');
          take('stripLanes'); take('stripGates');
          take('round'); take('roundLabel'); take('roundSide');
          take('roundCount'); take('passIndex'); take('passCount');
          if (data.practice !== undefined) { d.practice = data.practice === true; }
          if (data.stageMode !== undefined) { d.stageMode = data.stageMode; }
          if (data.autoStart !== undefined) { d.autoStart = data.autoStart === true; }
          if (data.stageWait !== undefined) { d.stageWait = data.stageWait; }
          if (data.dialIn !== undefined) { d.dialIn = data.dialIn === true; }
          if (data.breakout !== undefined) { d.breakout = data.breakout !== false; }
          // Ladder, field, finishing order and `champion` only arrive on a full
          // broadcast; absence must not clear the winner mid-pass.
          if (data.entrants !== undefined) {
            d.entrants = toArray(data.entrants);
            d.board = toArray(data.board);
            d.finishOrder = toArray(data.finishOrder);
            d.champion = data.champion || null;
          }
          d.current = (data.current && typeof data.current === 'object')
            ? data.current : null;
          // Rules re-seed only while the strip is empty (the server refuses
          // mid-pass changes anyway).
          if (!$scope.dragActive()) {
            dragSeed('format', 'format', data.format);
            dragSeed('lanes', 'lanes', data.lanes);
            dragSeed('advance', 'advance', data.advance);
            dragSeed('cut', 'cut', data.cut);
            dragSeed('rounds', 'rounds', data.roundLimit);
            dragSeed('tree', 'tree', data.tree);
            dragSeed('seed', 'seed', data.seed);
            dragSeed('timeout', 'timeout', data.timeout);
            $scope.dragUi.dialIn = d.dialIn;
            $scope.dragUi.breakout = d.breakout;
            $scope.dragUi.stageMode = d.stageMode;
            $scope.dragUi.autoStart = d.autoStart;
            dragSeed('stageWait', 'stageWait', data.stageWait);
          }
          // The dial box follows this driver's own entry, so somebody who set
          // one on a previous evening sees it rather than an empty field.
          var me = $scope.dragMyEntry();
          if (me && me.dial != null && $scope.dragUi.dial === '') {
            $scope.dragUi.dial = me.dial;
          }
        });
      });

      // The lights, pushed by the Lua module as they change.
      $scope.$on('RaceManagerDragTree', function (event, data) {
        $scope.$evalAsync(function () {
          $scope.dragLight.stage = (data && data.stage) || 'off';
          $scope.dragLight.lane  = data && data.lane;
          $scope.dragLight.delay = (data && data.delay) || 0;
          $scope.dragLight.dial  = data && data.dial;
          $scope.dragLight.prestaged = !!(data && data.prestaged);
          $scope.dragLight.staged    = !!(data && data.staged);
          $scope.dragLight.rollup    = !!(data && data.rollup);
        });
      });

      // This driver's own numbers, the moment they have them.
      $scope.$on('RaceManagerDragRun', function (event, data) {
        $scope.$evalAsync(function () {
          // `clear` (slip expired) and `aborted` (waved off) both mean no run to
          // show.
          if (!data || data.clear || data.aborted) {
            $scope.dragLast = { rt: null, et: null, speed: null, foul: false };
            return;
          }
          $scope.dragLast = { rt: data.rt, et: data.et, speed: data.speed,
                              foul: data.foul === true };
        });
      });

      // --- what the panel asks about the ladder ---------------------------
      // Cars on the strip, from placement to the result hold: every mid-pass
      // rule is gated on this.
      $scope.dragActive = function () {
        var p = $scope.drag.phase;
        return p === 'staging' || p === 'tree' || p === 'running' || p === 'result';
      };
      // A ladder exists at all. Distinct from the above: between passes there
      // is a tournament running and nothing on the strip.
      $scope.dragLive = function () {
        return $scope.drag.phase !== 'idle';
      };
      // The drag board: an admin's by tab, a driver's while a ladder runs. Defers
      // to derbyBoardOnly (a live derby has cars in an arena now).
      $scope.dragBoardOnly = function () {
        if ($scope.derbyBoardOnly()) { return false; }
        return $scope.isAdmin ? $scope.isMode('drag') : $scope.dragLive();
      };
      // MY OWN ROW, marked by the Lua module before the board got here -- the
      // server sends one broadcast to everybody and cannot address it. Used for
      // the driver's own dial-in box and for highlighting them on the board.
      $scope.dragMyEntry = function () {
        var list = $scope.drag.entrants || [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].you) { return list[i]; }
        }
        return null;
      };
      var DRAG_PHASE_LABEL = {
        idle: 'No ladder', ready: 'Ready', staging: 'Staging',
        tree: 'Tree', running: 'On the strip', result: 'Result',
        complete: 'Complete'
      };
      $scope.dragPhaseLabel = function () {
        return DRAG_PHASE_LABEL[$scope.drag.phase] || $scope.drag.phase;
      };
      // Three decimals, because the third one decides passes. A missing number
      // is a dash rather than a zero somebody will read as a very good run.
      $scope.dragET = function (t) {
        return (t === null || t === undefined) ? '--' : Number(t).toFixed(3);
      };
      $scope.dragMPH = function (v) {
        return (v === null || v === undefined) ? '--' : Number(v).toFixed(1);
      };
      $scope.dragLaneNote = function (lane) {
        if (!lane) { return ''; }
        if ($scope.drag.phase === 'staging' && lane.ready === false) { return 'Not ready'; }
        if (lane.foul) { return 'RED'; }
        if (lane.brokeOut) { return 'BREAKOUT'; }
        if (lane.dnf) { return 'DNF'; }
        return '';
      };
      $scope.dragEntrantStatus = function (e) {
        if (!e) { return ''; }
        if (e.status === 'champion') { return 'WINNER'; }
        if (e.status === 'withdrawn') { return 'Withdrawn'; }
        if (e.status === 'out') {
          return 'Out' + (e.outRound ? ' (R' + e.outRound + ')' : '');
        }
        if (!e.online) { return 'Offline'; }
        return 'In';
      };
      // The board: a finished ladder in finishing order, a running one with the
      // drivers still in first.
      $scope.dragStandings = function () {
        var list = ($scope.drag.entrants || []).slice();
        var points = $scope.drag.format === 'points';
        list.sort(function (a, b) {
          if (points) {
            if (a.points !== b.points) { return b.points - a.points; }
          } else {
            var ao = a.status === 'out' ? (a.outRound || 0) : Infinity;
            var bo = b.status === 'out' ? (b.outRound || 0) : Infinity;
            if (ao !== bo) { return bo - ao; }
            if (a.wins !== b.wins) { return b.wins - a.wins; }
          }
          var ae = a.bestET == null ? Infinity : a.bestET;
          var be = b.bestET == null ? Infinity : b.bestET;
          if (ae !== be) { return ae - be; }
          return a.seed - b.seed;
        });
        return list;
      };
      // Can a ladder be built at all? The strip has to exist first, and saying
      // WHY it cannot is the whole point of asking separately.
      $scope.dragStripReady = function () {
        return $scope.drag.stripGates >= 1 && $scope.drag.stripLanes >= 2;
      };
      // A practice pass needs ONE lane, not Build Ladder's two.
      $scope.dragStripTestable = function () {
        return $scope.drag.stripGates >= 1 && $scope.drag.stripLanes >= 1;
      };

      // --- commands -------------------------------------------------------
      $scope.dragApplyConfig = function () {
        var u = $scope.dragUi;
        var lanes = parseInt(u.lanes, 10);
        var advance = parseInt(u.advance, 10);
        if (isNaN(lanes) || lanes < 2) { lanes = 2; }
        if (isNaN(advance) || advance < 1) { advance = 1; }
        // Advancing everybody out of a pass is a round that narrows nothing.
        // The server clamps this too; doing it here as well means the box shows
        // the number that was actually applied.
        if (advance > lanes - 1) { advance = lanes - 1; u.advance = advance; }
        var cut = parseInt(u.cut, 10);
        var rounds = parseInt(u.rounds, 10);
        var timeout = parseInt(u.timeout, 10);
        if (isNaN(cut) || cut < 0) { cut = 0; }
        if (isNaN(rounds) || rounds < 1) { rounds = 1; }
        if (isNaN(timeout) || timeout < 10) { timeout = 10; }
        bngApi.engineLua("raceManager.dragSetConfig('" + (u.format || 'single')
          + "', " + lanes + ', ' + advance + ', ' + cut + ', ' + rounds
          + ", '" + (u.tree || 'sportsman') + "', '" + (u.seed || 'random')
          + "', " + (u.dialIn ? 'true' : 'false') + ', '
          + (u.breakout ? 'true' : 'false') + ', ' + timeout + ')');
      };
      // Applies at once: it changes which boxes are on screen (as derbySetMode).
      $scope.dragSetFormat = function (f) {
        if (f !== 'single' && f !== 'double' && f !== 'points') { return; }
        $scope.dragUi.format = f;
        $scope.dragApplyConfig();
      };
      $scope.dragSetTree = function (t) {
        if (t !== 'pro' && t !== 'sportsman') { return; }
        $scope.dragUi.tree = t;
        $scope.dragApplyConfig();
      };
      $scope.dragSetSeed = function (sd) {
        if (sd !== 'random' && sd !== 'order' && sd !== 'quali') { return; }
        $scope.dragUi.seed = sd;
        $scope.dragApplyConfig();
      };
      // The start procedure, applied on the press for the same reason.
      $scope.dragApplyStaging = function () {
        var wait = parseInt($scope.dragUi.stageWait, 10);
        if (isNaN(wait) || wait < 5) { wait = 5; }
        bngApi.engineLua("raceManager.dragSetStaging('"
          + ($scope.dragUi.stageMode || 'rollup') + "', "
          + ($scope.dragUi.autoStart ? 'true' : 'false') + ', ' + wait + ')');
      };
      $scope.dragSetStageMode = function (m) {
        if (m !== 'hold' && m !== 'rollup') { return; }
        $scope.dragUi.stageMode = m;
        $scope.dragApplyStaging();
      };
      $scope.dragToggleAutoStart = function () {
        $scope.dragUi.autoStart = !$scope.dragUi.autoStart;
        $scope.dragApplyStaging();
      };
      // How many lanes are in the beams, for the header. Under roll-up this is
      // the one number an admin watches between pressing Stage and the tree.
      $scope.dragStagedCount = function () {
        var lanes = ($scope.drag.current && $scope.drag.current.lanes) || [];
        var n = 0;
        for (var i = 0; i < lanes.length; i++) { if (lanes[i].staged) { n++; } }
        return n;
      };
      $scope.dragToggleDialIn = function () {
        $scope.dragUi.dialIn = !$scope.dragUi.dialIn;
        $scope.dragApplyConfig();
      };
      $scope.dragToggleBreakout = function () {
        $scope.dragUi.breakout = !$scope.dragUi.breakout;
        $scope.dragApplyConfig();
      };
      $scope.dragBuild = function () {
        bngApi.engineLua('raceManager.dragBuild()');
      };
      $scope.dragClearLadder = function () {
        bngApi.engineLua('raceManager.dragClear()');
      };
      $scope.dragStage = function () {
        bngApi.engineLua('raceManager.dragStage()');
      };
      // A warm-up pass: stages and holds in one press, times the run, scores
      // nothing. Works with one car, which is what makes the strip testable
      // before a field turns up.
      $scope.dragPractice = function () {
        bngApi.engineLua('raceManager.dragPractice()');
      };
      // Your last ET straight into the dial-in box (no transcription errors).
      $scope.dragDialFromLast = function () {
        if ($scope.dragLast.et == null) { return; }
        $scope.dragUi.dial = Number($scope.dragLast.et).toFixed(3);
        $scope.dragSetDial();
      };
      $scope.dragRunPass = function () {
        var c = $scope.dragReadyCount();
        if ($scope.dragReadyShown() && c.ready > 0 && c.ready < c.total) {
          $scope.readyUi.confirm = 'drag';
          return;
        }
        bngApi.engineLua('raceManager.dragRun()');
      };
      $scope.dragAbort = function () {
        bngApi.engineLua('raceManager.dragAbort()');
      };
      $scope.dragWithdraw = function (seed) {
        bngApi.engineLua('raceManager.dragWithdraw(' + (Number(seed) || 0) + ')');
      };
      // A driver declaring their own dial-in. One event; the server refuses the
      // admin form (a seed number) from anybody who is not one.
      $scope.dragSetDial = function () {
        var d = parseFloat($scope.dragUi.dial);
        if (!isFinite(d) || d <= 0) { return; }
        bngApi.engineLua('raceManager.dragSetDial(' + d + ')');
      };
      // ...and an admin setting one FOR somebody without the app. Two boxes, not
      // one per row: a row model is wiped by every broadcast.
      $scope.dragSetDialFor = function () {
        var seed = parseInt($scope.dragUi.dialSeed, 10);
        var d = parseFloat($scope.dragUi.dialFor);
        if (isNaN(seed) || seed < 1 || !isFinite(d) || d <= 0) { return; }
        bngApi.engineLua('raceManager.dragSetDial(' + d + ', ' + seed + ')');
      };

      // A mode applies at once: it changes which boxes are on screen. The server
      // forces lives to 1 in LMS; this is what DM would go back to.
      $scope.derbySetMode = function (mode) {
        if (mode !== 'lms' && mode !== 'dm') { return; }
        $scope.derbyUi.mode = mode;
        $scope.derbyApplyConfig();
      };
      $scope.derbyAddMarker = function () {
        bngApi.engineLua('raceManager.derbyAddMarker()');
      };
      $scope.derbyClearBoundary = function () {
        bngApi.engineLua('raceManager.derbyClearBoundary()');
      };

      // --- The rectangle editor ---------------------------------------------
      $scope.derbySetBoundaryMode = function (mode) {
        if ($scope.derbyActive()) { return; }
        bngApi.engineLua('raceManager.derbySetBoundaryMode("'
          + (mode === 'rect' ? 'rect' : 'polygon') + '")');
      };
      $scope.derbySetShapeCenter = function () {
        if ($scope.derbyActive()) { return; }
        bngApi.engineLua('raceManager.derbySetShapeCenter()');
      };
      // Every slider lands here. Lua takes nil for "leave this alone", so only
      // the fields that have a usable number are sent - and with Square linked,
      // width drives length as well.
      $scope.derbyApplyShape = function () {
        if ($scope.derbyActive()) { return; }
        var w = parseFloat($scope.rectUi.width);
        var l = $scope.rectUi.square ? w : parseFloat($scope.rectUi.length);
        var r = parseFloat($scope.rectUi.rot);
        var h = parseFloat($scope.rectUi.wall);
        if ($scope.rectUi.square && isFinite(w)) { $scope.rectUi.length = w; }
        bngApi.engineLua('raceManager.derbySetShape('
          + (isFinite(w) ? w : 'nil') + ', '
          + (isFinite(l) ? l : 'nil') + ', '
          + (isFinite(r) ? r : 'nil') + ', '
          + (isFinite(h) ? h : 'nil') + ')');
      };
      // Wall height and depth are their own call (they apply to a polygon arena
      // too; rectangle fields riding along would switch the mode).
      $scope.derbyApplyWallHeight = function () {
        if ($scope.derbyActive()) { return; }
        var h = parseFloat($scope.rectUi.wall);
        var d = parseFloat($scope.rectUi.wallDepth);
        if (!isFinite(h)) { return; }
        if (!isFinite(d)) { d = 1.5; }
        bngApi.engineLua('raceManager.derbySetShape(nil, nil, nil, '
          + h + ', ' + d + ')');
      };
      // Derby starting grid: drive to each slot and place it; slot 1 first.
      $scope.derbyAddStart = function () {
        bngApi.engineLua('raceManager.derbyAddStartPosition()');
      };
      $scope.derbyClearStarts = function () {
        bngApi.engineLua('raceManager.derbyClearStartPositions()');
      };

      // --- Editing one placed marker / start slot ----------------------------
      // Click a row to open its controls (Go / Move Here / X), again to close.
      // Each button is a request: the list redraws on the broadcast. No selection
      // once a derby is under way.
      function syncDerbySelection() {
        if ($scope.derbyActive()) {
          $scope.derbySelMarker = null;
          $scope.derbySelStart = null;
          return;
        }
        if ($scope.derbySelMarker > $scope.derby.boundary.length) {
          $scope.derbySelMarker = null;
        }
        if ($scope.derbySelStart > $scope.derby.startPositions.length) {
          $scope.derbySelStart = null;
        }
      }

      $scope.selectDerbyMarker = function (index) {
        if ($scope.derbyActive()) { return; }
        $scope.derbySelMarker = ($scope.derbySelMarker === index) ? null : index;
      };
      $scope.selectDerbyStart = function (index) {
        if ($scope.derbyActive()) { return; }
        $scope.derbySelStart = ($scope.derbySelStart === index) ? null : index;
      };

      $scope.derbyMoveMarker = function (index) {
        bngApi.engineLua('raceManager.derbyMoveMarker(' + index + ')');
      };
      $scope.derbyRemoveMarker = function (index) {
        bngApi.engineLua('raceManager.derbyRemoveMarker(' + index + ')');
      };
      $scope.derbyPreviewMarker = function (index) {
        bngApi.engineLua('raceManager.derbyPreviewMarker(' + index + ')');
      };
      $scope.derbyMoveStart = function (index) {
        bngApi.engineLua('raceManager.derbyMoveStartPosition(' + index + ')');
      };
      $scope.derbyRemoveStart = function (index) {
        bngApi.engineLua('raceManager.derbyRemoveStartPosition(' + index + ')');
      };
      $scope.derbyPreviewStart = function (index) {
        bngApi.engineLua('raceManager.derbyPreviewStartPosition(' + index + ')');
      };
      $scope.derbyToggleVisualize = function () {
        bngApi.engineLua('raceManager.derbyToggleVisualize()');
      };
      // A derby is under way from form-up: the field is held, the arena locked.
      $scope.derbyActive = function () {
        return $scope.derby.phase === 'forming'
          || $scope.derby.phase === 'countdown'
          || $scope.derby.phase === 'running';
      };
      $scope.derbyPhaseLabel = function () {
        switch ($scope.derby.phase) {
          case 'running':   return 'LIVE: ' + $scope.formatDerbyTime($scope.derby.time);
          case 'forming':   return 'Formed up: held';
          case 'countdown': return 'Countdown';
          case 'finished':  return 'Finished';
          default:          return 'Setup';
        }
      };
      $scope.derbyFormUp = function () {
        // Push the inputs first: once formed, the rules are locked.
        $scope.derbyApplyConfig();
        bngApi.engineLua('raceManager.derbyFormUp()');
      };


      $scope.derbyStart = function () {
        // No config push here - the rules were sent at Form Up and are locked
        // from that point, so this is purely "release the field".
        var c = $scope.derbyReadyCount();
        if ($scope.derbyReadyShown() && c.ready > 0 && c.ready < c.total) {
          $scope.readyUi.confirm = 'derby';
          return;
        }
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
          rebuildLayoutMenu();
        });
      });

      // --- Saved arenas: the track layouts' three-way split, on the arena ---
      // The server replaces a same-named arena without asking, so Save As New
      // and Overwrite, as the track layouts have.

      // Case-insensitive, like the server: "Pit" would otherwise look new here
      // and still replace "pit" there.
      function existingDerbyLayout(name) {
        var lower = (name || '').trim().toLowerCase();
        for (var i = 0; i < $scope.derbyLayouts.length; i++) {
          if (($scope.derbyLayouts[i].name || '').toLowerCase() === lower) {
            return $scope.derbyLayouts[i];
          }
        }
        return null;
      }
      function askDerby(text, ok, action) {
        $scope.derbyUi.confirm = { text: text, ok: ok, action: action };
      }
      $scope.confirmDerbyAction = function () {
        var c = $scope.derbyUi.confirm;
        $scope.derbyUi.confirm = null;
        if (c && c.action) { c.action(); }
      };
      $scope.cancelDerbyAction = function () {
        $scope.derbyUi.confirm = null;
      };
      // One send for both buttons, so an overwrite can never save less than a
      // new arena does. The timer fields go first so the arena is stored with
      // what is on screen rather than the last value the server saw.
      function sendDerbySave(name) {
        $scope.derbyApplyConfig();
        bngApi.engineLua('raceManager.derbySaveLayout(' + luaStr(name) + ')');
      }
      // What the arena on screen is, in the words a confirmation needs.
      function derbyArenaSummary() {
        var parts = [];
        if ($scope.derby.boundaryMode === 'rect') { parts.push('a rectangle'); }
        else { parts.push($scope.derby.boundaryCount + ' markers'); }
        parts.push($scope.derby.startCount + ' start position'
          + ($scope.derby.startCount === 1 ? '' : 's'));
        return parts.join(', ');
      }

      // A name that is already taken is an overwrite wearing the wrong button,
      // so it asks rather than replacing quietly.
      $scope.derbySaveLayout = function () {
        var name = ($scope.derbyUi.name || '').trim();
        if (!name) { return; }
        var clash = existingDerbyLayout(name);
        if (clash) {
          askDerby('"' + clash.name + '" already exists on this map. Saving replaces it '
            + 'with the arena on screen now (' + derbyArenaSummary() + ').',
            'Replace it', function () { sendDerbySave(name); });
          return;
        }
        sendDerbySave(name);
      };

      // Overwrite the SELECTED arena -- no name to type, which is the point of
      // it: the common edit is load, adjust, put it back. The selected name is
      // sent verbatim so the saved entry keeps its exact spelling and casing.
      $scope.derbyOverwriteLayout = function () {
        var name = $scope.derbyUi.selected;
        if (!name || $scope.derby.boundaryCount < 3) { return; }
        askDerby('Replace "' + name + '" with the arena on screen now ('
          + derbyArenaSummary() + ')? The saved version is gone for good.',
          'Overwrite', function () { sendDerbySave(name); });
      };

      $scope.derbyLoadLayout = function () {
        if (!$scope.derbyUi.selected) { return; }
        bngApi.engineLua('raceManager.derbyLoadLayout(' + luaStr($scope.derbyUi.selected) + ')');
      };
      // Behind a confirmation now, like the track layout Delete it sits beside
      // in spirit: an arena is a boundary built corner by corner and a grid
      // placed slot by slot, and nothing puts a deleted one back.
      $scope.derbyDeleteLayout = function () {
        var name = $scope.derbyUi.selected;
        if (!name) { return; }
        askDerby('Delete "' + name + '" from the server? This cannot be undone.',
          'Delete', function () {
            bngApi.engineLua('raceManager.derbyDeleteLayout(' + luaStr(name) + ')');
            if ($scope.derbyUi.selected === name) { $scope.derbyUi.selected = ''; }
          });
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
      // The server refused an overwrite that would have emptied part of a
      // layout. Names exactly what would go, and makes the admin say yes first.
      $scope.$on('RaceManagerSaveHeld', function (event, data) {
        if (!data || !data.name) { return; }
        $scope.$evalAsync(function () {
          $scope.layoutUi.confirm = {
            text: 'Saving over "' + data.name + '" would remove ' + (data.summary || 'part of it')
              + ' from the saved layout, because this client is not holding them. '
              + 'Load the layout again if that is not what you meant.',
            ok: 'Save anyway',
            action: function () { sendSave(data.name, true); }
          };
        });
      });

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
        $scope.adminRole = null;
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
        bngApi.engineLua('raceManager.changePassword(' + luaStr(p) + ", 'admin')");
        $scope.authUi.newPassword = '';
      };

      // The race director's password: empty is a REAL setting (it turns the tier
      // off), unlike the admin password, which would lock the owner out.
      $scope.changeModPassword = function () {
        var p = ($scope.authUi.newModPassword || '').trim();
        bngApi.engineLua('raceManager.changePassword(' + luaStr(p) + ", 'moderator')");
        $scope.authUi.newModPassword = '';
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
      // Starting with drivers still not ready asks first: they sit the session
      // out, and they are usually a friend who is about to be.
      $scope.startCountdown = function () {
        if (readyNeedsConfirm()) { $scope.readyUi.confirm = 'countdown'; return; }
        bngApi.engineLua('raceManager.startCountdown()');
      };
      // Start the race behind the pace car. The ALTERNATIVE to the countdown,
      // not a step before it -- see paceStart() for which of the two the panel
      // puts on screen.
      $scope.startRace = function () {
        if (readyNeedsConfirm()) { $scope.readyUi.confirm = 'race'; return; }
        bngApi.engineLua('raceManager.startRace()');
      };

      // ------------------------------------------------------------------
      // Ready check
      // ------------------------------------------------------------------
      // Forming the grid calls drivers ('called'); Ready puts each on their slot
      // ('gridded').
      $scope.readyUi = { confirm: null };
      $scope.readyCount = function () {
        var ready = 0, total = 0;
        for (var i = 0; i < $scope.drivers.length; i++) {
          var st = $scope.drivers[i].status;
          if (st === 'gridded') { ready++; total++; } else if (st === 'called') { total++; }
        }
        return { ready: ready, total: total };
      };
      $scope.readyShown = function () {
        return $scope.phase === 'grid' && $scope.readyCheck && $scope.readyCount().total > 0;
      };
      // Nobody ready: the server refuses the start, so the button says so.
      $scope.readyNobody = function () {
        return $scope.readyShown() && $scope.readyCount().ready === 0;
      };
      function readyNeedsConfirm() {
        if (!$scope.readyShown()) { return false; }
        var c = $scope.readyCount();
        return c.ready > 0 && c.ready < c.total;
      }
      // Who is still not ready, for the "start without them?" question in
      // whichever mode is asking it.
      $scope.notReadyNames = function (mode) {
        var names = [], i;
        if (mode === 'derby') {
          var ps = $scope.derby.players || [];
          for (i = 0; i < ps.length; i++) {
            if (ps[i].ready === false) { names.push($scope.driverName(ps[i])); }
          }
        } else if (mode === 'drag') {
          var lanes = dragLanes();
          for (i = 0; i < lanes.length; i++) {
            if (lanes[i].ready === false) { names.push(lanes[i].name); }
          }
        } else {
          for (i = 0; i < $scope.drivers.length; i++) {
            if ($scope.drivers[i].status === 'called') { names.push($scope.driverName($scope.drivers[i])); }
          }
        }
        return names.join(', ');
      };
      $scope.readyConfirmStart = function () {
        var which = $scope.readyUi.confirm;
        $scope.readyUi.confirm = null;
        if (which === 'derby') { bngApi.engineLua('raceManager.derbyStart()'); return; }
        if (which === 'drag') { bngApi.engineLua('raceManager.dragRun()'); return; }
        bngApi.engineLua(which === 'race' ? 'raceManager.startRace()' : 'raceManager.startCountdown()');
      };

      // The same call for a derby form-up and a drag pass. A derby row is
      // called while `ready === false`; a drag lane likewise, and a lane with
      // no driver in it carries no ready flag at all.
      $scope.derbyReadyCount = function () {
        var ps = $scope.derby.players || [], ready = 0, total = 0;
        for (var i = 0; i < ps.length; i++) {
          total++;
          if (ps[i].ready !== false) { ready++; }
        }
        return { ready: ready, total: total };
      };
      $scope.derbyReadyShown = function () {
        return $scope.readyCheck && $scope.derby.phase === 'forming'
          && $scope.derbyReadyCount().total > 0;
      };
      $scope.derbyReadyNobody = function () {
        return $scope.derbyReadyShown() && $scope.derbyReadyCount().ready === 0;
      };
      function dragLanes() {
        var c = $scope.drag && $scope.drag.current;
        return c ? toArray(c.lanes) : [];
      }
      $scope.dragReadyCount = function () {
        var lanes = dragLanes(), ready = 0, total = 0;
        for (var i = 0; i < lanes.length; i++) {
          if (lanes[i].id == null || lanes[i].ready == null) { continue; }
          total++;
          if (lanes[i].ready !== false) { ready++; }
        }
        return { ready: ready, total: total };
      };
      $scope.dragReadyShown = function () {
        return $scope.readyCheck && $scope.drag.phase === 'staging'
          && $scope.dragReadyCount().total > 0;
      };
      $scope.dragReadyNobody = function () {
        return $scope.dragReadyShown() && $scope.dragReadyCount().ready === 0;
      };
      $scope.derbyReadyDriver = function (p) {
        if (p) { bngApi.engineLua('raceManager.derbyReadyDriver(' + p.id + ')'); }
      };
      $scope.derbyReadyAll = function () { bngApi.engineLua('raceManager.derbyReadyAll()'); };
      $scope.dragReadyDriver = function (ln) {
        if (ln && ln.id != null) { bngApi.engineLua('raceManager.dragReadyDriver(' + ln.id + ')'); }
      };
      $scope.dragReadyAll = function () { bngApi.engineLua('raceManager.dragReadyAll()'); };

      // What is waiting on this driver: race grid, derby form-up or drag pass, one
      // banner. Used as !!readyPrompt() (a fresh object never settles a watch).
      $scope.readyPrompt = function () {
        if (!$scope.readyCheck) { return null; }
        if ($scope.phase === 'grid'
            && ($scope.myStatus === 'called' || $scope.myStatus === 'gridded')) {
          return { mode: 'race', ready: $scope.myStatus === 'gridded',
                   label: $scope.sessionKind === 'quali' ? 'Qualifying grid forming' : 'Grid forming',
                   where: $scope.myGridPos ? 'slot P' + $scope.myGridPos : 'your slot' };
        }
        if ($scope.derby.phase === 'forming') {
          var ps = $scope.derby.players || [];
          for (var i = 0; i < ps.length; i++) {
            if (ps[i].you && ps[i].ready != null) {
              return { mode: 'derby', ready: ps[i].ready !== false, label: 'Derby forming up',
                       where: ps[i].slot ? 'slot ' + ps[i].slot : 'your place' };
            }
          }
        }
        if ($scope.drag.phase === 'staging') {
          var lanes = dragLanes();
          for (var j = 0; j < lanes.length; j++) {
            if (lanes[j].you && lanes[j].ready != null) {
              return { mode: 'drag', ready: lanes[j].ready !== false, label: 'Your drag pass is up',
                       where: 'lane ' + lanes[j].lane };
            }
          }
        }
        return null;
      };
      $scope.readyPress = function (on) {
        var p = $scope.readyPrompt();
        if (!p) { return; }
        on = on !== false;
        if (p.mode === 'derby') { bngApi.engineLua('raceManager.derbyReady(' + on + ')'); return; }
        if (p.mode === 'drag') { bngApi.engineLua('raceManager.dragReady(' + on + ')'); return; }
        $scope.setReady(on);
      };
      $scope.readyCancelStart = function () { $scope.readyUi.confirm = null; };
      $scope.setReady = function (on) {
        bngApi.engineLua('raceManager.setReady(' + (on !== false) + ')');
      };
      $scope.readyDriver = function (row) {
        if (row) { bngApi.engineLua('raceManager.readyDriver(' + row.id + ')'); }
      };
      $scope.readyAll = function () {
        bngApi.engineLua('raceManager.readyAll()');
      };
      $scope.setReadyCheck = function (on) {
        bngApi.engineLua('raceManager.setReadyCheck(' + (!!on) + ')');
      };
      // Does this grid start behind the pace car? Never in qualifying.
      $scope.paceStart = function () {
        return $scope.paceLap && !$scope.pointToPoint
          && $scope.sessionKind !== 'quali';
      };
      // Advisory; shown once a session runs, and held on the grid (which IS a red
      // flag).
      $scope.flagShowing = function () {
        return $scope.phase === 'racing' || $scope.phase === 'qualifying'
          || $scope.phase === 'grid';
      };
      $scope.flagTitle = function () {
        if ($scope.driverFlag === 'checkered') {
          return 'Checkered flag: your race is over. Your car is a ghost, so you can '
            + 'drive anywhere and nobody still racing can touch you.';
        }
        if ($scope.driverFlag === 'red') { return 'Red flag: stop where you are and wait'; }
        if ($scope.driverFlag === 'yellow') { return 'Yellow flag: caution, race back to the line'; }
        if ($scope.driverFlag === 'white') { return 'White flag: last lap'; }
        if ($scope.driverFlag === 'blue') {
          return 'Blue flag: a car a lap up is close behind you. Hold your line '
            + 'and let them past.';
        }
        return 'Green flag: racing';
      };

      // How many drivers are still out there, for the driver who has finished and
      // is waiting on them. Counted off the same driver table the leaderboard
      // renders, so it cannot disagree with the rows above it.
      $scope.stillRacing = function () {
        var n = 0;
        for (var i = 0; i < $scope.drivers.length; i++) {
          var st = $scope.drivers[i].status;
          if (st === 'racing' || st === 'qualifying') { n++; }
        }
        return n;
      };

      // Retiring cannot be undone, so it asks. Through an object: both buttons sit
      // in ng-if child scopes.
      $scope.retireUi = { confirm: false };
      $scope.retire = function () {
        bngApi.engineLua('raceManager.retire()');
      };

      $scope.setSpectating = function (on) {
        bngApi.engineLua('raceManager.setSpectating(' + (on ? 'true' : 'false') + ')');
      };

      $scope.setFlag = function (f) {
        var want = (f === 'yellow' || f === 'red') ? f : 'green';
        bngApi.engineLua('raceManager.setFlag("' + want + '")');
      };

      $scope.endRace = function () {
        bngApi.engineLua('raceManager.endRace()');
      };
      $scope.resetLeaderboard = function () {
        bngApi.engineLua('raceManager.resetLeaderboard()');
      };
      // Clear Results Cache, two presses: no undo, and a results file is a
      // league's only record of a night.
      $scope.resultsUi = { confirmClear: false, confirmLocal: false };
      $scope.askClearResults    = function () { $scope.resultsUi.confirmClear = true; };
      $scope.cancelClearResults = function () { $scope.resultsUi.confirmClear = false; };
      $scope.clearResults = function () {
        $scope.resultsUi.confirmClear = false;
        bngApi.engineLua('raceManager.clearResults()');
      };
      // The same for this PC only, open to a moderator (the server's copy is the
      // record). Its own confirm flag, or one press would arm both rows.
      $scope.askClearLocal    = function () { $scope.resultsUi.confirmLocal = true; };
      $scope.cancelClearLocal = function () { $scope.resultsUi.confirmLocal = false; };
      $scope.clearLocalResults = function () {
        $scope.resultsUi.confirmLocal = false;
        bngApi.engineLua('raceManager.clearLocalResults()');
      };

      // ------------------------------------------------------------------
      // Map switching and map votes
      // ------------------------------------------------------------------
      // An admin switches at will; anyone may call a vote (passes at the server's
      // percentage). A switch restarts the server, so it asks first.
      $scope.maps = { list: [], current: '', phase: 'idle', left: 0, voting: true, votePercent: 60 };
      // `where` is the panel whose menu is open: 'admin' or 'driver'.
      $scope.mapsUi = { menu: null, pick: null, confirm: false, percent: 60, myVote: null,
                        percentEditing: false, driverOpen: false, rename: null };
      $scope.$on('RaceManagerMaps', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          // Every push is the whole state except the list, which only comes
          // when asked for. Replaced, not merged, so a finished vote clears.
          var list = data.list ? toArray(data.list) : $scope.maps.list;
          $scope.maps = data;
          $scope.maps.list = list;
          if (data.phase !== 'idle') { $scope.mapsUi.confirm = false; }
          if (!$scope.mapsUi.percentEditing) { $scope.mapsUi.percent = data.votePercent; }
          if (!data.vote || !$scope.mapsUi.myVote || $scope.mapsUi.myVote.id !== data.vote.id) {
            $scope.mapsUi.myVote = null;
          }
        });
      });
      $scope.mapsRefresh = function () {
        bngApi.engineLua('raceManager.mapRequest()');
      };
      $scope.mapsMenuOpen = function (where) { return $scope.mapsUi.menu === where; };
      $scope.mapsToggleMenu = function (where) {
        $scope.mapsUi.menu = $scope.mapsUi.menu === where ? null : where;
        if (!$scope.mapsUi.menu) { return; }
        // Asked for on every open: a driver has no tab change to trigger it.
        $scope.mapsRefresh();
        revealDropdown(where === 'admin' ? '.rm-maps .rm-layout-menu' : '.rm-mapvote .rm-layout-menu');
      };
      $scope.mapsPick = function (m) {
        $scope.mapsUi.menu = null;
        $scope.mapsUi.confirm = false;
        $scope.mapsUi.pick = m && !m.current ? m : null;
      };
      $scope.mapsLabel = function (m) {
        return m ? (m.label || m.name) : '';
      };
      $scope.mapsCurrentLabel = function () {
        var list = $scope.maps.list;
        for (var i = 0; i < list.length; i++) {
          if (list[i].current) { return list[i].label || list[i].name; }
        }
        return $scope.maps.currentLabel || $scope.maps.current || 'unknown';
      };
      // A level name as the server shows it. Only the current map has a label
      // on every client, and the layout and arena lists are always for it.
      $scope.mapShown = function (name) {
        if (name && name === $scope.maps.current && $scope.maps.currentLabel) {
          return $scope.maps.currentLabel;
        }
        return name;
      };
      // DISPLAY NAMES. The picked map, or the current one when nothing is
      // picked (the current map cannot be picked: it is not a switch target).
      $scope.mapsRenameTarget = function () {
        if ($scope.mapsUi.pick) { return $scope.mapsUi.pick; }
        var list = $scope.maps.list;
        for (var i = 0; i < list.length; i++) {
          if (list[i].current) { return list[i]; }
        }
        return null;
      };
      $scope.mapsRenameOpen = function () {
        var m = $scope.mapsRenameTarget();
        if (!m) { return; }
        $scope.mapsUi.menu = null;
        $scope.mapsUi.rename = { name: m.name, label: m.label || m.name,
                                 def: m['default'] || m.name, custom: !!m.custom };
      };
      $scope.mapsRenameCancel = function () { $scope.mapsUi.rename = null; };
      $scope.mapsRenameSave = function (useDefault) {
        var r = $scope.mapsUi.rename;
        if (!r) { return; }
        $scope.mapsUi.rename = null;
        bngApi.engineLua('raceManager.mapRename(' + luaStr(r.name) + ', '
          + luaStr(useDefault ? '' : (r.label || '')) + ')');
      };
      $scope.mapsAsk = function () {
        if ($scope.mapsUi.pick) { $scope.mapsUi.confirm = true; }
      };
      $scope.mapsCancelAsk = function () { $scope.mapsUi.confirm = false; };
      $scope.mapsSwitch = function () {
        var m = $scope.mapsUi.pick;
        $scope.mapsUi.confirm = false;
        if (!m) { return; }
        bngApi.engineLua('raceManager.mapSwitch(' + luaStr(m.name) + ')');
      };
      $scope.mapsCancel = function () {
        bngApi.engineLua('raceManager.mapCancel()');
      };
      $scope.mapsVoteStart = function () {
        var m = $scope.mapsUi.pick;
        if (!m) { return; }
        $scope.mapsUi.confirm = false;
        bngApi.engineLua('raceManager.mapVoteStart(' + luaStr(m.name) + ')');
      };
      $scope.mapsVote = function (yes) {
        var v = $scope.maps.vote;
        if (!v) { return; }
        $scope.mapsUi.myVote = { id: v.id, yes: !!yes };
        bngApi.engineLua('raceManager.mapVote(' + (!!yes) + ')');
      };
      $scope.mapsVoted = function (yes) {
        var mine = $scope.mapsUi.myVote;
        return !!mine && mine.yes === !!yes;
      };
      $scope.mapsVoteCancel = function () {
        bngApi.engineLua('raceManager.mapVoteCancel()');
      };
      $scope.mapsVoteLock = function (locked) {
        bngApi.engineLua('raceManager.mapVoteConfig(' + (!locked) + ', nil)');
      };
      $scope.mapsVotePercent = function () {
        $scope.mapsUi.percentEditing = false;
        var n = parseInt($scope.mapsUi.percent, 10);
        if (!(n >= 1 && n <= 100)) { $scope.mapsUi.percent = $scope.maps.votePercent; return; }
        bngApi.engineLua('raceManager.mapVoteConfig(nil, ' + n + ')');
      };
      // The pick is re-read from each new list, so a renamed pick shows its name.
      $scope.$watch('maps.list', function (list) {
        var pick = $scope.mapsUi.pick;
        if (!pick || !list) { return; }
        for (var i = 0; i < list.length; i++) {
          if (list[i].name === pick.name) {
            $scope.mapsUi.pick = list[i].current ? null : list[i];
            return;
          }
        }
      });
      // What config.json's mapRestart will do, before a switch has resolved it.
      $scope.mapsRestartText = function () {
        switch ($scope.maps.restart) {
          case 'watch':    return "Restart: the Management Tool's config check.";
          case 'relaunch': return 'Restart: Race Manager starts the server again.';
          case 'exit':     return 'Restart: your service manager, when the server stops.';
          case 'manual':   return 'Restart: by hand.';
          default:         return 'Restart: the Management Tool if it started the server, otherwise Race Manager.';
        }
      };

      // ------------------------------------------------------------------
      // Lap records
      // ------------------------------------------------------------------
      // One board per saved layout, scored at each session end. Clearing is the
      // admin tier's.
      $scope.records = { layouts: [], laps: [], layout: '', loaded: null, total: 0,
                         mapLabel: '', file: '', error: null };
      $scope.recordsUi = { open: false, menu: false, confirmClear: false, confirmRow: null };
      $scope.$on('RaceManagerRecords', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          var r = $scope.records;
          var list = toArray(data.layouts);
          // The loaded track is always on the menu, with or without times.
          var loaded = data.loaded || null;
          if (loaded && !list.some(function (l) { return l.name.toLowerCase() === loaded.toLowerCase(); })) {
            list.unshift({ name: loaded, count: 0 });
          }
          r.layouts = list;
          r.loaded = loaded;
          r.mapLabel = data.mapLabel || data.map || '';
          r.file = data.file || '';
          r.error = data.error || null;
          // A change pushed to everyone moves nobody off the board they are reading.
          var mine = r.layout;
          if (data.changed && mine && data.layout
              && mine.toLowerCase() !== String(data.layout).toLowerCase()) { return; }
          var laps = toArray(data.laps);
          var first = laps.length ? laps[0].time : 0;
          laps.forEach(function (l, i) { l.gap = i ? l.time - first : null; });
          r.layout = data.layout || '';
          r.laps = laps;
          r.total = data.total || 0;
          $scope.recordsUi.confirmClear = false;
          $scope.recordsUi.confirmRow = null;
        });
      });
      $scope.recordsRequest = function (layout) {
        bngApi.engineLua('raceManager.recordsRequest(' + (layout ? luaStr(layout) : 'nil') + ')');
      };
      $scope.recordsToggleMenu = function () {
        $scope.recordsUi.menu = !$scope.recordsUi.menu;
        if ($scope.recordsUi.menu) { revealDropdown('.rm-records .rm-layout-menu'); }
      };
      $scope.recordsPick = function (l) {
        $scope.recordsUi.menu = false;
        $scope.records.layout = l.name;
        $scope.recordsRequest(l.name);
      };
      $scope.recordsAskClear = function () { $scope.recordsUi.confirmClear = true; };
      $scope.recordsCancelClear = function () { $scope.recordsUi.confirmClear = false; };
      $scope.recordsClear = function () {
        $scope.recordsUi.confirmClear = false;
        if (!$scope.records.layout) { return; }
        bngApi.engineLua('raceManager.recordsClear(' + luaStr($scope.records.layout) + ')');
      };
      $scope.recordsAskRemove = function (l) { $scope.recordsUi.confirmRow = l.driver; };
      $scope.recordsCancelRemove = function () { $scope.recordsUi.confirmRow = null; };
      $scope.recordsRemove = function (l) {
        $scope.recordsUi.confirmRow = null;
        bngApi.engineLua('raceManager.recordsRemove(' + luaStr($scope.records.layout) + ', '
          + luaStr(l.driver) + ')');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (race settings)
      // ------------------------------------------------------------------
      // Session settings apply themselves (debounced 500 ms, or on blur): a
      // forgotten Set button raced the wrong distance. An empty box is NEVER
      // sent: it is a field mid-edit.
      //
      // Reset allowance: -1 unlimited, 0 none. Blank is still typing.
      $scope.applyMaxResets = function () {
        var n = parseInt($scope.settingsUi.resets, 10);
        if (isNaN(n)) { return; }
        if (n < 0) { n = -1; }
        bngApi.engineLua('raceManager.setMaxResets(' + n + ')');
      };

      // Module 1: what a legal reset does - repair in place or respawn at the
      // last checkpoint crossed.
      $scope.setResetMode = function (mode) {
        bngApi.engineLua('raceManager.setResetMode("'
          + (mode === 'checkpoint' ? 'checkpoint' : 'inplace') + '")');
      };

      // The badge on an unscored lap, three different facts:
      //   quali    thrown away: not timed, not one of the promised laps
      //   pace     the formation lap: on top of the distance
      //   standing a race's first lap off the grid: counts, only its time dropped
      // The badge is qualifying-only now; the race arms are KEPT (a league may
      // want them back: drop the `sessionKind` test on rm-out-badge).
      $scope.outLapLabel = function () {
        if ($scope.sessionKind === 'quali') { return 'OUT LAP'; }
        if ($scope.paceLap) { return 'PACE LAP: NOT SCORED'; }
        return 'LAP 1: NOT TIMED';
      };
      $scope.outLapNote = function () {
        if ($scope.sessionKind === 'quali') {
          return 'Out lap: not timed, not scored, not counted.';
        }
        if ($scope.paceLap) {
          return 'The formation lap: not timed, and not one of the race laps. '
            + 'Your lap 1 starts as you cross the line.';
        }
        return 'Counts toward the distance, but sets no lap time.';
      };

      // Race control: neutralise the race, and go racing again.
      $scope.callCaution = function () {
        bngApi.engineLua('raceManager.caution()');
      };
      $scope.callRestart = function () {
        bngApi.engineLua('raceManager.restart()');
      };
      // Wave a called restart off. Only the call goes: the race stays under
      // caution and the board stays frozen.
      $scope.cancelRestart = function () {
        bngApi.engineLua('raceManager.cancelRestart()');
      };
      // The free pass rule, for the next caution called.
      $scope.toggleLuckyDog = function () {
        bngApi.engineLua('raceManager.setLuckyDog(' + (!$scope.luckyDog) + ')');
      };
      // Only while a race runs (nothing to neutralise before the lights, no order
      // in qualifying).
      $scope.cautionAvailable = function () {
        return $scope.phase === 'racing' && $scope.sessionKind !== 'quali'
          && !$scope.pacing;
      };

      // Module 6: the heat program.
      $scope.applyHeats = function () {
        bngApi.engineLua('raceManager.setHeats('
          + (parseInt($scope.settingsUi.heats, 10) || 0) + ', '
          + (parseInt($scope.settingsUi.transfer, 10) || 0) + ', '
          + (parseInt($scope.settingsUi.heatLaps, 10) || 0) + ')');
      };
      $scope.drawHeats = function () {
        bngApi.engineLua('raceManager.drawHeats()');
      };
      // What the NEXT draw is seeded on. Changing it does not redraw: the draw
      // is its own button, and a seed change with no draw behind it has changed
      // nothing about tonight.
      $scope.setHeatDraw = function (mode) {
        bngApi.engineLua("raceManager.setHeatDraw('" + mode + "')");
      };
      $scope.setHeatCurrent = function (heat) {
        bngApi.engineLua('raceManager.setHeatCurrent(' + (parseInt(heat, 10) || 0) + ')');
      };
      // The heats to offer in the picker, as a real array: ng-repeat cannot
      // count, and building it here keeps the template free of arithmetic.
      $scope.heatList = function () {
        var out = [];
        for (var i = 1; i <= $scope.heatCount; i++) { out.push(i); }
        return out;
      };
      // What the next session IS, said in words. "Heat 2 of 3" and "Feature"
      // are the two things an admin needs to be sure of before pressing
      // Generate Grid, and the difference is who ends up on the track.
      $scope.heatLabel = function () {
        if (!$scope.heatCount) { return 'No heat program'; }
        var laps = $scope.heatLaps > 0
          ? (' \u00b7 ' + $scope.heatLaps + ' laps') : '';
        if (!$scope.heatCurrent) {
          return 'Feature - the whole field \u00b7 ' + $scope.totalLaps + ' laps';
        }
        return 'Heat ' + $scope.heatCurrent + ' of ' + $scope.heatCount + laps;
      };
      // A driver's own line: which heat they are in and whether they got out of
      // it. Nothing at all when no program is running.
      $scope.myHeatLabel = function (row) {
        if (!$scope.heatCount || !row || !row.heat) { return ''; }
        var s = 'H' + row.heat;
        if (row.heatPos) { s += ' P' + row.heatPos; }
        if (row.transferred === true) { s += ' \u2713'; }
        return s;
      };

      // Module 5: arm/disarm the pace lap for the next race.
      $scope.togglePaceLap = function () {
        bngApi.engineLua('raceManager.setPaceLap(' + (!$scope.paceLap) + ')');
      };

      // Module 2: arm/disarm the joker lap requirement.
      $scope.toggleJoker = function () {
        bngApi.engineLua('raceManager.setJokerEnabled(' + (!$scope.jokerEnabled) + ')');
      };

      // Module 4: capture the vehicle the admin is driving right now.
      $scope.whitelistCurrentVehicle = function () {
        bngApi.engineLua('raceManager.whitelistCurrentVehicle()');
      };
      // Your own copies, written on this PC: needs nothing from the server.
      $scope.openLocalResults = function () {
        bngApi.engineLua('raceManager.openLocalResults()');
      };
      $scope.openResults = function () {
        if (!$scope.resultsPath) { return; }
        bngApi.engineLua('raceManager.openResultsFolder(' + luaStr($scope.resultsPath) + ')');
      };

      $scope.clearGarage = function () {
        bngApi.engineLua('raceManager.clearGarage()');
      };

      // Open to everyone: the new car re-declares like any other. BY INDEX: the
      // parts are not on the broadcast, so the server sends that one car.
      $scope.takeGarageCar = function (g, replace) {
        if (!g || !g.index) { return; }
        bngApi.engineLua('raceManager.takeGarageCar(' + g.index + ', '
          + (replace ? 'true' : 'false') + ')');
      };

      // --- Saved garage sets ---------------------------------------------
      // The server owns every rule; these send and let the reply speak.
      $scope.saveGarageSet = function () {
        var name = ($scope.garageSetUi.name || '').trim();
        if (!name) { return; }
        bngApi.engineLua('raceManager.saveGarageSet(' + luaStr(name) + ')');
        $scope.garageSetUi.name = '';
      };
      // ADD merges a set into the list (a multi-class field from per-class sets).
      $scope.addGarageSet = function () {
        var name = $scope.garageSetUi.selected;
        if (!name) { return; }
        bngApi.engineLua('raceManager.loadGarageSet(' + luaStr(name) + ', true)');
      };
      $scope.loadGarageSet = function () {
        var name = $scope.garageSetUi.selected;
        if (!name) { return; }
        bngApi.engineLua('raceManager.loadGarageSet(' + luaStr(name) + ')');
      };
      $scope.deleteGarageSet = function () {
        var name = $scope.garageSetUi.selected;
        if (!name) { return; }
        bngApi.engineLua('raceManager.deleteGarageSet(' + luaStr(name) + ')');
        $scope.garageSetUi.selected = '';
      };
      // Tag an entry with the class its car runs in. Blank clears it.
      $scope.applyGarageClass = function (index) {
        var v = $scope.garageClassUi.input[index];
        bngApi.engineLua('raceManager.setGarageClass(' + (index + 1) + ", '"
          + String(v === undefined || v === null ? '' : v).replace(/'/g, '') + "')");
      };
      // More than one class among the DRIVERS? Set when the field arrives (as
      // splitField): as a template function it was a scan per row per digest.
      $scope.hasClasses = false;
      function refreshHasClasses(drivers) {
        for (var i = 0; i < drivers.length; i++) {
          if (drivers[i].class) { $scope.hasClasses = true; return; }
        }
        $scope.hasClasses = false;
      }
      // A driver's class and their place in it, as one cell. The same shape
      // myHeatLabel uses, for the same reason: two numbers that are one fact.
      $scope.classLabel = function (row) {
        if (!row || !row.class) { return ''; }
        return row.class + (row.classPos ? (' P' + row.classPos) : '');
      };

      // DISPLAY NAMES. What the entry matches is untouched; `was` lets the
      // server refuse if the list moved under the editor.
      $scope.garageRenameOpen = function (index) {
        var g = $scope.garage[index];
        if (!g) { return; }
        $scope.garageNameUi = { index: index, name: g.label || '', was: g.label || '',
                                def: g['default'] || g.label || '', custom: !!g['default'] };
      };
      $scope.garageRenameCancel = function () { $scope.garageNameUi.index = null; };
      $scope.garageRenameSave = function (useDefault) {
        var r = $scope.garageNameUi;
        if (r.index === null) { return; }
        bngApi.engineLua('raceManager.setGarageName(' + (r.index + 1) + ', '
          + luaStr(useDefault ? '' : (r.name || '')) + ', ' + luaStr(r.was) + ')');
        r.index = null;
      };
      $scope.removeGarageEntry = function (index) {
        bngApi.engineLua('raceManager.removeGarageEntry(' + (index + 1) + ')');
      };
      $scope.toggleGarageEnforce = function () {
        bngApi.engineLua('raceManager.setGarageEnforce(' + (!$scope.garageEnforce) + ')');
      };
      $scope.setGarageMode = function (mode) {
        bngApi.engineLua('raceManager.setGarageMode("' + mode + '")');
      };

      // Drivers ruled out of the list: carOk false only (null is no answer yet).
      $scope.garageOffenders = function () {
        var out = [];
        for (var i = 0; i < $scope.drivers.length; i++) {
          var d = $scope.drivers[i];
          if (d.carOk === false && !d.spectating) { out.push(d); }
        }
        return out;
      };

      // No applyWidth / applyHeight: the global gate size is gone. A gate takes
      // its size when it is placed, inherits it from the gate before, and is
      // edited on its own row -- so resizing one gate can never move another.

      $scope.setGridMode = function (mode) {
        bngApi.engineLua('raceManager.setGridMode("' + mode + '")');
      };
      $scope.gridModeLabel = function () {
        if ($scope.gridMode === 'random')  { return 'Random draw'; }
        if ($scope.gridMode === 'custom')  { return 'Custom order'; }
        if ($scope.gridMode === 'reverse') { return 'Reversed quali order'; }
        return 'Qualifying order';
      };
      // The qualifying order is the grid only under 'quali'.
      $scope.qualiOrderIsGrid = function () { return $scope.gridMode === 'quali'; };
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
      $scope.toggleNametags = function () {
        bngApi.engineLua('raceManager.setNametags(' + (!$scope.nametags) + ')');
      };
      $scope.toggleGhostQuali = function () {
        bngApi.engineLua('raceManager.setGhostQuali(' + (!$scope.ghostQuali) + ')');
      };
      // Qualifying is LAPS or TIMED, never both: the box not shown sends 0. The
      // mode is a display choice, seeded from the server.
      $scope.qualiUi = { mode: loadPref('qualiLimitMode', 'laps') === 'timed' ? 'timed' : 'laps' };
      $scope.isQualiLimitMode = function (mode) { return $scope.qualiUi.mode === mode; };

      // The numbers as the boxes currently read them, cleaned. Laps are per
      // driver; the time limit is entered in minutes and sent as seconds.
      function qualiLapsInput() {
        var n = parseInt($scope.settingsUi.qualiLaps, 10);
        return (isNaN(n) || n < 0) ? 0 : n;
      }
      function qualiSecondsInput() {
        var n = parseFloat($scope.settingsUi.qualiMins);
        return (isNaN(n) || n < 0) ? 0 : Math.round(n * 60);
      }
      // Send whichever limit the current mode governs, and 0 for the other.
      function pushQualiLimits() {
        var laps = $scope.qualiUi.mode === 'laps' ? qualiLapsInput() : 0;
        var secs = $scope.qualiUi.mode === 'timed' ? qualiSecondsInput() : 0;
        bngApi.engineLua('raceManager.setQualiLimits(' + laps + ', ' + secs + ')');
      }
      // An empty box is skipped (0 means UNLIMITED here). Switching mode is not:
      // zeroing the hidden limit is its point.
      $scope.applyQualiLimits = function () {
        var box = $scope.qualiUi.mode === 'laps'
          ? $scope.settingsUi.qualiLaps : $scope.settingsUi.qualiMins;
        if (box === '' || box === null || box === undefined) { return; }
        pushQualiLimits();
      };
      // Switching mode applies at once, or the old limit stays live.
      $scope.setQualiLimitMode = function (mode) {
        mode = (mode === 'timed') ? 'timed' : 'laps';
        if ($scope.qualiUi.mode === mode) { return; }
        $scope.qualiUi.mode = mode;
        savePref('qualiLimitMode', mode);
        pushQualiLimits();
      };
      // ------------------------------------------------------------------
      // Race length: a lap count OR a clock, never both
      // ------------------------------------------------------------------
      // As qualifying: pick one, the other is sent as 0.
      var RACE_MODES = { laps: true, timed: true, endurance: true };
      $scope.raceUi = { mode: RACE_MODES[loadPref('raceLimitMode', 'laps')] ? loadPref('raceLimitMode', 'laps') : 'laps' };
      $scope.isRaceLimitMode = function (mode) { return $scope.raceUi.mode === mode; };
      // Endurance runs to BOTH limits, so it is the one mode that shows both
      // boxes. The other two show the one they govern.
      $scope.raceShowLaps = function () { return $scope.raceUi.mode !== 'timed'; };
      $scope.raceShowMins = function () { return $scope.raceUi.mode !== 'laps'; };

      function raceLapsInput() {
        var n = parseInt($scope.settingsUi.laps, 10);
        return (isNaN(n) || n < 1) ? 1 : n;
      }
      function raceSecondsInput() {
        var n = parseFloat($scope.settingsUi.raceMins);
        return (isNaN(n) || n < 0) ? 0 : Math.round(n * 60);
      }
      function pushRaceLimits() {
        var laps = raceLapsInput();
        var secs = $scope.raceUi.mode === 'laps' ? 0 : raceSecondsInput();
        bngApi.engineLua('raceManager.setRaceLimits('
          + laps + ', ' + secs + ', "' + $scope.raceUi.mode + '")');
      }
      // An empty box is skipped (still typing; 0 minutes would mean a lap race).
      // In endurance BOTH boxes are live, and either mid-edit waits.
      $scope.applyRaceLimits = function () {
        var empty = function (v) { return v === '' || v === null || v === undefined; };
        if ($scope.raceShowLaps() && empty($scope.settingsUi.laps)) { return; }
        if ($scope.raceShowMins() && empty($scope.settingsUi.raceMins)) { return; }
        pushRaceLimits();
      };
      // Switching mode applies immediately. Waiting would leave the old limit
      // live underneath a panel showing the new mode's box, which is the state
      // this control exists to make impossible.
      $scope.setRaceLimitMode = function (mode) {
        if (!RACE_MODES[mode]) { mode = 'laps'; }
        if ($scope.raceUi.mode === mode) { return; }
        $scope.raceUi.mode = mode;
        savePref('raceLimitMode', mode);
        pushRaceLimits();
      };
      // The server's answer, not the boxes'. Reads raceMode so endurance says
      // what it actually is rather than being mistaken for a timed race by the
      // fact that it has a clock.
      $scope.raceLimitLabel = function () {
        if ($scope.pointToPoint) { return 'point to point: driven once'; }
        var mins = Math.round($scope.raceTimeLimit / 60);
        if ($scope.raceMode === 'timed') { return 'race: ' + mins + ' min + 1 lap'; }
        if ($scope.raceMode === 'endurance') {
          return 'race: ' + $scope.totalLaps + ' laps or ' + mins + ' min, first of the two';
        }
        return 'race: ' + $scope.totalLaps + ' laps';
      };
      // The session clock: a lap race counts UP, a timed race DOWN while racing;
      // a finished race shows elapsed. Elapsed is from the green (a pace lap reads
      // 0:00, a red flag holds it); raceTime is an older server's fallback.
      $scope.sessionClock = function () {
        var t;
        if ($scope.phase === 'racing'
            && $scope.raceLeft !== null && $scope.raceLeft !== undefined) {
          t = $scope.formatRaceTime($scope.raceLeft);
        } else {
          t = $scope.formatRaceTime($scope.raceClock !== null ? $scope.raceClock : $scope.raceTime);
        }
        return $scope.clockStopped ? ('\u23F8\uFE0E ' + t) : t;
      };
      // So the readout can say which way it is running rather than leaving a
      // driver to work it out from whether the digits are going up or down.
      $scope.sessionClockDown = function () {
        return $scope.phase === 'racing'
          && $scope.raceLeft !== null && $scope.raceLeft !== undefined;
      };
      // What the header says once the clock is out. Three states, three
      // sentences: waiting on the leader, the final lap running, the flag out.
      $scope.raceEndState = function () {
        if ($scope.phase !== 'racing') { return null; }
        if ($scope.finalLap) { return 'FLAG OUT'; }
        if ($scope.lastLapNum) { return 'FINAL LAP'; }
        if ($scope.raceExpired) { return '+1 LAP'; }
        return null;
      };

      // Remaining qualifying time for the header readout.
      $scope.qualiClock = function () {
        if ($scope.qualiLeft === null || $scope.qualiLeft === undefined) { return ''; }
        return $scope.formatRaceTime($scope.qualiLeft);
      };
      // The lap allowance is an allowance of TIMED laps, so the label says so
      // and names the out lap that sits in front of them: an admin setting 3 and
      // then watching drivers cross the line four times is owed the arithmetic.
      $scope.qualiLimitLabel = function () {
        var bits = [];
        if ($scope.qualiLapLimit > 0) { bits.push($scope.qualiLapLimit + ' timed laps'); }
        if ($scope.qualiTimeLimit > 0) { bits.push(Math.round($scope.qualiTimeLimit / 60) + ' min'); }
        var base = bits.length ? bits.join(' / ') : 'open';
        // Keyed on the TRACK (read while setting up); `qualiOutLap` answers for
        // the session on track.
        return $scope.pointToPoint ? base : (base + ' + out lap');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (starting grid editor)
      // ------------------------------------------------------------------
      // Place Start Position Here is editorAdd; the editor target picks the list.
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
      // Nudge mode borrows the mouse from the camera, so the panel has to show
      // clearly when it is on. The client echoes the real state back through the
      // route broadcast; this is only the request.
      $scope.toggleNudge = function () {
        bngApi.engineLua('raceManager.setNudgeMode(' + (!$scope.nudgeOn) + ')');
      };

      // Delete lives on a button rather than a key: guessing a keybind for a
      // destructive action on an engine that cannot be tested from here is how
      // the node grabber block shipped listening for names nothing answered to.
      $scope.nudgeTurn = function (dir) {
        if (!$scope.nudgeSel) { return; }
        bngApi.engineLua('raceManager.nudgeTurn(' + (dir < 0 ? -1 : 1) + ')');
      };

      $scope.nudgeLift = function (dir) {
        bngApi.engineLua('raceManager.nudgeLift(' + (dir >= 0 ? 1 : -1) + ')');
      };
      $scope.nudgeDelete = function () {
        if (!$scope.nudgeSel) { return; }
        bngApi.engineLua('raceManager.nudgeDelete()');
      };

      $scope.editorToggleVisualize = function () {
        bngApi.engineLua('raceManager.editorToggleVisualize()');
      };

      // Switch the editor's target list, applied locally too so the panel does
      // not wait for the echo.
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
          height: (typeof wp.height === 'number') ? wp.height : '',
          depth:  (typeof wp.depth === 'number') ? wp.depth : '',
          length: (typeof wp.length === 'number') ? wp.length : ''
        };
      };

      // A pit stall's box. Its own call, not the gate override: a stall is
      // car-sized and has a length where a gate has height and depth.
      // 0 stands in for blank, which is the default size.
      $scope.applyPitSize = function () {
        if (!$scope.selectedCp) { return; }
        var w = parseFloat($scope.cpEdit.width)  || 0;
        var l = parseFloat($scope.cpEdit.length) || 0;
        bngApi.engineLua('raceManager.setPitStallSize('
          + $scope.selectedCp + ', ' + w + ', ' + l + ')');
      };
      $scope.resetPitSize = function () {
        if (!$scope.selectedCp) { return; }
        $scope.cpEdit.width = 3.5;
        $scope.cpEdit.length = 6;
        bngApi.engineLua('raceManager.setPitStallSize(' + $scope.selectedCp + ', 0, 0)');
      };

      // Push the edit fields to the client. A blank field clears that override
      // (the gate falls back to the global default). 0 stands in for "blank".
      $scope.applyCheckpointOverride = function () {
        if (!$scope.selectedCp) { return; }
        var w = parseFloat($scope.cpEdit.width)  || 0;
        var h = parseFloat($scope.cpEdit.height) || 0;
        var dRaw = parseFloat($scope.cpEdit.depth);
        var d = isFinite(dRaw) ? dRaw : '';
        bngApi.engineLua('raceManager.setCheckpointOverride('
          + $scope.selectedCp + ', ' + w + ', ' + h + ', '
          + (d === '' ? 'nil' : d) + ')');
      };

      // Reset the selected gate back to the global defaults (clear all overrides).
      $scope.resetCheckpointOverride = function () {
        if (!$scope.selectedCp) { return; }
        $scope.cpEdit = { width: '', height: '', depth: '' };
        bngApi.engineLua('raceManager.setCheckpointOverride('
          + $scope.selectedCp + ', 0, 0, nil)');
      };

      // A gate's size, as shown on its row. Every gate placed or loaded carries
      // its own now; the fallback is only reached by one from a layout saved
      // before that was true, and the client fills those in as it loads.
      $scope.cpDim = function (wp, field) {
        if (wp && typeof wp[field] === 'number') { return wp[field]; }
        if (field === 'length') { return 6; }
        if (field === 'width') { return $scope.settingsUi.width; }
        if (field === 'depth') { return $scope.settingsUi.depth; }
        return $scope.settingsUi.height;
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (track layouts)
      // ------------------------------------------------------------------
      // The one place a save leaves for the client. `confirmed`: the admin
      // accepted a warning (a name clash, or the server's held save).
      function sendSave(name, confirmed) {
        console.log('[RaceManager] Save Layout "' + name + '": handing '
          + $scope.routeWaypoints.length + ' checkpoint(s) to client Lua'
          + (confirmed ? ' (confirmed)' : ''));
        bngApi.engineLua('raceManager.saveLayout(' + luaStr(name)
          + ', ' + (confirmed ? 'true' : 'false') + ')');
      }

      // Case-insensitive, like the server: otherwise "Oval" looks new and
      // silently replaces "oval".
      function existingLayout(name) {
        var lower = (name || '').trim().toLowerCase();
        for (var i = 0; i < $scope.layouts.length; i++) {
          if (($scope.layouts[i].name || '').toLowerCase() === lower) { return $scope.layouts[i]; }
        }
        return null;
      }

      // Put a confirmation in front of the admin. `action` runs if they accept.
      function askLayout(text, ok, action) {
        $scope.layoutUi.confirm = { text: text, ok: ok, action: action };
      }
      $scope.confirmLayoutAction = function () {
        var c = $scope.layoutUi.confirm;
        $scope.layoutUi.confirm = null;
        if (c && c.action) { c.action(); }
      };
      $scope.cancelLayoutAction = function () {
        $scope.layoutUi.confirm = null;
      };

      // A name that is already taken is an overwrite wearing the wrong button,
      // so it asks rather than replacing quietly.
      $scope.saveLayout = function () {
        var name = ($scope.layoutUi.name || '').trim();
        if (!name) {
          console.warn('[RaceManager] Save Layout: no name entered, nothing sent');
          return;
        }
        if (!$scope.routeWaypoints.length) {
          console.warn('[RaceManager] Save Layout: no checkpoints placed, nothing sent');
          return;
        }
        var clash = existingLayout(name);
        if (clash) {
          askLayout('"' + clash.name + '" already exists on this map. Saving replaces it '
            + 'with what is placed right now (' + $scope.routeWaypoints.length + ' gates).',
            'Replace it', function () { sendSave(name, false); });
          return;
        }
        sendSave(name, false);
      };

      // Overwrite the SELECTED layout - no typed name needed, which is the point
      // of it: the common edit is load, tweak, put it back.
      $scope.overwriteLayout = function () {
        var name = $scope.layoutUi.selected;
        if (!name || !$scope.routeWaypoints.length) { return; }
        askLayout('Replace "' + name + '" with what is placed right now ('
          + $scope.routeWaypoints.length + ' gates)? The saved version is gone for good.',
          'Overwrite', function () { sendSave(name, false); });
      };

      $scope.deleteLayout = function () {
        var name = $scope.layoutUi.selected;
        if (!name) { return; }
        askLayout('Delete "' + name + '" from the server? This cannot be undone.',
          'Delete', function () {
            bngApi.engineLua('raceManager.deleteLayout(' + luaStr(name) + ')');
            if ($scope.layoutUi.selected === name) { $scope.layoutUi.selected = ''; }
          });
      };

      $scope.loadLayout = function () {
        if (!$scope.layoutUi.selected) { return; }
        console.log('[RaceManager] Load Layout "' + $scope.layoutUi.selected + '" requested');
        bngApi.engineLua('raceManager.loadLayout(' + luaStr($scope.layoutUi.selected) + ')');
      };

      // Nothing loaded: no race track, no derby arena, one press, confirmed first
      // (it clears what everybody sees). askLayout is reached by hoisting.
      $scope.clearEverything = function () {
        askLayout(
          'Clear the race track AND the derby arena for everyone? '
            + 'Saved layouts and arenas are not deleted.',
          'Clear everything',
          function () { bngApi.engineLua('raceManager.clearEverything()'); });
      };

      // Open in the editor: a private copy, so two admins can work at once; the
      // server's track stays put.
      $scope.editLayout = function () {
        if (!$scope.layoutUi.selected) { return; }
        console.log('[RaceManager] Edit Layout "' + $scope.layoutUi.selected + '" requested (private)');
        bngApi.engineLua('raceManager.loadLayout('
          + luaStr($scope.layoutUi.selected) + ', true)');
      };

      // --- Free practice --------------------------------------------------
      //
      // Two halves that never appear together: admins approve, drivers drive.

      // Admin: open or close a layout for practice, read off the server's list.
      $scope.practiceApproved = function (name) {
        for (var i = 0; i < $scope.layouts.length; i++) {
          if ($scope.layouts[i].name === name) { return $scope.layouts[i].practice === true; }
        }
        return false;
      };
      $scope.togglePracticeApproval = function () {
        var name = $scope.layoutUi.selected;
        if (!name) { return; }
        bngApi.engineLua('raceManager.setLayoutPractice('
          + luaStr(name) + ', ' + (!$scope.practiceApproved(name)) + ')');
      };

      // Driver: the practice picker, its own selection, or browsing would move an
      // admin's Load/Overwrite target.
      $scope.practice       = false;
      $scope.practiceLayout = null;
      $scope.practiceDone   = 0;
      $scope.practiceLeft   = null;
      $scope.practiceComplete = false;
      $scope.practiceUi = { selected: '', laps: 0 };
      // The laps run in THIS practice session, newest first, and the best of
      // them. Cleared whenever practice starts or stops: a time set on one track
      // means nothing on the next.
      $scope.practiceLaps = [];
      $scope.practiceBest = null;
      $scope.practiceIsBest = function (l) {
        return l && $scope.practiceBest !== null && l.time === $scope.practiceBest;
      };
      $scope.practiceLayouts = function () {
        var out = [];
        for (var i = 0; i < $scope.layouts.length; i++) {
          if ($scope.layouts[i].practice === true) { out.push($scope.layouts[i]); }
        }
        return out;
      };
      // Offered only when the server is idle. The server refuses otherwise, and
      // a button that is going to be refused should not look available.
      $scope.canPractice = function () {
        return $scope.phase === 'waiting' && !$scope.derbyActive();
      };
      $scope.practiceDropdownOpen = false;
      $scope.togglePracticeDropdown = function () {
        $scope.practiceDropdownOpen = !$scope.practiceDropdownOpen;
        if ($scope.practiceDropdownOpen) { revealDropdown('.rm-practice .rm-layout-menu'); }
      };
      $scope.selectPracticeLayout = function (l) {
        $scope.practiceUi.selected = l && l.name || '';
        $scope.practiceDropdownOpen = false;
      };
      $scope.startPractice = function () {
        if (!$scope.practiceUi.selected) { return; }
        bngApi.engineLua('raceManager.practiceLayout('
          + luaStr($scope.practiceUi.selected) + ')');
      };
      $scope.applyPracticeLaps = function () {
        var n = parseInt($scope.practiceUi.laps, 10);
        if (isNaN(n) || n < 0) { n = 0; }
        bngApi.engineLua('raceManager.setPracticeLaps(' + n + ')');
      };
      $scope.endPractice = function () {
        bngApi.engineLua('raceManager.endPractice()');
      };
      // GHOSTED OR SOLID while practising, the driver's choice and remembered.
      // Ghosted by default: a practice car is somebody else's obstacle. Sent on
      // load as the sound switch is, so the Lua side holds it before any start.
      $scope.practiceGhost = loadPref('practiceGhost', true) !== false;
      function pushPracticeGhost() {
        bngApi.engineLua('if raceManager and raceManager.setPracticeGhost then '
          + 'raceManager.setPracticeGhost(' + ($scope.practiceGhost ? 'true' : 'false') + ') end');
      }
      $scope.togglePracticeGhost = function () {
        $scope.practiceGhost = !$scope.practiceGhost;
        savePref('practiceGhost', $scope.practiceGhost);
        pushPracticeGhost();
      };
      pushPracticeGhost();

      // Keep an opened menu visible: it flips above its trigger when there is no
      // room below but room above (the app has a hard bottom edge), and scrolls
      // into the tab body otherwise. Measured against the app's own box.
      function revealDropdown(selector) {
        setTimeout(function () {
          var menu = $element[0].querySelector(selector);
          if (!menu) { return; }
          menu.classList.remove('rm-layout-menu-up');
          if (!menu.getBoundingClientRect) { return; }
          var host = $element[0].getBoundingClientRect();
          var box  = menu.getBoundingClientRect();
          var spaceBelow = host.bottom - box.top;
          var spaceAbove = box.bottom - box.height - host.top;
          if (box.bottom > host.bottom && spaceAbove > spaceBelow) {
            menu.classList.add('rm-layout-menu-up');
            return;                       // flipped: it is on screen already
          }
          if (menu.scrollIntoView) { menu.scrollIntoView({ block: 'nearest' }); }
        }, 0);
      }

      // The layout dropdown (not a <select>, see layoutDropdownOpen).
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
        // (the route is a circuit - after the last gate you cross gate 1 again).
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

        // Branch gates: a dashed spur to the checkpoint each one is another way
        // through, not a second ring.
        var alts = toArray(layout.branches);
        ctx.save();
        ctx.setLineDash([5, 4]);
        ctx.strokeStyle = 'rgba(51, 217, 242, 0.85)';
        ctx.lineWidth = 2;
        alts.forEach(function (g) {
          var gx = Number(g.x), gy = Number(g.y), sl = Number(g.slot);
          if (!isFinite(gx) || !isFinite(gy) || !isFinite(sl)) { return; }
          var pt = { x: gx, y: gy };
          var main = cps[sl - 1];
          if (main) {
            ctx.beginPath();
            ctx.moveTo(px(main), py(main));
            ctx.lineTo(px(pt), py(pt));
            ctx.stroke();
          }
          ctx.beginPath();
          ctx.arc(px(pt), py(pt), 3, 0, Math.PI * 2);
          ctx.fillStyle = '#33d9f2';
          ctx.fill();
        });
        ctx.restore();

        // Gate count caption in the corner.
        ctx.fillStyle = 'rgba(154, 160, 166, 0.8)';
        ctx.font = '10px "Noto Sans", sans-serif';
        ctx.textAlign = 'left';
        ctx.fillText(cps.length + ' gates'
          + (alts.length ? ' · ' + alts.length + ' branch' + (alts.length === 1 ? '' : 'es') : '')
          + ' · ' + (layout.map || ''), 6, H - 6);
      }

      // ------------------------------------------------------------------
      // Module 3: HUD ergonomics (size + background fade)
      // ------------------------------------------------------------------
      // Resize from the corner and fade the background; both persist.
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

      // One opacity for the whole app, on an object (ng-if child scopes).
      $scope.lbUi = { opacity: loadPref('opacity', 0.85) };   // 0 (invisible) .. 1 (solid)

      // START SOUNDS, played by lights.lua: beeps for the countdown, GET READY
      // and the drag tree, a tone for GO and the green. Remembered here.
      $scope.soundOn = loadPref('sound', true) !== false;
      var soundSent = false;
      function pushSound() {
        bngApi.engineLua('if raceManager and raceManager.lightsSetSound then '
          + 'raceManager.lightsSetSound(' + ($scope.soundOn ? 'true' : 'false') + ') end');
      }
      $scope.toggleSound = function () {
        $scope.soundOn = !$scope.soundOn;
        savePref('sound', $scope.soundOn);
        pushSound();
      };
      pushSound();

      // ------------------------------------------------------------------
      // Collapsing the HUD
      // ------------------------------------------------------------------
      // Collapse to the status line, never to nothing: the bar keeps the restore
      // button. Persisted; not on lbUi (a click handler sets it, not ng-model).
      $scope.hudCollapsed = loadPref('collapsed', false) === true;

      // Setup out of the way while a session runs, for admins too (drivers have
      // had it since minimalMode). A remembered preference.
      $scope.autoSlim = loadPref('autoSlim', true) === true;
      $scope.toggleAutoSlim = function () {
        $scope.autoSlim = !$scope.autoSlim;
        savePref('autoSlim', $scope.autoSlim);
      };
      // Is the setup body hidden right now? The tab row goes with it, because a
      // row of tabs over nothing is a row of height buying nothing.
      $scope.setupHidden = function () {
        return $scope.isAdmin && $scope.autoSlim && $scope.sessionLive();
      };
      $scope.toggleCollapsed = function () {
        $scope.hudCollapsed = !$scope.hudCollapsed;
        savePref('collapsed', $scope.hudCollapsed);
      };

      // Each resizable panel has its own keys: the same pixels mean a different
      // size on each. `replace: true` makes $element[0] the .rm-root.
      var PANELS = {
        leaderboard: {
          el: function () { return $element[0].querySelector('.rm-table-wrap'); },
          wKey: 'width',    hKey: 'height',    minW: 200, minH: 80
        },
        hud: {
          el: function () { return $element[0]; },
          wKey: 'hudWidth', hKey: 'hudHeight', minW: 240, minH: 100
        },
        // A broadcast board is sized to a stream, so its own keys too.
        broadcast: {
          el: function () { return $element[0].querySelector('.rm-broadcast-board'); },
          wKey: 'bcWidth',  hKey: 'bcHeight',  minW: 260, minH: 90
        }
      };
      // px, null = follow the app window.
      var panelSize = {
        leaderboard: { w: loadPref('width', null),    h: loadPref('height', null) },
        hud:         { w: loadPref('hudWidth', null), h: loadPref('hudHeight', null) },
        broadcast:   { w: loadPref('bcWidth', null),  h: loadPref('bcHeight', null) }
      };

      // One style object per panel, rebuilt only on change: ngStyle's
      // $watchCollection is cheap on the SAME reference. Never mutate it.
      var styleCache = { leaderboard: null, hud: null, broadcast: null };
      var styleOpacity = null;

      function invalidatePanelStyles() {
        styleCache.leaderboard = null;
        styleCache.hud = null;
        styleCache.broadcast = null;
      }

      function panelStyle(name) {
        var o = Number($scope.lbUi.opacity);
        // The slider is shared by all three, so its move drops all three.
        if (o !== styleOpacity) { styleOpacity = o; invalidatePanelStyles(); }
        var style = styleCache[name];
        if (style) { return style; }
        var size = panelSize[name];
        style = { 'background-color': 'rgba(15, 17, 22, ' + o + ')' };
        if (size.w) { style.width = size.w + 'px'; }
        if (size.h) {
          style.height = size.h + 'px';
          style['max-height'] = size.h + 'px';
        }
        styleCache[name] = style;
        return style;
      }
      // Applied to the leaderboard container in minimal (driver) mode.
      $scope.lbStyle = function () { return panelStyle('leaderboard'); };
      // Applied to the app root everywhere else - admins on any tab, and
      // drivers outside a live session.
      $scope.hudStyle = function () { return panelStyle('hud'); };
      // ...and to the broadcast board, which is the whole app while it is on.
      $scope.bcStyle = function () { return panelStyle('broadcast'); };

      $scope.applyOpacity = function () { savePref('opacity', Number($scope.lbUi.opacity)); };

      // Every element with its own background follows the slider (the panel
      // fill, the header band and its border), through custom properties set on
      // the element: jqLite's .css() drops a --custom-prop.
      $scope.$watch('lbUi.opacity', function (op) {
        var o = Number(op);
        var css = $element[0].style;
        css.setProperty('--rm-panel-bg', 'rgba(15, 17, 22, ' + o + ')');
        // The header's tint and rule. Their alphas are the ones the stylesheet
        // used to hardcode, scaled by the slider so they fade in step.
        css.setProperty('--rm-accent-bg', 'rgba(255, 102, 0, ' + (o * 0.15) + ')');
        css.setProperty('--rm-accent-line', 'rgba(255, 102, 0, ' + (o * 0.5) + ')');
        // THE GRAYS LIFT AS THE FILL FADES. Tuned for a dark panel at the 0.85
        // default; below that they sit on the road and disappear.
        var t = Math.min(Math.max((0.85 - o) / 0.85, 0), 1);
        css.setProperty('--rm-muted', mixRgb([154, 160, 166], [232, 234, 237], t));
        css.setProperty('--rm-soft',  mixRgb([189, 193, 198], [241, 243, 244], t));
        css.setProperty('--rm-faint', mixRgb([95, 99, 104], [189, 193, 198], t));
        $element[0].classList.toggle('rm-see-through', o < 0.6);
      });
      function mixRgb(a, b, t) {
        return 'rgb(' + Math.round(a[0] + (b[0] - a[0]) * t) + ', '
          + Math.round(a[1] + (b[1] - a[1]) * t) + ', '
          + Math.round(a[2] + (b[2] - a[2]) * t) + ')';
      }

      // The board's measured size, for the driver bar and overlays. ONE
      // DIRECTION, board to bar (root-from-board converged on zero). Set directly
      // (jqLite drops --custom-props). A ResizeObserver, not a measuring $watch:
      // that forced 30+ layouts a second during live sessions.
      function measureBoard() {
        var board = $element[0].querySelector('.rm-table-wrap');
        var bar   = $element[0].querySelector('.rm-driverbar');
        var w = board ? board.offsetWidth : 0;
        var h = (board ? board.offsetHeight : 0) + (bar ? bar.offsetHeight : 0);
        // 'auto' rather than 0 while there is nothing to measure: a bar with no
        // width is a bar nobody can find the login button on.
        $element[0].style.setProperty('--rm-lb-width', w > 0 ? (w + 'px') : 'auto');
        $element[0].style.setProperty('--rm-lb-height', h > 0 ? (h + 'px') : 'auto');
      }

      var boardObserver = null;
      if (typeof ResizeObserver === 'function') {
        boardObserver = new ResizeObserver(measureBoard);
        // An identity check (querySelector forces no layout): has ng-if swapped
        // the board out? The observer answers size.
        $scope.$watch(function () {
          return $scope.minimalMode()
            ? $element[0].querySelector('.rm-table-wrap')
            : null;
        }, function (board) {
          boardObserver.disconnect();
          if (!board) { measureBoard(); return; }
          boardObserver.observe(board);
          var bar = $element[0].querySelector('.rm-driverbar');
          if (bar) { boardObserver.observe(bar); }
          measureBoard();
        });
      } else {
        // FALLBACK for a CEF with no ResizeObserver, the expensive way: KEPT, or
        // the driver bar loses its width.
        $scope.$watch(function () {
          if (!$scope.minimalMode()) { return ''; }
          var board = $element[0].querySelector('.rm-table-wrap');
          var bar   = $element[0].querySelector('.rm-driverbar');
          var w = board ? board.offsetWidth : 0;
          var h = (board ? board.offsetHeight : 0) + (bar ? bar.offsetHeight : 0);
          return w + 'x' + h;
        }, measureBoard);
      }



      // The HUD app host clips this app and only its layout editor can enlarge
      // it, so the grip stops at the host's edge.
      function hostBox() {
        var host = $element[0].parentElement;
        if (host && host.getBoundingClientRect) {
          var r = host.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) { return r; }
        }
        // Standalone (no HUD host): the viewport is the only limit.
        return { right: window.innerWidth, bottom: window.innerHeight };
      }

      var resizeFrom = null;
      function onResizeMove(ev) {
        if (!resizeFrom) { return; }
        var panel = resizeFrom.panel;
        var w = Math.max(panel.minW, resizeFrom.w + (ev.clientX - resizeFrom.x));
        var h = Math.max(panel.minH, resizeFrom.h + (ev.clientY - resizeFrom.y));
        w = Math.min(w, resizeFrom.maxW);
        h = Math.min(h, resizeFrom.maxH);
        $scope.$evalAsync(function () {
          panelSize[resizeFrom.name].w = Math.round(w);
          panelSize[resizeFrom.name].h = Math.round(h);
          invalidatePanelStyles();
        });
      }
      function onResizeEnd() {
        document.removeEventListener('mousemove', onResizeMove);
        document.removeEventListener('mouseup', onResizeEnd);
        if (resizeFrom) {
          var size = panelSize[resizeFrom.name];
          savePref(resizeFrom.panel.wKey, size.w);
          savePref(resizeFrom.panel.hKey, size.h);
        }
        resizeFrom = null;
      }
      // Grip in the bottom-right corner of the panel. Listeners go on the
      // document so the drag keeps tracking even when the pointer leaves the
      // (small) grip element.
      function startResize(name, ev) {
        var panel = PANELS[name];
        var el = panel.el();
        if (!el) { return; }
        ev.preventDefault();
        ev.stopPropagation();
        var rect = el.getBoundingClientRect();
        var host = hostBox();
        resizeFrom = {
          name: name, panel: panel,
          x: ev.clientX, y: ev.clientY, w: rect.width, h: rect.height,
          // Room left between the panel's own top-left and the host's edges.
          maxW: Math.max(panel.minW, host.right - rect.left),
          maxH: Math.max(panel.minH, host.bottom - rect.top)
        };
        document.addEventListener('mousemove', onResizeMove);
        document.addEventListener('mouseup', onResizeEnd);
      }
      $scope.startLeaderboardResize = function (ev) { startResize('leaderboard', ev); };
      $scope.startHudResize         = function (ev) { startResize('hud', ev); };
      $scope.startBroadcastResize   = function (ev) { startResize('broadcast', ev); };

      function resetSize(name) {
        panelSize[name].w = null;
        panelSize[name].h = null;
        invalidatePanelStyles();
        savePref(PANELS[name].wKey, null);
        savePref(PANELS[name].hKey, null);
      }
      $scope.resetLeaderboardSize = function () { resetSize('leaderboard'); };
      $scope.resetHudSize         = function () { resetSize('hud'); };
      $scope.resetBroadcastSize   = function () { resetSize('broadcast'); };

      // The HUD app slot broadcasts this whenever the layout editor resizes
      // our window. A size stored from a bigger window would now hang past the
      // clip edge, leaving the grip stranded out of reach, so pull it back in.
      function clampStored(name, maxW, maxH) {
        var size = panelSize[name], panel = PANELS[name];
        if (size.w && maxW > 0 && size.w > maxW) {
          size.w = Math.max(panel.minW, Math.round(maxW));
          savePref(panel.wKey, size.w);
        }
        if (size.h && maxH > 0 && size.h > maxH) {
          size.h = Math.max(panel.minH, Math.round(maxH));
          savePref(panel.hKey, size.h);
        }
        invalidatePanelStyles();
      }
      $scope.$on('app:resized', function (ev, size) {
        if (!size) { return; }
        clampStored('hud', size.width, size.height);
        clampStored('leaderboard', size.width, size.height);
        clampStored('broadcast', size.width, size.height);
      });

      $scope.$on('$destroy', function () {
        document.removeEventListener('mousemove', onResizeMove);
        document.removeEventListener('mouseup', onResizeEnd);
        // The queue goes with the timer. A teardown that stopped the clock but
        // left eight notices waiting would show all of them the moment the app
        // came back, timestamped to a session that has since ended.
        if (noticeTimer) { clearTimeout(noticeTimer); noticeTimer = null; }
        noticeQueue.length = 0;
        // The drag listeners are on the root element, not on a row, so they
        // outlive every ng-repeat rebuild -- which is the point of delegating
        // them, and also why they have to be taken off by hand here.
        $element[0].removeEventListener('mousedown', onDragDown);
        document.removeEventListener('mousemove', onDragMove, true);
        document.removeEventListener('mouseup', onDragUp, true);
        if (vehErrTimer) { clearTimeout(vehErrTimer); }
        if (goTimer) { clearTimeout(goTimer); }
        // The size observer holds the board and the bar, which the HUD teardown
        // is about to throw away.
        if (boardObserver) { boardObserver.disconnect(); boardObserver = null; }
        stopLapTicker();
        // Going away: no editor is open, so Lua stops drawing its furniture.
        bngApi.engineLua('raceManager.setEditorOpen(false)');
        bngApi.engineLua('raceManager.setDerbyEditorOpen(false)');
      });

      // ------------------------------------------------------------------
      // Lifecycle: load the backend and pull current state immediately so the
      // window is never blank, even before the first server broadcast.
      // ------------------------------------------------------------------
      // requestState also pulls the map-filtered layout list from the server.
      bngApi.engineLua('extensions.load("raceManager"); raceManager.requestState()');
      // Demo Derby module: pull its state separately (isolated channel).
      bngApi.engineLua('raceManager.derbyRequestState()');
      // And the ladder, for everybody: it is pushed only on change, and a driver
      // has no tab to pull it from.
      bngApi.engineLua('raceManager.dragRequestState()');
      // Re-assert the editor flags on mount (Lua was told "closed" on teardown).
      pushEditorOpen();
    }]
  };
}]);
