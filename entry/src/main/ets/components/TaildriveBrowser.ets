import { common, Want, wantConstant } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { vibrator } from '@kit.SensorServiceKit';
import { systemShare } from '@kit.ShareKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  BlurStrategy,
  DividerShowType,
  HdsNavigation,
  HdsNavigationAttribute,
  HdsNavigationTitleMode,
  TextStyleMode,
  hdsMaterial
} from '@kit.UIDesignKit';
import {
  PreparedTaildriveFile,
  TaildriveEntry,
  TaildriveGateway,
  TaildriveListResult,
  TaildriveMutationRequest,
  TaildriveMutationResult,
  TaildriveStatResult,
  TaildriveTransferSnapshot
} from '../services/TaildriveGateway';
import {
  clearTaildriveProgress,
  publishTaildriveCompletion,
  publishTaildriveProgress,
  TaildriveNotificationTransfer
} from '../services/TaildriveNotificationService';
import {
  TaildriveCachedPreview,
  TaildrivePreviewGateway
} from '../services/TaildrivePreviewGateway';
import { AppSecurityAuthenticator } from '../services/AppSecurityAuthenticator';
import { AppSecurityPreferences } from '../services/AppSecurityPreferences';
import { APP_FOREGROUND_EVENT } from '../services/AppLifecycleEvents';
import { DiagnosticEventStore } from '../services/DiagnosticEventStore';
import { MotionTokens } from './MotionTokens';

interface TaildriveEntryGroup {
  key: string;
  title: ResourceStr;
  entries: TaildriveEntry[];
}

interface TaildriveListItemModel {
  key: string;
  header: boolean;
  title: ResourceStr;
  entry: TaildriveEntry;
}

interface TaildriveThumbnailModel {
  remotePath: string;
  uri: string;
}

const TAILDRIVE_AUTO_PREVIEW_LIMIT_BYTES: number = 5 * 1024 * 1024;
const TAILDRIVE_REFRESH_INTERVAL_MS: number = 30000;
const TAILDRIVE_LOG_DOMAIN: number = 0x0000;
const TAILDRIVE_LOG_TAG: string = 'TaildrivePreview';
const TAILDRIVE_SECURITY_LOG_TAG: string = 'TaildriveSecurity';

class TaildriveListDataSource implements IDataSource {
  private data: TaildriveListItemModel[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): TaildriveListItemModel {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replaceAll(items: TaildriveListItemModel[]): void {
    this.data = [...items];
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

@Component
export struct TaildriveBrowser {
  @Prop @Watch('onConnectedChanged') connected: boolean = false;
  @Prop standalone: boolean = false;
  @Prop bottomInset: number = 0;
  @Prop titleBarPadding: number = 16;
  @Prop materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @Prop transparentBackground: boolean = false;
  @Prop targetMachineName: string = '';
  @Prop targetTailnetName: string = '';
  @Prop @Watch('onFolderLockEnabledChanged') folderLockEnabled: boolean = false;
  @Prop @Watch('onAppLockActiveChanged') appLockActive: boolean = false;
  @StorageLink('taildriveLockedFolderPaths') @Watch('onLockedFolderPathsChanged') lockedFolderPaths: string[] = [];
  @Prop @Watch('onTargetRequestChanged') targetRequestId: number = 0;
  @StorageLink('taildriveFilesTabActive') @Watch('onFilesTabActiveChanged') private filesTabActive: boolean = false;
  @StorageLink('taildriveBackRequest') @Watch('onBackRequestChanged') backRequest: number = 0;
  @State private path: string = '/';
  @State private entries: TaildriveEntry[] = [];
  @State private loading: boolean = false;
  @State private busy: boolean = false;
  @State private previewDownloading: boolean = false;
  @State private manualDownloadCount: number = 0;
  @State private reason: string = '';
  @State private status: string = '';
  @State private searchQuery: string = '';
  @State private sortMode: string = 'modified';
  @State private sortDescending: boolean = true;
  @State private groupMode: string = 'date';
  @State private sortDraftMode: string = 'modified';
  @State private sortDraftDescending: boolean = true;
  @State private groupDraftMode: string = 'date';
  @State @Watch('onSortSheetVisibilityChanged') private sortSheetVisible: boolean = false;
  @State private searchVisible: boolean = false;
  @State private selectionMode: boolean = false;
  @State private selectedPaths: string[] = [];
  @State private viewMode: string = 'list';
  @State private retryAvailable: boolean = false;
  @State private editorVisible: boolean = false;
  @State private editorName: string = '';
  @State private editorOperation: string = 'mkdir';
  @State private editorPath: string = '';
  @State private folderDialogVisible: boolean = false;
  @State @Watch('onPreviewDownloadVisibilityChanged') private previewDownloadVisible: boolean = false;
  @State private previewDownloadEntry: TaildriveEntry = TaildriveBrowser.emptyEntry();
  @State private detailsVisible: boolean = false;
  @State private detailsLoading: boolean = false;
  @State private detailsReason: string = '';
  @State private detailEntry: TaildriveEntry = TaildriveBrowser.emptyEntry();
  @State private moveVisible: boolean = false;
  @State private moveLoading: boolean = false;
  @State private movePath: string = '/';
  @State private moveRoot: string = '/';
  @State private moveEntries: TaildriveEntry[] = [];
  @State private transfer: TaildriveTransferSnapshot = TaildriveBrowser.idleTransfer();
  @State private thumbnails: TaildriveThumbnailModel[] = [];

  private readonly gateway: TaildriveGateway = new TaildriveGateway();
  private readonly previewGateway: TaildrivePreviewGateway = new TaildrivePreviewGateway();
  private readonly listDataSource: TaildriveListDataSource = new TaildriveListDataSource();
  contentScroller: Scroller = new Scroller();
  private breadcrumbScroller: Scroller = new Scroller();
  private nextTransferRequestId: number = Date.now();
  private previewRequestId: number = 0;
  private previewGeneration: number = 0;
  private transferTimer: number = -1;
  private transferPollInFlight: boolean = false;
  private statusTimer: number = -1;
  private refreshTimer: number = -1;
  private refreshInFlight: boolean = false;
  private targetOpenInFlight: boolean = false;
  private lastTargetRequestId: number = 0;
  private deferredTargetRequestId: number = 0;
  private lastNotifiedProgress: number = -1;
  private retryKind: string = '';
  private retryDownloadEntry: TaildriveEntry | undefined = undefined;
  private retryPreviewEntry: TaildriveEntry | undefined = undefined;
  private retryMutation: TaildriveMutationRequest | undefined = undefined;
  private retryMutationWorkingStatus: string = 'mutation_failed';
  private retryMutationCompletedStatus: string = 'mutation_completed';
  private pendingUpload: PreparedTaildriveFile | undefined = undefined;
  private pendingUploadPath: string = '';
  private movingEntry: TaildriveEntry | undefined = undefined;
  private lastBackRequest: number = 0;
  private thumbnailWorkPaths: string[] = [];
  private folderAccessGrants: string[] = [];
  private folderAccessAuthenticationInFlight: boolean = false;
  private folderPolicyAuthenticationInFlight: boolean = false;
  private protectedFolderResumePending: boolean = false;
  private protectedFolderResumeInFlight: boolean = false;
  private securityResumeTimer: number = -1;
  private appForegroundListener: () => void = () => this.handleAppForeground();

  aboutToAppear(): void {
    this.gateway.configure(this.context());
    this.gateway.cleanupStaleStaging(this.stagingRoot());
    this.context().eventHub.on(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.thumbnails = [];
    this.updateBackState();
    if (!this.connected) {
      return;
    }
    if (this.targetRequestId > 0 && this.targetMachineName.length > 0) {
      this.requestTargetMachineOpen();
    } else if (this.filesTabActive) {
      this.refresh();
    }
    if (this.filesTabActive) {
      this.startRefreshPolling();
    }
  }

  aboutToDisappear(): void {
    this.context().eventHub.off(APP_FOREGROUND_EVENT, this.appForegroundListener);
    this.clearSecurityResumeTimer();
    this.folderAccessGrants = [];
    this.protectedFolderResumePending = false;
    this.cancelPreviewDownload();
    this.stopTransferPolling();
    this.stopRefreshPolling();
    this.clearStatusTimer();
    clearTaildriveProgress();
    AppStorage.setOrCreate('taildriveUiBackActive', false);
  }

  private static emptyEntry(): TaildriveEntry {
    return { name: '', path: '', kind: '', size: 0, modifiedAtMs: 0 };
  }

  private static idleTransfer(): TaildriveTransferSnapshot {
    return {
      requestId: 0, direction: '', state: 'idle', reason: '', remotePath: '', localPath: '',
      fileName: '', bytes: 0, totalBytes: 0, startedAtMs: 0, completedAtMs: 0
    };
  }

  private onConnectedChanged(): void {
    if (this.connected) {
      if (this.targetRequestId > 0 && this.targetMachineName.length > 0) {
        this.requestTargetMachineOpen();
      } else if (this.filesTabActive) {
        this.refresh();
      }
      if (this.filesTabActive) {
        this.startRefreshPolling();
      }
    } else {
      this.stopRefreshPolling();
      this.folderAccessGrants = [];
      this.protectedFolderResumePending = false;
      this.entries = [];
      this.loading = false;
      this.searchVisible = false;
      this.exitSelectionMode();
      this.reason = 'backend_unavailable';
      this.status = '';
    }
  }

  private onTargetRequestChanged(): void {
    if (this.connected && this.targetRequestId > 0 && this.targetMachineName.length > 0) {
      this.requestTargetMachineOpen();
    }
  }

  private onFilesTabActiveChanged(): void {
    if (!this.filesTabActive) {
      this.stopRefreshPolling();
      this.folderAccessGrants = [];
      if (this.protectedFolderRoot(this.path).length > 0) {
        this.blockProtectedFolderContent();
      }
      return;
    }
    if (!this.connected) {
      return;
    }
    this.startRefreshPolling();
    if (this.protectedFolderResumePending || !this.hasFolderAccess(this.path)) {
      this.resumeProtectedFolderAccess();
      return;
    }
    if (this.targetOpenInFlight) {
      return;
    }
    if (this.targetRequestId > this.lastTargetRequestId && this.targetMachineName.length > 0) {
      this.requestTargetMachineOpen();
    } else {
      this.refresh();
    }
  }

  private onFolderLockEnabledChanged(): void {
    this.folderAccessGrants = [];
    if (!this.folderLockEnabled) {
      this.protectedFolderResumePending = false;
      if (this.filesTabActive && this.connected) {
        this.refresh();
      }
      return;
    }
    if (this.protectedFolderRoot(this.path).length > 0) {
      this.blockProtectedFolderContent();
      if (this.filesTabActive) {
        this.resumeProtectedFolderAccess();
      }
    }
  }

  private onLockedFolderPathsChanged(): void {
    this.folderAccessGrants = [];
    if (this.folderLockEnabled && this.protectedFolderRoot(this.path).length > 0) {
      this.blockProtectedFolderContent();
    }
  }

  private onAppLockActiveChanged(): void {
    if (!this.appLockActive && this.protectedFolderResumePending && this.filesTabActive) {
      this.resumeProtectedFolderAccess();
    }
  }

  private handleAppForeground(): void {
    this.folderAccessGrants = [];
    if (!this.folderLockEnabled || this.protectedFolderRoot(this.path).length === 0) {
      return;
    }
    this.blockProtectedFolderContent();
    this.clearSecurityResumeTimer();
    this.securityResumeTimer = setTimeout((): void => {
      this.securityResumeTimer = -1;
      if (this.filesTabActive && !this.appLockActive) {
        this.resumeProtectedFolderAccess();
      }
    }, 250);
  }

  private clearSecurityResumeTimer(): void {
    if (this.securityResumeTimer >= 0) {
      clearTimeout(this.securityResumeTimer);
      this.securityResumeTimer = -1;
    }
  }

  private onBackRequestChanged(): void {
    if (this.backRequest <= this.lastBackRequest) {
      return;
    }
    this.lastBackRequest = this.backRequest;
    if (this.folderDialogVisible) {
      this.closeFolderDialog();
    } else if (this.previewDownloadVisible) {
      this.previewDownloadVisible = false;
    } else if (this.sortSheetVisible) {
      this.closeSortPanel();
    } else if (this.selectionMode) {
      this.exitSelectionMode();
    } else if (this.searchVisible) {
      this.setSearchVisible(false);
    } else if (this.path !== '/') {
      this.goUp();
    }
  }

  private onSortSheetVisibilityChanged(): void {
    this.publishUiBackState();
  }

  private onPreviewDownloadVisibilityChanged(): void {
    this.publishUiBackState();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private vibrateTouch(strong: boolean = false): void {
    vibrator.startVibration({
      type: 'preset',
      effectId: strong ? vibrator.HapticFeedback.EFFECT_HARD : vibrator.HapticFeedback.EFFECT_SOFT
    }, { usage: 'touch' }).catch((): void => {});
  }

  private clearStatusTimer(): void {
    if (this.statusTimer >= 0) {
      clearTimeout(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private showTransientStatus(status: string): void {
    this.clearStatusTimer();
    this.status = status;
    this.statusTimer = setTimeout((): void => {
      if (this.status === status && !this.retryAvailable) {
        this.status = '';
      }
      this.statusTimer = -1;
    }, 5000);
  }

  private stagingRoot(): string {
    return `${this.context().cacheDir}/taildrive-staging`;
  }

  private requestTargetMachineOpen(): void {
    if (!this.connected || this.busy || this.targetRequestId <= this.lastTargetRequestId) {
      return;
    }
    if (this.loading || this.refreshInFlight || this.targetOpenInFlight) {
      this.deferredTargetRequestId = Math.max(this.deferredTargetRequestId, this.targetRequestId);
      return;
    }
    const requestId: number = this.targetRequestId;
    this.lastTargetRequestId = requestId;
    this.deferredTargetRequestId = 0;
    this.openTargetMachine(requestId);
  }

  private async openTargetMachine(requestId: number): Promise<void> {
    if (!this.connected || this.busy) {
      return;
    }
    const startedAtMs: number = Date.now();
    this.targetOpenInFlight = true;
    this.loading = true;
    this.reason = '';
    this.status = '';
    try {
      const directPath: string = this.directTargetMachinePath();
      if (directPath.length > 0) {
        if (!await this.ensureFolderAccess(directPath)) {
          return;
        }
        const direct: TaildriveListResult = await this.gateway.list(directPath);
        if (direct.state === 'ready') {
          this.applyListResult(direct, directPath);
          this.clearRetry();
          hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
            'target open completed. route=direct durationMs=%{public}s',
            (Date.now() - startedAtMs).toString());
          return;
        }
      }
      const root: TaildriveListResult = await this.gateway.list('/');
      if (root.state !== 'ready') {
        this.reason = root.reason.length > 0 ? root.reason : 'list_failed';
        this.setRetry('target');
        return;
      }
      let targetPath: string = '';
      const tailnets: TaildriveEntry[] = root.entries.filter((entry: TaildriveEntry) =>
        entry.kind === 'directory');
      tailnets.sort((left: TaildriveEntry, right: TaildriveEntry) =>
        this.tailnetMatchPriority(right.name) - this.tailnetMatchPriority(left.name));
      for (let index: number = 0; index < tailnets.length && targetPath.length === 0; index++) {
        const tailnet: TaildriveEntry = tailnets[index];
        const machines: TaildriveListResult = await this.gateway.list(tailnet.path);
        if (machines.state !== 'ready') {
          continue;
        }
        const target: TaildriveEntry | undefined = machines.entries.find((entry: TaildriveEntry) =>
          entry.kind === 'directory' && this.machineNamesMatch(entry.name, this.targetMachineName));
        if (target !== undefined) {
          targetPath = target.path;
        }
      }
      if (targetPath.length === 0) {
        this.path = '/';
        this.entries = root.entries;
        this.refreshThumbnails(root.entries);
        this.rebuildListDataSource();
        this.status = 'target_not_found';
        this.clearRetry();
        return;
      }
      if (!await this.ensureFolderAccess(targetPath)) {
        return;
      }
      this.path = targetPath;
      this.updateBackState();
      this.clearRetry();
      const target: TaildriveListResult = await this.gateway.list(targetPath);
      if (target.state !== 'ready') {
        this.reason = target.reason.length > 0 ? target.reason : 'list_failed';
        this.setRetry('target');
        return;
      }
      this.applyListResult(target, targetPath);
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'target open completed. route=fallback durationMs=%{public}s',
        (Date.now() - startedAtMs).toString());
    } catch (_error) {
      this.reason = 'backend_unavailable';
      this.setRetry('target');
      return;
    } finally {
      this.loading = false;
      this.targetOpenInFlight = false;
      if (this.deferredTargetRequestId > requestId) {
        this.requestTargetMachineOpen();
      }
    }
  }

  private directTargetMachinePath(): string {
    const tailnetName: string = this.targetTailnetName.trim();
    const normalizedMachine: string = this.normalizedMachineName(this.targetMachineName);
    const machineName: string = normalizedMachine.split('.')[0];
    if (!this.validName(tailnetName) || !this.validName(machineName)) {
      return '';
    }
    return this.joinPath(this.joinPath('/', tailnetName), machineName);
  }

  private tailnetMatchPriority(name: string): number {
    return name.trim().toLowerCase() === this.targetTailnetName.trim().toLowerCase() ? 1 : 0;
  }

  private applyListResult(result: TaildriveListResult, fallbackPath: string): void {
    this.path = result.path.length > 0 ? result.path : fallbackPath;
    this.entries = result.entries;
    this.refreshThumbnails(result.entries);
    this.updateBackState();
    this.selectedPaths = this.selectedPaths.filter((path: string) =>
      result.entries.some((entry: TaildriveEntry) => entry.path === path));
    this.rebuildListDataSource();
    this.reason = '';
  }

  private machineNamesMatch(left: string, right: string): boolean {
    const leftName: string = this.normalizedMachineName(left);
    const rightName: string = this.normalizedMachineName(right);
    return leftName === rightName || leftName.split('.')[0] === rightName.split('.')[0];
  }

  private normalizedMachineName(value: string): string {
    let name: string = value.trim().toLowerCase();
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    return name;
  }

  private async refresh(minimumIndicatorMs: number = 0, silent: boolean = false): Promise<void> {
    if (!this.connected || this.refreshInFlight || this.targetOpenInFlight) {
      return;
    }
    if (!this.hasFolderAccess(this.path)) {
      this.blockProtectedFolderContent();
      return;
    }
    const startedAtMs: number = Date.now();
    this.refreshInFlight = true;
    if (!silent) {
      this.loading = true;
    }
    this.reason = '';
    try {
      const result: TaildriveListResult = await this.gateway.list(this.path);
      if (result.state === 'ready') {
        this.applyListResult(result, this.path);
        if (this.retryKind === 'refresh') {
          this.clearRetry();
        }
      } else {
        this.reason = result.reason.length > 0 ? result.reason : 'list_failed';
        this.setRetry('refresh');
      }
    } catch (_error) {
      this.reason = 'backend_unavailable';
      this.setRetry('refresh');
    } finally {
      const remainingIndicatorMs: number = minimumIndicatorMs - (Date.now() - startedAtMs);
      if (remainingIndicatorMs > 0) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, remainingIndicatorMs));
      }
      if (!silent) {
        this.loading = false;
      }
      this.refreshInFlight = false;
      if (this.targetRequestId > this.lastTargetRequestId && this.targetMachineName.length > 0) {
        this.requestTargetMachineOpen();
      }
    }
  }

  private async openEntry(entry: TaildriveEntry): Promise<void> {
    if (!this.connected) {
      return;
    }
    if (this.selectionMode) {
      this.toggleEntrySelection(entry);
      return;
    }
    if (entry.kind === 'directory') {
      if (this.busy) {
        return;
      }
      if (!await this.ensureFolderAccess(entry.path)) {
        return;
      }
      this.path = entry.path;
      this.updateBackState();
      this.searchQuery = '';
      this.searchVisible = false;
      this.exitSelectionMode();
      this.publishUiBackState();
      await this.refresh();
      return;
    }
    await this.openFileForPreview(entry);
  }

  private folderPathSegments(remotePath: string): number {
    return remotePath.split('/').filter((segment: string) => segment.length > 0).length;
  }

  private normalizeFolderPath(remotePath: string): string {
    const normalized: string = remotePath.trim().replace(/\/+$/, '');
    return normalized.length > 0 ? normalized : '/';
  }

  // /tailnet/device is the first lockable path. Tailnet names remain navigation-only.
  private canLockFolder(entry: TaildriveEntry): boolean {
    return entry.kind === 'directory' && this.folderPathSegments(entry.path) >= 2;
  }

  private isFolderDirectlyLocked(remotePath: string): boolean {
    const normalized: string = this.normalizeFolderPath(remotePath);
    return this.lockedFolderPaths.some((path: string) =>
      this.normalizeFolderPath(path) === normalized);
  }

  private pathIsWithin(remotePath: string, folderPath: string): boolean {
    const normalizedPath: string = this.normalizeFolderPath(remotePath);
    const normalizedFolder: string = this.normalizeFolderPath(folderPath);
    return normalizedPath === normalizedFolder || normalizedPath.startsWith(`${normalizedFolder}/`);
  }

  private protectedFolderRoot(remotePath: string): string {
    if (!this.folderLockEnabled) {
      return '';
    }
    const matching: string[] = this.lockedFolderPaths
      .map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string) => this.pathIsWithin(remotePath, path));
    matching.sort((left: string, right: string) => right.length - left.length);
    return matching.length > 0 ? matching[0] : '';
  }

  private protectedFolderRootsTouching(remotePath: string): string[] {
    if (!this.folderLockEnabled) {
      return [];
    }
    const normalized: string = this.normalizeFolderPath(remotePath);
    return this.lockedFolderPaths
      .map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string, index: number, paths: string[]) =>
        paths.indexOf(path) === index &&
        (this.pathIsWithin(normalized, path) || this.pathIsWithin(path, normalized)));
  }

  private hasFolderAccess(remotePath: string): boolean {
    const protectedRoot: string = this.protectedFolderRoot(remotePath);
    return protectedRoot.length === 0 || this.folderAccessGrants.includes(protectedRoot);
  }

  private blockProtectedFolderContent(): void {
    this.protectedFolderResumePending = true;
    this.entries = [];
    this.thumbnails = [];
    this.thumbnailWorkPaths = [];
    this.exitSelectionMode();
    this.rebuildListDataSource();
  }

  private async resumeProtectedFolderAccess(): Promise<void> {
    if (!this.connected || !this.filesTabActive || this.appLockActive ||
      !this.protectedFolderResumePending || this.protectedFolderResumeInFlight) {
      return;
    }
    this.protectedFolderResumeInFlight = true;
    try {
      const protectedRoot: string = this.protectedFolderRoot(this.path);
      if (protectedRoot.length === 0) {
        this.protectedFolderResumePending = false;
        await this.refresh();
        return;
      }
      const passed: boolean = await this.ensureFolderAccess(this.path);
      if (passed) {
        this.protectedFolderResumePending = false;
        await this.refresh();
        return;
      }
      this.protectedFolderResumePending = false;
      this.path = this.parentPath(protectedRoot);
      this.updateBackState();
      await this.refresh();
    } finally {
      this.protectedFolderResumeInFlight = false;
    }
  }

  private async ensureFolderAccess(remotePath: string): Promise<boolean> {
    const protectedRoot: string = this.protectedFolderRoot(remotePath);
    if (protectedRoot.length === 0 || this.folderAccessGrants.includes(protectedRoot)) {
      return true;
    }
    if (this.folderAccessAuthenticationInFlight) {
      return false;
    }
    this.folderAccessAuthenticationInFlight = true;
    this.recordSecurityDiagnostic('folder_access_auth_started', 'protected_folder');
    try {
      const title: string = this.context().resourceManager.getStringSync(
        $r('app.string.security_folder_authentication_title').id);
      const passed: boolean = await AppSecurityAuthenticator.authenticate(title);
      if (passed) {
        this.folderAccessGrants = [...this.folderAccessGrants, protectedRoot];
        this.recordSecurityDiagnostic('folder_access_auth_completed', 'passed');
      } else {
        this.showTransientStatus('folder_authentication_failed');
        this.recordSecurityDiagnostic('folder_access_auth_completed', 'failed');
      }
      return passed;
    } finally {
      this.folderAccessAuthenticationInFlight = false;
    }
  }

  private async ensureProtectedMutationAccess(remotePath: string): Promise<boolean> {
    const protectedRoots: string[] = this.protectedFolderRootsTouching(remotePath);
    for (let index: number = 0; index < protectedRoots.length; index++) {
      if (!await this.ensureFolderAccess(protectedRoots[index])) {
        return false;
      }
    }
    return true;
  }

  private async ensureMutationRequestAccess(request: TaildriveMutationRequest): Promise<boolean> {
    if (!await this.ensureProtectedMutationAccess(request.path)) {
      return false;
    }
    if (request.newPath === undefined) {
      return true;
    }
    return await this.ensureFolderAccess(request.newPath);
  }

  private normalizeLockedFolderList(paths: string[]): string[] {
    const normalized: string[] = [];
    paths.map((path: string) => this.normalizeFolderPath(path))
      .filter((path: string) => path !== '/')
      .sort((left: string, right: string) => left.length - right.length)
      .forEach((path: string) => {
        if (!normalized.some((parent: string) => this.pathIsWithin(path, parent))) {
          normalized.push(path);
        }
      });
    return normalized;
  }

  private async reconcileLockedFoldersAfterMutation(request: TaildriveMutationRequest): Promise<boolean> {
    const sourcePath: string = this.normalizeFolderPath(request.path);
    let next: string[] = [...this.lockedFolderPaths];
    if (request.operation === 'delete') {
      next = next.filter((path: string) => !this.pathIsWithin(path, sourcePath));
    } else if ((request.operation === 'rename' || request.operation === 'move') &&
      request.newPath !== undefined) {
      const targetPath: string = this.normalizeFolderPath(request.newPath);
      next = next.map((path: string) => {
        const normalizedPath: string = this.normalizeFolderPath(path);
        if (!this.pathIsWithin(normalizedPath, sourcePath)) {
          return normalizedPath;
        }
        return `${targetPath}${normalizedPath.substring(sourcePath.length)}`;
      });
    } else {
      return true;
    }
    next = this.normalizeLockedFolderList(next);
    const current: string[] = this.normalizeLockedFolderList(this.lockedFolderPaths);
    if (JSON.stringify(next) === JSON.stringify(current)) {
      return true;
    }
    try {
      await AppSecurityPreferences.saveLockedFolderPaths(this.context(), next);
      AppStorage.setOrCreate('taildriveLockedFolderPaths', next);
      this.recordSecurityDiagnostic('folder_policy_reconciled', request.operation, next.length);
      return true;
    } catch (_error) {
      // Keep the current session aligned with the already-completed remote mutation.
      AppStorage.setOrCreate('taildriveLockedFolderPaths', next);
      this.recordSecurityDiagnostic('folder_policy_reconcile_failed', request.operation, next.length);
      return false;
    }
  }

  private toggleFolderLock(entry: TaildriveEntry): void {
    if (!this.canChangeFolderLock(entry) || this.folderPolicyAuthenticationInFlight) {
      return;
    }
    this.updateFolderLock(entry);
  }

  private canChangeFolderLock(entry: TaildriveEntry): boolean {
    if (!this.canLockFolder(entry)) {
      return false;
    }
    const protectedRoot: string = this.protectedFolderRoot(entry.path);
    return protectedRoot.length === 0 || this.isFolderDirectlyLocked(entry.path);
  }

  private async updateFolderLock(entry: TaildriveEntry): Promise<void> {
    this.folderPolicyAuthenticationInFlight = true;
    const normalized: string = this.normalizeFolderPath(entry.path);
    const operation: string = this.isFolderDirectlyLocked(normalized) ? 'unlock' : 'lock';
    this.recordSecurityDiagnostic('folder_policy_auth_started', operation);
    try {
      const title: string = this.context().resourceManager.getStringSync(
        $r('app.string.security_settings_authentication_title').id);
      const passed: boolean = await AppSecurityAuthenticator.authenticate(title);
      if (!passed) {
        this.showTransientStatus('folder_authentication_failed');
        this.recordSecurityDiagnostic('folder_policy_auth_completed', 'failed');
        return;
      }
      const next: string[] = this.isFolderDirectlyLocked(normalized) ?
        this.lockedFolderPaths.filter((path: string) => this.normalizeFolderPath(path) !== normalized) :
        [...this.lockedFolderPaths, normalized];
      await AppSecurityPreferences.saveLockedFolderPaths(this.context(), next);
      AppStorage.setOrCreate('taildriveLockedFolderPaths', next);
      this.folderAccessGrants = [];
      this.recordSecurityDiagnostic('folder_policy_changed', operation, next.length);
    } catch (_error) {
      this.recordSecurityDiagnostic('folder_policy_change_failed', operation);
      this.showTransientStatus('security_settings_save_failed');
    } finally {
      this.folderPolicyAuthenticationInFlight = false;
    }
  }

  private recordSecurityDiagnostic(event: string, phase: string, code: number = 0): void {
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_SECURITY_LOG_TAG,
      'event=%{public}s phase=%{public}s code=%{public}d', event, phase, code);
    try {
      DiagnosticEventStore.record(this.context().filesDir, 'ui', event, phase, code);
    } catch (_error) {
      // Security diagnostics are best-effort and never block folder access.
    }
  }

  private async openFileForPreview(entry: TaildriveEntry): Promise<void> {
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    // A new preview supersedes an unfinished preview download. This does not
    // touch manual exports, which use a separate transfer channel.
    await this.cancelPreviewDownload();
    const cached: TaildriveCachedPreview | undefined =
      this.previewGateway.cachedPreview(this.context(), entry);
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
      'open requested. cached=%{public}s size=%{public}d',
      cached === undefined ? 'false' : 'true', entry.size);
    if (cached !== undefined) {
      if (cached.thumbnailPath.length > 0) {
        this.setThumbnail(entry, cached.thumbnailPath);
      }
      // The external preview ability may keep its Promise pending until it
      // exits. It must not keep this file-row action pending either.
      this.openSystemPreview(entry, cached.path).catch(() => {});
      return;
    }
    if (entry.size >= 0 && entry.size < TAILDRIVE_AUTO_PREVIEW_LIMIT_BYTES) {
      await this.downloadForPreview(entry, true);
      return;
    }
    this.promptPreviewDownload(entry);
  }

  private promptPreviewDownload(entry: TaildriveEntry): void {
    this.previewDownloadEntry = entry;
    this.previewDownloadVisible = true;
  }

  private confirmPreviewDownload(): void {
    const entry: TaildriveEntry = this.previewDownloadEntry;
    this.previewDownloadVisible = false;
    this.downloadForPreview(entry, true);
  }

  private async downloadForPreview(entry: TaildriveEntry,
    openAfterDownload: boolean = true): Promise<void> {
    if (!this.connected) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download skipped before cleanup: disconnected');
      return;
    }
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download cleanup started');
    await this.cancelPreviewDownload();
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download cleanup returned');
    if (!this.connected) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download skipped after cleanup: disconnected');
      return;
    }
    const generation: number = ++this.previewGeneration;
    const requestId: number = this.newTransferRequestId();
    let root: string = '';
    let localPath: string = '';
    try {
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation started');
      root = this.previewGateway.root(this.context());
      localPath = this.previewGateway.prepareDownload(this.context(), entry);
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation completed');
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'download destination preparation failed');
      this.status = 'preview_download_failed';
      this.retryPreviewEntry = entry;
      this.setRetry('preview');
      return;
    }
    this.previewRequestId = requestId;
    this.previewDownloading = true;
    this.status = 'preview_downloading';
    this.clearRetry();
    this.startTransferPolling();
    hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
      'download requested. requestId=%{public}s', requestId.toString());
    let downloadCompleted: boolean = false;
    try {
      const result: TaildriveTransferSnapshot = await this.gateway.download({
        requestId: requestId,
        remotePath: entry.path,
        localRoot: root,
        localPath: localPath
      });
      if (generation !== this.previewGeneration) {
        return;
      }
      this.transfer = result;
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'download response. requestId=%{public}s state=%{public}s reason=%{public}s',
        requestId.toString(), result.state, result.reason);
      if (result.state !== 'completed') {
        this.status = result.reason.length > 0 ? result.reason : 'preview_download_failed';
        this.retryPreviewEntry = entry;
        this.setRetry('preview');
        return;
      }
      downloadCompleted = true;
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG,
        'download threw. requestId=%{public}s', requestId.toString());
      if (generation === this.previewGeneration) {
        this.status = 'preview_download_failed';
        this.retryPreviewEntry = entry;
        this.setRetry('preview');
      }
    } finally {
      if (generation === this.previewGeneration) {
        this.previewRequestId = 0;
        this.previewDownloading = false;
        this.stopTransferPolling();
        clearTaildriveProgress().catch(() => {});
      }
    }

    if (generation !== this.previewGeneration) {
      return;
    }
    if (!downloadCompleted) {
      publishTaildriveCompletion(this.context(), entry.name, false).catch(() => {});
      return;
    }

    this.showTransientStatus('preview_download_completed');
    this.previewGateway.createThumbnail(this.context(), entry, localPath)
      .then((thumbnailPath: string) => {
        if (thumbnailPath.length > 0) {
          this.setThumbnail(entry, thumbnailPath);
        }
      })
      .catch(() => {});
    publishTaildriveCompletion(this.context(), entry.name, true).catch(() => {});

    if (openAfterDownload) {
      // Do not await the external preview ability. Some system previewers keep
      // startAbility pending until the preview page returns.
      this.openSystemPreview(entry, localPath).catch(() => {});
    }
  }

  private newTransferRequestId(): number {
    this.nextTransferRequestId++;
    return this.nextTransferRequestId;
  }

  /**
   * Cancels only the active preview transfer. Manual exports use a separate
   * native request channel and are intentionally left running.
   */
  private async cancelPreviewDownload(): Promise<void> {
    if (this.previewRequestId <= 0) {
      return;
    }
    this.previewGeneration++;
    this.previewRequestId = 0;
    this.previewDownloading = false;
    this.stopTransferPolling();
    if (this.status === 'preview_downloading') {
      this.status = '';
    }
    if (this.retryKind === 'preview') {
      this.clearRetry();
    }
    clearTaildriveProgress().catch(() => {});
    // Cancellation shares the control channel with progress snapshots. Never
    // hold a later file click behind an old or slow control response.
    this.gateway.cancel().catch(() => {
      // The transfer may already have completed while the cancel request was queued.
    });
  }

  private async openSystemPreview(entry: TaildriveEntry, localPath: string): Promise<void> {
    const uri: string = fileUri.getUriFromPath(localPath);
    const type: string = this.contentTypeForEntry(entry);
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: type,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility requested');
      await this.context().startAbility(want);
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility returned');
      return;
    } catch (_error) {
      hilog.warn(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview startAbility failed');
      // Some releases do not route file URIs through startAbility. Keep the
      // browser handoff as a compatibility fallback after the authorized path.
    }
    try {
      await this.context().openLink(uri, { appLinkingOnly: false });
      hilog.info(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview openLink returned');
    } catch (_error) {
      hilog.error(TAILDRIVE_LOG_DOMAIN, TAILDRIVE_LOG_TAG, 'system preview openLink failed');
      this.status = 'preview_failed';
    }
  }

  private goUp(): void {
    if (this.path === '/' || this.busy) {
      return;
    }
    this.path = this.parentPath(this.path);
    this.updateBackState();
    this.searchQuery = '';
    this.searchVisible = false;
    this.exitSelectionMode();
    this.publishUiBackState();
    this.refresh();
  }

  private async selectUpload(): Promise<void> {
    if (!this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    if (!await this.ensureFolderAccess(this.path)) {
      return;
    }
    const documentPicker = new picker.DocumentViewPicker(this.context());
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    let uris: string[] = [];
    try {
      uris = await documentPicker.select(options);
    } catch (_error) {
      this.status = 'file_selection_failed';
    }
    if (uris.length === 0) {
      return;
    }
    this.discardPendingUpload();
    const requestId: number = Date.now();
    try {
      fileIo.mkdirSync(this.stagingRoot(), true);
      const staged: PreparedTaildriveFile = await this.gateway.stageUpload(uris[0], this.stagingRoot(), requestId);
      this.pendingUpload = staged;
      this.pendingUploadPath = this.joinPath(this.path, this.safeRemoteName(staged.name));
      await this.executeUpload(false);
    } catch (_error) {
      this.status = 'upload_failed';
      this.clearRetry();
    }
  }

  private async executeUpload(overwrite: boolean): Promise<void> {
    if (this.pendingUpload === undefined || this.pendingUploadPath.length === 0) {
      this.status = 'file_unavailable';
      this.clearRetry();
      return;
    }
    if (!await this.ensureFolderAccess(this.pendingUploadPath)) {
      return;
    }
    const staged: PreparedTaildriveFile = this.pendingUpload;
    this.busy = true;
    this.status = 'uploading';
    this.clearRetry();
    this.startTransferPolling();
    try {
      const result: TaildriveTransferSnapshot = await this.gateway.upload({
        requestId: Date.now(),
        remotePath: this.pendingUploadPath,
        localRoot: this.stagingRoot(),
        localPath: staged.path,
        sourceModifiedAtMs: staged.modifiedAtMs,
        overwrite: overwrite
      });
      this.transfer = result;
      if (result.state === 'completed') {
        this.showTransientStatus('upload_completed');
        await publishTaildriveCompletion(this.context(), staged.name, true);
        this.discardPendingUpload();
        await this.refresh();
      } else if ((result.reason === 'already_exists' || result.reason === 'file_exists') && !overwrite) {
        this.status = result.reason;
        this.promptUploadOverwrite(staged.name);
      } else {
        this.status = result.reason.length > 0 ? result.reason : 'upload_failed';
        this.setRetry('upload');
        await publishTaildriveCompletion(this.context(), staged.name, false);
      }
    } catch (_error) {
      this.status = 'upload_failed';
      this.setRetry('upload');
      await publishTaildriveCompletion(this.context(), staged.name, false);
    } finally {
      this.busy = false;
      this.stopTransferPolling();
      await clearTaildriveProgress();
    }
  }

  private promptUploadOverwrite(fileName: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.taildrive_overwrite_title'),
      message: fileName,
      autoCancel: false,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => this.discardPendingUpload()
      },
      secondaryButton: {
        value: $r('app.string.taildrive_replace_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.executeUpload(true)
      }
    });
  }

  private discardPendingUpload(): void {
    if (this.pendingUpload !== undefined) {
      this.gateway.cleanupStaged(this.pendingUpload);
    }
    this.pendingUpload = undefined;
    this.pendingUploadPath = '';
    if (this.retryKind === 'upload') {
      this.clearRetry();
    }
  }

  private async download(entry: TaildriveEntry): Promise<void> {
    if (!this.connected || entry.kind !== 'file') {
      return;
    }
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    const requestId: number = this.newTransferRequestId();
    const root: string = this.stagingRoot();
    const requestDir: string = `${root}/${requestId}`;
    const localPath: string = `${requestDir}/download.taildrive`;
    this.manualDownloadCount++;
    this.status = 'downloading';
    this.clearRetry();
    try {
      fileIo.mkdirSync(root, true);
      fileIo.mkdirSync(requestDir, true);
      const result: TaildriveTransferSnapshot = await this.gateway.download({
        requestId: requestId,
        remotePath: entry.path,
        localRoot: root,
        localPath: localPath
      }, true);
      if (result.state !== 'completed') {
        this.status = result.reason.length > 0 ? result.reason : 'download_failed';
        this.retryDownloadEntry = entry;
        this.setRetry('download');
        await publishTaildriveCompletion(this.context(), entry.name, false);
        return;
      }
      const documentPicker = new picker.DocumentViewPicker(this.context());
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.safeLocalName(entry.name)];
      const destinations: string[] = await documentPicker.save(options);
      if (destinations.length === 0) {
        this.status = 'export_cancelled';
        return;
      }
      const exported: boolean = await this.gateway.exportFile(localPath, destinations[0], result.bytes);
      if (exported) {
        this.showTransientStatus('download_completed');
      } else {
        this.status = 'export_failed';
      }
      if (exported) {
        await publishTaildriveCompletion(this.context(), entry.name, true);
      } else {
        this.retryDownloadEntry = entry;
        this.setRetry('download');
        await publishTaildriveCompletion(this.context(), entry.name, false);
      }
    } catch (_error) {
      this.status = 'download_failed';
      this.retryDownloadEntry = entry;
      this.setRetry('download');
      await publishTaildriveCompletion(this.context(), entry.name, false);
    } finally {
      this.cleanupDirectory(requestDir);
      this.manualDownloadCount = Math.max(0, this.manualDownloadCount - 1);
    }
  }

  private createFolder(): void {
    if (!this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    this.editorOperation = 'mkdir';
    this.editorPath = '';
    this.editorName = this.suggestNewFolderName();
    this.folderDialogVisible = true;
    this.publishUiBackState();
  }

  private localizedNewFolderName(): string {
    try {
      return this.context().resourceManager.getStringSync($r('app.string.taildrive_new_folder_default_name').id);
    } catch (_error) {
      return 'New folder';
    }
  }

  private suggestNewFolderName(): string {
    const baseName: string = this.localizedNewFolderName();
    const existingNames: string[] = this.entries.map((entry: TaildriveEntry) => entry.name.toLowerCase());
    if (!existingNames.includes(baseName.toLowerCase())) {
      return baseName;
    }
    let suffix: number = 2;
    while (existingNames.includes(`${baseName} (${suffix})`.toLowerCase())) {
      suffix++;
    }
    return `${baseName} (${suffix})`;
  }

  private closeFolderDialog(): void {
    this.folderDialogVisible = false;
    this.editorName = '';
    this.publishUiBackState();
  }

  private async submitFolderDialog(): Promise<void> {
    const name: string = this.editorName.trim();
    if (!this.validName(name)) {
      this.status = 'invalid_name';
      return;
    }
    if (!await this.ensureFolderAccess(this.path)) {
      return;
    }
    this.folderDialogVisible = false;
    this.editorName = '';
    this.publishUiBackState();
    await this.executeMutation({ operation: 'mkdir', path: this.joinPath(this.path, name) },
      'creating_folder', 'mutation_completed');
  }

  private renameEntry(entry: TaildriveEntry): void {
    if (!this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    this.editorOperation = 'rename';
    this.editorPath = entry.path;
    this.editorName = entry.name;
    this.editorVisible = true;
  }

  private confirmDelete(entry: TaildriveEntry): void {
    if (!this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.taildrive_delete_title'),
      message: entry.name,
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel_action'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.taildrive_delete_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.deleteEntry(entry)
      }
    });
  }

  private async deleteEntry(entry: TaildriveEntry): Promise<void> {
    await this.executeMutation({ operation: 'delete', path: entry.path }, 'deleting', 'delete_completed');
  }

  private confirmDeleteSelected(): void {
    const selected: TaildriveEntry[] = this.selectedEntries();
    if (selected.length === 0 || !this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.taildrive_delete_title'),
      message: $r('app.string.taildrive_delete_selected_message', selected.length),
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel_action'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.taildrive_delete_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.deleteSelectedEntries(selected)
      }
    });
  }

  private async deleteSelectedEntries(selected: TaildriveEntry[]): Promise<void> {
    for (let index: number = 0; index < selected.length; index++) {
      if (!await this.ensureProtectedMutationAccess(selected[index].path)) {
        return;
      }
    }
    this.busy = true;
    this.status = 'deleting';
    this.clearRetry();
    try {
      let lockPolicySaved: boolean = true;
      for (let index: number = 0; index < selected.length; index++) {
        const result: TaildriveMutationResult = await this.gateway.mutate({
          operation: 'delete',
          path: selected[index].path
        });
        if (result.state !== 'completed') {
          this.status = result.reason.length > 0 ? result.reason : 'delete_failed';
          return;
        }
        lockPolicySaved = await this.reconcileLockedFoldersAfterMutation({
          operation: 'delete', path: selected[index].path
        }) && lockPolicySaved;
      }
      this.showTransientStatus(lockPolicySaved ? 'delete_completed' : 'security_settings_save_failed');
      this.exitSelectionMode();
      await this.refresh();
    } catch (_error) {
      this.status = 'delete_failed';
    } finally {
      this.busy = false;
    }
  }

  private async submitEditor(): Promise<void> {
    const name: string = this.editorName.trim();
    if (!this.validName(name)) {
      this.status = 'invalid_name';
      return;
    }
    const protectedPath: string = this.editorOperation === 'mkdir' ? this.path : this.editorPath;
    if (!await this.ensureProtectedMutationAccess(protectedPath)) {
      return;
    }
    const targetPath: string = this.editorOperation === 'mkdir' ?
      this.joinPath(this.path, name) : this.joinPath(this.parentPath(this.editorPath), name);
    const request: TaildriveMutationRequest = this.editorOperation === 'mkdir' ?
      { operation: 'mkdir', path: targetPath } :
      { operation: 'rename', path: this.editorPath, newPath: targetPath };
    this.editorVisible = false;
    await this.executeMutation(request,
      this.editorOperation === 'mkdir' ? 'creating_folder' : 'renaming', 'mutation_completed');
  }

  private async executeMutation(request: TaildriveMutationRequest, workingStatus: string,
    completedStatus: string): Promise<void> {
    if (!await this.ensureMutationRequestAccess(request)) {
      return;
    }
    this.busy = true;
    this.status = workingStatus;
    this.clearRetry();
    try {
      const result: TaildriveMutationResult = await this.gateway.mutate(request);
      if (result.state === 'completed') {
        const lockPolicySaved: boolean = await this.reconcileLockedFoldersAfterMutation(request);
        this.showTransientStatus(lockPolicySaved ? completedStatus : 'security_settings_save_failed');
        this.retryMutation = undefined;
        await this.refresh();
      } else if ((result.reason === 'already_exists' || result.reason === 'file_exists') &&
        request.newPath !== undefined && request.overwrite !== true) {
        this.status = result.reason;
        this.promptMutationOverwrite(request, workingStatus, completedStatus);
      } else {
        this.status = result.reason.length > 0 ? result.reason : 'mutation_failed';
        this.retryMutation = request;
        this.retryMutationWorkingStatus = workingStatus;
        this.retryMutationCompletedStatus = completedStatus;
        this.setRetry('mutation');
      }
    } catch (_error) {
      this.status = request.operation === 'delete' ? 'delete_failed' : 'mutation_failed';
      this.retryMutation = request;
      this.retryMutationWorkingStatus = workingStatus;
      this.retryMutationCompletedStatus = completedStatus;
      this.setRetry('mutation');
    } finally {
      this.busy = false;
    }
  }

  private promptMutationOverwrite(request: TaildriveMutationRequest, workingStatus: string,
    completedStatus: string): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.taildrive_overwrite_title'),
      message: request.newPath === undefined ? '' : this.pathName(request.newPath),
      autoCancel: false,
      primaryButton: { value: $r('app.string.cancel_action'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.taildrive_replace_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.executeMutation({
          operation: request.operation,
          path: request.path,
          newPath: request.newPath,
          overwrite: true
        }, workingStatus, completedStatus)
      }
    });
  }

  private async showDetails(entry: TaildriveEntry): Promise<void> {
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    this.detailEntry = entry;
    this.detailsVisible = true;
    this.detailsLoading = true;
    this.detailsReason = '';
    try {
      const result: TaildriveStatResult = await this.gateway.stat(entry.path);
      if (result.state === 'ready') {
        this.detailEntry = result.entry;
      } else {
        this.detailsReason = result.reason;
      }
    } catch (_error) {
      this.detailsReason = 'backend_unavailable';
    } finally {
      this.detailsLoading = false;
    }
  }

  private async openMovePicker(entry: TaildriveEntry): Promise<void> {
    if (!this.connected || this.busy || !this.canModifyCurrentPath()) {
      return;
    }
    if (!await this.ensureProtectedMutationAccess(entry.path)) {
      return;
    }
    this.movingEntry = entry;
    this.moveRoot = this.shareRoot(entry.path);
    this.movePath = this.moveRoot;
    this.moveVisible = true;
    await this.loadMoveDirectory();
  }

  private async loadMoveDirectory(): Promise<void> {
    this.moveLoading = true;
    try {
      if (!await this.ensureFolderAccess(this.movePath)) {
        this.moveEntries = [];
        return;
      }
      const result: TaildriveListResult = await this.gateway.list(this.movePath);
      this.moveEntries = result.state === 'ready' ? result.entries : [];
      if (result.state !== 'ready') {
        this.status = result.reason;
      }
    } catch (_error) {
      this.moveEntries = [];
      this.status = 'backend_unavailable';
    } finally {
      this.moveLoading = false;
    }
  }

  private moveGoUp(): void {
    if (this.movePath === this.moveRoot || this.moveLoading) {
      return;
    }
    const parent: string = this.parentPath(this.movePath);
    this.movePath = parent.length < this.moveRoot.length ? this.moveRoot : parent;
    this.loadMoveDirectory();
  }

  private openMoveDirectory(entry: TaildriveEntry): void {
    if (entry.kind !== 'directory' || !this.validMoveDestination(entry.path)) {
      return;
    }
    this.movePath = entry.path;
    this.loadMoveDirectory();
  }

  private validMoveDestination(path: string): boolean {
    if (this.movingEntry === undefined) {
      return false;
    }
    return path !== this.movingEntry.path && !path.startsWith(`${this.movingEntry.path}/`);
  }

  private moveDestinationEntries(): TaildriveEntry[] {
    return this.moveEntries.filter((entry: TaildriveEntry) =>
      entry.kind === 'directory' && this.validMoveDestination(entry.path));
  }

  private async confirmMove(): Promise<void> {
    if (this.movingEntry === undefined) {
      return;
    }
    if (this.parentPath(this.movingEntry.path) === this.movePath) {
      this.status = 'same_location';
      this.moveVisible = false;
      return;
    }
    if (!await this.ensureProtectedMutationAccess(this.movingEntry.path) ||
      !await this.ensureFolderAccess(this.movePath)) {
      return;
    }
    const request: TaildriveMutationRequest = {
      operation: 'move',
      path: this.movingEntry.path,
      newPath: this.joinPath(this.movePath, this.movingEntry.name)
    };
    this.moveVisible = false;
    await this.executeMutation(request, 'moving', 'move_completed');
  }

  private async retryLastOperation(): Promise<void> {
    if (this.busy || !this.connected) {
      return;
    }
    if (this.retryKind === 'refresh') {
      await this.refresh();
    } else if (this.retryKind === 'target') {
      await this.openTargetMachine(this.targetRequestId);
    } else if (this.retryKind === 'upload') {
      await this.executeUpload(false);
    } else if (this.retryKind === 'download' && this.retryDownloadEntry !== undefined) {
      await this.download(this.retryDownloadEntry);
    } else if (this.retryKind === 'preview' && this.retryPreviewEntry !== undefined) {
      await this.downloadForPreview(this.retryPreviewEntry);
    } else if (this.retryKind === 'mutation' && this.retryMutation !== undefined) {
      const request: TaildriveMutationRequest = this.retryMutation;
      await this.executeMutation(request, this.retryMutationWorkingStatus, this.retryMutationCompletedStatus);
    }
  }

  private setRetry(kind: string): void {
    this.retryKind = kind;
    this.retryAvailable = true;
  }

  private clearRetry(): void {
    this.retryKind = '';
    this.retryAvailable = false;
    this.retryPreviewEntry = undefined;
  }

  private startTransferPolling(): void {
    this.stopTransferPolling();
    this.lastNotifiedProgress = -1;
    this.transferTimer = setInterval(() => {
      if (this.transferPollInFlight) {
        return;
      }
      this.transferPollInFlight = true;
      this.gateway.transferSnapshot().then((snapshot: TaildriveTransferSnapshot) => {
        this.transfer = snapshot;
        const progress: number = snapshot.totalBytes > 0 ?
          Math.floor(snapshot.bytes * 100 / snapshot.totalBytes) : 0;
        if ((snapshot.state === 'queued' || snapshot.state === 'transferring') &&
          (this.lastNotifiedProgress < 0 || progress >= this.lastNotifiedProgress + 5)) {
          this.lastNotifiedProgress = progress;
          const notificationTransfer: TaildriveNotificationTransfer = {
            direction: snapshot.direction,
            fileName: snapshot.fileName,
            bytes: snapshot.bytes,
            totalBytes: snapshot.totalBytes
          };
          publishTaildriveProgress(this.context(), notificationTransfer);
        }
      }).catch(() => {}).finally(() => {
        this.transferPollInFlight = false;
      });
    }, 400);
  }

  private stopTransferPolling(): void {
    if (this.transferTimer >= 0) {
      clearInterval(this.transferTimer);
      this.transferTimer = -1;
    }
  }

  private cancelVisibleTransfer(): void {
    if (this.previewDownloading) {
      this.cancelPreviewDownload();
      return;
    }
    this.gateway.cancel().catch(() => {});
  }

  private refreshThumbnails(entries: TaildriveEntry[]): void {
    const next: TaildriveThumbnailModel[] = [];
    entries.forEach((entry: TaildriveEntry) => {
      if (entry.kind !== 'file') {
        return;
      }
      const cached: TaildriveCachedPreview | undefined =
        this.previewGateway.cachedPreview(this.context(), entry);
      if (cached === undefined) {
        return;
      }
      if (cached.thumbnailPath.length > 0) {
        next.push({ remotePath: entry.path, uri: cached.thumbnailPath });
      } else {
        this.hydrateThumbnail(entry, cached.path);
      }
    });
    this.thumbnails = next;
  }

  private thumbnailUri(entry: TaildriveEntry): string {
    const thumbnail: TaildriveThumbnailModel | undefined = this.thumbnails.find(
      (candidate: TaildriveThumbnailModel) => candidate.remotePath === entry.path);
    if (thumbnail === undefined || thumbnail.uri.length === 0) {
      return '';
    }
    try {
      return fileIo.accessSync(thumbnail.uri) ? fileUri.getUriFromPath(thumbnail.uri) : '';
    } catch (_error) {
      return '';
    }
  }

  private setThumbnail(entry: TaildriveEntry, thumbnailPath: string): void {
    this.thumbnails = [
      ...this.thumbnails.filter((candidate: TaildriveThumbnailModel) =>
        candidate.remotePath !== entry.path),
      { remotePath: entry.path, uri: thumbnailPath }
    ];
  }

  private hydrateThumbnail(entry: TaildriveEntry, localPath: string): void {
    if (this.thumbnailWorkPaths.includes(entry.path)) {
      return;
    }
    this.thumbnailWorkPaths = [...this.thumbnailWorkPaths, entry.path];
    this.previewGateway.createThumbnail(this.context(), entry, localPath)
      .then((thumbnailPath: string) => {
        if (thumbnailPath.length > 0) {
          this.setThumbnail(entry, thumbnailPath);
        }
      })
      .catch(() => {
      })
      .finally(() => {
        this.thumbnailWorkPaths = this.thumbnailWorkPaths.filter((path: string) => path !== entry.path);
      });
  }

  private previewTypeText(entry: TaildriveEntry): string {
    const contentType: string = (entry.contentType ?? '').trim();
    if (contentType.length > 0) {
      return contentType;
    }
    const extension: string = this.fileExtension(entry.name);
    return extension.length > 0 ? extension.toUpperCase() : 'FILE';
  }

  private contentTypeForEntry(entry: TaildriveEntry): string {
    if ((entry.contentType ?? '').length > 0) {
      return entry.contentType as string;
    }
    const extension: string = this.fileExtension(entry.name);
    switch (extension) {
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      case 'bmp': return 'image/bmp';
      case 'heic': return 'image/heic';
      case 'heif': return 'image/heif';
      case 'mp4':
      case 'm4v': return 'video/mp4';
      case 'mkv': return 'video/x-matroska';
      case 'mov': return 'video/quicktime';
      case 'avi': return 'video/x-msvideo';
      case 'webm': return 'video/webm';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'json': return 'application/json';
      case 'zip': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }

  private displayEntries(): TaildriveEntry[] {
    const query: string = this.searchQuery.trim().toLowerCase();
    const filtered: TaildriveEntry[] = this.entries.filter((entry: TaildriveEntry) =>
      query.length === 0 || entry.name.toLowerCase().includes(query));
    return filtered.sort((left: TaildriveEntry, right: TaildriveEntry): number => {
      if (left.kind !== right.kind) {
        return left.kind === 'directory' ? -1 : 1;
      }
      let result: number = 0;
      if (this.sortMode === 'modified' && left.modifiedAtMs !== right.modifiedAtMs) {
        result = left.modifiedAtMs - right.modifiedAtMs;
      } else if (this.sortMode === 'size' && left.size !== right.size) {
        result = left.size - right.size;
      } else {
        result = left.name.toLowerCase().localeCompare(right.name.toLowerCase());
      }
      return this.sortDescending ? -result : result;
    });
  }

  private chooseSortMode(mode: string): void {
    if (this.sortDraftMode !== mode) {
      this.sortDraftMode = mode;
      this.sortDraftDescending = mode !== 'name';
    }
  }

  private chooseGroupMode(mode: string): void {
    this.groupDraftMode = mode;
  }

  private openSortPanel(): void {
    this.sortDraftMode = this.sortMode;
    this.sortDraftDescending = this.sortDescending;
    this.groupDraftMode = this.groupMode;
    this.sortSheetVisible = true;
    this.publishUiBackState();
  }

  private closeSortPanel(): void {
    this.sortSheetVisible = false;
    this.publishUiBackState();
  }

  private confirmSortPanel(): void {
    this.sortMode = this.sortDraftMode;
    this.sortDescending = this.sortDraftDescending;
    this.groupMode = this.groupDraftMode;
    this.rebuildListDataSource();
    this.closeSortPanel();
  }

  private cycleSortMode(): void {
    this.sortMode = this.sortMode === 'name' ? 'modified' : this.sortMode === 'modified' ? 'size' : 'name';
    this.sortDescending = this.sortMode !== 'name';
    this.rebuildListDataSource();
  }

  private sortModeText(): ResourceStr {
    if (this.sortMode === 'modified') return $r('app.string.taildrive_sort_modified');
    if (this.sortMode === 'size') return $r('app.string.taildrive_sort_size');
    return $r('app.string.taildrive_sort_name');
  }

  private groupedEntries(): TaildriveEntryGroup[] {
    const entries: TaildriveEntry[] = this.displayEntries();
    if (this.groupMode === 'none') {
      return [{ key: 'all', title: '', entries: entries }];
    }
    const keys: string[] = this.groupMode === 'type' ?
      ['folder', 'image', 'video', 'document', 'archive', 'other'] :
      ['today', 'yesterday', 'week', 'earlier', 'unknown'];
    const groups: TaildriveEntryGroup[] = [];
    keys.forEach((key: string) => {
      const grouped: TaildriveEntry[] = entries.filter((entry: TaildriveEntry) =>
        (this.groupMode === 'type' ? this.typeGroupKey(entry) : this.dateGroupKey(entry)) === key);
      if (grouped.length > 0) {
        groups.push({ key: key, title: this.groupTitle(key), entries: grouped });
      }
    });
    return groups;
  }

  private listItems(): TaildriveListItemModel[] {
    const items: TaildriveListItemModel[] = [];
    this.groupedEntries().forEach((group: TaildriveEntryGroup) => {
      if (group.key !== 'all') {
        items.push({
          key: `header-${group.key}`,
          header: true,
          title: group.title,
          entry: TaildriveBrowser.emptyEntry()
        });
      }
      group.entries.forEach((entry: TaildriveEntry) => items.push({
        key: entry.path,
        header: false,
        title: '',
        entry: entry
      }));
    });
    return items;
  }

  private flattenedGroupedEntries(): TaildriveEntry[] {
    const entries: TaildriveEntry[] = [];
    this.groupedEntries().forEach((group: TaildriveEntryGroup) => {
      group.entries.forEach((entry: TaildriveEntry) => entries.push(entry));
    });
    return entries;
  }

  private rebuildListDataSource(): void {
    this.listDataSource.replaceAll(this.listItems());
  }

  private groupTitle(key: string): ResourceStr {
    switch (key) {
      case 'folder': return $r('app.string.taildrive_group_folders');
      case 'image': return $r('app.string.taildrive_group_images');
      case 'video': return $r('app.string.taildrive_group_videos');
      case 'document': return $r('app.string.taildrive_group_documents');
      case 'archive': return $r('app.string.taildrive_group_archives');
      case 'today': return $r('app.string.taildrive_group_today');
      case 'yesterday': return $r('app.string.taildrive_group_yesterday');
      case 'week': return $r('app.string.taildrive_group_this_week');
      case 'earlier': return $r('app.string.taildrive_group_earlier');
      case 'unknown': return $r('app.string.taildrive_group_unknown_date');
      default: return $r('app.string.taildrive_group_other');
    }
  }

  private typeGroupKey(entry: TaildriveEntry): string {
    if (entry.kind === 'directory') {
      return 'folder';
    }
    const extension: string = this.fileExtension(entry.name);
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'].includes(extension)) {
      return 'image';
    }
    if (['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', '3gp'].includes(extension)) {
      return 'video';
    }
    if (['txt', 'md', 'json', 'jsonl', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv'].includes(extension)) {
      return 'document';
    }
    if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'hap', 'hsp', 'har', 'app', 'apk'].includes(extension)) {
      return 'archive';
    }
    return 'other';
  }

  private dateGroupKey(entry: TaildriveEntry): string {
    if (entry.modifiedAtMs <= 0) {
      return 'unknown';
    }
    const now: Date = new Date();
    const startToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (entry.modifiedAtMs >= startToday) {
      return 'today';
    }
    if (entry.modifiedAtMs >= startToday - 24 * 60 * 60 * 1000) {
      return 'yesterday';
    }
    if (entry.modifiedAtMs >= startToday - 7 * 24 * 60 * 60 * 1000) {
      return 'week';
    }
    return 'earlier';
  }

  private toggleSelectionMode(): void {
    this.vibrateTouch();
    if (this.selectionMode) {
      this.exitSelectionMode();
      return;
    }
    this.selectionMode = true;
    this.selectedPaths = [];
    this.rebuildListDataSource();
    this.publishUiBackState();
  }

  private exitSelectionMode(): void {
    this.selectionMode = false;
    this.selectedPaths = [];
    this.rebuildListDataSource();
    this.publishUiBackState();
  }

  private toggleEntrySelection(entry: TaildriveEntry): void {
    this.vibrateTouch();
    if (this.selectedPaths.includes(entry.path)) {
      this.selectedPaths = this.selectedPaths.filter((path: string) => path !== entry.path);
    } else {
      this.selectedPaths = [...this.selectedPaths, entry.path];
    }
    this.rebuildListDataSource();
  }

  private selectedTotalBytes(): number {
    let total: number = 0;
    this.selectedEntries().forEach((entry: TaildriveEntry) => {
      total += Math.max(0, entry.size);
    });
    return total;
  }

  private allVisibleEntriesSelected(): boolean {
    const visible: TaildriveEntry[] = this.displayEntries();
    return visible.length > 0 && visible.every((entry: TaildriveEntry) => this.isSelected(entry));
  }

  private toggleSelectAll(): void {
    this.vibrateTouch();
    const visible: TaildriveEntry[] = this.displayEntries();
    if (visible.length === 0) {
      return;
    }
    if (this.allVisibleEntriesSelected()) {
      const visiblePaths: string[] = visible.map((entry: TaildriveEntry) => entry.path);
      this.selectedPaths = this.selectedPaths.filter((path: string) => !visiblePaths.includes(path));
    } else {
      const selected: string[] = [...this.selectedPaths];
      visible.forEach((entry: TaildriveEntry) => {
        if (!selected.includes(entry.path)) {
          selected.push(entry.path);
        }
      });
      this.selectedPaths = selected;
    }
    this.rebuildListDataSource();
  }

  private selectFromContextMenu(entry: TaildriveEntry): void {
    this.vibrateTouch();
    if (!this.selectionMode) {
      this.selectionMode = true;
      this.selectedPaths = [];
      this.publishUiBackState();
    }
    if (!this.selectedPaths.includes(entry.path)) {
      this.selectedPaths = [...this.selectedPaths, entry.path];
    }
    this.rebuildListDataSource();
  }

  private isSelected(entry: TaildriveEntry): boolean {
    return this.selectedPaths.includes(entry.path);
  }

  private selectedEntries(): TaildriveEntry[] {
    return this.entries.filter((entry: TaildriveEntry) => this.selectedPaths.includes(entry.path));
  }

  private selectedEntry(): TaildriveEntry | undefined {
    const selected: TaildriveEntry[] = this.selectedEntries();
    return selected.length === 1 ? selected[0] : undefined;
  }

  private showSelectedDetails(): void {
    const entry: TaildriveEntry | undefined = this.selectedEntry();
    if (entry !== undefined) {
      this.showDetails(entry);
    }
  }

  private groupModeText(): ResourceStr {
    if (this.groupMode === 'type') return $r('app.string.taildrive_group_by_type');
    if (this.groupMode === 'date') return $r('app.string.taildrive_group_by_date');
    return $r('app.string.taildrive_group_none');
  }

  private joinPath(parent: string, name: string): string {
    const encoded: string = encodeURIComponent(name);
    return parent === '/' ? `/${encoded}` : `${parent}/${encoded}`;
  }

  private parentPath(remotePath: string): string {
    const slash: number = remotePath.lastIndexOf('/');
    return slash <= 0 ? '/' : remotePath.substring(0, slash);
  }

  private pathName(remotePath: string): string {
    const slash: number = remotePath.lastIndexOf('/');
    const encoded: string = slash >= 0 ? remotePath.substring(slash + 1) : remotePath;
    try {
      return decodeURIComponent(encoded);
    } catch (_error) {
      return encoded;
    }
  }

  private shareRoot(remotePath: string): string {
    const segments: string[] = remotePath.split('/').filter((segment: string) => segment.length > 0);
    return segments.length >= 3 ? `/${segments[0]}/${segments[1]}/${segments[2]}` : this.parentPath(remotePath);
  }

  private canModifyCurrentPath(): boolean {
    return this.path.split('/').filter((segment: string) => segment.length > 0).length >= 3;
  }

  private validName(name: string): boolean {
    return name.length > 0 && name.length <= 255 && name !== '.' && name !== '..' &&
      !name.includes('/') && !name.includes('\\') && !name.includes('\u0000');
  }

  private safeRemoteName(name: string): string {
    const value: string = this.safeLocalName(name);
    return value.length > 0 ? value : `upload-${Date.now()}`;
  }

  private safeLocalName(name: string): string {
    let value: string = name;
    const slash: number = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
    if (slash >= 0) {
      value = value.substring(slash + 1);
    }
    value = value.replace(/[\\/:*?"<>|]/g, '_').trim();
    if (value === '.' || value === '..') {
      return 'download';
    }
    return value.length > 0 ? value : 'download';
  }

  private cleanupDirectory(directory: string): void {
    try {
      if (!fileIo.accessSync(directory)) {
        return;
      }
      fileIo.listFileSync(directory).forEach((name: string) => {
        try { fileIo.unlinkSync(`${directory}/${name}`); } catch (_error) {}
      });
      fileIo.rmdirSync(directory);
    } catch (_error) {
      // Cache recovery removes stale request directories on the next visit.
    }
  }

  private formatSize(size: number): string {
    if (size < 1024) return `${size} B`;
    if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
    if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  }

  private formatModified(modifiedAtMs: number): string {
    if (modifiedAtMs <= 0) {
      return '-';
    }
    try {
      return new Date(modifiedAtMs).toLocaleString();
    } catch (_error) {
      return '-';
    }
  }

  private formatListDate(modifiedAtMs: number): string {
    if (modifiedAtMs <= 0) {
      return '';
    }
    const date: Date = new Date(modifiedAtMs);
    const month: string = `${date.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}/${month}/${day}`;
  }

  private fileExtension(name: string): string {
    const index: number = name.lastIndexOf('.');
    return index >= 0 ? name.substring(index + 1).toLowerCase() : '';
  }

  private remotePathDepth(remotePath: string): number {
    return remotePath.split('/').filter((segment: string) => segment.length > 0).length;
  }

  private isWindowsDriveDirectory(entry: TaildriveEntry): boolean {
    const kind: string = entry.kind.trim().toLowerCase();
    const contentType: string = (entry.contentType ?? '').trim().toLowerCase();
    if (['drive', 'disk', 'volume', 'drive_root', 'disk_root', 'filesystem_root'].includes(kind) ||
      ['application/x-drive', 'application/x-disk', 'inode/drive', 'inode/volume',
        'inode/mount-point'].includes(contentType)) {
      return true;
    }
    return /^[A-Za-z]:[\\/]?$/.test(entry.name.trim());
  }

  private specialFolderKind(name: string): string {
    switch (name.trim().toLowerCase()) {
      case '桌面':
      case 'desktop': return 'desktop';
      case '下载':
      case 'download':
      case 'downloads': return 'download';
      case '文档':
      case '文稿':
      case 'document':
      case 'documents':
      case 'docs': return 'document';
      case '图片':
      case '照片':
      case 'picture':
      case 'pictures':
      case 'photo':
      case 'photos':
      case 'image':
      case 'images': return 'picture';
      case '音乐':
      case 'music':
      case 'audio': return 'music';
      case '视频':
      case '影片':
      case 'video':
      case 'videos':
      case 'movie':
      case 'movies': return 'video';
      default: return '';
    }
  }

  private directoryIcon(entry: TaildriveEntry): Resource {
    const depth: number = this.remotePathDepth(entry.path);
    if (depth === 1) {
      return $r('app.media.ic_user');
    }
    if (depth === 2) {
      return $r('app.media.ic_network');
    }
    if (depth >= 3) {
      if (this.isWindowsDriveDirectory(entry)) {
        return $r('app.media.ic_disk_filled');
      }
      switch (this.specialFolderKind(entry.name)) {
        case 'desktop': return $r('app.media.taildrive_folder_desktop');
        case 'download': return $r('app.media.taildrive_folder_download');
        case 'document': return $r('app.media.taildrive_folder_document');
        case 'picture': return $r('app.media.taildrive_folder_picture');
        case 'music': return $r('app.media.taildrive_folder_music');
        case 'video': return $r('app.media.taildrive_folder_video');
      }
    }
    return $r('app.media.taildrive_file_folder');
  }

  private fileIcon(entry: TaildriveEntry): Resource {
    if (entry.kind === 'directory') {
      return this.directoryIcon(entry);
    }
    const extension: string = this.fileExtension(entry.name);
    switch (extension) {
      case '7z': return $r('app.media.ic_light_7z');
      case 'amr': return $r('app.media.ic_light_amr');
      case 'ape': return $r('app.media.ic_light_ape');
      case 'app': return $r('app.media.ic_light_app');
      case 'caj': return $r('app.media.ic_light_caj');
      case 'ics':
      case 'ical':
      case 'calendar': return $r('app.media.ic_light_calendar');
      case 'chm': return $r('app.media.ic_light_chm');
      case 'connect':
      case 'connection': return $r('app.media.ic_light_connect');
      case 'crdownload':
      case 'download':
      case 'part':
      case 'partial': return $r('app.media.ic_light_download');
      case 'dwg': return $r('app.media.ic_light_dwg');
      case 'dxf': return $r('app.media.ic_light_dxf');
      case 'eddx': return $r('app.media.ic_light_eddx');
      case 'eml':
      case 'emlx':
      case 'msg': return $r('app.media.ic_light_eml');
      case 'emmx': return $r('app.media.ic_light_emmx');
      case 'xls':
      case 'xlsx':
      case 'xlsm':
      case 'xlsb':
      case 'csv':
      case 'et':
      case 'ett':
      case 'ods': return $r('app.media.ic_light_excel');
      case 'exe':
      case 'msi':
      case 'com': return $r('app.media.ic_light_exe');
      case 'flac': return $r('app.media.ic_light_flac');
      case 'gz':
      case 'gzip': return $r('app.media.ic_light_gz');
      case 'hdoc': return $r('app.media.ic_light_hdoc');
      case 'hinote': return $r('app.media.ic_light_hinote');
      case 'htm': return $r('app.media.ic_light_htm');
      case 'html':
      case 'xhtml':
      case 'mht':
      case 'mhtml': return $r('app.media.ic_light_html');
      case 'kdh': return $r('app.media.ic_light_kdh');
      case 'log': return $r('app.media.ic_light_log');
      case 'm4a': return $r('app.media.ic_light_m4a');
      case 'mp3': return $r('app.media.ic_light_mp3');
      case 'aac':
      case 'midi':
      case 'mid':
      case 'ogg':
      case 'opus': return $r('app.media.ic_light_music');
      case 'nh': return $r('app.media.ic_light_nh');
      case 'pdf': return $r('app.media.ic_light_pdf');
      case 'ppt':
      case 'pptx':
      case 'pptm':
      case 'pps':
      case 'ppsx':
      case 'dps':
      case 'dpt':
      case 'odp': return $r('app.media.ic_light_ppt');
      case 'rar': return $r('app.media.ic_light_rar');
      case 'tar': return $r('app.media.ic_light_tar');
      case 'teb': return $r('app.media.ic_light_teb');
      case 'txt': return $r('app.media.ic_light_txt');
      case 'wav': return $r('app.media.ic_light_wav');
      case 'wma': return $r('app.media.ic_light_wma');
      case 'doc':
      case 'docx':
      case 'docm':
      case 'dot':
      case 'dotx':
      case 'wps':
      case 'wpt':
      case 'odt':
      case 'rtf': return $r('app.media.ic_light_word');
      case 'xml':
      case 'xsl':
      case 'xslt': return $r('app.media.ic_light_xml');
      case 'zip': return $r('app.media.ic_light_zip');
      case 'bz2':
      case 'xz':
      case 'zst':
      case 'lz':
      case 'lz4':
      case 'cab':
      case 'iso':
      case 'dmg': return $r('app.media.ic_light_zip_1');
      case 'hap':
      case 'hsp':
      case 'har':
      case 'apk':
      case 'aab':
      case 'ipa': return $r('app.media.ic_light_other_app');
    }
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'].includes(extension)) {
      return $r('app.media.ic_light_picture');
    }
    if (['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', '3gp'].includes(extension)) {
      return $r('app.media.ic_light_video');
    }
    if (['md', 'markdown', 'json', 'jsonl', 'yaml', 'yml', 'ini', 'conf', 'cfg', 'properties', 'sql',
      'ets', 'ts', 'tsx', 'js', 'jsx', 'java', 'kt', 'c', 'cc', 'cpp', 'h', 'hpp', 'go', 'rs', 'py',
      'sh', 'bat', 'cmd', 'ps1'].includes(extension)) {
      return $r('app.media.ic_light_text');
    }
    return extension.length === 0 ? $r('app.media.ic_light_unknow') : $r('app.media.ic_light_other');
  }

  private directoryKindText(entry: TaildriveEntry): ResourceStr {
    const depth: number = entry.path.split('/').filter((segment: string) => segment.length > 0).length;
    if (depth === 1) return $r('app.string.taildrive_type_tailnet');
    if (depth === 2) return $r('app.string.taildrive_type_device');
    if (depth === 3) return $r('app.string.taildrive_type_share');
    return $r('app.string.taildrive_type_folder');
  }

  private breadcrumbText(): string {
    const segments: string[] = this.displayPath().split('/').filter((segment: string) => segment.length > 0);
    if (segments.length === 0) {
      return 'Taildrive';
    }
    const visible: string[] = segments.length > 3 ? segments.slice(segments.length - 3) : segments;
    return `Taildrive  ›  ${visible.join('  ›  ')}`;
  }

  private breadcrumbSegments(): string[] {
    return this.path.split('/').filter((segment: string) => segment.length > 0).map((segment: string) => {
      try {
        return decodeURIComponent(segment);
      } catch (_error) {
        return segment;
      }
    });
  }

  private breadcrumbPath(index: number): string {
    const rawSegments: string[] = this.path.split('/').filter((segment: string) => segment.length > 0);
    let result: string = '/';
    for (let cursor: number = 0; cursor <= index && cursor < rawSegments.length; cursor++) {
      result = result === '/' ? `/${rawSegments[cursor]}` : `${result}/${rawSegments[cursor]}`;
    }
    return result;
  }

  private navigateToBreadcrumb(index: number): void {
    if (this.busy) {
      return;
    }
    this.vibrateTouch();
    this.path = index < 0 ? '/' : this.breadcrumbPath(index);
    this.searchQuery = '';
    this.searchVisible = false;
    this.exitSelectionMode();
    this.updateBackState();
    this.refresh();
  }

  private displayPath(value: string = this.path): string {
    try {
      return decodeURIComponent(value);
    } catch (_error) {
      return value;
    }
  }

  private updateBackState(): void {
    AppStorage.setOrCreate('taildriveCurrentPath', this.path);
    this.publishUiBackState();
    setTimeout((): void => {
      this.breadcrumbScroller.scrollEdge(Edge.End);
    }, 40);
  }

  private publishUiBackState(): void {
    AppStorage.setOrCreate('taildriveUiBackActive',
      this.selectionMode || this.searchVisible || this.sortSheetVisible || this.folderDialogVisible ||
      this.previewDownloadVisible);
  }

  private refreshWithFeedback(): void {
    this.vibrateTouch();
    this.refresh(450);
  }

  private setSearchVisible(visible: boolean): void {
    this.getUIContext().animateTo({
      duration: MotionTokens.NORMAL, curve: MotionTokens.curve()
    }, (): void => {
      this.searchVisible = visible;
      if (!visible) {
        this.searchQuery = '';
        this.rebuildListDataSource();
      }
      this.publishUiBackState();
    });
  }

  private updateSearchQuery(value: string): void {
    this.searchQuery = value;
    this.rebuildListDataSource();
  }

  private commitSearch(): void {
    this.searchQuery = this.searchQuery.trim();
    this.rebuildListDataSource();
    this.contentScroller.scrollEdge(Edge.Top);
  }

  private toggleViewMode(): void {
    this.getUIContext().animateTo({
      duration: MotionTokens.NORMAL, curve: MotionTokens.curve()
    }, (): void => {
      this.viewMode = this.viewMode === 'list' ? 'grid' : 'list';
    });
  }

  private transferProgress(): string {
    if (this.transfer.totalBytes <= 0) {
      return '';
    }
    const percent: number = Math.min(100, Math.floor(this.transfer.bytes * 100 / this.transfer.totalBytes));
    return `${percent}%`;
  }

  private statusText(): ResourceStr {
    return this.statusCodeText(this.status);
  }

  private statusCodeText(status: string): ResourceStr {
    switch (status) {
      case 'file_selection_failed': return $r('app.string.taildrive_status_select_failed');
      case 'uploading': return $r('app.string.taildrive_status_uploading');
      case 'upload_completed': return $r('app.string.taildrive_status_upload_completed');
      case 'upload_failed': return $r('app.string.taildrive_status_upload_failed');
      case 'downloading': return $r('app.string.taildrive_status_downloading');
      case 'preview_downloading': return $r('app.string.taildrive_status_preview_downloading');
      case 'preview_download_completed': return $r('app.string.taildrive_status_preview_download_completed');
      case 'preview_download_failed': return $r('app.string.taildrive_status_preview_download_failed');
      case 'preview_failed': return $r('app.string.taildrive_status_preview_failed');
      case 'paths_copied': return $r('app.string.taildrive_status_paths_copied');
      case 'copy_failed': return $r('app.string.taildrive_status_copy_failed');
      case 'share_failed': return $r('app.string.taildrive_status_share_failed');
      case 'select_one_for_details': return $r('app.string.taildrive_status_select_one_for_details');
      case 'export_cancelled': return $r('app.string.taildrive_status_export_cancelled');
      case 'download_completed': return $r('app.string.taildrive_status_download_completed');
      case 'export_failed': return $r('app.string.taildrive_status_export_failed');
      case 'deleting': return $r('app.string.taildrive_status_deleting');
      case 'delete_completed': return $r('app.string.taildrive_status_delete_completed');
      case 'delete_failed': return $r('app.string.taildrive_status_delete_failed');
      case 'creating_folder': return $r('app.string.taildrive_status_creating_folder');
      case 'renaming': return $r('app.string.taildrive_status_renaming');
      case 'moving': return $r('app.string.taildrive_status_moving');
      case 'move_completed': return $r('app.string.taildrive_status_move_completed');
      case 'mutation_completed': return $r('app.string.taildrive_status_mutation_completed');
      case 'mutation_failed': return $r('app.string.taildrive_status_mutation_failed');
      case 'invalid_name': return $r('app.string.taildrive_status_invalid_name');
      case 'same_location': return $r('app.string.taildrive_status_same_location');
      case 'target_not_found': return $r('app.string.taildrive_status_target_not_found');
      case 'folder_authentication_failed': return $r('app.string.security_authentication_failed');
      case 'security_settings_save_failed': return $r('app.string.security_settings_save_failed');
      case 'permission_denied': return $r('app.string.taildrive_status_permission_denied');
      case 'not_found': return $r('app.string.taildrive_status_not_found');
      case 'already_exists':
      case 'file_exists': return $r('app.string.taildrive_status_already_exists');
      case 'backend_unavailable': return $r('app.string.taildrive_status_backend_unavailable');
      case 'busy': return $r('app.string.taildrive_status_busy');
      case 'cancelled': return $r('app.string.taildrive_status_cancelled');
      case 'timeout': return $r('app.string.taildrive_status_timeout');
      case 'no_space': return $r('app.string.taildrive_status_no_space');
      case 'remote_unavailable': return $r('app.string.taildrive_status_remote_unavailable');
      case 'network_interrupted': return $r('app.string.taildrive_status_network_interrupted');
      case 'file_unavailable': return $r('app.string.taildrive_status_file_unavailable');
      case 'download_failed':
      case 'transfer_failed': return $r('app.string.taildrive_status_transfer_failed');
      default: return status;
    }
  }

  @Builder
  private FolderDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 0 }) {
        Text($r('app.string.taildrive_new_folder_title'))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 18 })
        TextInput({ text: this.editorName, placeholder: $r('app.string.taildrive_name_placeholder') })
          .width('100%')
          .height(48)
          .fontSize(17)
          .selectAll(true)
          .defaultFocus(true)
          .enterKeyType(EnterKeyType.Done)
          .backgroundColor(Color.Transparent)
          .id('taildrive-folder-dialog-input')
          .onChange((value: string) => this.editorName = value)
          .onSubmit(() => this.submitFolderDialog())
        Divider()
          .color($r('sys.color.comp_divider'))
        Row() {
          Text($r('app.string.cancel_action'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.emphasize'))
            .layoutWeight(1)
            .height(58)
            .textAlign(TextAlign.Center)
            .onClick(() => this.closeFolderDialog())
          Divider()
            .vertical(true)
            .height(34)
            .color($r('sys.color.comp_divider'))
          Text($r('app.string.confirm_action'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.emphasize'))
            .layoutWeight(1)
            .height(58)
            .textAlign(TextAlign.Center)
            .id('taildrive-folder-dialog-confirm')
            .onClick(() => this.submitFolderDialog())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('90%')
      .padding({ left: 24, right: 24 })
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(28)
      .shadow({ radius: 28, color: '#26000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#4D000000')
    .id('taildrive-folder-dialog')
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionTokens.duration(180), curve: MotionTokens.curve()
    }))
  }

  @Builder
  private EditorSheet() {
    Column({ space: 12 }) {
      Text(this.editorOperation === 'mkdir' ? $r('app.string.taildrive_new_folder_title') :
        $r('app.string.taildrive_rename_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      TextInput({ text: this.editorName, placeholder: $r('app.string.taildrive_name_placeholder') })
        .width('100%')
        .height(44)
        .enterKeyType(EnterKeyType.Done)
        .id('taildrive-editor-input')
        .onChange((value: string) => this.editorName = value)
        .onSubmit(() => this.submitEditor())
      Row({ space: 10 }) {
        Text($r('app.string.cancel_action'))
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding(12)
          .onClick(() => this.editorVisible = false)
        Text($r('app.string.confirm_action'))
          .fontColor($r('app.color.emphasize'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding(12)
          .id('taildrive-editor-confirm')
          .onClick(() => this.submitEditor())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 24 })
  }

  @Builder
  private DetailsSheet() {
    Column({ space: 12 }) {
      Text($r('app.string.taildrive_details_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (this.detailsLoading) {
        LoadingProgress().width(28).height(28)
      } else {
        Text(this.detailEntry.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        this.DetailRow($r('app.string.taildrive_details_type'),
          this.detailEntry.kind === 'directory' ? $r('app.string.taildrive_type_folder') :
            $r('app.string.taildrive_type_file'))
        this.DetailRow($r('app.string.taildrive_details_path'), this.displayPath(this.detailEntry.path))
        if (this.detailEntry.kind === 'file') {
          this.DetailRow($r('app.string.taildrive_details_size'), this.formatSize(this.detailEntry.size))
        }
        this.DetailRow($r('app.string.taildrive_details_modified'),
          this.formatModified(this.detailEntry.modifiedAtMs))
        if (this.detailEntry.contentType !== undefined && this.detailEntry.contentType.length > 0) {
          this.DetailRow($r('app.string.taildrive_details_content_type'), this.detailEntry.contentType)
        }
        if (this.detailsReason.length > 0) {
          Text(this.statusCodeText(this.detailsReason))
            .fontSize(12)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
        Row({ space: 8 }) {
          if (this.detailEntry.kind === 'file') {
            Text($r('app.string.taildrive_download_action'))
              .fontSize(13)
              .fontColor($r('app.color.emphasize'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 11, bottom: 11 })
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(12)
              .onClick(() => {
                const entry: TaildriveEntry = this.detailEntry;
                this.detailsVisible = false;
                this.download(entry);
              })
          }
          if (this.canModifyCurrentPath()) {
            Text($r('app.string.taildrive_rename_action'))
              .fontSize(13)
              .fontColor($r('app.color.emphasize'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 11, bottom: 11 })
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(12)
              .onClick(() => {
                const entry: TaildriveEntry = this.detailEntry;
                this.detailsVisible = false;
                this.renameEntry(entry);
              })
            Text($r('app.string.taildrive_move_action'))
              .fontSize(13)
              .fontColor($r('app.color.emphasize'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 11, bottom: 11 })
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(12)
              .onClick(() => {
                const entry: TaildriveEntry = this.detailEntry;
                this.detailsVisible = false;
                this.openMovePicker(entry);
              })
          }
        }
        .width('100%')
        if (this.canModifyCurrentPath()) {
          Text($r('app.string.taildrive_delete_action'))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 11, bottom: 11 })
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(12)
            .onClick(() => {
              const entry: TaildriveEntry = this.detailEntry;
              this.detailsVisible = false;
              this.confirmDelete(entry);
            })
        }
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 24 })
    .id('taildrive-details-sheet')
  }

  @Builder
  private PreviewDownloadSheet() {
    Column({ space: 16 }) {
      Text($r('app.string.taildrive_preview_download_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Column({ space: 8 }) {
        Text(this.previewDownloadEntry.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          Text(this.previewTypeText(this.previewDownloadEntry))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.formatSize(this.previewDownloadEntry.size))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.surface_subtle'))
      .borderRadius(14)
      Text($r('app.string.taildrive_preview_download_hint'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(20)
        .width('100%')
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text($r('app.string.cancel_action'))
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
        }
        .layoutWeight(1)
        .height(46)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius(14)
        .onClick(() => this.previewDownloadVisible = false)
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Text($r('app.string.taildrive_preview_download_action'))
            .fontSize(15)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .layoutWeight(1)
        .height(46)
        .backgroundColor($r('app.color.emphasize'))
        .borderRadius(14)
        .id('taildrive-preview-download-confirm')
        .onClick(() => this.confirmPreviewDownload())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 24 })
    .id('taildrive-preview-download-sheet')
  }

  @Builder
  private DetailRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width(92)
      Text(value)
        .fontSize(12)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  @Builder
  private MoveSheet() {
    Column({ space: 10 }) {
      Text($r('app.string.taildrive_move_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Row({ space: 8 }) {
        Text($r('app.string.taildrive_up_action'))
          .fontSize(12)
          .fontColor(this.movePath === this.moveRoot ? $r('sys.color.font_secondary') :
            $r('app.color.emphasize'))
          .onClick(() => this.moveGoUp())
        Text(this.displayPath(this.movePath))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      if (this.moveLoading) {
        LoadingProgress().width(24).height(24)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.moveDestinationEntries(), (entry: TaildriveEntry) => {
              Row({ space: 8 }) {
                this.EntryIcon(entry, 18)
                Text(entry.name)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.surface_subtle'))
              .borderRadius(10)
              .onClick(() => this.openMoveDirectory(entry))
            }, (entry: TaildriveEntry) => entry.path)
          }
          .width('100%')
        }
        .height(220)
        .nestedScroll({
          scrollForward: NestedScrollMode.PARENT_FIRST,
          scrollBackward: NestedScrollMode.SELF_FIRST
        })
      }
      Row({ space: 10 }) {
        Text($r('app.string.cancel_action'))
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding(12)
          .onClick(() => this.moveVisible = false)
        Text($r('app.string.taildrive_move_here_action'))
          .fontColor($r('app.color.emphasize'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding(12)
          .onClick(() => this.confirmMove())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 24 })
  }

  @Builder
  private LegacyBrowserContent() {
    Column({ space: 10 }) {
      if (!this.standalone) {
        Row() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(20)
            .fontColor([$r('app.color.emphasize')])
          Text($r('app.string.taildrive_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
          Blank()
          Text($r('app.string.taildrive_refresh_action'))
            .fontSize(12)
            .fontColor($r('app.color.emphasize'))
            .opacity(this.loading || !this.connected ? 0.45 : 1)
            .id('taildrive-inline-refresh')
            .onClick(() => this.refresh())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text($r('app.string.taildrive_subtitle'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      if (!this.connected) {
        Text($r('app.string.taildrive_connect_first'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.surface_subtle'))
          .borderRadius(12)
      } else {
        Row({ space: 8 }) {
          Text($r('app.string.taildrive_up_action'))
            .fontSize(12)
            .fontColor(this.path === '/' || this.busy ? $r('sys.color.font_secondary') :
              $r('app.color.emphasize'))
            .onClick(() => this.goUp())
          Text(this.displayPath())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .id('taildrive-legacy-path')
          if (this.standalone) {
            Text($r('app.string.taildrive_refresh_action'))
              .fontSize(12)
              .fontColor($r('app.color.emphasize'))
              .opacity(this.loading || this.busy ? 0.45 : 1)
              .id('taildrive-legacy-refresh')
              .onClick(() => this.refresh())
          }
          if (this.canModifyCurrentPath()) {
            Text($r('app.string.taildrive_new_folder_action'))
              .fontSize(12)
              .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
              .onClick(() => this.createFolder())
            Text($r('app.string.taildrive_upload_action'))
              .fontSize(12)
              .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
              .onClick(() => this.selectUpload())
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        Row({ space: 8 }) {
          TextInput({ text: this.searchQuery, placeholder: $r('app.string.taildrive_search_placeholder') })
            .height(36)
            .layoutWeight(1)
            .fontSize(12)
            .id('taildrive-legacy-search')
            .onChange((value: string) => this.searchQuery = value)
          Text(this.sortModeText())
            .fontSize(11)
            .fontColor($r('app.color.emphasize'))
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .onClick(() => this.cycleSortMode())
        }
        .width('100%')
        if (this.loading) {
          LoadingProgress().width(24).height(24).margin({ top: 18, bottom: 18 })
        } else if (this.displayEntries().length === 0) {
          Text(this.reason.length > 0 ? this.statusCodeText(this.reason) : $r('app.string.taildrive_empty'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 24, bottom: 24 })
            .id('taildrive-legacy-list-state')
        } else {
          ForEach(this.displayEntries(), (entry: TaildriveEntry) => {
            Column({ space: 7 }) {
              Row({ space: 8 }) {
                this.EntryIcon(entry, 18)
                Column({ space: 2 }) {
                  Text(entry.name)
                    .fontSize(13)
                    .fontColor($r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.kind === 'file' ?
                    `${this.formatSize(entry.size)} · ${this.formatModified(entry.modifiedAtMs)}` :
                    this.formatModified(entry.modifiedAtMs))
                    .fontSize(10)
                    .fontColor($r('sys.color.font_secondary'))
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .onClick(() => this.openEntry(entry))
              Row({ space: 14 }) {
                Text($r('app.string.taildrive_details_action'))
                  .fontSize(11)
                  .fontColor($r('app.color.emphasize'))
                  .onClick(() => this.showDetails(entry))
                if (entry.kind === 'file') {
                  Text($r('app.string.taildrive_download_action'))
                    .fontSize(11)
                    .fontColor($r('app.color.emphasize'))
                    .onClick(() => this.download(entry))
                }
                if (this.canModifyCurrentPath()) {
                  Text($r('app.string.taildrive_rename_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
                    .onClick(() => this.renameEntry(entry))
                  Text($r('app.string.taildrive_move_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.emphasize'))
                    .onClick(() => this.openMovePicker(entry))
                  Text($r('app.string.taildrive_delete_action'))
                    .fontSize(11)
                    .fontColor(this.busy ? $r('sys.color.font_secondary') : $r('app.color.status_error'))
                    .onClick(() => this.confirmDelete(entry))
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 10, bottom: 9 })
            .backgroundColor($r('app.color.surface_subtle'))
            .borderRadius(10)
            .id(`taildrive-legacy-entry-${entry.name}`)
          }, (entry: TaildriveEntry) => entry.path)
        }
        if ((this.busy || this.previewDownloading) &&
          (this.transfer.state === 'queued' || this.transfer.state === 'transferring')) {
          Row({ space: 8 }) {
            LoadingProgress().width(16).height(16)
            Text(this.transfer.fileName.length > 0 ? this.transfer.fileName :
              $r('app.string.taildrive_transfer_in_progress'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Text(this.transferProgress())
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            Text($r('app.string.cancel_action'))
              .fontSize(12)
              .fontColor($r('app.color.status_error'))
              .onClick(() => this.cancelVisibleTransfer())
          }
          .width('100%')
        }
      }
      if (this.status.length > 0 || this.retryAvailable) {
        Row({ space: 10 }) {
          if (this.status.length > 0) {
            Text(this.statusText())
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }
          if (this.retryAvailable) {
            Text($r('app.string.taildrive_retry_action'))
              .fontSize(11)
              .fontColor($r('app.color.emphasize'))
              .onClick(() => this.retryLastOperation())
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(this.standalone ? 0 : 14)
    .backgroundColor(this.standalone ? Color.Transparent : $r('app.color.surface_subtle'))
    .borderRadius(this.standalone ? 0 : 16)
    .id('taildrive-legacy-browser')
  }

  private startRefreshPolling(): void {
    this.stopRefreshPolling();
    this.refreshTimer = setInterval(() => {
      if (!this.connected || this.loading || this.busy) {
        return;
      }
      this.refresh(0, true);
    }, TAILDRIVE_REFRESH_INTERVAL_MS);
  }

  private stopRefreshPolling(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  @Builder
  private EntryIcon(entry: TaildriveEntry, size: number) {
    Stack() {
      if (entry.kind !== 'directory' && this.thumbnailUri(entry).length > 0) {
        Image(this.thumbnailUri(entry))
          .width(size)
          .height(size)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .clip(true)
      } else {
        Image(this.fileIcon(entry))
          .width(size)
          .height(size)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(size)
    .height(size)
  }

  @Builder
  private EntryMetadata(entry: TaildriveEntry) {
    Row({ space: 0 }) {
      if (this.formatListDate(entry.modifiedAtMs).length > 0) {
        Text(this.formatListDate(entry.modifiedAtMs))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
        Text(' - ')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      if (entry.kind === 'directory') {
        Text(this.directoryKindText(entry))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      } else {
        Text(this.formatSize(entry.size))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
    }
    .width('100%')
  }

  @Builder
  private SelectionMark(entry: TaildriveEntry) {
    Row() {
      if (this.isSelected(entry)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_on_primary')])
      }
    }
    .width(24)
    .height(24)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.isSelected(entry) ? $r('app.color.emphasize') : Color.Transparent)
    .border({
      width: 1,
      color: this.isSelected(entry) ? $r('app.color.emphasize') : $r('sys.color.comp_divider')
    })
    .borderRadius(12)
    .id(`taildrive-selection-mark-${entry.name}`)
    .onClick(() => this.toggleEntrySelection(entry))
  }

  @Builder
  private EntryContextPreview(entry: TaildriveEntry) {
    Row({ space: 12 }) {
      this.EntryIcon(entry, 46)
      Column({ space: 3 }) {
        Text(entry.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.EntryMetadata(entry)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width(300)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(22)
  }

  @Builder
  private EntryContextMenu(entry: TaildriveEntry) {
    Menu() {
      if (entry.kind === 'file') {
        MenuItem({ content: $r('app.string.taildrive_download_action') })
          .onClick(() => this.download(entry))
      }
      MenuItem({ content: $r('app.string.taildrive_multi_select_action') })
        .onClick(() => this.selectFromContextMenu(entry))
      if (this.folderLockEnabled && this.canChangeFolderLock(entry)) {
        MenuItem({ content: this.isFolderDirectlyLocked(entry.path) ?
          $r('app.string.security_unlock_folder_action') : $r('app.string.security_lock_folder_action') })
          .onClick(() => this.toggleFolderLock(entry))
      }
      if (this.canModifyCurrentPath()) {
        MenuItem({ content: $r('app.string.taildrive_move_action') })
          .onClick(() => this.openMovePicker(entry))
        MenuItem({ content: $r('app.string.taildrive_rename_action') })
          .onClick(() => this.renameEntry(entry))
      }
      MenuItem({ content: $r('app.string.taildrive_details_action') })
        .onClick(() => this.showDetails(entry))
      if (this.canModifyCurrentPath()) {
        MenuItem({ content: $r('app.string.taildrive_delete_action') })
          .onClick(() => this.confirmDelete(entry))
      }
    }
    .width(280)
  }

  @Builder
  private FileListRow(entry: TaildriveEntry) {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        Row({ space: 10 }) {
          this.EntryIcon(entry, 36)
          Column({ space: 2 }) {
            Text(entry.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            this.EntryMetadata(entry)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
        .id(`taildrive-entry-${entry.name}`)
        .onClick(() => this.openEntry(entry))
        if (this.selectionMode) {
          this.SelectionMark(entry)
        } else if (entry.kind === 'directory') {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('sys.color.icon_secondary')])
            .onClick(() => this.openEntry(entry))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 2, right: 10, top: 3, bottom: 3 })
      Divider()
        .color($r('app.color.divider_subtle'))
        .margin({ left: 46 })
    }
    .width('100%')
    .bindContextMenu(this.EntryContextMenu(entry), ResponseType.LongPress, {
      preview: this.EntryContextPreview(entry),
      previewBorderRadius: 22,
      borderRadius: 22,
      onAppear: (): void => this.vibrateTouch(true)
    })
  }

  @Builder
  private FileGridCell(entry: TaildriveEntry) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 2 }) {
        this.EntryIcon(entry, 42)
        Text(entry.name)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text(entry.kind === 'file' ? this.formatSize(entry.size) : this.formatListDate(entry.modifiedAtMs))
          .fontSize(9)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .width('100%')
      .padding({ left: 3, right: 3, top: 5, bottom: 4 })
      .alignItems(HorizontalAlign.Center)
      if (this.selectionMode) {
        this.SelectionMark(entry)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 82 })
    .backgroundColor(Color.Transparent)
    .border({
      width: this.isSelected(entry) ? 2 : 1,
      color: this.isSelected(entry) ? $r('app.color.emphasize') : $r('sys.color.comp_divider')
    })
    .borderRadius(10)
    .onClick(() => this.openEntry(entry))
    .bindContextMenu(this.EntryContextMenu(entry), ResponseType.LongPress, {
      preview: this.EntryContextPreview(entry),
      previewBorderRadius: 22,
      borderRadius: 22,
      onAppear: (): void => this.vibrateTouch(true)
    })
    .id(`taildrive-entry-${entry.name}`)
  }

  @Builder
  private EntryGroups() {
    Column({ space: 4 }) {
      ForEach(this.groupedEntries(), (group: TaildriveEntryGroup) => {
        if (group.key !== 'all') {
          Text(group.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 4, top: 12, bottom: 4 })
        }
        if (this.viewMode === 'list') {
          Column({ space: 0 }) {
            ForEach(group.entries, (entry: TaildriveEntry) => {
              this.FileListRow(entry)
            }, (entry: TaildriveEntry) => entry.path)
          }
          .width('100%')
        } else {
          GridRow({
            columns: { xs: 2, sm: 3, md: 4, lg: 5 },
            gutter: { x: 12, y: 12 }
          }) {
            ForEach(group.entries, (entry: TaildriveEntry) => {
              GridCol({ span: 1 }) {
                this.FileGridCell(entry)
              }
            }, (entry: TaildriveEntry) => entry.path)
          }
          .width('100%')
        }
      }, (group: TaildriveEntryGroup) => group.key)
    }
    .width('100%')
  }

  @Builder
  private StandaloneEntryViewport() {
    if (this.loading && this.entries.length === 0) {
      Column({ space: 10 }) {
        LoadingProgress().width(28).height(28)
        Text($r('app.string.taildrive_loading'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.displayEntries().length === 0) {
      Column({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(42)
          .fontColor([$r('sys.color.icon_secondary')])
        Text(this.reason.length > 0 ? this.statusCodeText(this.reason) : $r('app.string.taildrive_empty'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
          .lineHeight(20)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .id('taildrive-list-state')
    } else if (this.viewMode === 'list') {
      List({ scroller: this.contentScroller, space: 0 }) {
        LazyForEach(this.listDataSource, (item: TaildriveListItemModel) => {
          ListItem() {
            if (item.header) {
              Text(item.title)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 4, top: 8, bottom: 4 })
            } else {
              this.FileListRow(item.entry)
            }
          }
        }, (item: TaildriveListItemModel) => item.key)
      }
      .width('100%')
      .layoutWeight(1)
      .cachedCount(12)
      .contentEndOffset(this.bottomInset + 86)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .scrollBarWidth(3)
      .id('taildrive-list-view')
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionTokens.duration(180), curve: MotionTokens.curve()
      }))
    } else {
      Grid(this.contentScroller) {
        LazyForEach(this.listDataSource, (item: TaildriveListItemModel) => {
          if (item.header) {
            GridItem() {
              Text(item.title)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 2, top: 6, bottom: 2 })
            }
            .columnStart(0)
            .columnEnd(3)
          } else {
            GridItem() {
              this.FileGridCell(item.entry)
            }
          }
        }, (item: TaildriveListItemModel) => item.key)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(4)
      .rowsGap(4)
      .width('100%')
      .layoutWeight(1)
      .cachedCount(16)
      .contentEndOffset(this.bottomInset + 86)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Auto)
      .scrollBarWidth(3)
      .id('taildrive-grid-view')
      .transition(TransitionEffect.OPACITY.animation({
        duration: MotionTokens.duration(180), curve: MotionTokens.curve()
      }))
    }
  }

  @Builder
  private SearchField() {
    Row({ space: 8 }) {
      Image($r('app.media.taildrive_search'))
        .width(20)
        .height(20)
        .fillColor($r('sys.color.icon_secondary'))
      TextInput({ text: this.searchQuery, placeholder: $r('app.string.taildrive_search_placeholder') })
        .height(44)
        .layoutWeight(1)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .enterKeyType(EnterKeyType.Search)
        .id('taildrive-search')
        .onChange((value: string) => this.updateSearchQuery(value))
        .onSubmit(() => this.commitSearch())
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(16)
        .fontColor([$r('sys.color.icon_secondary')])
        .onClick(() => {
          this.searchQuery = '';
          this.rebuildListDataSource();
        })
    }
    .layoutWeight(1)
    .height(46)
    .padding({ left: 14, right: 14 })
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .border({ width: 1, color: $r('sys.color.comp_divider') })
    .borderRadius(23)
    .transition(TransitionEffect.OPACITY.animation({
      duration: MotionTokens.duration(180), curve: MotionTokens.curve()
    }))
  }

  @Builder
  private SortModeChoice(label: ResourceStr, mode: string, controlId: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.sortDraftMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.sortDraftMode === mode ? $r('app.color.emphasize') :
          $r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.sortDraftMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([$r('app.color.emphasize')])
          .id(`${controlId}-selected`)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.sortDraftMode === mode ? $r('sys.color.comp_background_tertiary') : Color.Transparent)
    .borderRadius(12)
    .id(controlId)
    .onClick(() => this.chooseSortMode(mode))
  }

  @Builder
  private GroupModeChoice(label: ResourceStr, mode: string, controlId: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.groupDraftMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.groupDraftMode === mode ? $r('app.color.emphasize') :
          $r('sys.color.font_primary'))
        .layoutWeight(1)
      if (this.groupDraftMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([$r('app.color.emphasize')])
          .id(`${controlId}-selected`)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.groupDraftMode === mode ? $r('sys.color.comp_background_tertiary') : Color.Transparent)
    .borderRadius(12)
    .id(controlId)
    .onClick(() => this.chooseGroupMode(mode))
  }

  @Builder
  private SortSheet() {
    Scroll() {
      Column({ space: 0 }) {
        Text($r('app.string.taildrive_sort_section'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ top: 4, bottom: 6 })
        this.SortModeChoice($r('app.string.taildrive_sort_name'), 'name', 'taildrive-sort-name')
        Divider().color($r('sys.color.comp_divider'))
        this.SortModeChoice($r('app.string.taildrive_sort_modified'), 'modified', 'taildrive-sort-modified')
        Divider().color($r('sys.color.comp_divider'))
        this.SortModeChoice($r('app.string.taildrive_sort_size'), 'size', 'taildrive-sort-size')
        Text($r('app.string.taildrive_sort_direction_section'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ top: 18, bottom: 6 })
        Row() {
          Text($r('app.string.taildrive_sort_ascending'))
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          if (!this.sortDraftDescending) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(18)
              .fontColor([$r('app.color.emphasize')])
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })
        .onClick(() => this.sortDraftDescending = false)
        Divider().color($r('sys.color.comp_divider'))
        Row() {
          Text($r('app.string.taildrive_sort_descending'))
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          if (this.sortDraftDescending) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(18)
              .fontColor([$r('app.color.emphasize')])
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })
        .onClick(() => this.sortDraftDescending = true)
        Text($r('app.string.taildrive_group_section'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ top: 18, bottom: 6 })
        this.GroupModeChoice($r('app.string.taildrive_group_none'), 'none', 'taildrive-group-none')
        Divider().color($r('sys.color.comp_divider'))
        this.GroupModeChoice($r('app.string.taildrive_group_by_type'), 'type', 'taildrive-group-type')
        Divider().color($r('sys.color.comp_divider'))
        this.GroupModeChoice($r('app.string.taildrive_group_by_date'), 'date', 'taildrive-group-date')
        Text($r('app.string.confirm_action'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_on_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor($r('app.color.emphasize'))
          .borderRadius(14)
          .margin({ top: 20, bottom: 12 })
          .id('taildrive-sort-confirm')
          .onClick(() => this.confirmSortPanel())
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    .id('taildrive-sort-panel')
  }

  @Builder
  private SheetHosts() {
    Stack() {
      Row()
        .width(0)
        .height(0)
        .id('taildrive-editor-sheet-host')
        .bindSheet($$this.editorVisible, this.EditorSheet(), {
          height: '31%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          onDisappear: () => {
            this.editorVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-details-sheet-host')
        .bindSheet($$this.detailsVisible, this.DetailsSheet(), {
          height: '60%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          onDisappear: () => {
            this.detailsVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-preview-download-sheet-host')
        .bindSheet($$this.previewDownloadVisible, this.PreviewDownloadSheet(), {
          height: '38%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          onDisappear: () => {
            this.previewDownloadVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-move-sheet-host')
        .bindSheet($$this.moveVisible, this.MoveSheet(), {
          height: '62%',
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          onDisappear: () => {
            this.moveVisible = false;
          }
        })
      Row()
        .width(0)
        .height(0)
        .id('taildrive-sort-sheet-host')
        .bindSheet($$this.sortSheetVisible, this.SortSheet(), {
          detents: ['58%', '72%'],
          preferType: SheetType.BOTTOM,
          mode: SheetMode.OVERLAY,
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          dragBar: true,
          showClose: true,
          enableOutsideInteractive: false,
          title: { title: $r('app.string.taildrive_sort_group_title') },
          onDisappear: () => {
            this.sortSheetVisible = false;
          }
        })
    }
    .width(0)
    .height(0)
    .id('taildrive-sheet-hosts')
  }

  @Builder
  private TopControls() {
    Row({ space: 6 }) {
      if (this.searchVisible) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(20)
            .fontColor([$r('sys.color.icon_primary')])
            .rotate({ angle: 180 })
        }
        .width(46)
        .height(46)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .border({ width: 1, color: $r('sys.color.comp_divider') })
        .borderRadius(23)
        .id('taildrive-search-back')
        .onClick(() => this.setSearchVisible(false))
        this.SearchField()
      } else if (this.selectionMode) {
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_primary')])
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .border({ width: 1, color: $r('sys.color.comp_divider') })
        .borderRadius(24)
        .id('taildrive-selection-close')
        .onClick(() => this.exitSelectionMode())
        Column({ space: 1 }) {
          Text(this.selectedPaths.length === 0 ? $r('app.string.taildrive_selection_empty') :
            $r('app.string.taildrive_selected_count', this.selectedPaths.length))
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.selectedPaths.length > 0) {
            Text($r('app.string.taildrive_selected_total', this.formatSize(this.selectedTotalBytes())))
              .fontSize(15)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.allVisibleEntriesSelected() ? $r('app.string.taildrive_deselect_all_action') :
          $r('app.string.taildrive_select_all_action'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .height(42)
          .padding({ left: 17, right: 17 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .border({ width: 1, color: $r('sys.color.comp_divider') })
          .borderRadius(21)
          .id('taildrive-select-all')
          .onClick(() => this.toggleSelectAll())
      }
    }
    .width('100%')
    .height(54)
    .animation({ duration: MotionTokens.NORMAL, curve: MotionTokens.curve() })
  }

  @Builder
  private BreadcrumbTrail() {
    Scroll(this.breadcrumbScroller) {
      Row({ space: 4 }) {
        Text('Taildrive')
          .fontSize(13)
          .fontColor(this.path === '/' ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          .maxLines(1)
          .id('taildrive-breadcrumb-root')
          .onClick(() => this.navigateToBreadcrumb(-1))
        ForEach(this.breadcrumbSegments(), (segment: string, index: number) => {
          Text('›')
            .fontSize(15)
            .fontColor($r('sys.color.icon_secondary'))
          Text(segment)
            .fontSize(13)
            .fontColor(index === this.breadcrumbSegments().length - 1 ?
              $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .maxLines(1)
            .id(`taildrive-breadcrumb-${index}`)
            .onClick(() => this.navigateToBreadcrumb(index))
        }, (segment: string, index: number) => `${index}-${segment}`)
      }
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .id('taildrive-path')
  }

  @Builder
  private PathBar() {
    Row({ space: 5 }) {
      if (this.path !== '/') {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(17)
            .fontColor([$r('sys.color.icon_primary')])
            .rotate({ angle: 180 })
            .id('taildrive-back-icon')
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
        .border({ width: 1, color: $r('sys.color.comp_divider') })
        .borderRadius(20)
        .id('taildrive-back')
        .onClick(() => this.goUp())
      }
      Row({ space: 2 }) {
        this.BreadcrumbTrail()
        Row() {
          if (this.loading) {
            LoadingProgress()
              .width(18)
              .height(18)
              .id('taildrive-refresh-loading')
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(17)
              .fontColor([$r('sys.color.icon_secondary')])
          }
        }
        .width(30)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .opacity(this.busy ? 0.45 : 1)
        .id('taildrive-refresh')
        .onClick(() => this.refreshWithFeedback())
      }
      .height(42)
      .layoutWeight(1)
      .padding({ left: 12, right: 4 })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .border({ width: 1, color: $r('sys.color.comp_divider') })
      .borderRadius(20)
    }
    .width('100%')
  }

  @Builder
  private TransferStatus() {
    Row({ space: 8 }) {
      LoadingProgress().width(18).height(18)
      Text(this.transfer.fileName.length > 0 ? this.transfer.fileName :
        $r('app.string.taildrive_transfer_in_progress'))
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.transferProgress())
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
      Text($r('app.string.cancel_action'))
        .fontSize(12)
        .fontColor($r('app.color.status_error'))
        .onClick(() => this.cancelVisibleTransfer())
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  @Builder
  private OperationStatus() {
    Row({ space: 10 }) {
      if (this.status.length > 0) {
        Text(this.statusText())
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
      } else {
        Blank().layoutWeight(1)
      }
      if (this.retryAvailable) {
        Text($r('app.string.taildrive_retry_action'))
          .fontSize(12)
          .fontColor($r('app.color.emphasize'))
          .onClick(() => this.retryLastOperation())
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(14)
  }

  private saveSelectedEntry(): void {
    const entry: TaildriveEntry | undefined = this.selectedEntry();
    if (entry === undefined || entry.kind !== 'file') {
      this.status = 'select_one_for_details';
      return;
    }
    this.download(entry);
  }

  private copySelectedPaths(): void {
    const selected: TaildriveEntry[] = this.selectedEntries();
    if (selected.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(
      pasteboard.MIMETYPE_TEXT_PLAIN, selected.map((entry: TaildriveEntry) => entry.path).join('\n'));
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => this.showTransientStatus('paths_copied'))
      .catch(() => this.status = 'copy_failed');
  }

  private async shareSelectedEntry(): Promise<void> {
    const entry: TaildriveEntry | undefined = this.selectedEntry();
    if (entry === undefined || entry.kind !== 'file') {
      this.status = 'select_one_for_details';
      return;
    }
    if (!await this.ensureFolderAccess(entry.path)) {
      return;
    }
    const cached: TaildriveCachedPreview | undefined =
      this.previewGateway.cachedPreview(this.context(), entry);
    if (cached === undefined) {
      this.promptPreviewDownload(entry);
      return;
    }
    try {
      const sharedData: systemShare.SharedData = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.FILE,
        uri: fileUri.getUriFromPath(cached.path),
        title: entry.name
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
      await controller.show(this.context(), {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (_error) {
      this.status = 'share_failed';
    }
  }

  private showMoreSelected(): void {
    if (this.selectedEntry() === undefined) {
      this.status = 'select_one_for_details';
      return;
    }
    this.showSelectedDetails();
  }

  @Builder
  private SelectionAction(icon: Resource, label: ResourceStr, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 3 }) {
        SymbolGlyph(icon)
          .fontSize(22)
          .fontColor([$r('sys.color.icon_primary')])
        Text(label)
          .fontSize(11)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(58)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.38)
    .onClick(action)
  }

  @Builder
  private SelectionMoreAction(enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Column({ space: 3 }) {
        Image($r('app.media.taildrive_more'))
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
        Text($r('app.string.taildrive_more_action'))
          .fontSize(11)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .height(58)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.38)
    .onClick(action)
  }

  @Builder
  private NormalBottomToolbar() {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_primary')])
          Text('+')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .offset({ x: 8, y: 6 })
        }
        .width(28)
        .height(28)
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('sys.color.comp_divider') })
      .borderRadius(21)
      .opacity(this.canModifyCurrentPath() && !this.busy ? 1 : 0.38)
      .id('taildrive-new-folder')
      .onClick(() => this.createFolder())
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image($r('app.media.tab_transfer'))
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('sys.color.comp_divider') })
      .borderRadius(21)
      .opacity(this.canModifyCurrentPath() && !this.busy ? 1 : 0.38)
      .id('taildrive-upload')
      .onClick(() => this.selectUpload())
      Button({ type: ButtonType.ROUNDED_RECTANGLE, stateEffect: true }) {
        Row({ space: 7 }) {
          Text(this.sortModeText())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([$r('sys.color.icon_primary')])
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      // Keep the content Row inside a concrete button width. With only a
      // constraintSize, the native Button content can resolve 100% against
      // the pre-constrained parent and overflow into the view toggle.
      .width(136)
      .height(42)
      .padding({ left: 14, right: 14 })
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('sys.color.comp_divider') })
      .borderRadius(21)
      .id('taildrive-sort')
      .onClick(() => this.openSortPanel())
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Image(this.viewMode === 'list' ? $r('app.media.taildrive_grid') : $r('app.media.taildrive_list'))
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
      }
      .width(42)
      .height(42)
      .backgroundColor(Color.Transparent)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('sys.color.comp_divider') })
      .borderRadius(21)
      .id('taildrive-view-toggle')
      .onClick(() => this.toggleViewMode())
    }
    .width('calc(100% - 60vp)')
    .height(52)
    .justifyContent(FlexAlign.Center)
    .margin({
      left: 30,
      right: 30,
      bottom: this.standalone ? Math.max(0, this.bottomInset - 16) : 14
    })
  }

  @Builder
  private SelectionBottomToolbar() {
    Row({ space: 0 }) {
      this.SelectionAction($r('sys.symbol.save'), $r('app.string.taildrive_share_action'),
        this.selectedPaths.length > 0, () => this.shareSelectedEntry())
      this.SelectionAction($r('sys.symbol.text_clipboard'), $r('app.string.taildrive_copy_action'),
        this.selectedPaths.length > 0, () => this.copySelectedPaths())
      this.SelectionAction($r('sys.symbol.trash'), $r('app.string.taildrive_delete_action'),
        this.selectedPaths.length > 0 && this.canModifyCurrentPath(),
        () => this.confirmDeleteSelected())
      this.SelectionMoreAction(this.selectedPaths.length > 0, () => this.showMoreSelected())
    }
    .width('calc(100% - 44vp)')
    .height(64)
    .justifyContent(FlexAlign.SpaceEvenly)
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 1, color: $r('sys.color.comp_divider') })
    .borderRadius(26)
    .margin({ bottom: this.standalone ? Math.max(0, this.bottomInset - 16) : 16 })
  }

  @Builder
  private BottomToolbar() {
    if (this.selectionMode) {
      this.SelectionBottomToolbar()
    } else {
      this.NormalBottomToolbar()
    }
  }

  @Builder
  private StandaloneNavigation() {
    HdsNavigation() {
      this.StandaloneBrowser()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.titleBarPadding),
        end: LengthMetrics.vp(this.titleBarPadding)
      },
      style: {
        // Keep the compact file title bar opaque and disable HDS blur/material effects.
        blurStrategy: BlurStrategy.DISABLE,
        originalStyle: {
          backgroundStyle: {
            backgroundColor: this.transparentBackground ? Color.Transparent :
              $r('sys.color.background_secondary')
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
              backgroundColor: $r('sys.color.comp_background_tertiary'),
              iconColor: $r('sys.color.icon_primary'),
              textColor: $r('sys.color.font_primary')
            }
          }
        }
      },
      content: {
        divider: { showType: DividerShowType.OFF },
        title: {
          mainTitle: $r('app.string.tab_files'),
          subTitle: $r('app.string.taildrive_subtitle')
        },
        menu: {
          maxCount: 2,
          value: !this.connected || this.searchVisible || this.selectionMode ? [] : [
            {
              content: {
                label: $r('app.string.taildrive_multi_select_action'),
                type: TextStyleMode.NORMAL,
                isEnabled: true,
                componentId: 'taildrive-multi-select',
                action: () => this.toggleSelectionMode()
              }
            },
            {
              content: {
                label: $r('app.string.taildrive_search_action'),
                icon: $r('app.media.taildrive_search'),
                isEnabled: true,
                componentId: 'taildrive-search-trigger',
                action: () => this.setSearchVisible(true)
              }
            }
          ]
        }
      }
    })
    // Use the compact native title bar and leave extra space below the status bar.
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.contentScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .padding({ top: 16 })
    .width('100%')
    .height('100%')
    .id('hds-navigation-files')
    .backgroundColor(this.transparentBackground ? Color.Transparent :
      $r('sys.color.background_secondary'))
  }

  @Builder
  private StandaloneBrowser() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 6 }) {
        if (this.connected) {
          if (this.searchVisible || this.selectionMode) {
            this.TopControls()
          }
          this.PathBar()
          this.StandaloneEntryViewport()
          if ((this.busy || this.previewDownloading) &&
            (this.transfer.state === 'queued' || this.transfer.state === 'transferring')) {
            this.TransferStatus()
          }
          if (this.status.length > 0 || this.retryAvailable) {
            this.OperationStatus()
          }
        } else {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(42)
              .fontColor([$r('sys.color.icon_secondary')])
            Text($r('app.string.taildrive_connect_first'))
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      if (this.connected) {
        this.BottomToolbar()
      }
    }
    .width('100%')
    .height('100%')
    .id('taildrive-browser')
  }

  @Builder
  private BrowserContent() {
    Column({ space: 12 }) {
      if (!this.standalone) {
        Row() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(20)
            .fontColor([$r('app.color.emphasize')])
          Text($r('app.string.taildrive_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .margin({ left: 8 })
        }
        .width('100%')
      } else if (this.connected) {
        this.TopControls()
      }
      if (!this.connected) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(42)
            .fontColor([$r('sys.color.icon_secondary')])
          Text($r('app.string.taildrive_connect_first'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 42, bottom: 42 })
      } else {
        this.PathBar()
        if (this.searchVisible) {
          this.SearchField()
        }
        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress().width(28).height(28)
            Text($r('app.string.taildrive_loading'))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
          .padding({ top: 48, bottom: 48 })
        } else if (this.displayEntries().length === 0) {
          Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.folder'))
              .fontSize(42)
              .fontColor([$r('sys.color.icon_secondary')])
            Text(this.reason.length > 0 ? this.statusCodeText(this.reason) : $r('app.string.taildrive_empty'))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .textAlign(TextAlign.Center)
              .lineHeight(20)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 48, bottom: 48 })
          .id('taildrive-inline-list-state')
        } else {
          this.EntryGroups()
        }
        if ((this.busy || this.previewDownloading) &&
          (this.transfer.state === 'queued' || this.transfer.state === 'transferring')) {
          this.TransferStatus()
        }
      }
      if (this.status.length > 0 || this.retryAvailable) {
        this.OperationStatus()
      }
    }
    .width('100%')
    .padding({
      top: this.standalone ? 8 : 14,
      bottom: this.standalone ? this.bottomInset + 82 : 14
    })
    .id('taildrive-inline-browser')
  }

  build() {
    if (this.standalone) {
      Stack({ alignContent: Alignment.Bottom }) {
        this.StandaloneNavigation()
        if (this.folderDialogVisible) {
          this.FolderDialog()
        }
        this.SheetHosts()
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        this.BrowserContent()
        this.SheetHosts()
      }
      .width('100%')
      .backgroundColor($r('app.color.surface_subtle'))
      .borderRadius(16)
    }
  }
}
