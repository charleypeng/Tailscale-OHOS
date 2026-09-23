import { common, Want } from '@kit.AbilityKit';
import { HosPlayerLaunchRequest } from './MediaIntegrationModels';

export interface HosPlayerContractConfig {
  action: string;
  baseUri: string;
}

// HosPlayer's published import contract. Keep this URI independent from the
// receiving application's bundle and ability names so the system resolver can
// route it through Deep Linking.
export const HOSPLAYER_CONTRACT: HosPlayerContractConfig = {
  action: 'ohos.want.action.viewData',
  baseUri: 'hosplayer://server/import'
};

export class HosPlayerLauncher {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  buildUri(request: HosPlayerLaunchRequest): string {
    this.validate(request);
    const fields: string[] = [
      `protocolVersion=${request.protocolVersion}`,
      `type=${encodeURIComponent(request.type)}`,
      `endpoint=${encodeURIComponent(request.endpoint)}`,
      `name=${encodeURIComponent(request.name)}`
    ];
    return `${HOSPLAYER_CONTRACT.baseUri}?${fields.join('&')}`;
  }

  async launch(request: HosPlayerLaunchRequest): Promise<void> {
    await this.context.startAbility(this.buildWant(request));
  }

  runOfflineSelfTest(): string {
    const want: Want = this.buildWant({
      protocolVersion: 1,
      type: 'jellyfin',
      endpoint: 'http://100.64.0.10:8096',
      name: '家庭 NAS'
    });
    const uri: string = want.uri ?? '';
    const passed: boolean = want.action === HOSPLAYER_CONTRACT.action &&
      uri.startsWith('hosplayer://server/import?') &&
      uri.includes('type=jellyfin') &&
      uri.includes('endpoint=http%3A%2F%2F100.64.0.10%3A8096') &&
      uri.includes('name=%E5%AE%B6%E5%BA%AD%20NAS') &&
      !uri.toLowerCase().includes('password') &&
      !uri.toLowerCase().includes('token');
    return passed ? `PASS | ${uri}` : 'FAILED | HosPlayer parameter contract';
  }

  private buildWant(request: HosPlayerLaunchRequest): Want {
    return {
      action: HOSPLAYER_CONTRACT.action,
      uri: this.buildUri(request)
    };
  }

  private validate(request: HosPlayerLaunchRequest): void {
    if (request.protocolVersion !== 1) {
      throw new Error('invalid_contract_version');
    }
    const normalizedUrl: string = request.endpoint.trim();
    if ((!normalizedUrl.startsWith('http://') && !normalizedUrl.startsWith('https://')) ||
      /^https?:\/\/[^/]*@/i.test(normalizedUrl) || normalizedUrl.length > 2048 ||
      normalizedUrl.includes('#')) {
      throw new Error('unsafe_server_url');
    }
    if (request.name.trim().length === 0 || request.name.length > 96) {
      throw new Error('invalid_server_name');
    }
  }
}
