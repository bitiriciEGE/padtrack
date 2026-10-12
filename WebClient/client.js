// Connection and touch logic for the Safari page, kept free of the DOM so it can be
// tested in Node (WebClientTests/). app.js wires it to the page.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./protocol.js'));
  else root.PadTrackClient = factory(root.PadTrackProtocol);
})(typeof self !== 'undefined' ? self : this, function (P) {
  'use strict';

  const TOKEN_KEY = 'padtrack.token';
  const SILENCE_LIMIT_MS = 4000; // the Mac pings twice a second while it uses this page
  const MAX_RETRY_MS = 5000;
  const CONGESTED_BYTES = 2048;

  function parseHash(hash) {
    const params = {};
    for (const part of String(hash || '').replace(/^#/, '').split('&')) {
      if (!part) continue;
      const i = part.indexOf('=');
      try {
        const key = decodeURIComponent(i < 0 ? part : part.slice(0, i));
        params[key] = i < 0 ? '' : decodeURIComponent(part.slice(i + 1));
      } catch (_) {
        // Malformed escape: ignore that part.
      }
    }
    return params;
  }

  function guessDeviceName(userAgent, maxTouchPoints) {
    const ua = String(userAgent || '');
    if (/iPad/.test(ua)) return 'iPad';
    if (/iPhone/.test(ua)) return 'iPhone';
    // iPadOS Safari presents itself as a Mac by default.
    if (/Macintosh/.test(ua) && maxTouchPoints > 1) return 'iPad';
    if (/Android/.test(ua)) return 'Android';
    return 'Tarayıcı';
  }

  /** Turns the browser's touch list into protocol touches with small rotating IDs. */
  class TouchTracker {
    constructor() {
      this.ids = new Map();
      this.nextID = 0;
    }

    /** touches: everything currently on the surface, as {identifier, clientX, clientY}. */
    frame(touches) {
      const seen = new Set();
      const points = [];
      for (const touch of touches) {
        seen.add(touch.identifier);
        let id = this.ids.get(touch.identifier);
        if (id === undefined) {
          id = this.assign();
          this.ids.set(touch.identifier, id);
        }
        points.push({ id, x: touch.clientX, y: touch.clientY });
      }
      for (const key of Array.from(this.ids.keys())) {
        if (!seen.has(key)) this.ids.delete(key);
      }
      points.sort((a, b) => a.id - b.id);
      return points.slice(0, P.MAX_TOUCHES);
    }

    // IDs rotate instead of being reused at once, like the iPad app: a new finger never
    // looks like an old one that jumped across the screen.
    assign() {
      const used = new Set(this.ids.values());
      let candidate = this.nextID;
      for (let i = 0; i < 256 && used.has(candidate); i++) candidate = (candidate + 1) & 0xff;
      this.nextID = (candidate + 1) & 0xff;
      return candidate;
    }
  }

  /**
   * One page, one Mac. States reported through env.onStatus:
   *   connecting · waiting (paired, Mac has not picked this page yet) · active ·
   *   paused (page hidden) · unpaired (needs a QR code; detail: none | used | revoked)
   *
   * env: { WebSocket, url, storage {get,set,remove}, getHash, setHash, deviceName,
   *        now, setTimeout, clearTimeout, setInterval, onStatus }
   */
  class PadClient {
    constructor(env) {
      this.env = env;
      this.socket = null;
      this.authenticated = false;
      this.active = false;
      this.suspended = false;
      this.host = '';
      this.deviceID = '';
      this.pairKey = null;
      this.token = null;
      this.unpairedReason = 'none';
      this.justPaired = false;
      this.seq = 0;
      this.surface = { width: 0, height: 0 };
      this.retryDelay = 0;
      this.retryTimer = null;
      this.flushTimer = null;
      this.pending = null;
      this.lastHeard = 0;
      this.lastTimestamp = 0;
      this.fingersDown = false;
      this.status = { state: 'idle', detail: '', host: '' };
    }

    start() {
      const params = parseHash(this.env.getHash());
      this.pairKey = params.p || null;
      this.token = params.t || this.env.storage.get(TOKEN_KEY) || null;
      if (params.t) this.env.storage.set(TOKEN_KEY, params.t);
      this.env.setInterval(() => this.checkLiveness(), 1000);
      this.connect();
    }

    get hasCredentials() {
      return Boolean(this.pairKey || this.token);
    }

    connect() {
      if (this.socket || this.suspended) return;
      this.clearRetry();
      if (!this.hasCredentials) {
        this.setStatus('unpaired', this.unpairedReason);
        return;
      }
      if (this.status.state !== 'connecting') this.setStatus('connecting');

      let socket;
      try {
        socket = new this.env.WebSocket(this.env.url);
      } catch (_) {
        this.scheduleRetry();
        return;
      }
      socket.binaryType = 'arraybuffer';
      this.socket = socket;
      this.authenticated = false;
      this.active = false;

      socket.onopen = () => {
        if (this.socket !== socket) return;
        const name = this.env.deviceName;
        const hello = this.pairKey
          ? { type: 'pair', key: this.pairKey, name }
          : { type: 'resume', token: this.token, name };
        socket.send(JSON.stringify(hello));
      };
      socket.onmessage = (event) => {
        if (this.socket === socket) this.receive(event.data);
      };
      socket.onclose = () => {
        if (this.socket === socket) this.closed();
      };
      socket.onerror = () => {}; // onclose follows
    }

    // MARK: Receiving

    receive(data) {
      this.lastHeard = this.env.now();
      if (typeof data === 'string') {
        this.receiveText(data);
        return;
      }
      const message = P.decode(new Uint8Array(data));
      switch (message.type) {
        case 'subscribe':
          if (message.hostName) this.host = message.hostName;
          this.active = true;
          this.sendHello();
          this.setStatus('active');
          break;
        case 'ping':
          this.send(P.encodePong(message.raw));
          break;
        case 'bye':
          this.active = false;
          this.setStatus('waiting');
          break;
        default:
          break;
      }
    }

    receiveText(text) {
      let message;
      try {
        message = JSON.parse(text);
      } catch (_) {
        return;
      }
      if (message.type === 'welcome') {
        this.authenticated = true;
        this.retryDelay = 0;
        this.deviceID = 'web-' + (message.device || '');
        if (message.host) this.host = message.host;
        if (message.token) {
          this.token = message.token;
          this.env.storage.set(TOKEN_KEY, message.token);
          this.justPaired = true;
        }
        // The token rides in the URL fragment (never sent to any server), so a Home Screen
        // bookmark made from this page carries it even if it gets its own storage.
        if (this.token) this.env.setHash('t=' + encodeURIComponent(this.token));
        this.pairKey = null;
        this.unpairedReason = 'none';
        if (!this.active) this.setStatus('waiting');
      } else if (message.type === 'denied') {
        if (message.reason === 'pair-key') {
          // An old or already used QR code. A page that was paired before can still resume.
          this.pairKey = null;
          if (!this.token) this.unpairedReason = 'used';
        } else {
          this.forgetToken('revoked');
        }
      }
    }

    closed() {
      this.socket = null;
      this.authenticated = false;
      this.active = false;
      this.pending = null;
      if (this.suspended) {
        this.setStatus('paused');
        return;
      }
      if (!this.hasCredentials) {
        this.env.setHash('');
        this.setStatus('unpaired', this.unpairedReason);
        return;
      }
      this.scheduleRetry();
    }

    scheduleRetry() {
      this.clearRetry();
      const delay = this.retryDelay;
      this.retryDelay = Math.min(Math.max(delay * 2, 500), MAX_RETRY_MS);
      this.setStatus('connecting', delay >= 2000 ? 'unreachable' : '');
      this.retryTimer = this.env.setTimeout(() => {
        this.retryTimer = null;
        this.connect();
      }, delay);
    }

    clearRetry() {
      if (this.retryTimer !== null) {
        this.env.clearTimeout(this.retryTimer);
        this.retryTimer = null;
      }
    }

    checkLiveness() {
      if (this.socket && this.active && this.env.now() - this.lastHeard > SILENCE_LIMIT_MS) {
        this.dropSocket();
      }
    }

    dropSocket() {
      const socket = this.socket;
      if (!socket) return;
      this.socket = null;
      try {
        socket.close();
      } catch (_) {
        // already closed
      }
      this.closed();
    }

    // MARK: Page lifecycle

    /** Page hidden (screen locked, app switched): Safari stops running it soon anyway. */
    suspend() {
      if (this.suspended) return;
      if (this.fingersDown) this.sendTouches([], this.lastTimestamp, true);
      this.suspended = true;
      this.clearRetry();
      this.dropSocket();
    }

    resume() {
      if (!this.suspended) return;
      this.suspended = false;
      this.retryDelay = 0;
      this.connect();
    }

    /** The user removed the pairing on this iPad. */
    forget() {
      this.forgetToken('none');
      this.pairKey = null;
      this.dropSocket();
    }

    forgetToken(reason) {
      this.token = null;
      this.env.storage.remove(TOKEN_KEY);
      this.unpairedReason = reason;
    }

    // MARK: Sending

    setSurface(width, height) {
      if (width === this.surface.width && height === this.surface.height) return;
      this.surface = { width, height };
      if (this.active) this.sendHello();
    }

    sendHello() {
      this.send(P.encodeHello({
        deviceName: this.env.deviceName,
        deviceID: this.deviceID,
        width: this.surface.width,
        height: this.surface.height,
      }));
    }

    /**
     * Every touch change. `structural` = a finger landed or lifted: always sent.
     * Plain moves are skipped while the socket is backed up; the newest one follows.
     */
    sendTouches(touches, timestamp, structural) {
      this.lastTimestamp = timestamp;
      this.fingersDown = touches.length > 0;
      if (!this.active || !this.isOpen()) return;
      if (!structural && this.socket.bufferedAmount > CONGESTED_BYTES) {
        this.pending = { touches, timestamp };
        this.scheduleFlush();
        return;
      }
      this.pending = null;
      this.sendFrame(touches, timestamp);
    }

    sendFrame(touches, timestamp) {
      this.seq = (this.seq + 1) >>> 0;
      this.send(P.encodeFrame(this.seq, timestamp, touches));
    }

    scheduleFlush() {
      if (this.flushTimer !== null) return;
      this.flushTimer = this.env.setTimeout(() => {
        this.flushTimer = null;
        const pending = this.pending;
        if (!pending) return;
        if (!this.active || !this.isOpen()) {
          this.pending = null;
          return;
        }
        if (this.socket.bufferedAmount > CONGESTED_BYTES) {
          this.scheduleFlush();
          return;
        }
        this.pending = null;
        this.sendFrame(pending.touches, pending.timestamp);
      }, 8);
    }

    isOpen() {
      return Boolean(this.socket && this.socket.readyState === 1 && this.authenticated);
    }

    send(bytes) {
      if (!this.socket || this.socket.readyState !== 1) return;
      try {
        this.socket.send(bytes);
      } catch (_) {
        // The close handler takes care of it.
      }
    }

    setStatus(state, detail) {
      this.status = { state, detail: detail || '', host: this.host };
      if (this.env.onStatus) this.env.onStatus(this.status);
    }
  }

  return { PadClient, TouchTracker, parseHash, guessDeviceName, TOKEN_KEY };
});
