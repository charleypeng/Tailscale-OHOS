import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import nativeBridge from 'libtailscale_ohos.so';

const SETTLE_MS: number = 750;
const MIN_REBIND_MS: number = 3000;
const RETRY_MS: number = 5000;

interface PhysicalNetwork {
  interfaceName: string;
  fingerprint: string;
  bearer: string;
}

// PR #11 introduced the host-to-Go network change bridge. Keep it in the VPN
// process so UI backgrounding does not disconnect the callback. A revision is
// retained until applied, including events received during an awaited rebind.
export class VpnNetworkMonitor {
  private active: boolean = false;
  private generation: number = 0;
  private revision: number = 0;
  private appliedRevision: number = 0;
  private inFlight: boolean = false;
  private timer: number = -1;
  private nextRebindAtMs: number = 0;
  private fingerprint: string = '';
  private netConnection?: connection.NetConnection;
  private registering: boolean = false;
  private readonly record: (event: string, code: number) => void;

  constructor(record: (event: string, code: number) => void) {
    this.record = record;
  }

  start(): void {
    if (this.active) {
      return;
    }
    this.active = true;
    this.generation++;
    this.fingerprint = '';
    this.changed();
  }

  stop(): void {
    this.active = false;
    this.generation++;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const monitor: connection.NetConnection | undefined = this.netConnection;
    this.netConnection = undefined;
    if (monitor !== undefined) {
      this.unregister(monitor);
    }
  }

  private unregister(monitor: connection.NetConnection): void {
    try {
      monitor.unregister((_error: BusinessError) => {});
    } catch (_error) {}
  }

  private register(): void {
    if (this.netConnection !== undefined || this.registering) {
      return;
    }
    const generation: number = this.generation;
    const monitor: connection.NetConnection = connection.createNetConnection();
    const changed: () => void = (): void => {
      if (this.active && this.generation === generation) {
        this.changed();
      }
    };
    monitor.on('netAvailable', changed);
    monitor.on('netLost', changed);
    monitor.on('netUnavailable', changed);
    monitor.on('netCapabilitiesChange', changed);
    monitor.on('netConnectionPropertiesChange', changed);
    this.registering = true;
    try {
      monitor.register((error: BusinessError): void => {
        this.registering = false;
        if (!this.active || this.generation !== generation) {
          this.unregister(monitor);
          return;
        }
        if (error) {
          this.record('vpn_network_monitor_failed', error.code ?? -1);
          this.schedule(RETRY_MS);
          return;
        }
        this.netConnection = monitor;
        this.record('vpn_network_monitor_started', 0);
        this.changed();
      });
    } catch (error) {
      this.registering = false;
      throw error as Error;
    }
  }

  private changed(): void {
    if (!this.active) {
      return;
    }
    this.revision++;
    this.schedule(SETTLE_MS);
  }

  private schedule(delayMs: number): void {
    if (!this.active || this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.refresh();
    }, Math.max(delayMs, this.nextRebindAtMs - Date.now()));
  }

  private async readDefaultNetwork(): Promise<PhysicalNetwork> {
    // getDefaultNet excludes VPN networks. Never select an interface by name
    // priority or from whichever bearer happened to send the latest callback.
    const net: connection.NetHandle = await connection.getDefaultNet();
    if (net.netId === 0) {
      return { interfaceName: '', fingerprint: 'offline', bearer: 'offline' };
    }
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(net);
    const current: connection.NetHandle = await connection.getDefaultNet();
    if (net.netId !== current.netId || props.interfaceName.length === 0) {
      throw new Error('default network changed while sampling');
    }
    const addresses: string[] = (props.linkAddresses ?? []).map((link: connection.LinkAddress) =>
      `${link.address.address}/${link.prefixLength}`).sort();
    const dns: string[] = (props.dnses ?? []).map((address: connection.NetAddress) => address.address).sort();
    const bearer: string = capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR) ?
      'cellular' : capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ? 'wifi' : 'other';
    // Kept in memory only: endpoint addresses and DNS are never diagnostic text.
    return {
      interfaceName: props.interfaceName,
      bearer: bearer,
      fingerprint: `${net.netId}|${props.interfaceName}|${addresses.join(',')}|${dns.join(',')}`
    };
  }

  private async refresh(): Promise<void> {
    if (!this.active || this.inFlight) {
      return;
    }
    this.inFlight = true;
    const generation: number = this.generation;
    const revision: number = this.revision;
    let retry: boolean = false;
    try {
      this.register();
      const network: PhysicalNetwork = await this.readDefaultNetwork();
      if (!this.active || generation !== this.generation || revision !== this.revision) {
        return;
      }
      if (network.fingerprint !== this.fingerprint) {
        this.nextRebindAtMs = Date.now() + MIN_REBIND_MS;
        const result: string = await nativeBridge.backendNetworkChangedAsync(network.interfaceName);
        if (!this.active || generation !== this.generation) {
          return;
        }
        if (!result.startsWith('OK')) {
          throw new Error('network rebind failed');
        }
        this.fingerprint = network.fingerprint;
        this.record(network.interfaceName.length === 0 ? 'vpn_network_offline' :
          `vpn_network_rebound_${network.bearer}`, 0);
      }
      this.appliedRevision = revision;
    } catch (error) {
      if (this.active && generation === this.generation) {
        this.record('vpn_network_refresh_failed', (error as BusinessError).code ?? -1);
        retry = true;
      }
    } finally {
      this.inFlight = false;
      // A timer may have fired while the native worker was pending. Replay the
      // latest revision instead of losing the final Wi-Fi/cellular transition.
      if (this.active && (retry || this.netConnection === undefined || this.revision !== this.appliedRevision)) {
        this.schedule(retry || this.netConnection === undefined ? RETRY_MS : SETTLE_MS);
      }
    }
  }
}
