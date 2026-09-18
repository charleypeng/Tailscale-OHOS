import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoragePaths } from './StoragePaths';
import { DiagnosticPrivacy } from './DiagnosticPrivacy';

const DOMAIN: number = 0x0000;
const TAG: string = 'VpnBackgroundTask';
const BUNDLE_NAME: string = 'io.github.tailscaleohos';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_STATUS_FRESH_MS: number = 15000;
const HEALTH_CHECK_INTERVAL_MS: number = 5000;
// A DATA_TRANSFER continuous task is cancelled when its progress is not
// refreshed for a long time, and it can also be suspended when the observed
// throughput stays low (system reasons 4 for both). A VPN link is bursty and
// often idle, so refresh the task well inside the documented window instead of
// letting the system decide the link has finished.
const PROGRESS_REFRESH_INTERVAL_MS: number = 240000;
// A bounded probe covers the connect-then-immediately-background race: the
// status file may still be empty when onBackground runs while the VPN extension
// finishes bringing the tunnel up a moment later.
const SESSION_PROBE_INTERVAL_MS: number = 500;
const SESSION_PROBE_LIMIT: number = 24;
// Huawei's official VPN keep-alive guidance ("应用切换到后台后VPN功能保活的解决方案")
// prescribes the dataTransfer background mode, and the module manifest declares
// the same value. multiDeviceConnection was cancelled by the system with
// reason 10 (not using multi-device capabilities) because this app is not a
// distributed multi-device service.
const CONTINUOUS_TASK_MODE: string = 'dataTransfer';
const CONTINUOUS_TASK_MODE_ENUM: backgroundTaskManager.BackgroundMode =
  backgroundTaskManager.BackgroundMode.DATA_TRANSFER;
const CANCEL_REASON_USER_REMOVE_NOTIFICATION: number = 3;
const CANCEL_REASON_USER_CANCEL: number = 1;

export class VpnBackgroundTaskManager {
  // Stage-model continuous tasks can only be requested by a UIAbility
  // (Background Tasks Kit "长时任务 > 约束与限制"). A VpnExtensionContext cannot
  // own one, so the VPN extension process relies on the task owned here.
  private abilityContext?: common.UIAbilityContext;
  private sessionActive: boolean = false;
  private appBackground: boolean = false;
  private starting: boolean = false;
  private started: boolean = false;
  private stopping: boolean = false;
  private listenerRegistered: boolean = false;
  private generation: number = 0;
  private healthTimer: number = -1;
  private progressTimer: number = -1;
  private retryTimer: number = -1;
  // Set when the user or the system cancels the task. Re-applying immediately
  // after such a cancellation violates the Background Tasks Kit rules, so the
  // next user-initiated VPN session is required before a new request.
  private suppressedReason: number = -1;
  private missingContextLogged: boolean = false;

  private readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      this.started = false;
      this.stopTimers();
      this.suppressedReason = typeof info.reason === 'number' ? Number(info.reason) : -1;
      this.generation++;
      hilog.info(DOMAIN, TAG,
        'Continuous task cancelled. id=%{public}d reason=%{public}d suppressed=%{public}t',
        info.id, this.suppressedReason,
        this.suppressedReason === CANCEL_REASON_USER_REMOVE_NOTIFICATION ||
          this.suppressedReason === CANCEL_REASON_USER_CANCEL);
    };

  private readonly suspendCallback =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      // A suspend keeps the task but pauses its protection; the periodic
      // progress refresh is what brings it back for a dataTransfer task.
      hilog.info(DOMAIN, TAG,
        'Continuous task suspend state changed. id=%{public}d suspended=%{public}t reason=%{public}d',
        info.continuousTaskId, info.suspendState, info.suspendReason ?? -1);
    };

  private readonly activeCallback =
    (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      this.started = true;
      this.suppressedReason = -1;
      hilog.info(DOMAIN, TAG, 'Continuous task active. id=%{public}d', info.id);
    };

  register(): void {
    if (this.listenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
      this.listenerRegistered = true;
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to register continuous-task cancellation listener. code=%{public}d',
        businessError.code ?? -1);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback);
    } catch (_error) {
      // API 20+ event; older system images have no suspension signal.
    }
    try {
      backgroundTaskManager.on('continuousTaskActive', this.activeCallback);
    } catch (_error) {
      // API 20+ event; older system images have no activation signal.
    }
  }

  unregister(): void {
    this.sessionActive = false;
    this.generation++;
    this.stopTimers();
    if (!this.listenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
      backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback);
      backgroundTaskManager.off('continuousTaskActive', this.activeCallback);
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to unregister continuous-task listeners. code=%{public}d',
        businessError.code ?? -1);
    }
    this.listenerRegistered = false;
  }

  // The UIAbility is the only context allowed to own a continuous task, so the
  // page and the ability hand their UIAbilityContext in here.
  attachAbilityContext(context: common.UIAbilityContext): void {
    this.abilityContext = context;
    this.missingContextLogged = false;
    this.sync();
  }

  // Called from the VPN extension process. That process has no UIAbility, so it
  // only publishes the session state through the shared status file; the ability
  // process performs the actual request.
  onVpnConnected(context: common.Context): void {
    this.sessionActive = true;
    this.suppressedReason = -1;
    if (this.abilityContext === undefined && context.filesDir.length > 0) {
      this.missingContextLogged = true;
    }
    this.sync();
  }

  onVpnDisconnected(_context: common.Context): void {
    this.sessionActive = false;
    const generation: number = this.generation;
    this.generation++;
    this.stopTimers();
    this.stop(generation + 1);
  }

  onBackground(context: common.UIAbilityContext): void {
    this.appBackground = true;
    this.attachAbilityContext(context);
    // Fall back to the shared VPN status file: the UI process may have been
    // created after the VPN session started.
    if (!this.sessionActive && this.hasLiveVpnStatus(context.filesDir)) {
      this.sessionActive = true;
      this.suppressedReason = -1;
    }
    this.sync();
    // The session may not be observable yet when the user backgrounds the app
    // right after tapping connect. Probe for a bounded window instead of
    // waiting for the next foreground transition.
    if (!this.sessionActive) {
      this.scheduleSessionProbe(context, 0);
    }
  }

  onForeground(context: common.UIAbilityContext): void {
    this.appBackground = false;
    this.stopSessionProbe();
    this.attachAbilityContext(context);
    if (!this.sessionActive) {
      this.stop(this.generation + 1);
    }
  }

  isTaskActive(): boolean {
    return this.started;
  }

  // A bounded probe covers the connect-then-immediately-background race: the
  // status file may still be empty when onBackground runs, while the VPN
  // extension finishes bringing the tunnel up a moment later.
  private scheduleSessionProbe(context: common.UIAbilityContext, attempt: number): void {
    if (attempt >= SESSION_PROBE_LIMIT || this.sessionActive) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (this.sessionActive || !this.appBackground) {
        return;
      }
      if (this.hasLiveVpnStatus(context.filesDir)) {
        this.sessionActive = true;
        this.suppressedReason = -1;
        this.sync();
        return;
      }
      this.scheduleSessionProbe(context, attempt + 1);
    }, SESSION_PROBE_INTERVAL_MS);
  }

  private sync(): void {
    const context: common.UIAbilityContext | undefined = this.abilityContext;
    if (context === undefined) {
      // Nothing to do yet. The VPN extension process reaches this path on every
      // status update, so only report it once per process.
      if (this.sessionActive && !this.missingContextLogged) {
        this.missingContextLogged = true;
        hilog.info(DOMAIN, TAG,
          'Continuous task waits for the UIAbility context that must own it');
      }
      return;
    }
    if (!this.sessionActive) {
      this.stop(this.generation + 1);
      return;
    }
    this.start(context, this.generation);
  }

  private async start(context: common.UIAbilityContext, generation: number): Promise<void> {
    if (this.started || this.starting || this.stopping) {
      return;
    }
    if (this.suppressedReason >= 0) {
      hilog.info(DOMAIN, TAG,
        'Continuous task stays cancelled until the next VPN session. reason=%{public}d',
        this.suppressedReason);
      return;
    }
    this.starting = true;
    const requestGeneration: number = generation;
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: BUNDLE_NAME,
          abilityName: ENTRY_ABILITY_NAME
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (requestGeneration !== this.generation || !this.sessionActive) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context, CONTINUOUS_TASK_MODE_ENUM, agent);
      if (requestGeneration !== this.generation || !this.sessionActive) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        return;
      }
      this.started = true;
      this.startHealthCheck(context, requestGeneration);
      this.startProgressRefresh(context, requestGeneration);
      hilog.info(DOMAIN, TAG,
        'VPN background continuous task started. mode=%{public}s', CONTINUOUS_TASK_MODE);
    } catch (error) {
      const businessError = error as BusinessError;
      const code: number = businessError.code ?? -1;
      // 9800005/9800006 mean the request itself was rejected (mode/business
      // mismatch or notification rejected). Retrying those in a loop is what
      // the Background Tasks Kit rules forbid, so record and wait for the next
      // user-initiated session instead.
      if (code === 9800005 || code === 9800006 || code === 201 || code === 401) {
        this.suppressedReason = code;
      }
      hilog.error(DOMAIN, TAG,
        'Failed to start VPN background continuous task. code=%{public}d %{public}s',
        code, DiagnosticPrivacy.formatLogError(businessError));
    } finally {
      this.starting = false;
    }
  }

  private async stop(generation: number): Promise<void> {
    if (this.stopping || (!this.started && !this.starting)) {
      return;
    }
    const context: common.UIAbilityContext | undefined = this.abilityContext;
    if (context === undefined) {
      return;
    }
    this.stopping = true;
    this.generation = Math.max(this.generation, generation);
    this.stopTimers();
    try {
      // Only stop the task this manager owns; the VPN extension has no task of
      // its own to cancel, and stopBackgroundRunning also drops unrelated
      // continuous tasks of the same ability.
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.started = false;
      hilog.info(DOMAIN, TAG, 'VPN background continuous task stopped');
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG,
        'Failed to stop VPN background continuous task. code=%{public}d %{public}s',
        businessError.code ?? -1, DiagnosticPrivacy.formatLogError(businessError));
      this.started = false;
    } finally {
      this.stopping = false;
      if (this.sessionActive && this.suppressedReason < 0) {
        this.sync();
      }
    }
  }

  private startHealthCheck(context: common.UIAbilityContext, generation: number): void {
    this.stopHealthCheck();
    this.healthTimer = setInterval(() => {
      if (generation !== this.generation || !this.started) {
        this.stopHealthCheck();
        return;
      }
      if (!this.hasLiveVpnStatus(context.filesDir)) {
        this.stopHealthCheck();
        this.sessionActive = false;
        this.stop(this.generation + 1);
      }
    }, HEALTH_CHECK_INTERVAL_MS);
  }

  // Refreshing the running task keeps a DATA_TRANSFER continuous task from
  // being cancelled for stale progress while the tunnel is up but idle.
  private startProgressRefresh(context: common.UIAbilityContext, generation: number): void {
    this.stopProgressRefresh();
    this.progressTimer = setInterval(() => {
      if (generation !== this.generation || !this.started) {
        this.stopProgressRefresh();
        return;
      }
      backgroundTaskManager.updateBackgroundRunning(context, [CONTINUOUS_TASK_MODE])
        .catch((error: BusinessError) => {
          hilog.warn(DOMAIN, TAG,
            'Failed to refresh VPN continuous task progress. code=%{public}d',
            error.code ?? -1);
        });
    }, PROGRESS_REFRESH_INTERVAL_MS);
  }

  private hasLiveVpnStatus(filesDir: string): boolean {
    try {
      const status: string = fileIo.readTextSync(StoragePaths.vpnStatusPath(filesDir));
      const heartbeatMatch: RegExpMatchArray | null = status.match(/heartbeatMs=(\d+)/);
      if (heartbeatMatch === null) {
        return false;
      }
      const heartbeatMs: number = Number(heartbeatMatch[1]);
      const ageMs: number = Date.now() - heartbeatMs;
      if (heartbeatMs <= 0 || ageMs < 0 || ageMs > VPN_STATUS_FRESH_MS) {
        return false;
      }
      const normalized: string = status.toLowerCase();
      if (normalized.includes('destroyed') || normalized.includes('stopped') ||
        normalized.includes('failed')) {
        return false;
      }
      return normalized.includes('state=running') ||
        normalized.includes('tun=true') ||
        normalized.includes('lifecycle entered') ||
        normalized.includes('connection object created') ||
        normalized.includes('creation pending') ||
        normalized.includes('interface established') ||
        normalized.includes('backend starting');
    } catch (_error) {
      return false;
    }
  }

  private stopTimers(): void {
    this.stopHealthCheck();
    this.stopProgressRefresh();
    this.stopSessionProbe();
  }

  private stopSessionProbe(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private stopHealthCheck(): void {
    if (this.healthTimer >= 0) {
      clearInterval(this.healthTimer);
      this.healthTimer = -1;
    }
  }

  private stopProgressRefresh(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }
}

// The UIAbility process owns the continuous task; the VPN extension process gets
// its own module instance, which only mirrors the VPN session state.
export const vpnBackgroundTaskManager: VpnBackgroundTaskManager = new VpnBackgroundTaskManager();
