// Post-call memory (SPEC MEM-1..4): summary + topics, then delete the raw transcript.
import type { SQSEvent } from 'aws-lambda';
import { summarizeCall } from '../ai/summarize.js';
import { batchDelete, put, queryPrefix, update } from '../lib/db.js';
import { getCall } from '../lib/flows.js';
import { K, newId } from '../lib/keys.js';
import { loadUsers } from '../lib/users.js';
import { sendToUser } from '../lib/ws.js';

export async function summarize(callId: string, now = new Date()) {
  const call = await getCall(callId);
  if (call.summarized) return { skipped: 'already' };
  const segs = await queryPrefix(`CALL#${callId}`, 'SEG#');
  const [a, b] = call.participants;
  const users = await loadUsers(call.participants);
  // Memory needs both people's consent at call time and now (MEM-4).
  const allowed = call.memoryAllowed && call.participants.every((u) => users.get(u)?.settings.memoryEnabled !== false);
  let topicsCreated = 0;
  if (allowed && segs.length) {
    const out = await summarizeCall(
      segs.map((s) => ({ who: s.userId === a ? ('A' as const) : ('B' as const), text: s.text })),
      now,
    );
    const endedAt = call.endedAt ?? now.toISOString();
    const durationSec = Math.max(0, Math.round((Date.parse(endedAt) - Date.parse(call.startedAt)) / 1000));
    await put({ ...K.summary(call.pairKey, callId), callId, summary: out.summary, durationSec, createdAt: now.toISOString() });
    for (const t of out.topics) {
      const id = newId('t');
      await put({
        ...K.topic(call.pairKey, id),
        id,
        title: t.title,
        aboutUserId: t.about === 'A' ? a : b,
        summary: t.summary,
        followUpAfter: t.followUpAfter ?? undefined,
        status: 'open',
        sourceCallId: callId,
        createdAt: now.toISOString(),
      });
      topicsCreated++;
    }
  }
  await batchDelete(segs.map((s) => ({ pk: s.pk, sk: s.sk })));
  await update(K.call(callId), { summarized: true });
  await sendToUser(a, { type: 'call.summary.ready', callId, friendId: b });
  await sendToUser(b, { type: 'call.summary.ready', callId, friendId: a });
  return { allowed, segments: segs.length, topicsCreated };
}

export const handler = async (event: SQSEvent) => {
  for (const r of event.Records) {
    try {
      await summarize(JSON.parse(r.body).callId);
    } catch (e) {
      // The call is gone (e.g. an account was deleted): nothing to summarize, don't retry.
      if ((e as any)?.status === 404) continue;
      throw e;
    }
  }
};
