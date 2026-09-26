// WebSocket route `transcript` (SPEC REF-1).
import type { APIGatewayProxyWebsocketEventV2 } from 'aws-lambda';
import { get } from '../lib/db.js';
import { K } from '../lib/keys.js';
import { handleTranscript } from '../lib/references.js';

export const handler = async (event: APIGatewayProxyWebsocketEventV2) => {
  const conn = await get(K.conn(event.requestContext.connectionId));
  if (!conn) return { statusCode: 410, body: '' };
  let body: any;
  try {
    body = JSON.parse(event.body ?? '{}');
  } catch {
    return { statusCode: 400, body: '' };
  }
  if (typeof body.callId !== 'string' || typeof body.text !== 'string') return { statusCode: 400, body: '' };
  try {
    await handleTranscript(conn.userId, body);
  } catch (e) {
    console.error('transcript failed', e);
  }
  return { statusCode: 200, body: '' };
};
