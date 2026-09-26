// Validation for PATCH /me settings.
import type { Settings } from '../engine/types.js';
import { bad } from './http.js';

const HM = /^([01]\d|2[0-3]):[0-5]\d$/;

const validators: { [K in keyof Settings]: (v: unknown) => boolean } = {
  frequency: (v) => ['off', 'low', 'normal', 'high'].includes(v as string),
  quietStart: (v) => typeof v === 'string' && HM.test(v),
  quietEnd: (v) => typeof v === 'string' && HM.test(v),
  minWindowMin: (v) => [5, 10, 15, 30].includes(v as number),
  respectFocus: (v) => typeof v === 'boolean',
  respectDriving: (v) => typeof v === 'boolean',
  skipBehavior: (v) => v === 'message' || v === 'nothing',
  photoMode: (v) => ['ask', 'auto', 'off'].includes(v as string),
  photoIndexing: (v) => typeof v === 'boolean',
  includeScreenshots: (v) => typeof v === 'boolean',
  memoryEnabled: (v) => typeof v === 'boolean',
};

/** Returns the validated subset; unknown keys (e.g. client-only disabledCalendarIds) are ignored. */
export function validateSettingsPatch(patch: unknown): Partial<Settings> {
  if (patch === undefined) return {};
  if (!patch || typeof patch !== 'object') throw bad('invalid_settings');
  const out: Partial<Settings> = {};
  for (const [k, v] of Object.entries(patch)) {
    const check = validators[k as keyof Settings];
    if (!check) continue;
    if (!check(v)) throw bad('invalid_settings', `invalid value for ${k}`);
    (out as any)[k] = v;
  }
  return out;
}

export function isValidTimeZone(tz: unknown): tz is string {
  if (typeof tz !== 'string' || !tz) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
