import { beforeEach, expect, it, vi } from 'vitest';

vi.mock('../src/lib/db.js', () => ({ get: vi.fn(), put: vi.fn(), del: vi.fn(), query: vi.fn(), queryPrefix: vi.fn(), isConditionalFailure: (e: any) => e?.name === 'ConditionalCheckFailedException' }));
vi.mock('../src/lib/flows.js', () => ({ getCall: vi.fn() }));
vi.mock('../src/lib/users.js', () => ({ getUser: vi.fn() }));
vi.mock('../src/ai/detector.js', () => ({ detectReference: vi.fn(), retrievalQueries: () => ['ramen bowl'] }));
vi.mock('../src/ai/embed.js', () => ({ embedText: vi.fn().mockResolvedValue([1]) }));
vi.mock('../src/ai/rerank.js', () => ({ rerankPhotos: vi.fn() }));
vi.mock('../src/lib/vectors.js', () => ({ queryPhotos: vi.fn(), queryCaptionPhotos: vi.fn().mockResolvedValue([]) }));
vi.mock('../src/lib/s3.js', () => ({ presignGet: vi.fn().mockResolvedValue('https://example.com/photo') }));
vi.mock('../src/lib/ws.js', () => ({ sendToUser: vi.fn() }));
import { get, put, del, query, queryPrefix } from '../src/lib/db.js';
import { getCall } from '../src/lib/flows.js';
import { getUser } from '../src/lib/users.js';
import { detectReference } from '../src/ai/detector.js';
import { rerankPhotos } from '../src/ai/rerank.js';
import { queryPhotos } from '../src/lib/vectors.js';
import { sendToUser } from '../src/lib/ws.js';
import { handleTranscript } from '../src/lib/references.js';

const input = { callId: 'c', segId: 's', text: 'I ate ramen in Chinatown in Houston', isPartial: true };
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(getCall).mockResolvedValue({ id: 'c', participants: ['u'] } as any);
  vi.mocked(getUser).mockResolvedValue({ settings: { photoMode: 'auto' } } as any);
  vi.mocked(get).mockResolvedValue({ status: 'indexed', s3Key: 'photo' } as any);
  vi.mocked(put).mockResolvedValue();
  vi.mocked(query).mockResolvedValue([]);
  vi.mocked(queryPrefix).mockResolvedValue([]);
  vi.mocked(detectReference).mockResolvedValue({ isReference: true, query: 'ramen bowl', placeHint: 'Houston', confidence: 0.9 });
  vi.mocked(queryPhotos).mockResolvedValue([
    { key: 'u#skyline', similarity: 0.9, metadata: { caption: 'Houston skyline' } },
    { key: 'u#ramen', similarity: 0.8, metadata: { caption: 'Bowl of ramen noodles' } },
  ]);
  vi.mocked(rerankPhotos).mockResolvedValue({ key: 'u#ramen', confidence: 0.9 });
});

it('passes spoken subject to reranker and suggests partials without auto-sharing or storing them as final history', async () => {
  await handleTranscript('u', input);
  expect(rerankPhotos).toHaveBeenCalledWith(expect.stringContaining(input.text), expect.any(Array));
  expect(sendToUser).toHaveBeenCalledWith('u', expect.objectContaining({ photoId: 'ramen', auto: false }));
  expect(vi.mocked(put).mock.calls.some(([item]) => item.sk.startsWith('SEG#'))).toBe(false);
  expect(del).toHaveBeenCalledWith(expect.anything(), 'leaseToken = :owner', expect.anything());
});

it('does not substitute the skyline when the ramen photo was already suggested', async () => {
  vi.mocked(queryPrefix).mockResolvedValue([{ userId: 'u', photoId: 'ramen' }] as any);
  await handleTranscript('u', input);
  expect(sendToUser).not.toHaveBeenCalled();
});

it('does not guess when the reranker fails', async () => {
  vi.mocked(rerankPhotos).mockRejectedValueOnce(new Error('unavailable'));
  await handleTranscript('u', input);
  expect(sendToUser).not.toHaveBeenCalled();
  expect(del).toHaveBeenCalled();
});

it('skips competing partial searches', async () => {
  vi.mocked(put).mockRejectedValueOnce({ name: 'ConditionalCheckFailedException' });
  await handleTranscript('u', input);
  expect(detectReference).not.toHaveBeenCalled();
  expect(del).not.toHaveBeenCalled();
});
