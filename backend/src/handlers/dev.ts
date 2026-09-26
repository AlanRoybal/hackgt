// Dev-only hooks for integration tests (routes exist only when stage=dev).
import { adminSetPhone } from '../lib/cognito.js';
import { queryPrefix } from '../lib/db.js';
import { env } from '../lib/env.js';
import { bad, notFound, router } from '../lib/http.js';
import { forceExpire, runMatcher } from '../lib/matcher.js';
import { getUser, meResponse } from '../lib/users.js';
import { claimPhone } from './me.js';
import { summarize } from './summarizer.js';
import { sweep } from './photoSweep.js';

const guard = () => {
  if (!env.isDev) throw notFound();
};

export const handler = router({
  'POST /dev/matcher/run': async ({ body }) => {
    guard();
    const now = body.now ? Date.parse(body.now) : undefined;
    return runMatcher({
      now,
      onlyUserIds: Array.isArray(body.onlyUserIds) ? body.onlyUserIds : undefined,
      immediate: body.immediate !== false,
    });
  },
  'GET /dev/pushes/{userId}': async ({ params }) => {
    guard();
    const items = await queryPrefix(`PUSHLOG#${params.userId}`, '2', { desc: true });
    return { pushes: items.map((i) => ({ kind: i.kind, payload: i.payload, createdAt: i.createdAt })) };
  },
  'POST /dev/nudges/{id}/expire': async ({ params }) => {
    guard();
    const n = await forceExpire(params.id);
    return { state: n.state };
  },
  'POST /dev/calls/{id}/summarize': async ({ params }) => {
    guard();
    return summarize(params.id);
  },
  'POST /dev/phone/verify': async ({ body }) => {
    guard();
    if (typeof body.userId !== 'string' || typeof body.phone !== 'string') throw bad('invalid');
    const u = await getUser(body.userId);
    await adminSetPhone(u.username, body.phone);
    return meResponse(await claimPhone(u, body.phone));
  },
  'POST /dev/photos/sweep': async () => {
    guard();
    return sweep();
  },
});
