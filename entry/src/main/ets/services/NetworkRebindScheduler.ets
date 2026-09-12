const DEBOUNCE_MS: number = 750;
const MIN_INTERVAL_MS: number = 3000;
const MAX_WAIT_MS: number = 3000;
const MAX_RETRIES: number = 3;

// Serialize native socket changes and retain the latest event while one runs.
export class NetworkRebindScheduler {
  private readonly rebind: (reason: string) => Promise<void>;
  private timer: number = -1;
  private stopped: boolean = false;
  private inFlight: boolean = false;
  private pendingReason: string = '';
  private firstPendingAt: number = -1;
  private lastStartedAt: number = -MIN_INTERVAL_MS;
  private retries: number = 0;

  constructor(rebind: (reason: string) => Promise<void>) {
    this.rebind = rebind;
  }

  schedule(reason: string): void {
    if (this.stopped) {
      return;
    }
    this.retries = 0;
    this.enqueue(reason);
  }

  stop(): void {
    this.stopped = true;
    this.pendingReason = '';
    this.firstPendingAt = -1;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private enqueue(reason: string): void {
    this.pendingReason = reason;
    if (this.firstPendingAt < 0) {
      this.firstPendingAt = Date.now();
    }
    if (!this.inFlight) {
      this.arm();
    }
  }

  private arm(): void {
    if (this.stopped || this.pendingReason.length === 0) {
      return;
    }
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    const now: number = Date.now();
    const due: number = Math.max(this.lastStartedAt + MIN_INTERVAL_MS,
      Math.min(now + DEBOUNCE_MS, this.firstPendingAt + MAX_WAIT_MS));
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.run();
    }, Math.max(0, due - now));
  }

  private async run(): Promise<void> {
    if (this.stopped || this.inFlight || this.pendingReason.length === 0) {
      return;
    }
    const reason: string = this.pendingReason;
    this.pendingReason = '';
    this.firstPendingAt = -1;
    this.inFlight = true;
    this.lastStartedAt = Date.now();
    try {
      await this.rebind(reason);
      this.retries = 0;
    } catch (_error) {
      // A newer platform event takes precedence over retrying old state.
      if (!this.stopped && this.pendingReason.length === 0 && this.retries < MAX_RETRIES) {
        this.retries++;
        this.enqueue(reason);
      }
    } finally {
      this.inFlight = false;
      if (!this.stopped) {
        this.arm();
      }
    }
  }
}
