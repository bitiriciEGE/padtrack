// PadTrack wire protocol (see Packages/PadTrackCore/Sources/PadTrackCore/Wire.swift).
// Little-endian; one message per WebSocket binary frame. Only the messages the
// Safari page sends or receives are implemented here.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.PadTrackProtocol = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const VERSION = 1;
  const MAX_TOUCHES = 10;
  const Kind = { hello: 1, frame: 2, ping: 3, pong: 4, subscribe: 5, bye: 6 };
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  // Length-prefixed UTF-8, at most 255 bytes (same cut as the Swift side).
  function stringBytes(value) {
    return encoder.encode(String(value || '')).slice(0, 255);
  }

  function encodeHello({ deviceName, deviceID, width, height }) {
    const name = stringBytes(deviceName);
    const id = stringBytes(deviceID);
    const bytes = new Uint8Array(1 + 1 + 4 + 4 + 1 + name.length + 1 + id.length);
    const view = new DataView(bytes.buffer);
    let o = 0;
    bytes[o++] = Kind.hello;
    bytes[o++] = VERSION;
    view.setFloat32(o, width, true); o += 4;
    view.setFloat32(o, height, true); o += 4;
    bytes[o++] = name.length; bytes.set(name, o); o += name.length;
    bytes[o++] = id.length; bytes.set(id, o);
    return bytes;
  }

  // touches: [{ id, x, y }] in CSS pixels (= iPad points), origin top-left.
  function encodeFrame(seq, timestamp, touches) {
    const list = touches.slice(0, MAX_TOUCHES);
    const bytes = new Uint8Array(1 + 4 + 8 + 1 + list.length * 9);
    const view = new DataView(bytes.buffer);
    bytes[0] = Kind.frame;
    view.setUint32(1, seq >>> 0, true);
    view.setFloat64(5, timestamp, true);
    bytes[13] = list.length;
    let o = 14;
    for (const touch of list) {
      bytes[o] = touch.id & 0xff;
      view.setFloat32(o + 1, touch.x, true);
      view.setFloat32(o + 5, touch.y, true);
      o += 9;
    }
    return bytes;
  }

  // The ping value is the Mac's clock in nanoseconds (u64); it is echoed back byte for byte.
  function encodePong(raw) {
    const bytes = new Uint8Array(9);
    bytes[0] = Kind.pong;
    bytes.set(raw.subarray(0, 8), 1);
    return bytes;
  }

  function decode(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    if (bytes.length === 0) return { type: 'invalid' };
    switch (bytes[0]) {
      case Kind.ping:
        if (bytes.length < 9) return { type: 'invalid' };
        return { type: 'ping', raw: bytes.slice(1, 9) };
      case Kind.subscribe: {
        if (bytes.length < 4) return { type: 'invalid' };
        const length = bytes[3];
        if (bytes.length < 4 + length) return { type: 'invalid' };
        return {
          type: 'subscribe',
          version: bytes[1],
          transport: bytes[2],
          hostName: decoder.decode(bytes.subarray(4, 4 + length)),
        };
      }
      case Kind.bye:
        return { type: 'bye' };
      default:
        return { type: 'other', kind: bytes[0] };
    }
  }

  return { VERSION, MAX_TOUCHES, Kind, encodeHello, encodeFrame, encodePong, decode };
});
