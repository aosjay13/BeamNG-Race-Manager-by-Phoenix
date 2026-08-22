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

      // Settings inputs (host).
      //
      // These live on an OBJECT, not as bare scope primitives, and that is not
      // cosmetic: every settings control sits inside `ng-if="isAdmin"`, and an
      // ng-if creates a child scope. Binding `ng-model="lapsInput"` there would
      // write the typed value onto the ng-if child scope, shadowing the
      // controller's own `lapsInput` - so "Set" would post the stale default to
      // the server and the server's echo back would never reach the input the
      // admin is looking at. Going through `settingsUi.*` resolves the object on
      // the controller scope and mutates it in place, so both directions work.
      $scope.settingsUi = {
        laps: 5,
        resets: -1,            // -1 unlimited, 0 none, N per driver per session
        width: 20,             // checkpoint rectangle: lateral span
        height: 8,             // metres the gate rises ABOVE where it was placed
        depth: 2,              // metres it drops BELOW; the two are independent
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
      $scope.jokerGates = 0;      // joker gates the LOADED TRACK has (server's count)
      $scope.jokerRoute = [];     // joker gates placed/loaded on this client
      $scope.jokerNext = 1;
      $scope.jokerTaken = false;
      $scope.jokerLap = null;
      // Which list the checkpoint editor appends to and shows. Three targets:
      // the main lap, the joker route and the starting grid. Anything else is
      // not a target the client Lua knows about, so it falls back to the main
      // lap - the same normalisation raceManager.setEditorTarget applies.
      // Every tab the editor offers. A tab missing from here silently falls back
      // to the main route, which looks like the button doing nothing.
      var EDITOR_TARGETS = { main: true, joker: true, pit: true, start: true,
                             branch: true, marker: true };
      function editorTargetOf(value) {
        return EDITOR_TARGETS[value] ? value : 'main';
      }
      $scope.editorTarget = 'main';
      $scope.nudgeOn = false;
      $scope.nudgeSel = null;
      // Branch gates: the other ways through a checkpoint. Each carries the
      // checkpoint it belongs to and never adds one, so driving through either
      // gate clears the same slot - which is why the leaderboard needs no lane
      // arithmetic at all, and why nothing here tracks which way a driver went.
      $scope.branches = [];        // [{ slot, x, y, z, ... }]
      // Direction markers: signage for long point-to-point stages. Non-functional
      // by design -- nothing arms them, nothing scores them.
      $scope.markers = [];         // [{ x, y, z, hx, hy, kind, ... }]
      $scope.markerKind = 'right'; // the symbol the next placed marker gets
      $scope.markerKinds = [];     // symbol keys, in the order the panel offers them
      $scope.markerLabels = {};    // key -> human label, both from the extension
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
      $scope.garage = [];             // [{ model, label }]
      $scope.garageEnforce = false;
      // Race entry: everyone connected is in the field by default, and an admin
      // can switch to opt-in when it should be a subset of who is on the server.
      // Only ever a mirror of the server's answer - this is the value the panel
      // shows for the fraction of a second before the first broadcast lands.
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
      // Does the session on track open with an out lap - one trip past the line
      // that is not timed and does not count? Mirrored from the server (it is
      // off on a point-to-point stage, which is driven once) and shown as a
      // header badge, so a spectator or an admin can see which rules the session
      // is running under. Whether THIS driver is on theirs right now is a
      // separate question, answered by the lap clock feed below, which is
      // instant rather than a broadcast behind.
      $scope.qualiOutLap = false;
      // FORCED SPECTATOR: the car has been removed and the view is in freecam.
      // A finisher and a driver serving a penalty are both here without having
      // opted out of anything, so this must never be read as an entry decision.
      // It used to be the same variable, and every route push overwrote the
      // entry decision with it, which is what made Rejoin look broken.
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
      $scope.lapLive = null;   // { elapsed, at, lap }: last push + when it landed
      $scope.lapHold = null;   // { lapTime, lap, until }: completed time on hold
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
      // Is this driver on the out lap right now? The lap clock feed carries it,
      // which is what makes this instant: the bridge knows the moment the car
      // crosses the line, while the driver row that also carries it arrives on a
      // broadcast up to a third of a second later. A readout still reading NOT
      // TIMED into a lap that is being timed is the one error this must not make.
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

      // A lap just completed: hold its time on screen. The live clock above is
      // already counting the new lap - this only parks a copy of the old one.
      //
      // An out lap arrives here with NO time, deliberately: it was not timed, so
      // there is nothing to hold, and the slot says what the lap was instead. A
      // time shown for it - even a greyed-out one - is a number a driver will
      // try to beat.
      $scope.$on('RaceManagerLapDone', function (event, data) {
        if (!data) { return; }
        if (!data.outLap && typeof data.lapTime !== 'number') { return; }
        $scope.$evalAsync(function () {
          $scope.lapHold = {
            lapTime: data.outLap ? null : data.lapTime,
            outLap: !!data.outLap,
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
      // CLOSED until somebody asks for it.
      //
      // It used to open itself, which was fine while it was also suppressed for
      // the whole of a live session -- the two wrongs cancelled. Removing that
      // suppression (it was a dead end: the button that opens the panel lives in
      // the driver bar, which only exists in that mode) left it opening itself
      // over the top of a race instead. A login prompt is something you go and
      // get: the lock button in the driver bar and the one in the header both
      // fetch it, and nothing else needs to.
      $scope.showLogin = false;      // is the login prompt visible?
      $scope.loginPinned = false;    // user explicitly asked to see login
      $scope.pwMsg = null;           // transient confirmation after a password change

      // ----------------------------------------------------------------
      // Admin panel tabs
      // ----------------------------------------------------------------
      // Every admin panel used to render stacked, one under the other. That
      // overflowed the app window - .rm-root is overflow:hidden and only the
      // leaderboard scrolls, so anything past the bottom edge was unreachable,
      // and with the editor and derby panels both open it was most of them.
      // One panel shows at a time now; the tab body scrolls as a safety net so
      // a long gate list or a full derby table can't clip at a small size.
      //
      // Those panels are now grouped by MODE first. Race and Derby are two
      // independent game modes that share nothing but the entry list, and a flat
      // tab strip put four race panels and one derby panel side by side - so the
      // race session controls and the track layout picker sat above the Derby
      // tab, offering an admin a Load Layout button for a race they were not
      // setting up. Mode picks the world; the sub-tabs below pick the panel
      // within it.
      var MODES = { race: true, derby: true, admin: true };
      var MODE_TABS = {
        // Cup sits under Race rather than beside it as a fourth mode: a cup is
        // a property of a race night, not a parallel game mode the way a derby
        // is. Nothing in it applies to a derby, and it wraps the races that the
        // other tabs here configure.
        race:  { race: true, quali: true, cup: true, garage: true, editor: true },
        derby: { derby: true, editor: true },
        admin: { admin: true }
      };
      var DEFAULT_TAB = { race: 'race', derby: 'derby', admin: 'admin' };

      function modeOf(value) { return MODES[value] ? value : 'race'; }
      function adminTabOf(mode, value) {
        return MODE_TABS[mode][value] ? value : DEFAULT_TAB[mode];
      }
      // Persisted so an admin returns to the panel they were working in - and
      // per mode, so switching to Derby and back lands on the race panel they
      // left rather than resetting to the first one.
      // (loadPref/savePref are declared further down; both are hoisted function
      // declarations, so calling them here is safe.)
      $scope.mode = modeOf(loadPref('adminMode', 'race'));
      $scope.adminTab = adminTabOf($scope.mode,
        loadPref('adminTab.' + $scope.mode, DEFAULT_TAB[$scope.mode]));
      $scope.isMode = function (mode) { return $scope.mode === mode; };
      $scope.isAdminTab = function (tab) { return $scope.adminTab === tab; };

      // RUNNING A RACE, OR CONFIGURING ONE.
      //
      // These two replace fourteen copies of "phase === 'countdown' || phase
      // === 'racing'" spread through the markup, and the copies were wrong the
      // same way fourteen times: every one of them missed QUALIFYING, so the
      // whole editor stayed live for the length of a qualifying session. 'grid'
      // was missed too, where the field is already placed and frozen on its
      // slots and a gate moving under a parked car is the same mistake as one
      // moving under a car at speed.
      //
      // canEdit is the CAPABILITY, and it is the seam a permissions system
      // plugs into later: the markup asks whether this thing may be done, not
      // who is doing it or what the phase happens to be called. The matching
      // gate in Lua (edit.canConfigure) is what actually enforces it -- this
      // half only decides what the panel offers, and a disabled button has
      // never stopped anybody who can reach the console.
      $scope.sessionRunning = function () {
        return $scope.phase === 'grid' || $scope.phase === 'countdown'
            || $scope.phase === 'racing' || $scope.phase === 'qualifying';
      };
      // TWO GATES, because they are protecting two different things.
      //
      // canEdit is about GEOMETRY: placing, moving, resizing and reordering
      // gates. It includes 'grid', where the field is already placed and frozen
      // on its slots -- a gate moving under a parked car is the same mistake as
      // one moving under a car at speed.
      //
      // canSetRules is about the RULES: laps, the reset allowance and mode, the
      // joker, the qualifying limits, the grid mode, and which track is loaded.
      // Those are fine to change while a grid is formed and nobody has moved,
      // and the SERVER has always agreed -- every one of those handlers is gated
      // on sessionUnderWay(), which is countdown, racing and qualifying and has
      // never included 'grid'.
      //
      // Folding them into one predicate disabled a row of controls the server
      // would happily have accepted, which took away adjusting the rules on the
      // grid without leaving the race. The bug that was actually worth fixing is
      // still fixed: both of these name QUALIFYING, which every one of the
      // fourteen hand-written guards had missed.
      $scope.canEdit = function () {
        return $scope.isAdmin && !$scope.sessionRunning();
      };
      $scope.canSetRules = function () {
        return $scope.isAdmin
          && $scope.phase !== 'countdown'
          && $scope.phase !== 'racing'
          && $scope.phase !== 'qualifying';
      };
      // Both editors are render gates in Lua, which has no idea whether its panel
      // is on screen. Tell it, so authoring furniture - start-slot outlines, gate
      // rectangles, arena corner labels - stays in the editor instead of being
      // drawn for every driver on the server.
      //
      // The two are pushed together and are mutually exclusive by construction:
      // one Editor sub-tab exists per mode, and only one mode is ever open.
      function pushEditorOpen() {
        // BROADCAST MODE COUNTS AS CLOSED. The panel is gone from the DOM there,
        // but the drawing it gates lives in the world and Lua only hears about
        // the panel -- so an admin broadcasting from the Editor tab would stream
        // gate rectangles and start-slot outlines over the race.
        var editing = $scope.isAdmin && $scope.adminTab === 'editor'
          && !$scope.broadcastMode();
        var race  = editing && $scope.mode === 'race';
        var derby = editing && $scope.mode === 'derby';
        bngApi.engineLua('raceManager.setEditorOpen(' + (!!race) + ')');
        bngApi.engineLua('raceManager.setDerbyEditorOpen(' + (!!derby) + ')');
      }
      // Panels that need a nudge as they re-enter the DOM: the track preview
      // canvas has to be drawn once it exists, and the derby module pulls its
      // state over its own channel.
      function afterTabChange() {
        pushEditorOpen();
        if ($scope.mode === 'race' && $scope.adminTab === 'editor') { schedulePreview(); }
        if ($scope.mode === 'derby') {
          bngApi.engineLua('raceManager.derbyRequestState()');
        }
        // The cup is pushed only when it changes, so a panel opened long after
        // the last change would otherwise render an empty table until the next
        // race finished. Same reason the derby pulls its own state here.
        if ($scope.mode === 'race' && $scope.adminTab === 'cup') {
          bngApi.engineLua('raceManager.cupRequestState()');
        }
      }
      $scope.selectMode = function (mode) {
        $scope.mode = modeOf(mode);
        savePref('adminMode', $scope.mode);
        $scope.adminTab = adminTabOf($scope.mode,
          loadPref('adminTab.' + $scope.mode, DEFAULT_TAB[$scope.mode]));
        afterTabChange();
      };
      $scope.selectAdminTab = function (tab) {
        $scope.adminTab = adminTabOf($scope.mode, tab);
        savePref('adminTab.' + $scope.mode, $scope.adminTab);
        afterTabChange();
      };

      // Checkpoint editor state
      $scope.routeWaypoints = [];
      $scope.nextWp = 1;
      $scope.visualize = true;
      $scope.editorMsg = null;
      // Per-checkpoint override editor: which gate (1-based) is selected, plus
      // its edit fields. Blank fields mean "use the global default".
      $scope.selectedCp = null;
      $scope.cpEdit = { width: '', height: '', depth: '' };

      // Track layout state (server-side persistent layouts, current map only)
      $scope.layouts = [];              // [{ name, map, width, checkpoints }]
      $scope.layoutMap = '';            // map the server filtered the list by
      // Bound as an object ("dot rule") because these inputs live inside the
      // ng-if editor panel, whose child scope would shadow primitive bindings.
      // `confirm` holds the pending destructive action: { text, ok, action }.
      // Null whenever nothing is being asked.
      $scope.layoutUi = { name: '', selected: '', confirm: null };
      // The layout picker is a custom DOM dropdown, not a native <select>:
      // BeamNG's UI runs in Chromium Embedded Framework (CEF), where a native
      // <select> popup is a separate OS window that never renders over the game
      // surface - the box shows a value but clicking it does nothing. We open
      // and close this menu ourselves so it lives inside the app's own DOM.
      $scope.layoutDropdownOpen = false;

      // ----------------------------------------------------------------
      // CUP / SERIES POINTS - mirrored from RM_CupUpdate, its own channel.
      //
      // Everything here is read-only state from the server. The panel never
      // computes a total or decides a position: it renders the standings it is
      // sent, and sends the admin's edits back. That is the same split the
      // server side keeps, and it is what stops the app and the plugin from
      // ever disagreeing about who is leading.
      // ----------------------------------------------------------------
      $scope.cup = {
        enabled: false,
        name: '',
        round: 0,              // rounds scored so far; the next race is round + 1
        preset: '',            // key of the active preset, or 'custom'
        racePoints: [],        // position -> points; past the end scores nothing
        // Derbies score on a table of their own: a cup may be all races, all
        // derbies or a mixture, and lasting eight minutes in a banger is not
        // the same achievement as winning a ten-lap race.
        derbyPreset: '',
        derbyPoints: [],       // empty = derbies do not score
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
      // Dot rule: every one of these lives inside the ng-if cup panel, whose
      // child scope would shadow a bare primitive.
      //
      // `points` and `quali` are edit buffers, not mirrors. They are only
      // re-seeded from the server when the admin is not mid-edit (see
      // cupSeedEditors), because a broadcast landing between two keystrokes
      // must not wipe a table being typed.
      $scope.cupUi = {
        name: '',
        // Name typed into "Save as". Initialised here so the object owns it
        // before any child scope can shadow it.
        saveName: '',
        preset: '',
        derbyPreset: '',
        points: [],
        derby: [],
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
        // Which standings table is on screen. A mixed cup contains a race
        // championship and a derby championship as well as an overall one, and
        // three narrow tables read far better in a HUD-sized window than one
        // very wide one.
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
      // "Differs from the server", which is what the Apply buttons key off. An
      // unseeded buffer is not an edit, so these all read clean until the first
      // broadcast has filled the fields - otherwise Apply would be live over
      // blank inputs.
      $scope.cupPointsDirty = function () {
        return cupTableDiffers($scope.cupUi.points, $scope.cup.racePoints);
      };
      $scope.cupDerbyDirty = function () {
        return cupTableDiffers($scope.cupUi.derby, $scope.cup.derbyPoints);
      };
      $scope.cupQualiDirty = function () {
        return cupTableDiffers($scope.cupUi.quali, $scope.cup.qualiPoints);
      };
      $scope.cupBonusDirty = function () {
        for (var i = 0; i < $scope.cup.bonuses.length; i++) {
          var b = $scope.cup.bonuses[i];
          if (Number($scope.cupUi.bonus[b.key] || 0) !== Number(b.value || 0)) {
            return true;
          }
        }
        return false;
      };

      // What the server last told us each editable thing was.
      //
      // Re-seeding the boxes cannot simply be "unless the buffer differs from
      // the server", because that question has two very different answers with
      // the same symptom:
      //
      //   * the admin is part way through typing  -> leave the boxes alone
      //   * the server's own value has changed     -> the boxes MUST follow
      //
      // Comparing buffer against server conflates them, and the second case is
      // what Load is: it replaces the table on the server, which then looks
      // exactly like an edit in progress, so the boxes were left showing the
      // old preset. Pressing Apply afterwards sent those stale numbers straight
      // back and the server correctly marked the table hand-edited -- which is
      // why loading a preset appeared to do nothing and then turned itself into
      // "Custom".
      //
      // Remembering what the server last said separates the two: if that has
      // moved, the server changed and the buffer follows; if it has not, any
      // difference is the admin's typing and is left alone.
      var cupSeen = { race: null, derby: null, quali: null, bonus: null,
                      preset: null, derbyPreset: null };

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
      }

      // Take the server's next answer for one table whatever it is, discarding
      // whatever is in the box. Used by the controls that ASK the server to
      // replace a table: loading a preset that is already active leaves the
      // server value unchanged, and without this the boxes would keep local
      // edits the admin had just asked to overwrite.
      function cupExpectReseed(which) { cupSeen[which] = null; }

      // Cup dropdowns.
      //
      // Custom DOM menus rather than a native <select>, for the reason the
      // track-layout picker already documents: BeamNG's UI is Chromium Embedded
      // Framework, where a <select> popup is a separate OS window that never
      // renders over the game surface. The box shows its value and clicking it
      // does nothing at all -- which is exactly how these shipped, because a
      // native select works perfectly in a desktop browser and so nothing
      // caught it until the panel was opened in the game.
      //
      // One flag for all of them, keyed by name, so only one menu is ever open:
      // 'race', 'derby', or 'bind:<pid>' for a connected driver's picker.
      $scope.cupOpenMenu = null;
      $scope.cupMenuOpen = function (key) { return $scope.cupOpenMenu === key; };
      $scope.cupToggleMenu = function (key) {
        $scope.cupOpenMenu = ($scope.cupOpenMenu === key) ? null : key;
        if ($scope.cupOpenMenu) { revealDropdown('.rm-cup .rm-layout-menu'); }
      };
      $scope.cupPickPreset = function (which, preset) {
        if (which === 'derby') { $scope.cupUi.derbyPreset = preset.key; }
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
      // Two different questions, and they need two different answers.
      //
      //   *Label()  -- what the server is actually scoring with. The summary
      //               line reports this, and it must not move because somebody
      //               opened a menu.
      //   *Pick()   -- what is currently chosen in the dropdown, which is what
      //               its own closed box has to show. A picker that still reads
      //               "30P Aggressive" after you picked "35P Folk Race" looks
      //               like it ignored the click; the native <select> this
      //               replaced showed the pick immediately, and so does this.
      $scope.cupPresetLabel = function () { return cupLabelFor($scope.cup.preset); };
      $scope.cupDerbyPresetLabel = function () { return cupLabelFor($scope.cup.derbyPreset); };
      $scope.cupPresetPick = function () {
        return cupLabelFor($scope.cupUi.preset || $scope.cup.preset);
      };
      $scope.cupDerbyPresetPick = function () {
        return cupLabelFor($scope.cupUi.derbyPreset || $scope.cup.derbyPreset);
      };
      // How deep each table actually pays, which is the one number an admin
      // needs to sanity-check a preset against their field size.
      $scope.cupScoringDepth = function () { return $scope.cup.racePoints.length; };
      $scope.cupDerbyDepth = function () { return $scope.cup.derbyPoints.length; };
      $scope.cupQualiEnabled = function () { return $scope.cup.qualiPoints.length > 0; };
      $scope.cupDerbyEnabled = function () { return $scope.cup.derbyPoints.length > 0; };
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

      // Which standings table is showing, and how it is ordered. Every number
      // in it is the server's; only the choice of column and the sort key are
      // decided here, and the server sends a ready-made position for each of
      // the three orderings so even the ranking rule lives in one place.
      $scope.cupSetView = function (v) { $scope.cupUi.view = v; };
      $scope.cupIsView = function (v) { return $scope.cupUi.view === v; };
      $scope.cupSortKey = function () {
        if ($scope.cupUi.view === 'race')  { return 'racePos'; }
        if ($scope.cupUi.view === 'derby') { return 'derbyPos'; }
        return 'pos';
      };
      // Has this cup actually seen both kinds of event? A cup of nothing but
      // races has no reason to offer a derby table, and vice versa.
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
      $scope.cupIsMixed = function () {
        return $scope.cupHasRaces() && $scope.cupHasDerbies();
      };

      $scope.cupStart = function () {
        bngApi.engineLua('raceManager.cupStart("'
          + String($scope.cupUi.name || '').replace(/"/g, '') + '")');
        $scope.cupUi.confirmReset = false;
      };
      $scope.cupSetEnabled = function (on) {
        bngApi.engineLua('raceManager.cupSetEnabled(' + (!!on) + ')');
      };
      $scope.cupToggleEnabled = function () { $scope.cupSetEnabled(!$scope.cup.enabled); };
      // Two presses, because one press destroys a season's worth of points.
      // Clear Results Cache is behind the same pattern for the same reason.
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
      // Saving the current race table as a named system.
      //
      // A saved system joins the SAME picker the built-ins are in, rather than
      // getting a list of its own: from the admin's side "load 25P Moderate" and
      // "load the table we agreed last month" are the same action, and the
      // server marks which ones it made so only those offer Delete.
      // ON cupUi, NOT a bare scope property. Every control here sits inside
      // ng-if="cup.enabled && cupUi.showScoring", which makes a CHILD scope: a
      // bare ng-model would write the typed name onto that child, leaving the
      // controller's copy empty and Save sending nothing. Going through the
      // object resolves it on the controller and mutates it in place.
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

      // A points table crosses to Lua as a comma-separated string rather than a
      // structure. Every other command in this app passes numbers and strings,
      // and a table would mean serialising one into a Lua literal by hand --
      // more ways to be wrong than a list of integers is worth. The client
      // bridge parses it back into an array.
      //
      // Trailing zeroes are dropped on the way out: a position past the end of
      // the table scores nothing anyway, so "25,18,15" and the same followed by
      // twenty-one zeroes are the same scoring system, and the short form is
      // what the panel gets back.
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
      // The spinner grid is fine for changing ONE position and miserable for
      // entering a system: twenty-four boxes, each a click-click-click, and no
      // way to see the shape of what you have typed. A points table is a list of
      // numbers and reads perfectly well as one.
      //
      // The line and the boxes are the SAME buffer, in both directions. Typing
      // in the line fills the boxes, nudging a box rewrites the line, and Apply
      // sends whatever is in the buffer either way -- so neither is a second
      // source of truth and there is no "which one wins" to get wrong.
      //
      // Nothing new crosses to Lua: cupCsv already built exactly this string for
      // the Apply path, and the bridge already parses it back. This is the same
      // format, shown to the admin instead of hidden from them.
      function cupParseCsv(text, buffer) {
        var parts = String(text || '').split(/[^0-9]+/);
        var n = 0;
        for (var i = 0; i < parts.length && n < CUP_EDIT_POSITIONS; i++) {
          if (parts[i] !== '') { buffer[n++] = Math.min(9999, Math.floor(Number(parts[i]))); }
        }
        // Anything the typed line did not reach scores nothing. Without this a
        // shorter line would leave the tail of a longer previous table standing
        // underneath it, which is the one way this could silently pay points
        // nobody entered.
        while (n < CUP_EDIT_POSITIONS) { buffer[n++] = 0; }
      }

      // Split out so the three tables share one implementation rather than
      // three that drift. `which` names the buffer and the label only.
      var CUP_TABLES = { race: 'points', derby: 'derby', quali: 'quali' };
      $scope.cupLine = { race: '', derby: '', quali: '' };

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
      $scope.cupApplyQuali = function () {
        bngApi.engineLua('raceManager.cupSetQualiPoints("' + cupCsv($scope.cupUi.quali) + '")');
      };
      // One Apply per bonus row. The rows are generated from the server's
      // registry, so a bonus added later gets its control for free -- and a
      // single number field per row is better edited on its own than behind one
      // Apply covering all of them.
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
      // Assigning a connection to a saved driver. This is an admin decision and
      // cannot be anything else: BeamMP issues a fresh random guest name on
      // every join, so the server has no way to tell a returning regular from
      // somebody who has never raced here. Guessing would eventually hand one
      // player another's name and their championship points.
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
      // Entries free to be assigned: not already held by someone else on the
      // server. The driver's own current entry stays in their list so the
      // dropdown can show what they are now.
      //
      // `boundPid == null` and NOT `!boundPid`: BeamMP player ids are
      // ZERO-BASED, so the first player on the server is id 0 and a falsy test
      // reads them as nobody -- which would offer their driver to everyone else
      // as unclaimed. This mod has been bitten by that exact assumption before.
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
        // behaviour that has always existed: counted out once and you are out.
        lives: 1,
        // The arena itself, mirrored from the server so the setup panel can
        // list and edit it entry by entry. The counts are kept alongside
        // because the header and the disabled rules read them everywhere.
        boundary: [],         // [{ x, y, z }] in perimeter order
        startPositions: [],   // [{ x, y, z, hx, hy }], slot 1 first
        boundaryCount: 0,
        startCount: 0,        // derby starting grid slots placed
        // Which of the two boundary editors authored that polygon. 'polygon' is
        // the drive-and-place one that has always existed and is still the only
        // way to build a non-rectangular arena; 'rect' derives four corners from
        // a centre and a pair of extents. Gameplay reads `boundary` either way.
        boundaryMode: 'polygon',
        shape: null,          // { cx, cy, cz, halfW, halfL, rot } while 'rect'
        wallHeight: 6,        // how tall the arena walls are drawn (visual only)
        wallDepth: 1.5,       // how far they drop below the boundary (visual only)
        // Who takes part: 'all' (every connected player, the historical
        // behaviour) or 'join' (only drivers who pressed Join Race).
        entrants: 0,          // how many would be in a derby started right now
        maxResets: -1,        // resets per driver per derby (-1 = unlimited)
        visualize: true,      // boundary/grid visuals shown (client-local)
        winner: null,
        players: []           // { id, name, status, reason, elimTime, resets }
      };
      // Dot rule again: these inputs live inside the ng-if derby panel.
      $scope.derbyUi = { oob: 5, demo: 10, lives: 1, resets: -1, name: '', selected: '' };
      // The rectangle sliders. Width and length are the FULL span in metres,
      // which is what an admin measures an arena in - the server stores half
      // extents and the conversion happens in the Lua command. `square` links
      // the two so one slider drives both.
      $scope.rectUi = { width: 120, length: 120, rot: 0, wall: 6, wallDepth: 1.5, square: false };
      // Saved arenas for the hosted map (same workflow as track layouts).
      $scope.derbyLayouts = [];
      $scope.derbyLayoutMap = '';
      $scope.derbyDropdownOpen = false;
      // Last config values mirrored from the server. Broadcasts only overwrite
      // an input while it still shows the previous server value; an edit in
      // progress (field differs) survives marker drops and other rebroadcasts.
      var derbyCfgSeen = { oob: null, demo: null, lives: null, resets: null };
      // The rectangle sliders follow the same rule, and are declared up here
      // beside it for the same reason: the broadcast handler reads this, and a
      // `var` further down the controller is only assigned when execution
      // reaches it.
      // Every key syncRectField is called with MUST be seeded null. An unseeded key
// is undefined, which matches neither branch of the follow test, so the slider
// silently never follows the server again.
var rectSeen = { width: null, length: null, rot: null, wall: null, wallDepth: null };
      function syncRectField(key, value) {
        if (typeof value !== 'number') { return; }
        var rounded = Math.round(value * 10) / 10;
        if (rectSeen[key] === null || Number($scope.rectUi[key]) === rectSeen[key]) {
          $scope.rectUi[key] = rounded;
        }
        rectSeen[key] = rounded;
      }
      // Pull the sliders back into line with the arena the server just sent. A
      // value the admin is in the middle of dragging is not overwritten, but
      // anything that still matches what the server last said follows it -
      // otherwise loading a saved arena would redraw the walls while the
      // sliders went on showing the old numbers.
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
      // Which listed entry has its edit controls open, 1-based, or null. Two
      // selections rather than one shared "selected entry": the marker list and
      // the start grid are shown at the same time, so a single one would make
      // picking a slot silently close the marker you were working on. Plain
      // scope properties, like the checkpoint editor's selectedCp - only
      // controller functions write them, so no ng-if child scope can shadow one.
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
      // hunt. Bump this with main.lua, raceManager.lua and app.json's "version"
      // -- they are the released package version and wiring_test fails if the
      // four disagree.
      var APP_BUILD = '0.9.0';
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

      // THE LAP A DRIVER IS ON, which is not the number of times they have
      // crossed the line.
      //
      // currentLap counts CROSSINGS, and on a track that owes an out lap the
      // first of those is a lap nobody scored -- so a two lap race read "3/2" on
      // the last lap: three crossings against a target that never counted the
      // give-away one. The two numbers were measuring different things.
      //
      // While the out lap is still owed there is no racing lap yet, so the cell
      // says so rather than claiming lap 1.
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
        return row.currentLap + '/' + $scope.totalLaps;
      };

      $scope.phaseLabel = function () {
        if ($scope.sessionKind === 'quali' && QUALI_PHASE_LABELS[$scope.phase]) {
          return QUALI_PHASE_LABELS[$scope.phase];
        }
        return PHASE_LABELS[$scope.phase] || $scope.phase;
      };
      $scope.statusLabel = function (s) { return STATUS_LABELS[s] || s; };

      // Should this driver's row read OUT LAP where its lap time goes?
      //
      // The server's flag answers "does this driver's next crossing complete an
      // out lap", which is only a statement about somebody still in the session.
      // A driver who withdrew, went out, or was taken by the grace timeout keeps
      // it set - they never completed one - and their row would otherwise
      // announce an out lap they are no longer driving, next to a status of DNF
      // or Not entered.
      $scope.showOutLap = function (row) {
        if (!row || !row.outLap) { return false; }
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
      // The server sends the driver array already sorted leader-first with a
      // `position` integer on every row - and that integer is the row's index,
      // because assignPositions stamps it while walking the sorted array. The
      // table therefore renders the array as it arrives.
      //
      // It used to re-sort by that integer as well, defensively, "in case a
      // payload ever arrives out of order". It cannot: the order and the number
      // come from the same loop on the server. What the guard did cost was a
      // sort of the whole field on every digest - three times a second for the
      // length of a race, on every machine connected - to reproduce an order it
      // had already been handed. tests/stress_test.lua checks the invariant on
      // every broadcast it makes, in every phase, so this is pinned down rather
      // than assumed.
      //
      // `track by row.id` in the ng-repeat is what makes Angular MOVE the
      // existing <tr> nodes instead of rebuilding them, which is what keeps the
      // reordering smooth instead of flickering.

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

      // Metres to this client's next checkpoint, for the header readout.
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
      // A live session is anything a driver is actively taking part in.
      // A derby counts as live from FORM-UP, not from GO. It used to read
      // `derby.phase === 'running'`, which predates the two-step start: a driver
      // standing on the derby grid through the countdown was not in a live
      // session by this test, so they kept the full spectator chrome and the
      // leaderboard below it until the moment the field was released.
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
      // Generate Grid is NOT gated on that, and the difference is the whole of a
      // reported blocker.
      //
      // The button was disabled for every session under way, which includes
      // qualifying -- so the one control that takes a host from qualifying to the
      // race was greyed out for exactly as long as they needed it. The server
      // supersedes a running qualifying session now (RM_onGenerateGrid), but a
      // disabled button never reaches it, and the only control still lit was
      // Start Quali. That is what "Generate Grid starts qualifying" looked like
      // from the outside: it was not doing anything at all.
      //
      // A live RACE is still refused, by the server and here, because
      // superseding one throws away a result the field is mid-way through
      // earning.
      $scope.raceUnderWay = function () {
        return $scope.phase === 'countdown' || $scope.phase === 'racing';
      };
      // Minimal mode: not logged in as an admin AND a session is live. The
      // whole chrome (header, session controls, editor, derby panel, login bar)
      // is removed from the DOM and only the leaderboard is left on screen.
      // Outside a live session the normal spectator UI comes back, so there is
      // always a way to reach the login prompt.
      $scope.minimalMode = function () {
        return !$scope.isAdmin && $scope.sessionLive();
      };
      // Which board fills the leaderboard area below the panels. The two
      // audiences ask different questions of it, so they key on different
      // things:
      //
      //   * A DRIVER's board follows the SESSION. Once a derby has formed up,
      //     the derby standings are the only standings that mean anything to
      //     them.
      //   * An ADMIN's board follows the MODE they are working in, because they
      //     are usually setting a derby up long before one forms up. This used
      //     to be `!isAdmin` alone -- written for the driver HUD, before the
      //     panel had modes -- so the race table rendered under the derby panel
      //     on every tab. Worse than irrelevant: a derby never touches race
      //     state, so `drivers` still holds the LAST race's field, and what an
      //     admin was reading during a derby was the previous race's results
      //     (or the previous qualifying times, via isQualiView in 'waiting').
      $scope.derbyBoardOnly = function () {
        return $scope.isAdmin ? $scope.isMode('derby') : $scope.derbyActive();
      };

      // Qualifying view for the whole of a qualifying session - including its
      // grid and countdown, which a qualifying session now has just like a race
      // does - and in waiting, where a closed quali's provisional order is still
      // the useful thing to show if any times exist. Race view otherwise.
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
      // A board for somebody WATCHING rather than driving. Minimal mode above is
      // still a driver's HUD - it answers "where am I, what lap, how many resets
      // left" - and none of that is a question a broadcaster has. Theirs is the
      // opposite: the whole field at once, who is out and why, and a way to put
      // the camera on whoever the story is about.
      //
      // WHO GETS IT. Anyone not in the field, which is two different states that
      // mean the same thing here: the entry decision (pressed Spectate) and a car
      // taken away (finished, or serving a penalty). They are deliberately
      // separate variables everywhere else in this file - conflating them is what
      // once made Rejoin look broken - so this reads both rather than picking one.
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
        // The editor is a render gate in Lua, and it draws gate rectangles and
        // start-slot outlines into the WORLD. An admin who is also the
        // broadcaster would otherwise stream authoring furniture over the race:
        // the panel is gone, the drawing is not, because Lua is told about the
        // panel and knows nothing about this mode.
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
      // Same, from a standings row. A cup entry is a ROSTER identity, not a
      // connection, so it only has a car while whoever it is bound to is on the
      // server; the map below is empty for everyone else and the row is simply
      // not clickable.
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
      // THE BOARD DOES NOT OUTLIVE THE SPELL THAT SHOWED IT.
      //
      // Being out of the field is two different things wearing one name. Pressing
      // Spectate is a decision that lasts; taking the chequered flag makes you a
      // spectator for the few seconds between your finish and the results, by
      // accident of timing rather than by choice. `broadcast.on` is remembered
      // across a teardown, and with both states feeding broadcastMode() that
      // memory meant crossing the line silently threw an admin into a stream
      // graphic and back out again, mid race night, having asked for none of it.
      // Reported from a live session as "the leaderboard switches to non admin
      // for the five second wait".
      //
      // So the preference is cleared when the spell ENDS. Somebody who sits a
      // session out presses the button once and keeps the board for as long as
      // they are out -- including across the finish of the race they are
      // watching, because their own entry decision has not changed. Somebody who
      // merely finished gets their own panel back and stays there.
      //
      // IT IS STILL REMEMBERED WITHIN A SPELL, which is the reason the preference
      // exists at all: BeamNG tears this directive down whenever the HUD layer
      // goes (opening the pause menu does it), and without the stored value the
      // board would vanish on every pause.
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
        var total = $scope.totalLaps || 0;
        return total > 0 ? (leader.currentLap + '/' + total) : String(leader.currentLap);
      };

      // ------------------------------------------------------------------
      // Time behind
      // ------------------------------------------------------------------
      // TWO SOURCES, because the two sessions are scored on different things and
      // a gap has to mean the same thing as the classification above it.
      //
      //   * A RACE is scored on the clock, so the gap is a subtraction of two
      //     split stamps taken at the last checkpoint both cars reached. The
      //     server does that arithmetic (assignPositions) and sends `gap` and
      //     `intv` already rounded; nothing here recomputes either.
      //   * QUALIFYING is scored on the best LAP. Two drivers who set identical
      //     laps ten minutes apart are level, so a clock delta says nothing --
      //     the server deliberately sends none and the gap is the difference
      //     between best laps, which is already on every row.
      //
      // A gap is only a TIME while both cars are on the same lap. Once a driver
      // is lapped the honest answer is how many laps, and a number of seconds
      // that happens to exceed a lap time is the one reading that would mislead
      // a commentator.
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
      // ...and to the car directly ahead. Same data, one row up - including the
      // lap rule, which bites harder here than it does for the gap. A driver a
      // lap down is usually directly behind somebody on the lead lap, and their
      // split delta at a checkpoint a lap apart is a real number that means
      // nothing: it would put "+48.6" between two cars that are not racing each
      // other at all.
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

      // The field, split the way a board reads it. Done ONCE PER BROADCAST
      // rather than once per digest, which is the same reason the race table
      // renders the server's order instead of re-sorting it: this runs three
      // times a second for the length of a race, on every machine connected.
      //
      //   running    - everyone still in the session, in the server's order
      //   out        - retired and disqualified, with the ruling that put them there
      //   spectating - not in the field at all, counted rather than listed
      //
      // A driver sitting the session out is not a racer, and a board listing them
      // among the runners claims a field bigger than the one on track.
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

      $scope.formatFinish = function (row) {
        if (row.status === 'dnf') { return 'DNF'; }
        if (row.finishTime === null || row.finishTime === undefined) {
          return row.currentLap ? ('Lap ' + row.currentLap + '/' + $scope.totalLaps) : '-';
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
          $scope.flag = (data.flag === 'yellow' || data.flag === 'red') ? data.flag : 'green';
          // READ HERE, on the state broadcast, which is the one that arrives on a
          // clock. It was read only in the ROUTE handler, and that fires on
          // editor changes and checkpoint crossings -- so the flag changed when
          // the driver went through a gate and at no other time. The client was
          // sending it on both channels the whole while; only one was listening.
          if (data.driverFlag) { $scope.driverFlag = data.driverFlag; }
          // Which session the shared lifecycle is running. Qualifying and racing
          // go through the same phases now (grid -> countdown -> running ->
          // done), so the phase alone no longer says which one you are looking
          // at - this does, and it is what the qualifying/race view switches on.
          $scope.sessionKind = data.sessionKind === 'quali' ? 'quali' : 'race';
          if (typeof data.sessionLaps === 'number') { $scope.sessionLaps = data.sessionLaps; }
          $scope.raceTime = data.raceTime || 0;
          // Who holds the session's fastest lap. One id, compared per row when
          // the table renders - no scan, and no second sorted copy of the field.
          $scope.bestLapPid = (data.bestLapPid === undefined) ? null : data.bestLapPid;
          if (typeof data.pointToPoint === 'boolean') { $scope.pointToPoint = data.pointToPoint; }
          $scope.drivers = data.drivers || [];
          // The broadcast board's three buckets, cut from the array that just
          // landed. Here rather than in a template expression for the same
          // reason the race table renders the server's order untouched: a
          // template function is re-run on every digest, and this one only has
          // new work to do when a broadcast arrives.
          splitField($scope.drivers);
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
          // ...but never the GO frame, which owns its own lifetime on a timer.
          //
          // On GO the phase is ALREADY 'racing', and a race broadcasts state
          // three times a second, so this line wiped GO! within a third of a
          // second of it appearing. A derby sends no such broadcast, which is
          // why GO showed there and nowhere else. The counts still clear this
          // way, which is what tidies up an aborted countdown.
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
          // Qualifying rules. The inputs are re-seeded the same way the laps
          // and resets fields are: only when the server's value actually moved,
          // so an edit in progress is never yanked out from under the admin.
          $scope.ghostQuali = !!data.ghostQuali;
          $scope.nametags = !!data.nametags;
          $scope.qualiOutLap = !!data.qualiOutLap;
          // A limit becoming non-zero is also what picks the Laps/Timed toggle,
          // so an admin opening the app onto a session somebody else set up
          // lands on the mode it is actually running. Keyed on the value having
          // MOVED, like the boxes above and for a sharper reason: this fires
          // three times a second, and re-deciding the mode from the standing
          // values on every broadcast would snap the toggle back to the old
          // mode in the gap between a press and the server's echo of it.
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
      // The overlay owns its own lifetime, in both modes. A race used to clear
      // it as a side effect of the next state broadcast, which is why GO! was
      // gone in a third of a second there and sat forever on a derby, which
      // sends no such broadcast. Neither was the intent.
      // GO holds longer than the counts do. It is the one frame everybody is
      // actually looking at, and 1.5s was gone before a driver had looked up.
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

      // Circuit or sprint stage. Owned by the loaded track, toggled in the
      // editor, and mirrored from both the route push and the state broadcast.
      $scope.pointToPoint = false;
      $scope.togglePointToPoint = function () {
        $scope.pointToPoint = !$scope.pointToPoint;
        bngApi.engineLua('raceManager.setPointToPoint(' + (!!$scope.pointToPoint) + ')');
      };

      $scope.$on('RaceManagerRoute', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.routeWaypoints = data.waypoints || [];
          $scope.pitRoute = data.pitRoute || [];
          $scope.pitActive = !!data.pitActive;
          $scope.pitLeft = data.pitLeft || 0;
          $scope.nextWp = data.nextWp || 1;
          $scope.visualize = data.visualize !== false;
          if (typeof data.pointToPoint === 'boolean') { $scope.pointToPoint = data.pointToPoint; }
          if (typeof data.clientBuild === 'string') { $scope.clientBuild = data.clientBuild; }
          // Admin session restored from the client bridge. This directive is
          // destroyed and rebuilt every time BeamNG tears down the HUD layer -
          // opening the pause menu does exactly that - so isAdmin cannot live
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

      // The list the editor panel shows: main lap, joker route, pit stalls or
      // starting grid, whichever the editor is currently pointed at.
      //
      // Every target needs a case here. A missing one does not fail loudly --
      // it falls through to the main route, so the tab's own count reads
      // correctly off its real list while the list underneath shows the
      // checkpoints instead. That is exactly how the pit tab came to show four
      // stalls when one had been placed.
      $scope.editorWaypoints = function () {
        if ($scope.editorTarget === 'joker') { return $scope.jokerRoute; }
        if ($scope.editorTarget === 'pit')   { return $scope.pitRoute; }
        if ($scope.editorTarget === 'start') { return $scope.startPositions; }
        if ($scope.editorTarget === 'branch') { return $scope.branches; }
        if ($scope.editorTarget === 'marker') { return $scope.markers; }
        return $scope.routeWaypoints;
      };

      // ------------------------------------------------------------------
      // ------------------------------------------------------------------
      // Dragging a gate to reorder the route
      // ------------------------------------------------------------------
      // Replaces the up/down button pair, which cost two buttons on EVERY gate
      // row to move one gate one place.
      //
      // MOUSE EVENTS, NOT HTML5 DRAG-AND-DROP. The first version used
      // draggable="true" with dragstart/dragover/drop, which is the obvious way
      // to do this and does not work here: the grip took the grab cursor (that
      // is only CSS) and nothing ever moved, because BeamNG's CEF host does not
      // deliver the drag events to the page. Nothing errors, the gesture simply
      // does nothing -- so it looked like a bug in the drop logic rather than
      // the whole mechanism being absent.
      //
      // mousedown/mousemove/mouseup are plain DOM and always arrive. The move
      // and up listeners go on the DOCUMENT rather than the row, so a pointer
      // that leaves the list mid-drag is still tracked and the drag still ends
      // when the button comes up somewhere else.
      //
      // Delegated for the down event, because ng-repeat rebuilds these rows on
      // every change and a listener bound to a row is bound to an element that
      // will not exist after the first drop.
      //
      // Nothing new crosses to Lua: reorderCheckpoint(from, to) already existed
      // behind the arrows, branch-slot fixups included.
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
      // Only one picker menu is ever open, so one key identifies it. Same custom
      // dropdown the layout and cup pickers use: a native <select> renders an OS
      // popup that CEF never draws over the game, so it looks like a control and
      // then does nothing.
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
      // The symbol for the NEXT marker placed, or for one already down.
      //
      // One entry point for both because it is the same decision from the
      // admin's side: no index means "what I am about to place", an index means
      // "that one there". Drive the route dropping signs, then say what each one
      // means -- which is how a stage actually gets built.
      $scope.setMarkerKind = function (kind, index) {
        if (!kind) { return; }
        bngApi.engineLua('raceManager.setMarkerKind(' + luaStr(kind)
          + (index === undefined || index === null ? '' : ', ' + index) + ')');
      };
      $scope.markerLabelOf = function (kind) {
        return $scope.markerLabels[kind] || kind || '';
      };
      // The glyph the BUTTON shows. Deliberately not the same drawing as the
      // one on the board: this is a 12px label in a row of seven, and the
      // in-world symbol is line geometry sized to read at two hundred metres.
      $scope.markerGlyph = function (kind) {
        return ({ right: '→', left: '←', up: '↑', down: '↓',
                  uturn: '↰', splitRight: '⤴', splitLeft: '⤳' })[kind] || '?';
      };

      $scope.reorderCheckpoint = function (from, to) {
        var list = $scope.editorWaypoints();
        if (to < 1 || to > list.length) { return; }
        bngApi.engineLua('raceManager.reorderCheckpoint(' + from + ', ' + to + ')');
      };
      // NOT generateGrid. That name was already taken, further down this file, by
      // the admin button that FORMS THE RACE GRID -- it teleports the whole field
      // onto its slots and holds them there for the countdown. Two functions on
      // one scope key is last-one-wins, and the other one is defined later, so
      // this button quietly became "start the race": it froze the admin in place
      // and placed no start positions at all.
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

      // ------------------------------------------------------------------
      // Regulation notices, forced spectating and vehicle rejections
      // ------------------------------------------------------------------
      // ONE QUEUE, and everything transient goes through it.
      //
      // What was here before was a single slot: each notice overwrote whatever
      // was showing AND restarted the one shared six-second timer, so a reset
      // notice arriving behind a caution replaced the caution and then hid
      // itself at a time that belonged to neither. Two things arriving together
      // meant one of them was never seen at all, and there was no way to say
      // that a flag matters more than a lap time.
      //
      // Notices now RANK. A higher-ranked one preempts what is showing and the
      // displaced notice is not lost, it waits. Equal ranks queue in arrival
      // order. Anything outranked by what is already up waits its turn rather
      // than clobbering it.
      //
      // Presentation is decided per kind, in NOTICE_STYLE below, so that adding
      // a notification later is one row there rather than another timer and
      // another slot in this controller.
      var NOTICE_DEFAULT = { rank: 0, flash: false, ms: 6000, colour: 'grey' };
      var NOTICE_STYLE = {
        // Flags outrank everything: a caution is a fact about the session and
        // has to reach a driver whose eyes are on the road, ahead of any
        // informational message competing for the same strip.
        // The flash, and the colour comes from the notice rather than from
        // here: green, yellow, red, white and chequered are all kind 'flag'
        // and each waves in its own colour.
        flag:     { rank: 40, flash: true,  ms: 2600 },
        // Being removed from the session, or having a car refused, is the other
        // class a driver cannot afford to miss.
        spectate: { rank: 30, flash: false, ms: 6000 },
        vehicle:  { rank: 30, flash: false, ms: 6000 },
        session:  { rank: 20, flash: false, ms: 6000 },
        // Running out of resets changes what this driver is allowed to do for
        // the rest of the session, so it flashes rather than scrolling past in
        // the strip. Amber, not the flag yellow: a caution is about the
        // session and this is about one car.
        resetsout: { rank: 25, flash: true, ms: 2600, colour: 'amber' },
        // Gold, and a flash rather than the strip. On a driver's panel the
        // strip painted 16% gold over a transparent root, which is to say over
        // the road going past: legible on an admin's dark panel and very nearly
        // invisible on everybody else's, which is how it went unnoticed.
        fastest:  { rank: 10, flash: true,  ms: 2600, colour: 'gold' },
        // Everything else (grid, joker, pit, reset, ghost, finish, server)
        // takes NOTICE_DEFAULT. They are the running commentary.
      };
      function noticeStyle(kind) {
        var s = NOTICE_STYLE[kind] || NOTICE_DEFAULT;
        return {
          rank:   s.rank   !== undefined ? s.rank   : NOTICE_DEFAULT.rank,
          flash:  s.flash  !== undefined ? s.flash  : NOTICE_DEFAULT.flash,
          ms:     s.ms     !== undefined ? s.ms     : NOTICE_DEFAULT.ms,
          colour: s.colour !== undefined ? s.colour : NOTICE_DEFAULT.colour
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

      // A cap, because a queue with no bound is a way to make the panel
      // unusable: a driver spinning in a barrier can generate reset notices
      // faster than they drain. The OLDEST LOW-RANKED one goes, never the
      // highest, so a caution is never the thing dropped to make room.
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

      function noticePush(kind, msg, sub) {
        var st = noticeStyle(kind);
        var item = { kind: kind, msg: msg, sub: sub || null, rank: st.rank,
                     flash: st.flash, ms: st.ms, colour: st.colour };
        // Nothing showing: straight up.
        if (!$scope.notice) {
          noticeQueue.push(item);
          noticeAdvance();
          return;
        }
        // Outranks what is up: preempt it.
        //
        // The displaced notice goes back in the queue ONLY if it has not really
        // been seen yet. Requeueing unconditionally is what made a fastest lap
        // replay itself a few seconds after the race ended: the chequered flag
        // preempted it, the fastest lap went back in the queue, and it came
        // round again when the flag expired. From the driver's seat that reads
        // as the notification firing twice.
        //
        // A notice that has held the panel for MIN_SEEN has done its job and is
        // superseded. One that was pushed a moment before something outranked
        // it never reached anybody and is worth keeping.
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
          noticePush(data.kind || 'info', data.msg, data.sub);
        });
      });

      // Reset ghosting: this driver's own countdown to contact resuming.
      //
      // The bridge pushes at ~10 Hz and the readout is interpolated between
      // pushes, the same arrangement the lap clock uses - a guihook per frame
      // would be a message per frame for a number nobody can read that fast.
      //
      // `blocked` means the timer has run out but another car is still in the
      // way, so the countdown is replaced by "MOVE CLEAR" rather than sitting at
      // zero: the driver is waiting on the OTHER car now, not on a clock, and
      // there is no time at which it gives up and lets them go solid.
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
          // `lapsed`: the server refused a command because this session is no
          // longer authenticated. Not a wrong password, so it must not light the
          // "Incorrect password" warning, but it IS the one case where the login
          // should come to the admin rather than waiting to be fetched. They
          // were mid-session pressing buttons that had quietly stopped working.
          var lapsed = !!(data && data.lapsed);
          $scope.isAdmin = ok;
          $scope.authError = !ok && !restored && !lapsed;
          if (lapsed) { $scope.showLogin = true; }
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
      $scope.$on('RaceManagerCup', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.cup.enabled = !!data.cupEnabled;
          $scope.cup.name = data.cupName || '';
          $scope.cup.round = data.round || 0;
          $scope.cup.preset = data.preset || 'custom';
          $scope.cup.derbyPreset = data.derbyPreset || 'custom';
          $scope.cup.racePoints = toArray(data.racePoints);
          $scope.cup.derbyPoints = toArray(data.derbyPoints);
          $scope.cup.qualiPoints = toArray(data.qualiPoints);
          $scope.cup.presets = toArray(data.presets);
          $scope.cup.bonuses = toArray(data.bonuses);
          $scope.cup.standings = toArray(data.standings);
          $scope.cup.roster = toArray(data.roster);
          $scope.cup.connected = toArray(data.connected);
          // entryId -> the pid that entry is bound to right now, so a standings
          // row on the broadcast board can hand the camera a car. Built here
          // rather than scanned per row per digest; an entry whose driver is not
          // on the server has no pid and its row is simply not clickable.
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
          $scope.derby.phase = data.derbyPhase || 'idle';
          $scope.derby.entrants = data.entrants || 0;
          $scope.derby.time = data.derbyTime || 0;
          $scope.derby.winner = data.winner || null;
          $scope.derby.boundary = toArray(data.boundary);
          $scope.derby.startPositions = toArray(data.startPositions);
          $scope.derby.boundaryCount = $scope.derby.boundary.length;
          $scope.derby.startCount = $scope.derby.startPositions.length;
          $scope.derby.players = toArray(data.players);
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
          // Keep the open edit controls pointed at something that still exists.
          // An entry deleted here (by this admin or another one) must not leave
          // a panel of buttons hanging over the entry that took its number, and
          // a derby going live closes them: the arena is locked from form-up on.
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

      $scope.derbyApplyConfig = function () {
        var oob = parseFloat($scope.derbyUi.oob);
        var demo = parseFloat($scope.derbyUi.demo);
        if (!isFinite(oob) || oob <= 0 || !isFinite(demo) || demo <= 0) { return; }
        // Resets mirror the race rule: blank or negative = unlimited, 0 = none.
        var resets = parseInt($scope.derbyUi.resets, 10);
        if (isNaN(resets) || resets < 0) { resets = -1; }
        // Lives floor at 1: nought lives would knock the whole field out on the
        // first stopped timer, which is not a derby.
        var lives = parseInt($scope.derbyUi.lives, 10);
        if (isNaN(lives) || lives < 1) { lives = 1; }
        bngApi.engineLua('raceManager.derbySetConfig(' + oob + ', ' + demo + ', '
          + resets + ', ' + lives + ')');
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
      // Wall height applies to a drive-and-place arena too, so it is its own
      // call: the rectangle fields must not ride along and switch the mode.
      // Height and depth ride the same command: both are how the arena is drawn
      // and neither touches the flat out-of-bounds test, so there is no reason
      // for them to travel separately.
      $scope.derbyApplyWallHeight = function () {
        if ($scope.derbyActive()) { return; }
        var h = parseFloat($scope.rectUi.wall);
        var d = parseFloat($scope.rectUi.wallDepth);
        if (!isFinite(h)) { return; }
        if (!isFinite(d)) { d = 1.5; }
        bngApi.engineLua('raceManager.derbySetShape(nil, nil, nil, '
          + h + ', ' + d + ')');
      };
      $scope.derbyIsRect = function () { return $scope.derby.boundaryMode === 'rect'; };
      // Derby starting grid: drive to each slot and place it; slot 1 first.
      $scope.derbyAddStart = function () {
        bngApi.engineLua('raceManager.derbyAddStartPosition()');
      };
      $scope.derbyClearStarts = function () {
        bngApi.engineLua('raceManager.derbyClearStartPositions()');
      };

      // --- Editing one placed marker / start slot ----------------------------
      // Same shape as the track editor's lists: click a row to open its
      // controls, click it again to close them, then Go / Move Here / ✕. The
      // arena belongs to the server, so every button here is a request - the
      // list redraws when the broadcast comes back, not when the button is
      // pressed. Selection is refused (and dropped) once a derby is under way,
      // which is the same rule the server enforces on the commands themselves.
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
          case 'running':   return 'LIVE: ' + $scope.formatDerbyTime($scope.derby.time);
          case 'forming':   return 'Formed up: held';
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


      $scope.derbyStart = function () {
        // No config push here - the rules were sent at Form Up and are locked
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
      // Advisory only: it is shown to the field and announced in chat, and the
      // server decides whether the session is in a state to be flagged at all.
      // Shown once a session is actually running. On the grid the red lamp says
      // what is happening, and out of a session a flag would be furniture.
      // Held on the grid counts: that IS a red flag, and it is the one moment a
      // driver most wants to be told nothing is happening yet.
      $scope.flagShowing = function () {
        return $scope.phase === 'racing' || $scope.phase === 'qualifying'
          || $scope.phase === 'grid';
      };
      $scope.flagTitle = function () {
        if ($scope.driverFlag === 'checkered') {
          return 'Chequered flag: your race is over. Your car is a ghost, so you can '
            + 'drive anywhere and nobody still racing can touch you.';
        }
        if ($scope.driverFlag === 'red') { return 'Red flag: stop where you are and wait'; }
        if ($scope.driverFlag === 'yellow') { return 'Yellow flag: caution, race back to the line'; }
        if ($scope.driverFlag === 'white') { return 'White flag: last lap'; }
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

      // Retiring cannot be undone, so the button asks first.
      //
      // THROUGH AN OBJECT, because both buttons live inside ng-if blocks and
      // ng-if makes a child scope: `confirmRetire = true` written there lands on
      // the CHILD and shadows the parent, so the sibling that shows the
      // confirmation never sees it change. Pressing Retire did nothing at all,
      // in both panels. The same trap the settings inputs carry a note about.
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
      // Clear Results Cache, behind the same two-press confirmation End Cup
      // uses, and for the same reason: it deletes every saved .txt in the
      // results folder on the server, there is no undo, and the button sits one
      // row under Set Password in a panel an admin opens for other things. A
      // results file is the only record a league has of a race night once the
      // session is over.
      $scope.resultsUi = { confirmClear: false };
      $scope.askClearResults    = function () { $scope.resultsUi.confirmClear = true; };
      $scope.cancelClearResults = function () { $scope.resultsUi.confirmClear = false; };
      $scope.clearResults = function () {
        $scope.resultsUi.confirmClear = false;
        bngApi.engineLua('raceManager.clearResults()');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (race settings)
      // ------------------------------------------------------------------
      // ------------------------------------------------------------------
      // Session settings apply themselves
      // ------------------------------------------------------------------
      // These used to sit behind a Set button, and forgetting to press it is a
      // silent failure that only shows up as the wrong race distance. A commit
      // button earns its place when an edit is multi-field and only makes sense
      // applied together -- the cup points tables, where 24 boxes are one
      // decision -- or when applying is expensive or destructive. A single
      // number that is cheap to send, trivially changed again, and displayed
      // back from the server right beside the box is none of those things.
      //
      // The inputs carry ng-model-options="{ debounce: { default: 500, blur: 0
      // } }": the model settles half a second after typing stops, or instantly
      // when the field loses focus, and ng-change sends it. Debounce is what
      // makes this safe rather than chatty -- without it "12" would be sent as
      // 1 and then 12, and every one of those is a broadcast to every client.
      //
      // An empty box is NEVER sent. It is a field mid-edit, not an instruction:
      // a driver clearing 5 to type 12 must not spend the half second in
      // between racing to whatever an empty box would mean.
      $scope.applyTotalLaps = function () {
        var n = parseInt($scope.settingsUi.laps, 10);
        if (!n || n < 1) { return; }
        bngApi.engineLua('raceManager.setTotalLaps(' + n + ')');
      };
      // Module 1: reset allowance. Blank or negative = unlimited, 0 = none.
      // Unlimited is -1, and only -1. A blank box used to mean it too, which
      // cannot survive auto-apply: clearing the field to retype a number would
      // spend the moment in between setting the allowance to unlimited, and
      // announce it. Blank is now "still typing" here, exactly as it is for the
      // laps field, and the one documented way to say unlimited is to type -1.
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
      // Does the provisional order shown in the qualifying table double as the
      // starting grid? Only under 'quali'. Every other mode decides the grid
      // somewhere else - a draw that has not happened, pins the table does not
      // show, or a reversal - so the column stops calling itself Grid rather
      // than showing a number the grid will contradict.
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
      // Qualifying session length: LAPS or TIMED, one or the other.
      //
      // The server takes both numbers and treats 0 as unlimited, so "3 laps and
      // 10 minutes" is a state it can hold - and a panel offering both boxes at
      // once invites it by accident. A qualifying session is one thing or the
      // other, so the panel asks which, shows that box alone, and sends 0 for
      // the one not in use. Nothing about the server contract changes; what
      // changes is that the two cannot be armed together by mistake.
      //
      // Which mode the panel is in is a display choice, so it lives here rather
      // than on the wire - but it is seeded from the server below, so an admin
      // opening the app on a session somebody else configured lands on the mode
      // that session is actually running.
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
      // Typing in the box that is on screen. An empty box is skipped, for the
      // same reason it is on the laps and resets fields - here it would read as
      // 0, which in a qualifying session means UNLIMITED, so clearing "3" to
      // type "12" would spend the half second in between running an open
      // session. (Switching MODE goes straight to pushQualiLimits below and is
      // not skipped: that call has to land even with an empty box, because
      // zeroing the limit the panel has stopped showing is the point of it.)
      $scope.applyQualiLimits = function () {
        var box = $scope.qualiUi.mode === 'laps'
          ? $scope.settingsUi.qualiLaps : $scope.settingsUi.qualiMins;
        if (box === '' || box === null || box === undefined) { return; }
        pushQualiLimits();
      };
      // Switching mode applies immediately, like every other toggle in this
      // panel. Waiting for Set would leave the old limit live underneath a
      // panel showing the new mode's empty box - which is the state this whole
      // control exists to make impossible.
      $scope.setQualiLimitMode = function (mode) {
        mode = (mode === 'timed') ? 'timed' : 'laps';
        if ($scope.qualiUi.mode === mode) { return; }
        $scope.qualiUi.mode = mode;
        savePref('qualiLimitMode', mode);
        pushQualiLimits();
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
        // Keyed on the TRACK, not on the running session: this label is read
        // while setting a session up, when the session running is a race or
        // nothing at all. `qualiOutLap` on the broadcast answers the other
        // question - whether the session on track right now has one - and is
        // what the driver-facing chrome uses.
        return $scope.pointToPoint ? base : (base + ' + out lap');
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (starting grid editor)
      // ------------------------------------------------------------------
      // "Place Start Position Here" is the same editorAdd the checkpoint tabs
      // use - the editor target decides which list it lands in.
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
          height: (typeof wp.height === 'number') ? wp.height : '',
          depth:  (typeof wp.depth === 'number') ? wp.depth : ''
        };
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
        if (field === 'width') { return $scope.settingsUi.width; }
        if (field === 'depth') { return $scope.settingsUi.depth; }
        return $scope.settingsUi.height;
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (track layouts)
      // ------------------------------------------------------------------
      // (luaStr defined above in the admin-authentication section.)
      // The one place a save leaves for the client. `confirmed` is the admin
      // having accepted a warning, either the name clash below or the server's
      // held-save reply.
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

      // NOTHING LOADED: no race track, no derby arena, one press.
      //
      // Confirmed first, because it is the one editor action that throws away
      // what everybody on the server can see rather than only what this admin
      // is working on. The confirmation reuses the layout panel's own inline
      // prompt: the game's CEF layer cannot draw a browser dialog over the
      // world, which is the same reason the layout picker is not a <select>.
      // askLayout is declared further down and is reached here by hoisting,
      // which JS does for function declarations and Lua does not do for locals.
      // The equivalent line in the extension would be a nil global.
      $scope.clearEverything = function () {
        askLayout(
          'Clear the race track AND the derby arena for everyone? '
            + 'Saved layouts and arenas are not deleted.',
          'Clear everything',
          function () { bngApi.engineLua('raceManager.clearEverything()'); });
      };

      // OPEN IN THE EDITOR: the same layout, to this admin only.
      //
      // The distinction is the one thing separating two admins working at once
      // from two admins overwriting each other. Load Layout moves the whole
      // server onto a track; this pulls a copy down to edit and leaves the
      // server's own track, grid and joker count exactly where they are.
      $scope.editLayout = function () {
        if (!$scope.layoutUi.selected) { return; }
        console.log('[RaceManager] Edit Layout "' + $scope.layoutUi.selected + '" requested (private)');
        bngApi.engineLua('raceManager.loadLayout('
          + luaStr($scope.layoutUi.selected) + ', true)');
      };

      // The layout and arena pickers are absolutely positioned menus, and the
      // admin tab body is a scroll container - a menu opened near its bottom
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

        // Branch gates: a dashed spur from each one to the checkpoint it is
        // another way through, and a dot where it stands.
        //
        // NOT a second ring. The old preview traced one dashed lap per lane,
        // which drew a whole extra circuit for what is often two corners, and on
        // a head-on oval drew the same ring twice. A spur says the true thing
        // instead: here is another way through THAT checkpoint.
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
      // The app is painted over the windscreen, so wherever it renders it gets
      // two controls: drag the bottom-right corner to resize it, and a slider
      // to fade its background out of the way. Both persist in localStorage so
      // the choice survives a session.
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

      // One opacity for the app as a whole: fading "the HUD" means the same
      // thing to an admin reading the panels and to a driver reading the
      // leaderboard, so both sliders read and write this one preference.
      //
      // Opacity is bound with ng-model from inside an ng-if (the driver bar and
      // the header are both one), so it has to hang off an object for the same
      // reason the settings inputs do: a bare primitive would be shadowed on
      // the ng-if child scope, leaving the slider moving a copy nothing reads.
      $scope.lbUi = { opacity: loadPref('opacity', 0.85) };   // 0 (invisible) .. 1 (solid)

      // ------------------------------------------------------------------
      // Collapsing the HUD
      // ------------------------------------------------------------------
      // The app is painted over the windscreen and most of it is only wanted
      // some of the time: an admin setting a race up needs the panels, and the
      // same admin driving one does not. Collapsed, everything folds away to the
      // single status line the header (or the driver bar) already is.
      //
      // IT NEVER COLLAPSES TO NOTHING. The bar that stays carries the phase, the
      // clock and the button to bring it back, so there is always something to
      // press -- an app that could hide its own restore control would need the
      // game's app editor to recover, which is not a HUD toggle, it is a trap.
      //
      // Persisted like the size and the opacity, so it survives the pause menu
      // and the next session. Kept OUT of lbUi: that object exists because
      // ng-model needs a property to write through from an ng-if child scope,
      // and this is set by a click handler on the parent scope instead.
      $scope.hudCollapsed = loadPref('collapsed', false) === true;
      $scope.toggleCollapsed = function () {
        $scope.hudCollapsed = !$scope.hudCollapsed;
        savePref('collapsed', $scope.hudCollapsed);
      };

      // Two panels can be resized, but never both at once: in minimal mode the
      // leaderboard IS the HUD, and everywhere else the HUD is the whole app
      // root with its chrome. Same drag, same storage, separate keys - the
      // same number of pixels means a different size on each, so one shared
      // pair would yank whichever panel was not dragged to a nonsense size the
      // moment the mode flipped.
      //
      // `replace: true` on the directive means $element[0] IS .rm-root, so the
      // root resolves to the element itself rather than a descendant.
      var PANELS = {
        leaderboard: {
          el: function () { return $element[0].querySelector('.rm-table-wrap'); },
          wKey: 'width',    hKey: 'height',    minW: 200, minH: 80
        },
        hud: {
          el: function () { return $element[0]; },
          wKey: 'hudWidth', hKey: 'hudHeight', minW: 240, minH: 100
        },
        // A THIRD SET OF KEYS, for the same reason there is a second: the same
        // number of pixels means a different size on each of these, so a shared
        // pair yanks whichever panel was not dragged the moment the mode flips.
        // A broadcast board is a stream graphic sized to a stream, and a
        // driver's leaderboard is sized to fit around a windscreen.
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

      function panelStyle(name) {
        var size = panelSize[name];
        var style = { 'background-color': 'rgba(15, 17, 22, ' + Number($scope.lbUi.opacity) + ')' };
        if (size.w) { style.width = size.w + 'px'; }
        if (size.h) {
          style.height = size.h + 'px';
          style['max-height'] = size.h + 'px';
        }
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

      // The sticky table header paints its own near-opaque background, so
      // without this it would survive the fade as a solid strip across an
      // otherwise see-through HUD. It follows the slider through a custom
      // property, which has to be written straight onto the element: jqLite's
      // .css() camel-cases the name it is given, so a `--custom-prop` set
      // through ng-style is silently dropped. (`replace: true` makes
      // $element[0] the .rm-root div itself.)
      //
      // THREE PROPERTIES, ONE SLIDER. The panel fill was the only one for a
      // while, which meant the header's orange band and its border kept their
      // own fixed alpha: fade the HUD all the way out and a solid orange stripe
      // stayed painted across the middle of the view. Anything with a background
      // of its own has to be driven from here, or "opacity" means "opacity,
      // except that bit".
      $scope.$watch('lbUi.opacity', function (op) {
        var o = Number(op);
        var css = $element[0].style;
        css.setProperty('--rm-panel-bg', 'rgba(15, 17, 22, ' + o + ')');
        // The header's tint and rule. Their alphas are the ones the stylesheet
        // used to hardcode, scaled by the slider so they fade in step.
        css.setProperty('--rm-accent-bg', 'rgba(255, 102, 0, ' + (o * 0.15) + ')');
        css.setProperty('--rm-accent-line', 'rgba(255, 102, 0, ' + (o * 0.5) + ')');
      });

      // THE BOARD'S MEASURED WIDTH, for the driver bar to match and wrap inside.
      //
      // ONE DIRECTION ONLY: board -> bar. The board's width does not depend on
      // the bar, so this settles on the first pass. The version that set the
      // ROOT from this collapsed the app -- the board's max-width is 100% of the
      // root, so root-from-board is a loop that converges on zero, and it took
      // the resize grip down with it.
      //
      // A custom property must be set on the element directly: jqLite's .css()
      // camel-cases the name, so a --custom-prop through ng-style is dropped.
      // BOTH DIMENSIONS. Width alone was enough for the driver bar, but the
      // overlays need a height too or they stay full-window tall: a narrow
      // column of red down the whole screen instead of a box over the panel.
      $scope.$watch(function () {
        if (!$scope.minimalMode()) { return ''; }
        var board = $element[0].querySelector('.rm-table-wrap');
        var bar   = $element[0].querySelector('.rm-driverbar');
        var w = board ? board.offsetWidth : 0;
        var h = (board ? board.offsetHeight : 0) + (bar ? bar.offsetHeight : 0);
        return w + 'x' + h;
      }, function (size) {
        var parts = String(size).split('x');
        var w = parseInt(parts[0], 10) || 0;
        var h = parseInt(parts[1], 10) || 0;
        // 'auto' rather than 0 while there is nothing to measure: a bar with no
        // width is a bar nobody can find the login button on.
        $element[0].style.setProperty('--rm-lb-width', w > 0 ? (w + 'px') : 'auto');
        $element[0].style.setProperty('--rm-lb-height', h > 0 ? (h + 'px') : 'auto');
      });



      // BeamNG paints this app inside its HUD app host: an absolutely
      // positioned box, sized in px from the layout and clipped with
      // overflow:hidden. Nothing we do to our own elements can make that box
      // bigger - the window belongs to the HUD app layout editor (Pause >
      // System > HUD Apps), and the only Lua hook for it writes the layout
      // file without re-rendering. So anything dragged past that edge is
      // simply clipped and unreachable, which reads as "the drag does
      // nothing". The grip stops at the edge instead.
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
        stopLapTicker();
        // The app is going away (HUD teardown, pause menu, app closed), so
        // neither editor is open any more. Without this the start-slot markers
        // and the arena's corner labels would stay drawn in the world with no
        // panel behind them.
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
      // Re-assert both editor flags on mount. The mode and its tab are restored
      // from localStorage, so a rebuilt app can come straight back up on either
      // Editor tab -- and the Lua side was told "closed" when the old one was
      // torn down.
      pushEditorOpen();
    }]
  };
}]);
