import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

const TAILDRIVE_QUERY_REQUEST_FILE: string = 'taildrive-query-request.json';
const TAILDRIVE_QUERY_RESPONSE_FILE: string = 'taildrive-query-response.json';
const TAILDRIVE_TRANSFER_REQUEST_FILE: string = 'taildrive-transfer-request.json';
const TAILDRIVE_TRANSFER_RESPONSE_FILE: string = 'taildrive-transfer-response.json';
const TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE: string = 'taildrive-manual-transfer-request.json';
const TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE: string = 'taildrive-manual-transfer-response.json';
const TAILDRIVE_CONTROL_REQUEST_FILE: string = 'taildrive-control-request.json';
const TAILDRIVE_CONTROL_RESPONSE_FILE: string = 'taildrive-control-response.json';
// A cold remote directory query first performs a bounded native TSMP warm-up
// (up to 5 s), then retains the existing 20 s WebDAV request limit.
const TAILDRIVE_QUERY_TIMEOUT_MS: number = 32000;
const TAILDRIVE_MUTATION_TIMEOUT_MS: number = 35000;
const TAILDRIVE_TRANSFER_TIMEOUT_MS: number = 30 * 60 * 1000 + 10000;
const TAILDRIVE_CONTROL_TIMEOUT_MS: number = 5000;

interface TaildriveExtensionRequest {
  requestId: number;
  operation: string;
  payload: string;
}

interface TaildriveExtensionResponse {
  requestId: number;
  result: string;
}

export interface TaildriveEntry {
  name: string;
  path: string;
  kind: string;
  size: number;
  modifiedAtMs: number;
  contentType?: string;
  etag?: string;
}

export interface TaildriveListResult {
  state: string;
  path: string;
  entries: TaildriveEntry[];
  reason: string;
}

export interface TaildriveStatResult {
  state: string;
  entry: TaildriveEntry;
  reason: string;
}

export interface TaildriveMutationRequest {
  operation: string;
  path: string;
  newPath?: string;
  overwrite?: boolean;
}

export interface TaildriveMutationResult {
  state: string;
  operation: string;
  path: string;
  newPath: string;
  reason: string;
}

export interface TaildriveTransferRequest {
  requestId: number;
  remotePath: string;
  localRoot: string;
  localPath: string;
  sourceModifiedAtMs?: number;
  overwrite?: boolean;
}

export interface TaildriveTransferSnapshot {
  requestId: number;
  direction: string;
  state: string;
  reason: string;
  remotePath: string;
  localPath: string;
  fileName: string;
  bytes: number;
  totalBytes: number;
  startedAtMs: number;
  completedAtMs: number;
}

export interface PreparedTaildriveFile {
  path: string;
  requestDir: string;
  name: string;
  size: number;
  modifiedAtMs: number;
}

/** Owns the Taildrive request protocol and app-private staging copies. */
export class TaildriveGateway {
  private context?: common.UIAbilityContext;
  private nextRequestId: number = Date.now();
  private queryQueue: Promise<void> = Promise.resolve();
  private transferQueue: Promise<void> = Promise.resolve();
  private manualTransferQueue: Promise<void> = Promise.resolve();
  private controlQueue: Promise<void> = Promise.resolve();

  configure(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async list(path: string): Promise<TaildriveListResult> {
    const text: string = await this.requestThroughVpnExtension('query', 'list',
      JSON.stringify({ path: path }), TAILDRIVE_QUERY_TIMEOUT_MS);
    return this.parseList(text);
  }

  async stat(path: string): Promise<TaildriveStatResult> {
    const text: string = await this.requestThroughVpnExtension('query', 'stat',
      JSON.stringify({ path: path }), TAILDRIVE_QUERY_TIMEOUT_MS);
    return this.parseStat(text);
  }

  async mutate(request: TaildriveMutationRequest): Promise<TaildriveMutationResult> {
    const text: string = await this.requestThroughVpnExtension('query', 'mutate',
      JSON.stringify(request), TAILDRIVE_MUTATION_TIMEOUT_MS);
    return this.parseMutation(text);
  }

  async download(request: TaildriveTransferRequest, manual: boolean = false): Promise<TaildriveTransferSnapshot> {
    const channel: string = manual ? 'manualTransfer' : 'transfer';
    const text: string = await this.requestThroughVpnExtension(channel, 'download',
      JSON.stringify(request), TAILDRIVE_TRANSFER_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async upload(request: TaildriveTransferRequest): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('transfer', 'upload',
      JSON.stringify(request), TAILDRIVE_TRANSFER_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async transferSnapshot(): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('control', 'snapshot', '',
      TAILDRIVE_CONTROL_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  async cancel(): Promise<TaildriveTransferSnapshot> {
    const text: string = await this.requestThroughVpnExtension('control', 'cancel', '',
      TAILDRIVE_CONTROL_TIMEOUT_MS);
    return this.parseTransfer(text);
  }

  private async requestThroughVpnExtension(channel: string, operation: string,
    payload: string, timeoutMs: number): Promise<string> {
    return this.enqueue(channel, () => this.performVpnExtensionRequest(channel, operation, payload, timeoutMs));
  }

  private enqueue(channel: string, task: () => Promise<string>): Promise<string> {
    let release: () => void = () => {};
    let previous: Promise<void>;
    const next: Promise<void> = new Promise<void>((resolve: () => void) => { release = resolve; });
    if (channel === 'transfer') {
      previous = this.transferQueue;
      this.transferQueue = next;
    } else if (channel === 'manualTransfer') {
      previous = this.manualTransferQueue;
      this.manualTransferQueue = next;
    } else if (channel === 'control') {
      previous = this.controlQueue;
      this.controlQueue = next;
    } else {
      previous = this.queryQueue;
      this.queryQueue = next;
    }
    return previous.then(task).finally(() => release());
  }

  private async performVpnExtensionRequest(channel: string, operation: string,
    payload: string, timeoutMs: number): Promise<string> {
    if (this.context === undefined) {
      throw new Error('Taildrive VPN Extension channel is not configured.');
    }
    const requestId: number = ++this.nextRequestId;
    const requestPath: string = `${this.context.filesDir}/${this.requestFile(channel)}`;
    const responsePath: string = `${this.context.filesDir}/${this.responseFile(channel)}`;
    const request: TaildriveExtensionRequest = {
      requestId: requestId,
      operation: operation,
      payload: payload
    };
    this.writeText(responsePath, '');
    if (!this.writeText(requestPath, JSON.stringify(request))) {
      throw new Error('Taildrive VPN Extension request failed.');
    }
    const startedAt: number = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
      try {
        if (!fileIo.accessSync(responsePath)) {
          continue;
        }
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length === 0) {
          continue;
        }
        const response: TaildriveExtensionResponse = JSON.parse(responseText) as TaildriveExtensionResponse;
        if (response.requestId !== requestId) {
          continue;
        }
        this.writeText(responsePath, '');
        return response.result;
      } catch (_error) {
        // The Extension may be replacing the response while it is read. Keep
        // polling until the matching complete JSON object is visible.
      }
    }
    this.writeText(requestPath, '');
    throw new Error('Taildrive VPN Extension request timed out.');
  }

  private requestFile(channel: string): string {
    if (channel === 'transfer') {
      return TAILDRIVE_TRANSFER_REQUEST_FILE;
    }
    if (channel === 'manualTransfer') {
      return TAILDRIVE_MANUAL_TRANSFER_REQUEST_FILE;
    }
    if (channel === 'control') {
      return TAILDRIVE_CONTROL_REQUEST_FILE;
    }
    return TAILDRIVE_QUERY_REQUEST_FILE;
  }

  private responseFile(channel: string): string {
    if (channel === 'transfer') {
      return TAILDRIVE_TRANSFER_RESPONSE_FILE;
    }
    if (channel === 'manualTransfer') {
      return TAILDRIVE_MANUAL_TRANSFER_RESPONSE_FILE;
    }
    if (channel === 'control') {
      return TAILDRIVE_CONTROL_RESPONSE_FILE;
    }
    return TAILDRIVE_QUERY_RESPONSE_FILE;
  }

  private writeText(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) {}
      }
    }
  }

  async stageUpload(uri: string, root: string, requestId: number): Promise<PreparedTaildriveFile> {
    const requestDir: string = `${root}/${requestId}`;
    if (fileIo.accessSync(requestDir)) {
      throw new Error('Taildrive staging request already exists.');
    }
    fileIo.mkdirSync(requestDir, true);
    let source: fileIo.File | undefined = undefined;
    try {
      source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(source.fd);
      if (!stat.isFile() || stat.size < 0) {
        throw new Error('Selected item is not a regular file.');
      }
      const destination: string = `${requestDir}/upload.taildrive`;
      await fileIo.copyFile(source.fd, destination);
      if (stat.mtime > 0) {
        fileIo.utimes(destination, stat.mtime);
      }
      const copied: fileIo.Stat = fileIo.lstatSync(destination);
      if (!copied.isFile() || copied.size !== stat.size) {
        throw new Error('Taildrive staging verification failed.');
      }
      return {
        path: destination,
        requestDir: requestDir,
        name: source.name,
        size: copied.size,
        modifiedAtMs: stat.mtime
      };
    } catch (_error) {
      this.cleanupStagedDirectory(requestDir);
      throw new Error('Taildrive file staging failed.');
    } finally {
      if (source !== undefined) {
        try {
          fileIo.closeSync(source);
        } catch (_error) {
          // The provider may close the descriptor after a failed copy.
        }
      }
    }
  }

  cleanupStaged(file: PreparedTaildriveFile): void {
    this.cleanupStagedDirectory(file.requestDir);
  }

  cleanupStaleStaging(root: string, maxAgeMs: number = 24 * 60 * 60 * 1000): void {
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
      const cutoffMs: number = Date.now() - maxAgeMs;
      fileIo.listFileSync(root).forEach((name: string) => {
        const requestDir: string = `${root}/${name}`;
        try {
          const stat: fileIo.Stat = fileIo.statSync(requestDir);
          if (stat.isDirectory() && stat.mtime > 0 && stat.mtime <= cutoffMs) {
            this.cleanupStagedDirectory(requestDir);
          }
        } catch (_error) {
          // Another cleanup pass may have already removed the request directory.
        }
      });
    } catch (_error) {
      // Cache recovery is best-effort and never blocks remote file access.
    }
  }

  async exportFile(sourcePath: string, destinationUri: string, expectedSize: number): Promise<boolean> {
    if (destinationUri.length === 0) {
      return false;
    }
    let source: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    let verifier: fileIo.File | undefined = undefined;
    let copied: boolean = false;
    try {
      source = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      destination = this.openExportDestination(destinationUri);
      await fileIo.copyFile(source.fd, destination.fd);
      fileIo.closeSync(source);
      source = undefined;
      fileIo.closeSync(destination);
      destination = undefined;
      verifier = fileIo.openSync(destinationUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(verifier.fd);
      copied = stat.isFile() && stat.size === expectedSize;
    } catch (_error) {
      copied = false;
    }
    if (source !== undefined) {
      try { fileIo.closeSync(source); } catch (_error) { copied = false; }
    }
    if (destination !== undefined) {
      try { fileIo.closeSync(destination); } catch (_error) { copied = false; }
    }
    if (verifier !== undefined) {
      try { fileIo.closeSync(verifier); } catch (_error) { copied = false; }
    }
    if (!copied) {
      try { fileIo.unlinkSync(destinationUri); } catch (_error) {
        // A provider may not allow deletion of a failed export URI.
      }
    }
    return copied;
  }

  private openExportDestination(uri: string): fileIo.File {
    try {
      return fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    } catch (_error) {
      return fileIo.openSync(uri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    }
  }

  private cleanupStagedDirectory(requestDir: string): void {
    try {
      if (!fileIo.accessSync(requestDir)) {
        return;
      }
      fileIo.listFileSync(requestDir).forEach((name: string) => {
        try {
          const itemPath: string = `${requestDir}/${name}`;
          if (fileIo.statSync(itemPath).isFile()) {
            fileIo.unlinkSync(itemPath);
          }
        } catch (_error) {
          // Best-effort cleanup; cache cleanup can retry later.
        }
      });
      fileIo.rmdirSync(requestDir);
    } catch (_error) {
      // Best-effort cleanup; the Go side never treats the staging cache as authoritative.
    }
  }

  private parseList(text: string): TaildriveListResult {
    try {
      const value: TaildriveListResult = JSON.parse(text) as TaildriveListResult;
      if (!Array.isArray(value.entries)) {
        value.entries = [];
      }
      return value;
    } catch (_error) {
      return { state: 'failed', path: '/', entries: [], reason: 'invalid_result' };
    }
  }

  private parseStat(text: string): TaildriveStatResult {
    try {
      return JSON.parse(text) as TaildriveStatResult;
    } catch (_error) {
      return {
        state: 'failed',
        entry: { name: '', path: '', kind: '', size: 0, modifiedAtMs: 0 },
        reason: 'invalid_result'
      };
    }
  }

  private parseMutation(text: string): TaildriveMutationResult {
    try {
      return JSON.parse(text) as TaildriveMutationResult;
    } catch (_error) {
      return { state: 'failed', operation: '', path: '', newPath: '', reason: 'invalid_result' };
    }
  }

  private parseTransfer(text: string): TaildriveTransferSnapshot {
    try {
      return JSON.parse(text) as TaildriveTransferSnapshot;
    } catch (_error) {
      return {
        requestId: 0, direction: '', state: 'failed', reason: 'invalid_result',
        remotePath: '', localPath: '', fileName: '', bytes: 0, totalBytes: 0,
        startedAtMs: 0, completedAtMs: 0
      };
    }
  }
}
