import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { userAuth } from '@kit.UserAuthenticationKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AppSecurityAuth';
const CHALLENGE_LENGTH: number = 16;
const AUTH_TRUST_LEVEL: userAuth.AuthTrustLevel = userAuth.AuthTrustLevel.ATL2;

/** Uses HarmonyOS' system authentication widget; no credentials or AuthToken are retained. */
export class AppSecurityAuthenticator {
  static authenticate(title: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (passed: boolean) => void) => {
      let instance: userAuth.UserAuthInstance | undefined = undefined;
      let settled: boolean = false;
      const finish = (passed: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          instance?.off('result', callback);
        } catch (_error) {
          // Authentication has already reached a terminal state.
        }
        resolve(passed);
      };
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult): void => {
          hilog.info(DOMAIN, TAG, 'Authentication completed. result=%{public}d', result.result);
          finish(result.result === userAuth.UserAuthResultCode.SUCCESS);
        }
      };
      let stage: string = 'availability';
      try {
        const authTypes: userAuth.UserAuthType[] = AppSecurityAuthenticator.availableAuthTypes();
        if (authTypes.length === 0) {
          hilog.error(DOMAIN, TAG, 'No enrolled system authentication type is available.');
          finish(false);
          return;
        }
        stage = 'challenge';
        const challenge: Uint8Array = cryptoFramework.createRandom()
          .generateRandomSync(CHALLENGE_LENGTH).data;
        stage = 'instance';
        instance = userAuth.getUserAuthInstance({
          challenge: challenge,
          authType: authTypes,
          authTrustLevel: AUTH_TRUST_LEVEL
        }, { title: title });
        stage = 'listener';
        instance.on('result', callback);
        stage = 'start';
        instance.start();
        hilog.info(DOMAIN, TAG, 'System authentication widget started. typeCount=%{public}d', authTypes.length);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'Authentication setup failed. stage=%{public}s code=%{public}d',
          stage, businessError.code ?? -1);
        finish(false);
      }
    });
  }

  private static availableAuthTypes(): userAuth.UserAuthType[] {
    const candidates: userAuth.UserAuthType[] = [
      userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT,
      userAuth.UserAuthType.PIN
    ];
    const available: userAuth.UserAuthType[] = [];
    candidates.forEach((authType: userAuth.UserAuthType) => {
      try {
        userAuth.getAvailableStatus(authType, AUTH_TRUST_LEVEL);
        available.push(authType);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.info(DOMAIN, TAG, 'Authentication type unavailable. type=%{public}d code=%{public}d',
          authType, businessError.code ?? -1);
      }
    });
    return available;
  }
}
