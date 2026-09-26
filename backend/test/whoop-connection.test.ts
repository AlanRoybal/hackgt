import { beforeEach, expect, it, vi } from 'vitest';
vi.mock('../src/lib/db.js', () => ({ get: vi.fn(), put: vi.fn(), del: vi.fn(), update: vi.fn(), queryGsi: vi.fn(), isConditionalFailure: (e: any) => e?.name === 'ConditionalCheckFailedException' }));
import { get, del, update } from '../src/lib/db.js';
import { finishWhoop, whoopStatus, syncWhoop, disconnectWhoop } from '../src/lib/whoop.js';
beforeEach(() => { vi.resetAllMocks(); vi.unstubAllGlobals(); });

it('never returns OAuth credentials through the status endpoint', async () => {
  vi.mocked(get).mockResolvedValue({ pk: 'USER#u', sk: 'WHOOP', accessToken: 'private-access', refreshToken: 'private-refresh', sleepEnabled: true, workoutEnabled: true });
  const status = await whoopStatus('u');
  expect(status.connected).toBe(true);
  expect(JSON.stringify(status)).not.toContain('private');
});

it('rejects expired state without making a token exchange', async () => {
  const fetch = vi.fn(); vi.stubGlobal('fetch', fetch);
  vi.mocked(get).mockResolvedValue({ pk: 'USER#u', sk: 'WHOOP_STATE', oauthState: 'abcdefgh', ttl: 1 });
  await expect(finishWhoop('u', 'code', 'abcdefgh')).rejects.toMatchObject({ code: 'invalid_oauth_state' });
  expect(fetch).not.toHaveBeenCalled();
});

it('rejects a state from a different connection attempt', async () => {
  vi.mocked(get).mockResolvedValue({ pk: 'USER#u', sk: 'WHOOP_STATE', oauthState: 'abcdefgh', ttl: Date.now() / 1000 + 600 });
  await expect(finishWhoop('u', 'code', 'different')).rejects.toMatchObject({ code: 'invalid_oauth_state' });
  expect(del).not.toHaveBeenCalled();
});

it('does not refresh or fetch when a concurrent sync owns the connection', async () => {
  const fetch = vi.fn(); vi.stubGlobal('fetch', fetch);
  vi.mocked(get).mockResolvedValue({ pk: 'USER#u', sk: 'WHOOP', generation: 'g' });
  vi.mocked(update).mockRejectedValue({ name: 'ConditionalCheckFailedException' });
  await syncWhoop('u');
  expect(fetch).not.toHaveBeenCalled();
});

it('removes local access even when provider revocation is unavailable', async () => {
  vi.mocked(get).mockResolvedValue({ pk: 'USER#u', sk: 'WHOOP', accessToken: 'access', expiresAt: Date.now() + 600000 });
  vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')));
  await disconnectWhoop('u');
  expect(del).toHaveBeenCalledWith({ pk: 'USER#u', sk: 'WHOOP' });
  expect(del).toHaveBeenCalledWith({ pk: 'USER#u', sk: 'WHOOP_STATE' });
});
