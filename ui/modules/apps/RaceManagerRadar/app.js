angular.module('beamng.apps')

/**
 * PRM - Radar: the cars around this driver's own car and how close they
 * are, heading up, our car in the middle.
 *
 * NO ANGULAR BINDINGS. lua/ge/extensions/raceManager/radar.lua pushes the cars
 * in range on RaceManagerRadar, about twenty times a second while any are near
 * and never while none are. Each push moves a fixed pool of SVG shapes; nothing
 * here is watched, so the app adds nothing to the digest the main panel runs.
 */
.directive('raceManagerRadar', [function () {
  return {
    templateUrl: '/ui/modules/apps/RaceManagerRadar/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$element', function ($scope, $element) {
      var root = $element[0];
      var NS = 'http://www.w3.org/2000/svg';
      var POOL = 16;           // cars drawn at most; the nearest win
      var SEGS = 2;            // spotter segments per side
      var RED = 2;             // meters of gap
      var AMBER = 6;
      var BAR_X = 27.4;        // inner edge of each spotter bar from our center line
      var BAR_W = 1.6;
      var BAR_HALF = 6.5;      // the bars run this far ahead of and behind our center
      var SIDE_REACH = 4;      // a car this far off our side, or closer, is alongside
      var HOLD_MS = 1500;      // stay up this long after the last car leaves
      var PREVIEW_MS = 6000;

      var built = false;
      var cars = [];           // [{ g, body, glass, label, cache }]
      var segs = { left: [], right: [] };
      var meBody = null;
      var meGlass = null;
      var meSize = '';
      var caption = null;
      var preview = true;
      var hideTimer = null;

      function make(tag, cls, parent) {
        var el = document.createElementNS(NS, tag);
        if (cls) { el.setAttribute('class', cls); }
        parent.appendChild(el);
        return el;
      }

      function build() {
        if (built) { return; }
        built = true;
        var carLayer = root.querySelector('.rmr-cars');
        var labelLayer = root.querySelector('.rmr-labels');
        var segLayer = root.querySelector('.rmr-segs');
        meBody = root.querySelector('.rmr-me-body');
        meGlass = root.querySelector('.rmr-me-glass');
        caption = root.querySelector('.rmr-caption');
        for (var i = 0; i < POOL; i++) {
          var g = make('g', null, carLayer);
          g.style.display = 'none';
          cars.push({
            g: g,
            body: make('path', 'rmr-car', g),
            glass: make('path', 'rmr-glass', g),
            label: make('text', 'rmr-label', labelLayer),
            cache: {}
          });
          cars[i].label.style.display = 'none';
        }
        ['left', 'right'].forEach(function (side) {
          for (var j = 0; j < SEGS; j++) {
            var r = make('rect', null, segLayer);
            r.setAttribute('x', side === 'left' ? -BAR_X - BAR_W : BAR_X);
            r.setAttribute('width', BAR_W);
            r.setAttribute('rx', BAR_W / 2);
            r.style.display = 'none';
            segs[side].push(r);
          }
        });
      }

      // Write an attribute only when it changes: most cars barely move between
      // two pushes, and a style recalculation per shape per push adds up.
      function put(slot, el, key, name, value) {
        if (slot.cache[key] === value) { return; }
        slot.cache[key] = value;
        if (name === 'display') { el.style.display = value; } else if (name === 'text') {
          el.textContent = value;
        } else { el.setAttribute(name, value); }
      }

      function round(v) { return Math.round(v * 100) / 100; }

      function colorClass(c) {
        if (c.gh) { return 'rmr-car rmr-ghost'; }
        var lapped = c.lap ? ' rmr-lapped' : '';
        if (c.g < RED) { return 'rmr-car rmr-red' + lapped; }
        if (c.g < AMBER) { return 'rmr-car rmr-amber' + lapped; }
        return c.lap ? 'rmr-car rmr-blue' : 'rmr-car rmr-far';
      }

      function gapText(g) {
        return (g < 10 ? g.toFixed(1) : String(Math.round(g))) + ' m';
      }

      // The car's extent in our frame: how far it reaches across and along us.
      function extent(c) {
        var r = c.a * Math.PI / 180;
        var sx = Math.sin(r), sy = Math.cos(r);
        var hl = c.l / 2, hw = c.w / 2;
        var ax = Math.abs(sx * hl) + Math.abs(sy * hw);
        var ay = Math.abs(sy * hl) + Math.abs(sx * hw);
        return { x0: c.x - ax, x1: c.x + ax, y0: c.y - ay, y1: c.y + ay };
      }

      function drawSegments(list, me) {
        var used = { left: 0, right: 0 };
        var hw = (me && me.w ? me.w : 1.9) / 2;
        for (var i = 0; i < list.length; i++) {
          var c = list[i];
          if (c.gh) { continue; }
          var e = extent(c);
          var side = null;
          if (e.x1 <= -hw + 0.3 && -hw - e.x1 < SIDE_REACH) { side = 'left'; }
          if (e.x0 >= hw - 0.3 && e.x0 - hw < SIDE_REACH) { side = 'right'; }
          if (!side || used[side] >= SEGS) { continue; }
          var y0 = Math.max(e.y0, -BAR_HALF), y1 = Math.min(e.y1, BAR_HALF);
          if (y1 <= y0) { continue; }
          var r = segs[side][used[side]++];
          r.setAttribute('y', round(-y1));
          r.setAttribute('height', round(y1 - y0));
          r.setAttribute('class', c.g < RED ? 'rmr-seg-red' : 'rmr-seg-amber');
          r.style.display = '';
        }
        ['left', 'right'].forEach(function (side) {
          for (var j = used[side]; j < SEGS; j++) { segs[side][j].style.display = 'none'; }
        });
      }

      // A CAR, top down, at its real size: a body with a rounded nose and
      // mirrors, and the windscreen and rear window, which say which way is
      // front without an arrow. Built from fractions of the half-width W and
      // half-length L, so any car keeps the same shape. Ours and every other.
      function carPaths(w, l) {
        var W = w / 2, L = l / 2;
        function p(x, y) { return round(x * W) + ' ' + round(y * L); }
        return {
          body: 'M ' + p(-0.72, -1) + ' Q ' + p(0, -1.05) + ' ' + p(0.72, -1)
            + ' Q ' + p(1, -1) + ' ' + p(1, -0.78)
            + ' L ' + p(1, 0.84) + ' Q ' + p(1, 1) + ' ' + p(0.76, 1)
            + ' L ' + p(-0.76, 1) + ' Q ' + p(-1, 1) + ' ' + p(-1, 0.84)
            + ' L ' + p(-1, -0.78) + ' Q ' + p(-1, -1) + ' ' + p(-0.72, -1) + ' Z'
            // Mirrors.
            + ' M ' + p(1, -0.38) + ' L ' + p(1.24, -0.42) + ' L ' + p(1.24, -0.3) + ' L ' + p(1, -0.28) + ' Z'
            + ' M ' + p(-1, -0.38) + ' L ' + p(-1.24, -0.42) + ' L ' + p(-1.24, -0.3) + ' L ' + p(-1, -0.28) + ' Z',
          // Windscreen, curved along its lower edge, then the rear window.
          glass: 'M ' + p(-0.8, -0.4) + ' Q ' + p(0, -0.5) + ' ' + p(0.8, -0.4)
            + ' L ' + p(0.66, -0.1) + ' L ' + p(-0.66, -0.1) + ' Z'
            + ' M ' + p(-0.66, 0.46) + ' L ' + p(0.66, 0.46) + ' L ' + p(0.76, 0.7)
            + ' Q ' + p(0, 0.76) + ' ' + p(-0.76, 0.7) + ' Z'
        };
      }

      // Ours: only on a size change.
      function drawMe(me) {
        if (!me || !me.l || !me.w) { return; }
        var key = me.l + 'x' + me.w;
        if (key === meSize) { return; }
        meSize = key;
        var shape = carPaths(me.w, me.l);
        meBody.setAttribute('d', shape.body);
        meGlass.setAttribute('d', shape.glass);
      }

      function show(on) {
        if (on) {
          if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
          root.classList.remove('rmr-hidden');
          return;
        }
        if (hideTimer || preview) { return; }
        hideTimer = setTimeout(function () {
          hideTimer = null;
          root.classList.add('rmr-hidden');
        }, HOLD_MS);
      }

      function render(data) {
        build();
        var list = (data && data.cars) || [];
        var range = (data && data.range) || 25;
        var edge = (data && data.edge) || 6;
        drawMe(data && data.me);
        // Nearest first, so a crowded field spends the pool and the labels on
        // the cars that matter.
        list.sort(function (a, b) { return a.g - b.g; });
        for (var i = 0; i < POOL; i++) {
          var slot = cars[i];
          var c = list[i];
          if (!c) {
            put(slot, slot.g, 'disp', 'display', 'none');
            put(slot, slot.label, 'ldisp', 'display', 'none');
            continue;
          }
          var d = Math.sqrt(c.x * c.x + c.y * c.y);
          var fade = d <= range ? 1 : Math.max(0, 1 - (d - range) / edge);
          put(slot, slot.g, 'disp', 'display', '');
          put(slot, slot.g, 'tf', 'transform', 'translate(' + c.x + ' ' + (-c.y) + ') rotate(' + c.a + ')');
          put(slot, slot.g, 'op', 'opacity', round(fade));
          // The shape is rebuilt only when this slot gets a car of another size.
          var size = c.w + 'x' + c.l;
          if (slot.cache.size !== size) {
            slot.cache.size = size;
            var shape = carPaths(c.w, c.l);
            slot.body.setAttribute('d', shape.body);
            slot.glass.setAttribute('d', shape.glass);
          }
          put(slot, slot.body, 'cls', 'class', colorClass(c));
          // The windows say which way it faces. A ghost is an outline only.
          put(slot, slot.glass, 'gd', 'display', c.gh ? 'none' : '');
          var parts = [];
          if (c.p) { parts.push('P' + c.p); }
          if (!c.gh && c.g < AMBER) { parts.push(gapText(c.g)); }
          var text = parts.join(' · ');
          if (!text || fade < 0.2) {
            put(slot, slot.label, 'ldisp', 'display', 'none');
          } else {
            // OUTWARD, away from us: a label above a car alongside lands on our
            // own car, which is the one thing the radar must not hide.
            var ux = d > 0.5 ? c.x / d : 0, uy = d > 0.5 ? c.y / d : 1;
            var off = Math.max(c.l, c.w) / 2 + 1.2;
            put(slot, slot.label, 'ldisp', 'display', '');
            put(slot, slot.label, 'txt', 'text', text);
            put(slot, slot.label, 'anchor', 'text-anchor',
              ux < -0.35 ? 'end' : (ux > 0.35 ? 'start' : 'middle'));
            put(slot, slot.label, 'lx', 'x', round(c.x + ux * off));
            put(slot, slot.label, 'ly', 'y', round(-(c.y + uy * off) + 0.8));
          }
        }
        drawSegments(list, data && data.me);
        show(list.length > 0);
      }

      $scope.$on('RaceManagerRadar', function (event, data) {
        // The first real car ends the preview: the caption goes, the cars stay.
        if (preview && data && data.cars && data.cars.length) {
          preview = false;
          caption.style.display = 'none';
        }
        render(data);
      });

      // SHOWN FOR A FEW SECONDS WHEN IT LOADS, so a driver who has just added
      // it can see where it went. After that it is invisible until a car is near.
      build();
      root.classList.remove('rmr-hidden');
      var previewTimer = setTimeout(function () {
        preview = false;
        if (caption) { caption.style.display = 'none'; }
        var anyShown = cars.some(function (s) { return s.cache.disp === ''; });
        if (!anyShown) { root.classList.add('rmr-hidden'); }
      }, PREVIEW_MS);

      $scope.$on('$destroy', function () {
        clearTimeout(previewTimer);
        if (hideTimer) { clearTimeout(hideTimer); }
      });
    }]
  };
}]);
