// Local, deterministic demonstration of the production engine. No AWS access or notifications.
import { adaptiveDecision, appendResponse, HOUR, type AdaptiveHistory } from '../src/engine/adaptive.js';
import { suppressionReasons } from '../src/engine/suppression.js';
import { DEFAULT_SETTINGS } from '../src/engine/types.js';
const start = Date.parse('2026-09-21T19:00:00Z');
let history: AdaptiveHistory = { samples: [] };
const rows: Record<string, string | number>[] = [];
function show(label: string, now: number) {
  const decision = adaptiveDecision(history, 'UTC', now);
  const reasons = suppressionReasons({ id: 'demo', tz: 'UTC', settings: { ...DEFAULT_SETTINGS }, adaptive: history }, { busyBlocks: [], syncedAt: new Date(now).toISOString() }, now);
  rows.push({ scenario: label, time: new Date(now).toISOString(), result: reasons.join(', ') || 'Eligible if friend is also available', 'backoff hours left': Math.max(0, Math.round((decision.cooldownUntil - now) / HOUR)), frequency: 'normal (unchanged)' });
}
function respond(day: number, outcome: 'skip' | 'accept') {
  const now = start + day * 24 * HOUR;
  history = appendResponse(history, { id: `demo-${day}`, at: new Date(now).toISOString(), offeredAt: new Date(now).toISOString(), outcome }, now);
  return now;
}
show('New user', start);
show('One decline: no automatic backoff', respond(0, 'skip'));
show('Second decline: back off temporarily', respond(1, 'skip'));
for (let day = 2; day <= 6; day++) respond(day, 'skip');
show('Busy week: longer temporary backoff', start + 6 * 24 * HOUR);
show('Cooldown ends without any response', start + 7 * 24 * HOUR + HOUR);
show('Next week: older behavior fades', start + 13 * 24 * HOUR);
show('Accepting reinforces recovery', respond(13, 'accept'));
console.table(rows);
console.log('Synthetic timeline using the real decision engine; no real users or notifications were modified.');
