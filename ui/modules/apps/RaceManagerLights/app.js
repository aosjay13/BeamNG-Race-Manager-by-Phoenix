angular.module('beamng.apps')

/**
 * Race Manager Lights: the start lights, the flags and the drag tree, in a box
 * of their own so a driver can put them where they are already looking.
 *
 * NO ANGULAR BINDINGS. The light arrives on RaceManagerLights (pushed by
 * lua/ge/extensions/raceManager/lights.lua only when it changes) and is drawn
 * by setting classes on the SVG directly. Nothing here is watched, so the app
 * adds nothing to the digest the main panel already runs and never starts one.
 */
.directive('raceManagerLights', [function () {
  return {
    templateUrl: '/ui/modules/apps/RaceManagerLights/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    controller: ['$scope', '$element', function ($scope, $element) {
      var root = $element[0];

      // Five lamps for a race. '-' is unlit; the letters are the color
      // classes in app.html. GET READY is amber and blinks, which is the whole
      // point of this app: it must never be mistaken for the green.
      var RACE = {
        idle:        { lamps: '-----', cap: 'RACE LIGHTS' },
        grid:        { lamps: '-----', cap: 'ON THE GRID' },
        count3:      { lamps: 'r---r', cap: '3' },
        count2:      { lamps: 'rr-rr', cap: '2' },
        count1:      { lamps: 'rrrrr', cap: '1' },
        go:          { lamps: 'ggggg', cap: 'GO' },
        pace:        { lamps: 'y-y-y', cap: 'PACE LAP' },
        ready:       { lamps: 'aaaaa', cap: 'GET READY', blink: true },
        green:       { lamps: 'ggggg', cap: 'GREEN FLAG' },
        cautionBack: { lamps: 'yyyyy', cap: 'CAUTION · RACE BACK', blink: true },
        caution:     { lamps: 'yyyyy', cap: 'CAUTION' },
        restart:     { lamps: 'yy-yy', cap: 'RESTART THIS LAP' },
        yellow:      { lamps: '-yyy-', cap: 'YELLOW FLAG', blink: true },
        red:         { lamps: 'rrrrr', cap: 'RED FLAG' },
        white:       { lamps: 'wwwww', cap: 'LAST LAP' },
        checkered:   { lamps: 'ccccc', cap: 'CHECKERED FLAG' },
        blue:        { lamps: 'bbbbb', cap: 'BLUE FLAG', blink: true }
      };
      // A moment (GO, the green, a flag of your own) only shows over these. A
      // red or a caution that arrives during one wins at once.
      var LOW = { off: true, grid: true };
      var HINT = ['a', 'a', 'a', 'g', 'r'];
      var PREVIEW_MS = 6000;
      // Widest a caption may run, per layout, before it is squeezed to fit.
      var CAP_MAX = { w: 470, t: 160 };
      // TALL WHEN THE BOX IS. HUD apps have no settings of their own, but the
      // driver sizes the box: drawn taller than it is wide, the lamps stand up.
      var TALL_RATIO = 1.25;
      var vertical = false;

      var standing = 'off';
      var tree = null;
      var moment = null;
      var momentUntil = 0;
      var momentTimer = null;
      var slip = null;
      var preview = true;
      // What each element was last given, so a push that changes one lamp
      // writes one attribute.
      var written = {};
      var els = null;

      // BOTH LAYOUTS ARE KEPT CURRENT, the hidden one too, so switching shows
      // the right light at once. A write per lamp per change, a few times a race.
      function layout(svg, key) {
        return {
          key: key,
          race: svg ? svg.querySelectorAll('.rml-race .rml-lamp') : [],
          drag: svg ? svg.querySelectorAll('.rml-drag .rml-lamp') : [],
          pre: svg ? svg.querySelector('.rml-pre') : null,
          stage: svg ? svg.querySelector('.rml-stage') : null,
          cap: svg ? svg.querySelector('.rml-cap') : null
        };
      }

      function el() {
        if (els) { return els; }
        els = [layout(root.querySelector('svg.rml-wide'), 'w'),
               layout(root.querySelector('svg.rml-tall'), 't')];
        return els;
      }

      function setClass(node, key, cls) {
        if (!node || written[key] === cls) { return; }
        written[key] = cls;
        node.setAttribute('class', cls);
      }

      // Squeezed to fit only when too long; stretching a short word to the full
      // width would look like a different font. A hidden layout measures zero,
      // so it is fitted again when it is shown (orient).
      function fit(L) {
        var cap = L.cap;
        if (!cap) { return; }
        cap.removeAttribute('textLength');
        cap.removeAttribute('lengthAdjust');
        try {
          if (cap.getComputedTextLength() > CAP_MAX[L.key]) {
            cap.setAttribute('textLength', String(CAP_MAX[L.key]));
            cap.setAttribute('lengthAdjust', 'spacingAndGlyphs');
          }
        } catch (e) { /* not laid out yet: the caption is still readable */ }
      }

      function setCaption(text) {
        el().forEach(function (L) {
          if (!L.cap || written[L.key + 'cap'] === text) { return; }
          written[L.key + 'cap'] = text;
          L.cap.textContent = text;
          fit(L);
        });
      }

      function orient() {
        var w = root.clientWidth, h = root.clientHeight;
        if (!w || !h) { return; }
        var v = h > w * TALL_RATIO;
        if (v === vertical) { return; }
        vertical = v;
        root.classList.toggle('rml-vertical', v);
        fit(el()[v ? 1 : 0]);
      }

      function drawRace(name) {
        var p = RACE[name] || RACE.idle;
        el().forEach(function (L) {
          for (var i = 0; i < L.race.length; i++) {
            var c = p.lamps.charAt(i);
            var cls = 'rml-lamp';
            if (c === 'c') {
              cls += (i % 2 === 0) ? ' rml-chk-a' : ' rml-chk-b';
            } else if (c !== '-') {
              cls += ' rml-' + c + (p.blink ? ' rml-blink' : '');
            }
            setClass(L.race[i], L.key + 'r' + i, cls);
          }
        });
        setCaption(p.cap);
      }

      function fmt(v, n) {
        return (v === null || v === undefined) ? '--' : Number(v).toFixed(n);
      }

      function drawTree() {
        var t = tree || {};
        var st = t.stage || 'off';
        var lit = [
          st === 'amber1' || st === 'amber2' || st === 'amber3',
          st === 'amber2' || st === 'amber3',
          st === 'amber3',
          st === 'green',
          st === 'red' || (!tree && slip && slip.foul)
        ];
        el().forEach(function (L) {
          for (var i = 0; i < L.drag.length; i++) {
            setClass(L.drag[i], L.key + 'd' + i,
              'rml-lamp ' + (lit[i] ? 'rml-' + HINT[i] : 'rml-hint-' + HINT[i]));
          }
          setClass(L.pre, L.key + 'pre', 'rml-small rml-pre' + (t.prestaged ? ' rml-on' : ''));
          setClass(L.stage, L.key + 'stage', 'rml-small rml-stage' + (t.staged ? ' rml-on' : ''));
        });
        if (!tree && slip) {
          setCaption((slip.foul ? 'RED  ' : '') + 'RT ' + fmt(slip.rt, 3)
            + '  ET ' + fmt(slip.et, 3) + '  ' + fmt(slip.speed, 1) + ' MPH');
        } else if (st === 'red') {
          setCaption('RED LIGHT');
        } else {
          var cap = t.lane ? 'LANE ' + t.lane : 'DRAG';
          if (t.dial) { cap += ' · DIAL ' + fmt(t.dial, 2); }
          if (t.delay > 0) { cap += ' · +' + fmt(t.delay, 3); }
          setCaption(cap);
        }
      }

      function render() {
        orient();
        var show = standing;
        if (moment && Date.now() < momentUntil) {
          if (LOW[show]) { show = moment; }
        } else {
          moment = null;
        }
        var dragMode = show === 'tree' || (show === 'off' && !!slip);
        root.classList.toggle('rml-dragmode', dragMode);
        if (dragMode) {
          drawTree();
        } else {
          drawRace(show === 'off' ? 'idle' : show);
        }
        root.classList.toggle('rml-hidden', show === 'off' && !slip && !preview);
      }

      $scope.$on('RaceManagerLights', function (event, data) {
        if (!data) { return; }
        standing = data.light || 'off';
        tree = data.tree || null;
        if (data.moment) {
          moment = data.moment;
          momentUntil = Date.now() + (Number(data.hold) || 3) * 1000;
          if (momentTimer) { clearTimeout(momentTimer); }
          momentTimer = setTimeout(function () { momentTimer = null; render(); },
            momentUntil - Date.now() + 20);
        }
        // The resend answering this app's own load is usually 'off', and must
        // not cut the preview short.
        if (standing !== 'off' || data.moment) { preview = false; }
        render();
      });

      // This driver's time slip, held until drag.lua takes it down.
      $scope.$on('RaceManagerDragRun', function (event, data) {
        if (!data || data.clear || data.aborted) {
          slip = null;
        } else if (data.et != null || data.rt != null) {
          slip = { rt: data.rt, et: data.et, speed: data.speed, foul: data.foul === true };
        }
        render();
      });

      // SHOWN FOR A FEW SECONDS WHEN IT LOADS, so a driver who has just added
      // it can see where it went. After that it is invisible until there is a
      // light to show.
      render();
      var previewTimer = setTimeout(function () { preview = false; render(); }, PREVIEW_MS);

      // Resizing the box in the HUD editor flips the layout as it happens.
      // Without ResizeObserver it still flips, on the next light.
      var resizeWatch = null;
      if (window.ResizeObserver) {
        resizeWatch = new ResizeObserver(function () { orient(); });
        resizeWatch.observe(root);
      }

      // The light it missed while it was not loaded.
      if (window.bngApi) {
        bngApi.engineLua('if raceManager and raceManager.lightsResend then raceManager.lightsResend() end');
      }

      $scope.$on('$destroy', function () {
        if (momentTimer) { clearTimeout(momentTimer); }
        clearTimeout(previewTimer);
        if (resizeWatch) { resizeWatch.disconnect(); }
      });
    }]
  };
}]);
