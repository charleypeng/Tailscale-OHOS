import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface AnimationSettings {
  preset: number;
  duration: number;
  amplitude: number;
  damping: number;
}

export const DEFAULT_ANIMATION_SETTINGS: AnimationSettings = {
  preset: 1,
  duration: 60,
  amplitude: 56,
  damping: 64
};

const STORE_NAME: string = 'mesh_arc_animation';
const PRESET_KEY: string = 'animation_preset';
const DURATION_KEY: string = 'animation_duration';
const AMPLITUDE_KEY: string = 'animation_amplitude';
const DAMPING_KEY: string = 'animation_damping';

/** Owns persisted animation controls and the live values consumed by MotionTokens. */
export class AnimationPreferences {
  private static currentSettings: AnimationSettings = AnimationPreferences.defaults();

  static defaults(): AnimationSettings {
    return {
      preset: DEFAULT_ANIMATION_SETTINGS.preset,
      duration: DEFAULT_ANIMATION_SETTINGS.duration,
      amplitude: DEFAULT_ANIMATION_SETTINGS.amplitude,
      damping: DEFAULT_ANIMATION_SETTINGS.damping
    };
  }

  static current(): AnimationSettings {
    return {
      preset: AnimationPreferences.currentSettings.preset,
      duration: AnimationPreferences.currentSettings.duration,
      amplitude: AnimationPreferences.currentSettings.amplitude,
      damping: AnimationPreferences.currentSettings.damping
    };
  }

  static apply(settings: AnimationSettings): AnimationSettings {
    const normalized: AnimationSettings = AnimationPreferences.normalize(settings);
    AnimationPreferences.currentSettings = normalized;
    return AnimationPreferences.current();
  }

  static async load(context: common.Context): Promise<AnimationSettings> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return AnimationPreferences.apply({
        preset: store.getSync(PRESET_KEY, DEFAULT_ANIMATION_SETTINGS.preset) as number,
        duration: store.getSync(DURATION_KEY, DEFAULT_ANIMATION_SETTINGS.duration) as number,
        amplitude: store.getSync(AMPLITUDE_KEY, DEFAULT_ANIMATION_SETTINGS.amplitude) as number,
        damping: store.getSync(DAMPING_KEY, DEFAULT_ANIMATION_SETTINGS.damping) as number
      });
    } catch (_error) {
      return AnimationPreferences.apply(AnimationPreferences.defaults());
    }
  }

  static async save(context: common.Context, settings: AnimationSettings): Promise<void> {
    const normalized: AnimationSettings = AnimationPreferences.apply(settings);
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(PRESET_KEY, normalized.preset);
    store.putSync(DURATION_KEY, normalized.duration);
    store.putSync(AMPLITUDE_KEY, normalized.amplitude);
    store.putSync(DAMPING_KEY, normalized.damping);
    await store.flush();
  }

  private static normalize(settings: AnimationSettings): AnimationSettings {
    return {
      preset: AnimationPreferences.normalizePreset(settings.preset),
      duration: AnimationPreferences.normalizeControl(settings.duration,
        DEFAULT_ANIMATION_SETTINGS.duration),
      amplitude: AnimationPreferences.normalizeControl(settings.amplitude,
        DEFAULT_ANIMATION_SETTINGS.amplitude),
      damping: AnimationPreferences.normalizeControl(settings.damping,
        DEFAULT_ANIMATION_SETTINGS.damping)
    };
  }

  private static normalizePreset(value: number): number {
    const rounded: number = Math.round(value);
    return rounded >= -1 && rounded <= 2 ? rounded : DEFAULT_ANIMATION_SETTINGS.preset;
  }

  private static normalizeControl(value: number, fallback: number): number {
    if (!Number.isFinite(value)) {
      return fallback;
    }
    return Math.min(100, Math.max(0, Math.round(value)));
  }
}
