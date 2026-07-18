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
    controller: ['$scope', '$element', function ($scope, $element) {

      // ------------------------------------------------------------------
      // State
      // ------------------------------------------------------------------
      $scope.phase = 'waiting';   // waiting | qualifying | grid | countdown | racing | finished
      $scope.raceTime = 0;
      $scope.totalLaps = 5;
      $scope.countdown = null;    // null = hidden, 3..1 = number, 0 = GO!
      $scope.drivers = [];

      // Settings inputs (host)
      $scope.lapsInput = 5;
      $scope.widthInput = 20;

      // Checkpoint editor state
      $scope.showEditor = false;
      $scope.routeWaypoints = [];
      $scope.nextWp = 1;
      $scope.visualize = true;
      $scope.editorMsg = null;

      // Track layout state (server-side persistent layouts, current map only)
      $scope.layouts = [];              // [{ name, map, width, checkpoints }]
      $scope.layoutMap = '';            // map the server filtered the list by
      // Bound as an object ("dot rule") because these inputs live inside the
      // ng-if editor panel, whose child scope would shadow primitive bindings.
      $scope.layoutUi = { name: '', selected: '' };

      // ----------------------------------------------------------------
      // DEMO DERBY (isolated module) — separate state, events and commands;
      // nothing here touches the circuit racing scope above.
      // ----------------------------------------------------------------
      $scope.showDerby = false;
      $scope.derby = {
        phase: 'idle',        // idle | running | finished (server authoritative)
        time: 0,
        boundaryCount: 0,
        winner: null,
        players: []           // { id, name, status, reason, elimTime }
      };
      // Dot rule again: these inputs live inside the ng-if derby panel.
      $scope.derbyUi = { oob: 5, demo: 10 };
      $scope.derbyWarning = null;  // { type: 'oob'|'stopped', remaining } or null

      var PHASE_LABELS = {
        waiting:    'Waiting',
        qualifying: 'Qualifying',
        grid:       'Grid Locked',
        countdown:  'Countdown',
        racing:     'Racing',
        finished:   'Race Over'
      };
      var STATUS_LABELS = {
        waiting:    'Waiting',
        qualifying: 'On Track',
        gridded:    'On Grid',
        racing:     'Racing',
        finished:   'Finished',
        dnf:        'DNF'
      };

      $scope.phaseLabel = function () { return PHASE_LABELS[$scope.phase] || $scope.phase; };
      $scope.statusLabel = function (s) { return STATUS_LABELS[s] || s; };

      // Qualifying view while the quali session runs (and in waiting, where a
      // closed quali's provisional order is still the useful thing to show if
      // any times exist); Race view from Grid Locked onward.
      $scope.isQualiView = function () {
        if ($scope.phase === 'qualifying') { return true; }
        if ($scope.phase === 'waiting') {
          return $scope.drivers.some(function (d) { return d.qualiBest != null; });
        }
        return false;
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
          $scope.raceTime = data.raceTime || 0;
          $scope.drivers = data.drivers || [];
          if (typeof data.totalLaps === 'number') {
            if ($scope.totalLaps !== data.totalLaps) { $scope.lapsInput = data.totalLaps; }
            $scope.totalLaps = data.totalLaps;
          }
          if ($scope.phase !== 'countdown') { $scope.countdown = null; }
        });
      });

      $scope.$on('RaceManagerCountdown', function (event, data) {
        $scope.$evalAsync(function () {
          // data.count: 3, 2, 1, 0 (GO!), -1 (hide overlay)
          var c = (data && typeof data.count === 'number') ? data.count : -1;
          $scope.countdown = c >= 0 ? c : null;
        });
      });

      $scope.$on('RaceManagerRoute', function (event, data) {
        if (!data) { return; }
        $scope.$evalAsync(function () {
          $scope.routeWaypoints = data.waypoints || [];
          $scope.nextWp = data.nextWp || 1;
          $scope.visualize = data.visualize !== false;
          if (typeof data.width === 'number') { $scope.widthInput = data.width; }
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
          $scope.derby.time = data.derbyTime || 0;
          $scope.derby.winner = data.winner || null;
          $scope.derby.boundaryCount = toArray(data.boundary).length;
          $scope.derby.players = toArray(data.players);
          if (typeof data.oobLimit === 'number' && $scope.derby.phase !== 'running') {
            $scope.derbyUi.oob = data.oobLimit;
          }
          if (typeof data.demoLimit === 'number' && $scope.derby.phase !== 'running') {
            $scope.derbyUi.demo = data.demoLimit;
          }
          if ($scope.derby.phase !== 'running') { $scope.derbyWarning = null; }
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

      $scope.toggleDerby = function () {
        $scope.showDerby = !$scope.showDerby;
        if ($scope.showDerby) {
          bngApi.engineLua('raceManager.derbyRequestState()');
        }
      };

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
        bngApi.engineLua('raceManager.derbySetConfig(' + oob + ', ' + demo + ')');
      };
      $scope.derbyAddMarker = function () {
        bngApi.engineLua('raceManager.derbyAddMarker()');
      };
      $scope.derbyClearBoundary = function () {
        bngApi.engineLua('raceManager.derbyClearBoundary()');
      };
      $scope.derbyStart = function () {
        // Push the current timer inputs first so the derby always starts with
        // what the admin sees in the two fields.
        $scope.derbyApplyConfig();
        bngApi.engineLua('raceManager.derbyStart()');
      };
      $scope.derbyEnd = function () {
        bngApi.engineLua('raceManager.derbyEnd()');
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
        var n = parseInt($scope.lapsInput, 10);
        if (!n || n < 1) { return; }
        bngApi.engineLua('raceManager.setTotalLaps(' + n + ')');
      };
      $scope.applyWidth = function () {
        var w = parseFloat($scope.widthInput);
        if (!w || w <= 0) { return; }
        bngApi.engineLua('raceManager.setCheckpointWidth(' + w + ')');
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

      $scope.toggleEditor = function () {
        $scope.showEditor = !$scope.showEditor;
        if ($scope.showEditor) { schedulePreview(); }  // canvas re-enters the DOM
      };

      // ------------------------------------------------------------------
      // UI -> LUA commands (track layouts)
      // ------------------------------------------------------------------
      // Layout names go through engineLua as Lua string literals.
      function luaStr(s) {
        return "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, ' ') + "'";
      }

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

      $scope.onLayoutSelect = function () {
        schedulePreview();
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
      // Lifecycle: load the backend and pull current state immediately so the
      // window is never blank, even before the first server broadcast.
      // ------------------------------------------------------------------
      // requestState also pulls the map-filtered layout list from the server.
      bngApi.engineLua('extensions.load("raceManager"); raceManager.requestState()');
      // Demo Derby module: pull its state separately (isolated channel).
      bngApi.engineLua('raceManager.derbyRequestState()');
    }]
  };
}]);
