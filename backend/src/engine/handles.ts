// Handle rules (SPEC ACC-3): 3–20 chars of a-z 0-9 _ . ; no leading/trailing '.', no '..'.

export const RESERVED_HANDLES = new Set([
  'admin', 'administrator', 'nudge', 'nudgeapp', 'support', 'help', 'root', 'api', 'www', 'settings', 'me',
  'official', 'apple', 'staff', 'system', 'null', 'undefined', 'everyone', 'security', 'team', 'mod', 'moderator',
]);

export type HandleCheck = { ok: true; handle: string } | { ok: false; reason: 'invalid' | 'reserved' };

export function normalizeHandle(raw: string): string {
  return raw.trim().replace(/^@/, '').toLowerCase();
}

export function checkHandle(raw: string): HandleCheck {
  const h = normalizeHandle(raw);
  if (!/^[a-z0-9_.]{3,20}$/.test(h)) return { ok: false, reason: 'invalid' };
  if (h.startsWith('.') || h.endsWith('.') || h.includes('..')) return { ok: false, reason: 'invalid' };
  if (RESERVED_HANDLES.has(h)) return { ok: false, reason: 'reserved' };
  return { ok: true, handle: h };
}
