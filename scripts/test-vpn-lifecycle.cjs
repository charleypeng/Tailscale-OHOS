// Host regression tests execute the production ArkTS service/Extension methods.
// Set TYPESCRIPT_PATH to typescript.js when DevEco is installed elsewhere.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
function harness(overrides = {}) {
  let now = 100000, next = 0;
  const jobs = new Map(), modules = new Map();
  const clock = {
    setTimeout(fn, ms) { jobs.set(++next, { fn, due: now + ms }); return next; },
    clearTimeout(id) { jobs.delete(id); },
    setInterval(fn, ms) { jobs.set(++next, { fn, due: now + ms, interval: ms }); return next; },
    clearInterval(id) { jobs.delete(id); }
  };
  function load(relative) {
    const filename = path.resolve(root, relative.endsWith('.ets') ? relative : relative + '.ets');
    if (modules.has(filename)) return modules.get(filename);
    const exports = {};
    modules.set(filename, exports);
    const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
      reportDiagnostics: true, fileName: filename.replace(/\.ets$/, '.ts')
    });
    assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
    vm.runInNewContext(output.outputText, {
      exports, ...clock, Date: { now: () => now }, AppStorage: { setOrCreate() {} },
      require(specifier) {
        if (specifier in overrides) return overrides[specifier];
        if (/\/(NetworkRebindScheduler|VpnTiming)$/.test(specifier)) {
          return load(path.relative(root, path.resolve(path.dirname(filename), specifier)));
        }
        if (specifier === '@kit.NetworkKit') return { VpnExtensionAbility: class {} };
        if (specifier === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {}, error() {} } };
        if (specifier === './StoragePaths') return { StoragePaths: { vpnStatusPath: d => d + '/status' } };
        if (specifier === './DiagnosticPrivacy') return { DiagnosticPrivacy: { formatLogError: () => 'test error' } };
        return {};
      }
    }, { filename });
    return exports;
  }
  return {
    load, jobs, now: () => now,
    async advance(ms) {
      const end = now + ms;
      while (true) {
        const nextJob = [...jobs].filter(([, j]) => j.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
        if (!nextJob) break;
        const [id, job] = nextJob;
        now = job.due;
        if (job.interval) job.due += job.interval; else jobs.delete(id);
        job.fn();
        await flush();
      }
      now = end;
      await flush();
    }
  };
}
function scheduler(h, run) {
  return new (h.load('services/NetworkRebindScheduler').NetworkRebindScheduler)(run);
}
test('retains latest cellular event while rebind is pending; never overlaps', async () => {
  const h = harness(), pending = deferred(), calls = [];
  const s = scheduler(h, reason => { calls.push(reason); return calls.length === 1 ? pending.promise : Promise.resolve(); });
  s.schedule('wifi-lost'); await h.advance(750);
  s.schedule('cellular-available'); await h.advance(500);
  s.schedule('cellular-properties'); await h.advance(4000);
  assert.deepEqual(calls, ['wifi-lost']);
  pending.resolve(); await flush(); await h.advance(750);
  assert.deepEqual(calls, ['wifi-lost', 'cellular-properties']);
});
test('continuous capability events cannot starve rebind', async () => {
  const h = harness(), times = [];
  const s = scheduler(h, async () => { times.push(h.now()); });
  for (let i = 0; i < 20; i++) { s.schedule('capabilities'); await h.advance(500); }
  assert.equal(times[0], 103000);
  assert.ok(times.length >= 3);
  for (let i = 1; i < times.length; i++) assert.ok(times[i] - times[i - 1] >= 3000);
});
test('burst is coalesced and retries are bounded when no new events arrive', async () => {
  const h = harness(); let count = 0;
  const s = scheduler(h, async () => { count++; throw Error('offline'); });
  s.schedule('lost'); await h.advance(100); s.schedule('available');
  await h.advance(749); assert.equal(count, 0);
  await h.advance(1); assert.equal(count, 1);
  await h.advance(20000); assert.equal(count, 4); assert.equal(h.jobs.size, 0);
});
test('stop cancels queued and in-flight follow-up work, including failure retries', async () => {
  const h = harness(), pending = deferred(); let count = 0;
  const s = scheduler(h, () => { count++; return pending.promise; });
  s.schedule('available'); await h.advance(750); s.schedule('changed');
  s.stop(); pending.reject(Error('offline')); await flush();
  s.schedule('ignored'); await h.advance(20000);
  assert.equal(count, 1); assert.equal(h.jobs.size, 0);
  const queued = scheduler(h, async () => { count++; });
  queued.schedule('available'); queued.stop(); await h.advance(5000);
  assert.equal(count, 1);
});
function backgroundHarness() {
  const agents = [], starts = [], stops = [], context = { filesDir: '/test' };
  let status;
  const h = harness({
    '@kit.AbilityKit': { wantAgent: {
      getWantAgent() { const d = deferred(); agents.push(d); return d.promise; },
      OperationType: { START_ABILITY: 0 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 }
    } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      on() {}, off() {}, BackgroundMode: { MULTI_DEVICE_CONNECTION: 1 },
      async startBackgroundRunning(ctx) { starts.push(ctx); },
      async stopBackgroundRunning(ctx) { stops.push(ctx); },
      async getAllContinuousTasks() { return starts.length > stops.length ? [{ abilityName: 'EntryAbility' }] : []; }
    } },
    '@kit.CoreFileKit': { fileIo: { readTextSync: () => status ?? `OK | state=Running | heartbeatMs=${h.now()}` } }
  });
  const manager = new (h.load('services/VpnBackgroundTaskManager').VpnBackgroundTaskManager)();
  return { h, manager, agents, starts, stops, context, setStatus: value => { status = value; } };
}
test('background start survives a foreground/background race while WantAgent is pending', async () => {
  const { h, manager, agents, starts, context } = backgroundHarness();
  manager.onBackground(context); assert.equal(agents.length, 1);
  manager.onForeground(context); manager.onBackground(context); await flush();
  agents[0].resolve({}); await flush(); assert.equal(agents.length, 2);
  agents[1].resolve({}); await flush(); assert.deepEqual(starts, [context]);
  await h.advance(5000); assert.equal(h.jobs.size, 1);
  manager.onForeground(context); manager.unregister(); await flush();
  assert.equal(h.jobs.size, 0);
});
test('no background task is created after owner destruction', async () => {
  const { manager, agents, starts, context } = backgroundHarness();
  manager.onBackground(context); manager.onForeground(context); manager.unregister();
  agents[0].resolve({}); await flush(); assert.equal(starts.length, 0);
});
test('stale heartbeat is rejected while a five-second idle heartbeat remains live', () => {
  const { h, manager, setStatus } = backgroundHarness();
  setStatus(`OK | state=Running | heartbeatMs=${h.now() - 6000}`);
  assert.equal(manager.hasLiveVpnStatus('/test'), true);
  setStatus(`OK | state=Running | heartbeatMs=${h.now() - 16000}`);
  assert.equal(manager.hasLiveVpnStatus('/test'), false);
});
test('cold-start verification tolerates an idle heartbeat tick plus scheduling jitter', () => {
  const timing = harness().load('services/VpnTiming');
  assert.ok(timing.VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS > timing.VPN_STATUS_INTERVAL_MS + 1000);
  assert.ok(timing.VPN_HEARTBEAT_FRESH_MS > timing.VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS);
  assert.ok(timing.VPN_SNAPSHOT_FRESH_MS > timing.VPN_STATUS_INTERVAL_MS * 2);
});
test('slow snapshots do not block requests, notifications, or the five-second heartbeat', async () => {
  const native = { backendSnapshot: () => new Promise(() => {}) };
  const h = harness({ 'libtailscale_ohos.so': { default: native } });
  const Extension = h.load('vpnextensionability/TailscaleVpnExtensionAbility').default;
  const extension = new Extension(); let requests = 0, notifications = 0, heartbeats = 0;
  extension.writeCurrentStatusHeartbeat = () => heartbeats++;
  extension.processBackendStopRequest = () => false;
  for (const method of ['processPeerConnectivityRequest', 'processSunshineProbeRequest',
    'processMediaServiceProbeRequest', 'processTaildropCancelRequest', 'processTaildropReceiveRequest',
    'processTaildriveQueryRequest', 'processTaildriveTransferRequest', 'processTaildriveControlRequest']) {
    extension[method] = () => {};
  }
  extension.processTaildropSendRequest = () => requests++;
  extension.refreshTaildropIncomingNotification = () => notifications++;
  extension.startStatusUpdates(); await h.advance(16000);
  assert.equal(requests, 16); assert.equal(notifications, 17); assert.equal(heartbeats, 3);
  assert.equal(extension.statusUpdateInFlight, true);
});
