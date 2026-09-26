// WebSocket routes: $connect, $disconnect, ping, waiting, $default (SPEC §3.8).
import type { APIGatewayProxyResultV2, APIGatewayProxyWebsocketEventV2 } from 'aws-lambda';
import { del, get, put, update } from '../lib/db.js';
import { verifyAccessToken } from '../lib/cognitoJwt.js';
import { K } from '../lib/keys.js';
import { postToConnection } from '../lib/ws.js';

type WsEvent = APIGatewayProxyWebsocketEventV2 & { queryStringParameters?: Record<string, string> };

const ok: APIGatewayProxyResultV2 = { statusCode: 200, body: '' };

export async function connect(event: WsEvent): Promise<APIGatewayProxyResultV2> {
  const token = event.queryStringParameters?.token;
  if (!token) return { statusCode: 401, body: 'missing token' };
  let sub: string;
  try {
    sub = (await verifyAccessToken(token)).sub;
  } catch {
    return { statusCode: 401, body: 'invalid token' };
  }
  const id = event.requestContext.connectionId;
  await put({
    ...K.conn(id),
    connectionId: id,
    userId: sub,
    connectedAt: new Date().toISOString(),
    ttl: Math.floor(Date.now() / 1000) + 3 * 3600,
    gsi1pk: `CONNUSER#${sub}`,
    gsi1sk: id,
  });
  return ok;
}

export async function disconnect(event: WsEvent): Promise<APIGatewayProxyResultV2> {
  await del(K.conn(event.requestContext.connectionId)).catch(() => {});
  return ok;
}

/** Handles `ping`, `waiting`, and anything unrouted. */
export async function message(event: WsEvent): Promise<APIGatewayProxyResultV2> {
  const id = event.requestContext.connectionId;
  let body: any = {};
  try {
    body = JSON.parse(event.body ?? '{}');
  } catch {}
  const conn = await get(K.conn(id));
  if (!conn) return { statusCode: 410, body: 'unknown connection' };
  // Any message keeps the connection record alive.
  const ttl = Math.floor(Date.now() / 1000) + 3 * 3600;
  switch (body.action) {
    case 'ping':
      await update(K.conn(id), { ttl });
      await postToConnection(id, { type: 'pong' });
      return ok;
    case 'waiting': {
      const nudgeId = typeof body.nudgeId === 'string' ? body.nudgeId : undefined;
      await update(K.conn(id), { waitingNudgeId: nudgeId, ttl });
      return ok;
    }
    default:
      await postToConnection(id, { type: 'error', message: `unknown action ${String(body.action)}` });
      return ok;
  }
}
