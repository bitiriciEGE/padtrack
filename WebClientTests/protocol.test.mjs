// node --test WebClientTests/*.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const P = require('../WebClient/protocol.js');

const hex = (bytes) => Buffer.from(bytes).toString('hex');
const bytes = (text) => new Uint8Array(Buffer.from(text, 'hex'));

// Same fixtures as WebSocketTests.testWireFixturesSharedWithJavaScript in Swift.
test('encodes exactly what the Swift decoder expects', () => {
  assert.equal(hex(P.encodeHello({ deviceName: 'iPad', deviceID: 'web-1', width: 1180, height: 820 })),
    '01010080934400004d440469506164057765622d31');
  assert.equal(hex(P.encodeFrame(7, 1.5, [{ id: 3, x: 10.25, y: 20.5 }])),
    '0207000000000000000000f83f0103000024410000a441');
  assert.equal(hex(P.encodePong(bytes('0807060504030201'))), '040807060504030201');
});

test('decodes what the Swift encoder produces', () => {
  assert.deepEqual(P.decode(bytes('050104034d6163')),
    { type: 'subscribe', version: 1, transport: 4, hostName: 'Mac' });
  const ping = P.decode(bytes('032a00000000000000'));
  assert.equal(ping.type, 'ping');
  assert.equal(hex(ping.raw), '2a00000000000000');
  assert.deepEqual(P.decode(bytes('06')), { type: 'bye' });
  assert.equal(P.decode(new Uint8Array(0)).type, 'invalid');
  assert.equal(P.decode(bytes('0501')).type, 'invalid');
  assert.equal(P.decode(bytes('05010405')).type, 'invalid', 'host name longer than the message');
});

test('frames are capped at ten fingers and wrap the sequence number', () => {
  const touches = Array.from({ length: 12 }, (_, i) => ({ id: i, x: i, y: i }));
  const frame = P.encodeFrame(2 ** 32 + 5, 0, touches);
  assert.equal(frame.length, 1 + 4 + 8 + 1 + 10 * 9);
  assert.equal(frame[13], 10);
  assert.equal(new DataView(frame.buffer).getUint32(1, true), 5);
});

test('long and non-ASCII names are cut at 255 bytes like Swift', () => {
  const hello = P.encodeHello({ deviceName: 'ç'.repeat(200), deviceID: '', width: 1, height: 1 });
  assert.equal(hello[10], 255);
  assert.equal(hello.length, 1 + 1 + 4 + 4 + 1 + 255 + 1);
});
