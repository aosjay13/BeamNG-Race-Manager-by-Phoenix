angular.module('beamng.apps')

/**
 * Race Manager UI app.
 *
 * Receives race state via the native guihooks bridge ('RaceManagerUpdate',
 * 'RaceManagerCountdown') and renders host controls plus a live driver table.
 * The data originates on the BeamMP server (server/RaceManager/main.lua) and
 * is relayed by the client bridge extension lua/ge/extensions/raceManager.lua.
 * Reactive updates use $scope.$evalAsync (guihooks events arrive outside
 * Angular's digest cycle).
 */
.directive('raceManager', [function () {
  return {
    templateUrl: '/ui/modules/apps/RaceManager/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', function ($scope) {

      // ------------------------------------------------------------------
      // State
      // ------------------------------------------------------------------
      $scope.phase = 'waiting';   // waiting | grid | countdown | racing | finished
      $scope.raceTime = 0;
      $scope.countdown = null;    // null = hidden, 3..1 = number, 0 = GO!
      $scope.drivers = [];

      // Waypoint editor state
      $scope.showEditor = false;
      $scope.routeWaypoints = [];
      $scope.nextWp = 1;
      $scope.visualize = true;
      $scope.editorMsg = null;

      var PHASE_LABELS = {
        waiting:   'Waiting',
        grid:      'Grid Set',
        countdown: 'Countdown',
        racing:    'Racing',
        finished:  'Race Over'
      };
      var STATUS_LABELS = {
        waiting:  'Waiting',
        gridded:  'On Grid',
        racing:   'Racing',
        finished: 'Finished',
        dnf:      'DNF'
      };

      $scope.phaseLabel = function () { return PHASE_LABELS[$scope.phase] || $scope.phase; };
      $scope.statusLabel = function (s) { return STATUS_LABELS[s] || s; };

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

      $scope.formatFinishTime = function (row) {
        if (row.status === 'dnf') { return 'DNF'; }
        var t = row.finishTime;
        if (t === null || t === undefined) { return '—'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3);
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
        });
      });

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
      // UI -> LUA commands (host controls)
      // ------------------------------------------------------------------
      $scope.setGrid = function () {
        bngApi.engineLua('extensions.load("raceManager"); raceManager.setGrid()');
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

      // ------------------------------------------------------------------
      // UI -> LUA commands (waypoint editor)
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

      // ------------------------------------------------------------------
      // Lifecycle: load the backend and pull current state immediately so the
      // window is never blank, even before the first server broadcast.
      // ------------------------------------------------------------------
      bngApi.engineLua('extensions.load("raceManager"); raceManager.requestState()');
    }]
  };
}]);
