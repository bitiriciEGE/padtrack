// Wires PadClient to the page: touch surface, status pill, pairing and settings sheets.
(function () {
  'use strict';

  const { PadClient, TouchTracker, guessDeviceName } = window.PadTrackClient;
  const $ = (id) => document.getElementById(id);

  const surface = $('surface');
  const statusPill = $('status');
  const statusText = $('status-text');
  const pairingSheet = $('pairing');
  const pairingReason = $('pairing-reason');
  const settingsSheet = $('settings');
  const settingsStatus = $('settings-status');
  const showTouchesToggle = $('show-touches');
  const homeHint = $('home-hint');

  const isStandalone = window.navigator.standalone === true
    || (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);

  // localStorage can throw (private browsing, storage disabled).
  const storage = {
    get(key) { try { return window.localStorage.getItem(key); } catch (_) { return null; } },
    set(key, value) { try { window.localStorage.setItem(key, value); } catch (_) { /* fragment still has it */ } },
    remove(key) { try { window.localStorage.removeItem(key); } catch (_) { /* nothing stored */ } },
  };

  // MARK: Status

  const messages = {
    idle: () => 'Başlatılıyor…',
    connecting: (s) => s.detail === 'unreachable'
      ? "Mac'e ulaşılamıyor · PadTrack açık mı, aynı Wi‑Fi'de misin?"
      : "Mac'e bağlanılıyor…",
    waiting: (s) => `${s.host || 'Mac'} · Mac menüsünde “Bağlan”a tıkla`,
    active: (s) => `${s.host || 'Mac'} · Safari`,
    paused: () => 'Duraklatıldı',
    unpaired: () => 'Eşleştirme gerekli',
  };

  const pairingReasons = {
    none: '',
    used: 'Bu QR kod kullanılmış ya da yenilenmiş. Mac menüsündeki güncel kodu okut.',
    revoked: "Bu iPad'in eşleşmesi Mac'te kaldırılmış. Yeniden eşleştirmek için QR kodu okut.",
  };

  function render(status) {
    const text = (messages[status.state] || messages.idle)(status);
    statusText.textContent = text;
    settingsStatus.textContent = text;
    statusPill.dataset.state = status.state;

    const unpaired = status.state === 'unpaired';
    pairingSheet.hidden = !unpaired;
    pairingReason.textContent = unpaired ? pairingReasons[status.detail] || '' : '';
    pairingReason.hidden = !pairingReason.textContent;

    if (status.state === 'waiting' && client && client.justPaired && !isStandalone && !hintDismissed()) {
      homeHint.hidden = false;
    }
  }

  // MARK: Client

  const client = new PadClient({
    WebSocket: window.WebSocket,
    url: (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws',
    storage,
    getHash: () => location.hash,
    setHash: (hash) => {
      try {
        history.replaceState(null, '', location.pathname + location.search + (hash ? '#' + hash : ''));
      } catch (_) {
        // Not fatal: the token is also in localStorage.
      }
    },
    deviceName: guessDeviceName(navigator.userAgent, navigator.maxTouchPoints || 0),
    now: () => performance.now(),
    setTimeout: (fn, ms) => window.setTimeout(fn, ms),
    clearTimeout: (handle) => window.clearTimeout(handle),
    setInterval: (fn, ms) => window.setInterval(fn, ms),
    onStatus: render,
  });

  // MARK: Touches

  const tracker = new TouchTracker();
  const dots = new Map();
  let showTouches = storage.get('padtrack.showTouches') !== '0';
  showTouchesToggle.checked = showTouches;

  function handleTouches(event) {
    event.preventDefault();
    // targetTouches: fingers that started on the surface (not on the settings button).
    const points = tracker.frame(event.targetTouches);
    // Safari's event.timeStamp is in milliseconds on the page's monotonic clock.
    const ms = event.timeStamp > 1e12 ? performance.now() : event.timeStamp;
    client.sendTouches(points, ms / 1000, event.type !== 'touchmove');
    if (showTouches) drawDots(points);
    requestWakeLock();
  }

  for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) {
    surface.addEventListener(type, handleTouches, { passive: false });
  }
  // Safari's own pinch-zoom and double-tap gestures.
  for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
    document.addEventListener(type, (event) => event.preventDefault(), { passive: false });
  }
  surface.addEventListener('contextmenu', (event) => event.preventDefault());

  function drawDots(points) {
    const alive = new Set();
    for (const point of points) {
      alive.add(point.id);
      let dot = dots.get(point.id);
      if (!dot) {
        dot = document.createElement('div');
        dot.className = 'finger';
        surface.appendChild(dot);
        dots.set(point.id, dot);
      }
      dot.style.transform = `translate(${point.x - 28}px, ${point.y - 28}px)`;
    }
    for (const [id, dot] of dots) {
      if (!alive.has(id)) {
        dot.remove();
        dots.delete(id);
      }
    }
  }

  function clearDots() {
    for (const dot of dots.values()) dot.remove();
    dots.clear();
  }

  // MARK: Surface size and page lifecycle

  function updateSurface() {
    client.setSurface(window.innerWidth, window.innerHeight);
  }
  window.addEventListener('resize', updateSurface);
  window.addEventListener('orientationchange', () => window.setTimeout(updateSurface, 250));

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      client.suspend();
      clearDots();
    } else {
      client.resume();
      requestWakeLock();
    }
  });
  window.addEventListener('pagehide', () => client.suspend());
  window.addEventListener('pageshow', () => { if (!document.hidden) client.resume(); });

  // Keeps the screen on where Safari allows it (needs HTTPS, so usually not on a local
  // address); otherwise the settings sheet explains Auto-Lock.
  let wakeLock = null;
  function requestWakeLock() {
    if (wakeLock || !navigator.wakeLock || document.hidden) return;
    navigator.wakeLock.request('screen').then((lock) => {
      wakeLock = lock;
      lock.addEventListener('release', () => { wakeLock = null; });
    }).catch(() => {});
  }

  // MARK: Sheets

  function hintDismissed() {
    return storage.get('padtrack.homeHintDismissed') === '1';
  }

  $('settings-button').addEventListener('click', () => {
    settingsSheet.hidden = false;
  });
  $('settings-done').addEventListener('click', () => {
    settingsSheet.hidden = true;
  });
  showTouchesToggle.addEventListener('change', () => {
    showTouches = showTouchesToggle.checked;
    storage.set('padtrack.showTouches', showTouches ? '1' : '0');
    if (!showTouches) clearDots();
  });
  $('forget').addEventListener('click', () => {
    if (!window.confirm("Bu iPad'in eşleşmesi kaldırılsın mı? Tekrar bağlanmak için QR kodu yeniden okutman gerekir.")) return;
    settingsSheet.hidden = true;
    client.forget();
  });
  $('home-hint-close').addEventListener('click', () => {
    homeHint.hidden = true;
    storage.set('padtrack.homeHintDismissed', '1');
  });
  $('standalone-note').hidden = !isStandalone;

  updateSurface();
  client.start();
})();
