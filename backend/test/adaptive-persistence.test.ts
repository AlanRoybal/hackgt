import { beforeEach, expect, it, vi } from 'vitest';
vi.mock('../src/lib/db.js', () => ({ ddb: { send: vi.fn() }, get: vi.fn() }));
import { ddb, get } from '../src/lib/db.js';
import { commitNudgeTransition, isTransitionConflict } from '../src/lib/adaptive.js';
import type { NudgeItem } from '../src/lib/flows.js';
const n = { id: 'n1', version: 2, kind: 'auto', participants: ['a', 'b'], responses: {}, createdAt: '2026-09-26T18:00:00Z' } as NudgeItem;
const next = { state: 'expired' as const, participants: n.participants, responses: { a: 'expired' as const, b: 'expired' as const } };
beforeEach(() => { vi.resetAllMocks(); vi.stubEnv('TABLE_NAME', 'test-nudge'); vi.mocked(get).mockResolvedValue({ adaptiveVersion: 3 }); });
it('writes expiration and only nonresponders feedback in one conditional transaction', async () => {
  await commitNudgeTransition({ ...n, responses: { a: 'accepted' } }, next, { type: 'expire' });
  const input = (vi.mocked(ddb.send).mock.calls[0][0] as any).input;
  expect(input.TransactItems).toHaveLength(2);
  expect(input.TransactItems[1].Update.Key.pk).toBe('USER#b');
  expect(input.TransactItems[1].Update.ConditionExpression).toContain('adaptiveVersion = :v');
  expect(input.TransactItems[0].Update.ConditionExpression).toBe('#v = :v');
});
it('does not learn from direct call declines or expirations', async () => {
  await commitNudgeTransition({ ...n, kind: 'direct' }, next, { type: 'expire' });
  expect((vi.mocked(ddb.send).mock.calls[0][0] as any).input.TransactItems).toHaveLength(1);
});
it('persists explicit pause atomically with the response', async () => {
  const now = Date.now();
  await commitNudgeTransition(n, next, { type: 'respond', userId: 'a', action: 'pause' }, now);
  const item = (vi.mocked(ddb.send).mock.calls[0][0] as any).input.TransactItems[1].Update;
  expect(item.ExpressionAttributeValues[':pause']).toBe(new Date(now + 3600000).toISOString());
});
it('propagates failed transactions for retry without separate feedback writes', async () => {
  const error = { name: 'TransactionCanceledException', CancellationReasons: [{ Code: 'ConditionalCheckFailed' }] };
  vi.mocked(ddb.send).mockRejectedValue(error);
  await expect(commitNudgeTransition(n, next, { type: 'expire' })).rejects.toEqual(error);
  expect(isTransitionConflict(error)).toBe(true);
  expect(isTransitionConflict({ name: 'AccessDeniedException' })).toBe(false);
});
