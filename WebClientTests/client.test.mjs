// node --test WebClientTests/*.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const P = require('../WebClient/protocol.js');
const { PadClient, TouchTracker, parseHash, guessDeviceName, TOKEN_KEY } = require('../WebClient/client.js');

// MARK: Test doubles

class FakeSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.bufferedAmount = 0;
    this.sent = [];
  }
  open() { this.readyState = 1; this.onopen && this.onopen(); }
  send(data) { this.sent.push(data); }
  close() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.onclose && this.onclose({});
  }
  serverText(object) { this.onmessage({ data: JSON.stringify(object) }); }
  serverBinary(bytes) {
    this.onmessage({ data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
  }
  get sentJSON() { return this.sent.filter((d) => typeof d === 'string').map((d) => JSON.parse(d)); }
  get sentBinary() { return this.sent.filter((d) => typeof d !== 'string').map((d) => P.decodeAny(d)); }
}

// Decoder for what the page sends (the Swift side's job in production).
P.decodeAny = (bytes) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  switch (bytes[0]) {
    case 1: return { type: 'hello', width: view.getFloat32(2, true), height: view.getFloat32(6, true) };
    case 2: {
      const touches = [];
      for (let i = 0; i < bytes[13]; i++) {
        const o = 14 + i * 9;
        touches.push({ id: bytes[o], x: view.getFloat32(o + 1, true), y: view.getFloat32(o + 5, true) });
      }
      return { type: 'frame', seq: view.getUint32(1, true), timestamp: view.getFloat64(5, true), touches };
    }
    case 4: return { type: 'pong', raw: Buffer.from(bytes.subarray(1)).toString('hex') };
    default: return { type: 'other', kind: bytes[0] };
  }
};

function setup({ hash = '', stored = null } = {}) {
  const sockets = [];
  const timers = [];
  const statuses = [];
  const store = new Map(stored ? [[TOKEN_KEY, stored]] : []);
  const env = {
    hash,
    clock: 0,
    WebSocket: function (url) {
      const socket = new FakeSocket(url);
      sockets.push(socket);
      return socket;
    },
    url: 'ws://mac.local:47391/ws',
    storage: {
      get: (k) => (store.has(k) ? store.get(k) : null),
      set: (k, v) => store.set(k, v),
      remove: (k) => store.delete(k),
    },
    getHash: () => env.hash,
    setHash: (h) => { env.hash = h ? '#' + h : ''; },
    deviceName: 'iPad',
    now: () => env.clock,
    setTimeout: (fn, ms) => { const t = { fn, ms, done: false }; timers.push(t); return t; },
    clearTimeout: (t) => { if (t) t.done = true; },
    setInterval: () => 0,
    onStatus: (s) => statuses.push(s),
  };
  const client = new PadClient(env);
  const runTimers = () => {
    const due = timers.filter((t) => !t.done);
    for (const t of due) { t.done = true; t.fn(); }
    return due.map((t) => t.ms);
  };
  const last = () => statuses[statuses.length - 1];
  const socket = () => sockets[sockets.length - 1];
  return { client, env, sockets, socket, timers, runTimers, statuses, last, store };
}

const subscribeBytes = new Uint8Array([5, 1, 4, 3, 0x4d, 0x61, 0x63]); // "Mac"
const pingBytes = new Uint8Array([3, 0x2a, 0, 0, 0, 0, 0, 0, 0]);

// MARK: Pairing and the session

test('QR pairing, then subscribe, ping and frames', () => {
  const t = setup({ hash: '#p=KEY123' });
  t.client.setSurface(1180, 820);
  t.client.start();
  assert.equal(t.sockets.length, 1);
  assert.equal(t.socket().url, 'ws://mac.local:47391/ws');
  assert.equal(t.last().state, 'connecting');

  t.socket().open();
  assert.deepEqual(t.socket().sentJSON, [{ type: 'pair', key: 'KEY123', name: 'iPad' }]);

  t.socket().serverText({ type: 'welcome', token: 'TOKEN', device: 'abc', host: 'MacBook' });
  assert.equal(t.store.get(TOKEN_KEY), 'TOKEN');
  assert.equal(t.env.hash, '#t=TOKEN', 'the one-time key leaves the URL, the token replaces it');
  assert.equal(t.last().state, 'waiting');
  assert.equal(t.client.justPaired, true);

  // Nothing is sent before the Mac picks this page.
  t.client.sendTouches([{ id: 0, x: 1, y: 2 }], 1, true);
  assert.equal(t.socket().sentBinary.length, 0);

  t.socket().serverBinary(subscribeBytes);
  assert.equal(t.last().state, 'active');
  assert.equal(t.last().host, 'Mac');
  assert.deepEqual(t.socket().sentBinary, [{ type: 'hello', width: 1180, height: 820 }]);

  t.socket().serverBinary(pingBytes);
  assert.deepEqual(t.socket().sentBinary[1], { type: 'pong', raw: '2a00000000000000' });

  t.client.sendTouches([{ id: 0, x: 10.5, y: 20.25 }], 2.5, true);
  t.client.sendTouches([], 2.6, true);
  const frames = t.socket().sentBinary.filter((m) => m.type === 'frame');
  assert.deepEqual(frames.map((f) => f.seq), [1, 2]);
  assert.deepEqual(frames[0].touches, [{ id: 0, x: 10.5, y: 20.25 }]);
  assert.equal(frames[0].timestamp, 2.5);
  assert.deepEqual(frames[1].touches, []);

  t.client.setSurface(820, 1180);
  assert.deepEqual(t.socket().sentBinary.at(-1), { type: 'hello', width: 820, height: 1180 });

  t.socket().serverBinary(new Uint8Array([6]));
  assert.equal(t.last().state, 'waiting');
});

test('a paired page resumes with its stored token', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  assert.deepEqual(t.socket().sentJSON, [{ type: 'resume', token: 'TOKEN', name: 'iPad' }]);
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'MacBook' });
  assert.equal(t.last().state, 'waiting');
  assert.equal(t.client.justPaired, false);
  assert.equal(t.env.hash, '#t=TOKEN');
});

test('a token in the URL (Home Screen bookmark) is used and saved', () => {
  const t = setup({ hash: '#t=FROMURL' });
  t.client.start();
  assert.equal(t.store.get(TOKEN_KEY), 'FROMURL');
  t.socket().open();
  assert.equal(t.socket().sentJSON[0].token, 'FROMURL');
});

test('without credentials it asks for the QR code and does not connect', () => {
  const t = setup();
  t.client.start();
  assert.equal(t.sockets.length, 0);
  assert.deepEqual(t.last(), { state: 'unpaired', detail: 'none', host: '' });
});

test('a used QR code on a new iPad ends in "unpaired: used"', () => {
  const t = setup({ hash: '#p=OLD' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'denied', reason: 'pair-key' });
  t.socket().close();
  assert.equal(t.last().state, 'unpaired');
  assert.equal(t.last().detail, 'used');
  assert.equal(t.env.hash, '', 'the dead key is removed from the URL');
  assert.deepEqual(t.runTimers(), [], 'no reconnect loop');
});

test('a used QR code on an already paired iPad falls back to the token', () => {
  const t = setup({ hash: '#p=OLD', stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  assert.equal(t.socket().sentJSON[0].type, 'pair');
  t.socket().serverText({ type: 'denied', reason: 'pair-key' });
  t.socket().close();
  assert.deepEqual(t.runTimers(), [0], 'retries at once');
  t.socket().open();
  assert.deepEqual(t.socket().sentJSON, [{ type: 'resume', token: 'TOKEN', name: 'iPad' }]);
});

test('a revoked token is forgotten', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'denied', reason: 'token' });
  t.socket().close();
  assert.equal(t.store.has(TOKEN_KEY), false);
  assert.equal(t.last().state, 'unpaired');
  assert.equal(t.last().detail, 'revoked');
});

// MARK: Resilience

test('reconnects with backoff and says when the Mac is unreachable', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  const delays = [];
  for (let i = 0; i < 6; i++) {
    t.socket().close(); // connection refused
    delays.push(...t.runTimers());
  }
  assert.deepEqual(delays, [0, 500, 1000, 2000, 4000, 5000]);
  assert.equal(t.sockets.length, 7);

  // The detail appears once retries are slow.
  t.socket().close();
  assert.equal(t.last().detail, 'unreachable');

  // A successful welcome resets the backoff.
  t.runTimers();
  t.socket().open();
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'Mac' });
  t.socket().close();
  assert.deepEqual(t.runTimers(), [0]);
});

test('a silent Mac is detected while active', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'Mac' });
  t.socket().serverBinary(subscribeBytes);
  const first = t.socket();

  t.env.clock = 3000;
  t.client.checkLiveness();
  assert.equal(first.readyState, 1);

  t.env.clock = 4500;
  t.client.checkLiveness();
  assert.equal(first.readyState, 3);
  assert.equal(t.last().state, 'connecting');
  t.runTimers();
  assert.equal(t.sockets.length, 2);
});

test('moves are coalesced while the socket is backed up; landings and lifts never are', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'Mac' });
  t.socket().serverBinary(subscribeBytes);
  const frames = () => t.socket().sentBinary.filter((m) => m.type === 'frame');

  t.socket().bufferedAmount = 10000;
  t.client.sendTouches([{ id: 0, x: 1, y: 1 }], 1, true);
  t.client.sendTouches([{ id: 0, x: 2, y: 2 }], 1.01, false);
  t.client.sendTouches([{ id: 0, x: 3, y: 3 }], 1.02, false);
  assert.equal(frames().length, 1, 'only the landing went out');

  t.socket().bufferedAmount = 0;
  t.runTimers();
  assert.equal(frames().length, 2);
  assert.deepEqual(frames()[1].touches, [{ id: 0, x: 3, y: 3 }], 'the newest move, not the skipped one');

  // A lift sent while congested goes out and makes a pending move obsolete.
  t.socket().bufferedAmount = 10000;
  t.client.sendTouches([{ id: 0, x: 4, y: 4 }], 1.03, false);
  t.client.sendTouches([], 1.04, true);
  t.socket().bufferedAmount = 0;
  t.runTimers();
  assert.deepEqual(frames().map((f) => f.touches.length), [1, 1, 0]);
});

test('hiding the page lifts fingers, disconnects, and showing it reconnects', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'Mac' });
  t.socket().serverBinary(subscribeBytes);
  t.client.sendTouches([{ id: 0, x: 1, y: 1 }], 5, true);
  const first = t.socket();

  t.client.suspend();
  const frames = first.sentBinary.filter((m) => m.type === 'frame');
  assert.deepEqual(frames.at(-1), { type: 'frame', seq: 2, timestamp: 5, touches: [] });
  assert.equal(first.readyState, 3);
  assert.equal(t.last().state, 'paused');
  assert.deepEqual(t.runTimers(), [], 'no reconnect while hidden');

  t.client.resume();
  assert.equal(t.sockets.length, 2);
});

test('forgetting the pairing on the iPad', () => {
  const t = setup({ stored: 'TOKEN' });
  t.client.start();
  t.socket().open();
  t.socket().serverText({ type: 'welcome', device: 'abc', host: 'Mac' });
  t.client.forget();
  assert.equal(t.store.has(TOKEN_KEY), false);
  assert.equal(t.env.hash, '');
  assert.equal(t.last().state, 'unpaired');
  assert.deepEqual(t.runTimers(), []);
});

// MARK: Touches and helpers

test('touch IDs rotate and follow fingers', () => {
  const tracker = new TouchTracker();
  const touch = (identifier, x) => ({ identifier, clientX: x, clientY: 0 });

  assert.deepEqual(tracker.frame([touch(0, 1)]), [{ id: 0, x: 1, y: 0 }]);
  assert.deepEqual(tracker.frame([touch(0, 2), touch(1, 5)]), [{ id: 0, x: 2, y: 0 }, { id: 1, x: 5, y: 0 }]);
  assert.deepEqual(tracker.frame([touch(1, 6)]), [{ id: 1, x: 6, y: 0 }]);
  // Safari reuses identifier 0 for the next finger; the protocol ID does not come back.
  assert.deepEqual(tracker.frame([touch(1, 6), touch(0, 9)]), [{ id: 1, x: 6, y: 0 }, { id: 2, x: 9, y: 0 }]);
  assert.deepEqual(tracker.frame([]), []);

  const many = Array.from({ length: 12 }, (_, i) => touch(100 + i, i));
  assert.equal(tracker.frame(many).length, 10);
});

test('touch IDs wrap around 255 without colliding', () => {
  const tracker = new TouchTracker();
  tracker.nextID = 255;
  const held = { identifier: 'held', clientX: 0, clientY: 0 };
  assert.equal(tracker.frame([held])[0].id, 255);
  const second = tracker.frame([held, { identifier: 'b', clientX: 0, clientY: 0 }]);
  assert.deepEqual(second.map((p) => p.id).sort((a, b) => a - b), [0, 255]);
});

test('URL fragment parsing and device names', () => {
  assert.deepEqual(parseHash('#p=abc-_1&x'), { p: 'abc-_1', x: '' });
  assert.deepEqual(parseHash('#t=a%2Bb'), { t: 'a+b' });
  assert.deepEqual(parseHash('#t=%E0%A4%A'), {});
  assert.deepEqual(parseHash(''), {});

  assert.equal(guessDeviceName('Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)', 5), 'iPad');
  assert.equal(guessDeviceName('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari', 5), 'iPad');
  assert.equal(guessDeviceName('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari', 0), 'Tarayıcı');
  assert.equal(guessDeviceName('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)', 5), 'iPhone');
});
