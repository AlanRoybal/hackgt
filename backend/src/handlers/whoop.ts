import { router } from '../lib/http.js';
import { whoopStatus, startWhoop, finishWhoop, setWhoopOptions, disconnectWhoop, syncWhoopConnections } from '../lib/whoop.js';
export const handler = router({
  'GET /me/whoop': async ({ userId }) => whoopStatus(userId),
  'POST /me/whoop/connect': async ({ userId }) => startWhoop(userId),
  'POST /me/whoop/callback': async ({ userId, body }) => finishWhoop(userId, body.code, body.state),
  'PATCH /me/whoop': async ({ userId, body }) => setWhoopOptions(userId, body),
  'DELETE /me/whoop': async ({ userId }) => disconnectWhoop(userId),
});
export const sync = syncWhoopConnections;
