(function () {
  'use strict';

  angular.module('beamng.apps')
    .directive('raceManager', [function () {
      return {
        templateUrl: '/ui/modules/apps/RaceManager/app.html',
        replace: true,
        restrict: 'EA',
        scope: true,
        controllerAs: 'vm',
        bindToController: true,
        controller: ['$scope', function ($scope) {
          var vm = this
          vm.paused = false
          vm.raceDuration = 0
          vm.raceDurationFormatted = '--:--.---'
          vm.vehicles = []

          var vueState = null
          if (window.Vue && window.Vue.reactive) {
            vueState = window.Vue.reactive({
              raceDuration: vm.raceDuration,
              raceDurationFormatted: vm.raceDurationFormatted,
              vehicles: vm.vehicles
            })
          }

          function applyUpdate(data) {
            data = data || {}

            vm.raceDuration = Number(data.raceDuration) || 0
            vm.raceDurationFormatted = data.raceDurationFormatted || '--:--.---'
            vm.vehicles = Array.isArray(data.vehicles) ? data.vehicles : []

            if (vueState) {
              vueState.raceDuration = vm.raceDuration
              vueState.raceDurationFormatted = vm.raceDurationFormatted
              vueState.vehicles = vm.vehicles
            }

            if (!$scope.$$phase) {
              $scope.$digest()
            }
          }

          var deregRaceUpdate = $scope.$on('RaceManagerUpdate', function (_event, data) {
            applyUpdate(data)
          })

          var deregPause = $scope.$on('app:pause', function () {
            vm.paused = true
            if (!$scope.$$phase) {
              $scope.$digest()
            }
          })

          var deregResume = $scope.$on('app:resume', function () {
            vm.paused = false
            if (!$scope.$$phase) {
              $scope.$digest()
            }
          })

          $scope.$on('$destroy', function () {
            if (typeof deregRaceUpdate === 'function') {
              deregRaceUpdate()
            }
            if (typeof deregPause === 'function') {
              deregPause()
            }
            if (typeof deregResume === 'function') {
              deregResume()
            }
          })
        }]
      }
    }])
})()
