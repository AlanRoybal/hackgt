// Shared domain types for the pure nudge engine (no AWS imports here).

export type Frequency = 'off' | 'low' | 'normal' | 'high';
export type SkipBehavior = 'message' | 'nothing';
export type PhotoMode = 'ask' | 'auto' | 'off';

export interface Settings {
  frequency: Frequency;
  quietStart: string; // HH:mm local
  quietEnd: string;
  minWindowMin: 5 | 10 | 15 | 30;
  respectFocus: boolean;
  respectDriving: boolean;
  skipBehavior: SkipBehavior;
  photoMode: PhotoMode;
  photoIndexing: boolean;
  includeScreenshots: boolean;
  memoryEnabled: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  frequency: 'normal',
  quietStart: '00:00',
  quietEnd: '08:00',
  minWindowMin: 5,
  respectFocus: true,
  respectDriving: true,
  skipBehavior: 'message',
  photoMode: 'ask',
  photoIndexing: true,
  includeScreenshots: false,
  memoryEnabled: true,
};

export interface BusyBlock { start: string; end: string }

export interface Availability {
  whoop?: import('./whoop.js').WhoopSignal;
  busyBlocks: BusyBlock[];
  syncedAt?: string;
  focus?: { isFocused: boolean; at: string };
  driving?: { isDriving: boolean; at: string };
}

export interface EngineUser {
  id: string;
  tz: string;
  settings: Settings;
  recentNudgeAts?: string[];
  lastNudgeAt?: string;
  busyUntil?: string;
}

export type NudgeState =
  | 'precheck' | 'pending' | 'accepted_by_one' | 'matched' | 'in_call'
  | 'ended' | 'skipped' | 'expired' | 'cancelled';

export type NudgeResponse = 'accepted' | 'skipped' | 'less' | 'expired';

export const TERMINAL_STATES: NudgeState[] = ['ended', 'skipped', 'expired', 'cancelled'];
