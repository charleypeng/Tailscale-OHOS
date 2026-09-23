import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface AppSecuritySettings {
  appLockEnabled: boolean;
  folderLockEnabled: boolean;
  lockedFolderPaths: string[];
}

const STORE_NAME: string = 'mesh_arc_security';
const APP_LOCK_ENABLED_KEY: string = 'app_lock_enabled';
const FOLDER_LOCK_ENABLED_KEY: string = 'folder_lock_enabled';
const LOCKED_FOLDER_PATHS_KEY: string = 'locked_folder_paths';

/** Stores only lock policy and Taildrive paths. System authentication data never enters app storage. */
export class AppSecurityPreferences {
  static async load(context: common.Context): Promise<AppSecuritySettings> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return {
        appLockEnabled: store.getSync(APP_LOCK_ENABLED_KEY, false) as boolean,
        folderLockEnabled: store.getSync(FOLDER_LOCK_ENABLED_KEY, false) as boolean,
        lockedFolderPaths: AppSecurityPreferences.normalizePaths(
          store.getSync(LOCKED_FOLDER_PATHS_KEY, '[]') as string)
      };
    } catch (_error) {
      return AppSecurityPreferences.defaults();
    }
  }

  static async saveAppLockEnabled(context: common.Context, enabled: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(APP_LOCK_ENABLED_KEY, enabled);
    await store.flush();
  }

  static async saveFolderLockEnabled(context: common.Context, enabled: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(FOLDER_LOCK_ENABLED_KEY, enabled);
    await store.flush();
  }

  static async saveLockedFolderPaths(context: common.Context, paths: string[]): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(LOCKED_FOLDER_PATHS_KEY, JSON.stringify(AppSecurityPreferences.normalizePathList(paths)));
    await store.flush();
  }

  private static defaults(): AppSecuritySettings {
    return { appLockEnabled: false, folderLockEnabled: false, lockedFolderPaths: [] };
  }

  private static normalizePaths(value: string): string[] {
    try {
      const parsed: string[] = JSON.parse(value) as string[];
      return Array.isArray(parsed) ? AppSecurityPreferences.normalizePathList(parsed) : [];
    } catch (_error) {
      return [];
    }
  }

  private static normalizePathList(paths: string[]): string[] {
    const candidates: string[] = [];
    paths.forEach((path: string) => {
      const value: string = path.trim().replace(/\/+$/, '');
      if (value.length > 1 && value.startsWith('/') && !candidates.includes(value)) {
        candidates.push(value);
      }
    });
    candidates.sort((left: string, right: string) => left.length - right.length);
    const normalized: string[] = [];
    candidates.forEach((value: string) => {
      if (!normalized.some((parent: string) => value === parent || value.startsWith(`${parent}/`))) {
        normalized.push(value);
      }
    });
    return normalized;
  }
}
