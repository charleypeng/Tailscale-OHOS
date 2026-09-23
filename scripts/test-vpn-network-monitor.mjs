import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/VpnNetworkMonitor.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class VpnNetworkMonitor', 'class VpnNetworkMonitor'));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

function fixture() {
  const f = { now: 10000, timers: new Map(), nextId: 0, callbacks: new Map(), calls: [], events: [],
    netId: 10, name: 'wlan0', address: '192.0.2.2', gate: null, propertiesGate: null,
    failure: false, registerError: false, registered: 0, unregistered: 0 };
  const monitor = {
    on: (event, cb) => f.callbacks.set(event, cb),
    register: cb => { f.registered++; cb(f.registerError ? { code: 201 } : undefined); },
    unregister: cb => { f.unregistered++; cb(); }
  };
  const sandbox = {
    Date: { now: () => f.now },
    setTimeout: (cb, ms) => { const id = ++f.nextId; f.timers.set(id, { cb, at: f.now + ms }); return id; },
    clearTimeout: id => f.timers.delete(id),
    connection: { createNetConnection: () => monitor,
      NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1 },
      getNetCapabilities: async () => ({ bearerTypes: [f.name.startsWith('rmnet') ? 0 : 1] }),
      getDefaultNet: async () => ({ netId: f.netId }),
      getConnectionProperties: async () => {
        const props = { interfaceName: f.name, linkAddresses: [{ address: { address: f.address }, prefixLength: 24 }], dnses: [] };
        if (f.propertiesGate) await f.propertiesGate.promise;
        return props;
      } },
    nativeBridge: { backendNetworkChangedAsync: async name => {
      f.calls.push(name); if (f.gate) await f.gate.promise;
      return f.failure ? 'FAILED | refresh' : 'OK | refresh';
    } }
  };
  vm.runInNewContext(js + '\nglobalThis.Monitor = VpnNetworkMonitor;', sandbox);
  f.monitor = new sandbox.Monitor((event, code) => f.events.push({ event, code }));
  f.advance = async ms => {
    f.now += ms;
    for (const [id, timer] of [...f.timers]) {
      if (timer.at <= f.now) { f.timers.delete(id); timer.cb(); }
    }
    await flush();
  };
  f.start = async () => { f.monitor.start(); await f.advance(750); await f.advance(750); };
  f.change = (name, id) => { f.name = name; f.netId = id; f.callbacks.get('netAvailable')({ netId: id }); };
  return f;
}

test('uses the current default network, coalesces duplicates, never logs address data', async () => {
  const f = fixture(); await f.start(); assert.deepEqual(f.calls, ['wlan0']);
  f.callbacks.get('netAvailable')({ netId: 900 }); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0']);
  assert.doesNotMatch(JSON.stringify(f.events), /wlan|192\.0/);
});

test('replays a cellular transition whose timer fires during an in-flight Wi-Fi rebind', async () => {
  const f = fixture(); f.gate = deferred(); await f.start();
  f.change('rmnet0', 20); await f.advance(5000);
  assert.deepEqual(f.calls, ['wlan0']);
  f.gate.resolve(); await flush(); await f.advance(750);
  assert.deepEqual(f.calls, ['wlan0', 'rmnet0']);
});

test('discards a stale read when default net changes before properties return', async () => {
  const f = fixture(); await f.start();
  f.propertiesGate = deferred(); f.change('wlan0', 11); await f.advance(4000);
  f.change('rmnet0', 20); f.propertiesGate.resolve(); await flush(); await f.advance(5000);
  assert.deepEqual(f.calls, ['wlan0', 'rmnet0']);
});

test('same interface on a new Wi-Fi network and address renewal both trigger refresh', async () => {
  const f = fixture(); await f.start(); f.change('wlan0', 11); await f.advance(4000);
  f.address = '192.0.2.3'; f.callbacks.get('netConnectionPropertiesChange')({}); await f.advance(4000);
  assert.equal(f.calls.length, 3);
});

test('clears the route hint when offline and applies the restored bearer', async () => {
  const f = fixture(); await f.start(); f.netId = 0; f.callbacks.get('netLost')({ netId: 10 });
  await f.advance(4000); f.change('rmnet0', 20); await f.advance(4000);
  assert.deepEqual(f.calls, ['wlan0', '', 'rmnet0']);
});

test('failed native refresh retries without another platform callback', async () => {
  const f = fixture(); f.failure = true; await f.start();
  f.failure = false; await f.advance(5000); assert.deepEqual(f.calls, ['wlan0', 'wlan0']);
});

test('registration failures retry and do not leak a listener after stop', async () => {
  const f = fixture(); f.registerError = true; await f.start();
  f.registerError = false; await f.advance(5000); await f.advance(750);
  assert.equal(f.registered, 2);
  f.monitor.stop(); assert.equal(f.unregistered, 1);
  f.change('rmnet0', 20); await f.advance(6000); assert.equal(f.calls.length, 1);
});

test('stop during native work cancels replay and releases the registered listener', async () => {
  const f = fixture(); f.gate = deferred(); await f.start();
  f.change('rmnet0', 20); f.monitor.stop(); f.gate.resolve(); await flush(); await f.advance(10000);
  assert.deepEqual(f.calls, ['wlan0']); assert.equal(f.unregistered, 1); assert.equal(f.timers.size, 0);
});
