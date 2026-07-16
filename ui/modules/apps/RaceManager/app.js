angular.module('beamng.apps')

/**
 * Race Manager UI app.
 *
 * Receives leaderboard state from lua/ge/extensions/raceManager.lua via the
 * native guihooks bridge ('RaceManagerUpdate') and renders a live standings
 * table. Reactive updates are driven by $scope.$evalAsync (a safe digest
 * trigger; guihooks events arrive outside Angular's digest cycle).
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
      $scope.raceActive = false;
      $scope.raceTime = 0;
      $scope.standings = [];

      // ------------------------------------------------------------------
      // Formatting helpers
      // ------------------------------------------------------------------
      function pad2(n) { return (n < 10 ? '0' : '') + n; }

      $scope.formatRaceTime = function (t) {
        if (!t || t < 0) { return '00:00'; }
        var h = Math.floor(t / 3600);
        var m = Math.floor((t % 3600) / 60);
        var s = Math.floor(t % 60);
        return (h > 0 ? h + ':' + pad2(m) : pad2(m)) + ':' + pad2(s);
      };

      $scope.formatLapTime = function (t) {
        if (t === null || t === undefined) { return '—'; }
        var m = Math.floor(t / 60);
        var s = t - m * 60;
        return m + ':' + (s < 10 ? '0' : '') + s.toFixed(3);
      };

      $scope.formatGap = function (row) {
        if (row.pos === 1) { return 'Leader'; }
        if (row.dnf) { return 'DNF'; }
        var gap = row.gapLeader;
        if (gap === null || gap === undefined) { return '—'; }
        if (typeof gap === 'string') { return gap; }        // '+2 L' lapped format
        return '+' + gap.toFixed(3);
      };

      // ------------------------------------------------------------------
      // Bridge: LUA -> UI
      // ------------------------------------------------------------------
      $scope.$on('RaceManagerUpdate', function (event, data) {
        if (!data) { return; }
        // guihooks events fire outside the digest cycle; $evalAsync applies
        // the mutation and schedules a digest without risking
        // "$digest already in progress" errors.
        $scope.$evalAsync(function () {
          $scope.raceActive = !!data.raceActive;
          $scope.raceTime = data.raceTime || 0;
          $scope.standings = data.standings || [];
        });
      });

      // ------------------------------------------------------------------
      // UI -> LUA commands
      // ------------------------------------------------------------------
      $scope.startRace = function () {
        bngApi.engineLua('extensions.load("raceManager"); raceManager.startRace()');
      };

      $scope.stopRace = function () {
        bngApi.engineLua('raceManager.stopRace()');
      };

      $scope.resetRace = function () {
        bngApi.engineLua('raceManager.resetRace()');
      };

      // ------------------------------------------------------------------
      // Lifecycle
      // ------------------------------------------------------------------
      // Load the backend extension and ask for the current state so the app
      // shows live data immediately when (re)opened mid-race.
      bngApi.engineLua('extensions.load("raceManager"); raceManager.requestState()');

      $scope.$on('$destroy', function () {
        // Backend keeps running so timing isn't lost if the app is re-opened.
      });
    }]
  };
}]);
