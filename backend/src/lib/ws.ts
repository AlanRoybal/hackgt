// Sending server → client WebSocket events (SPEC §3.8).
import {
  ApiGatewayManagementApiClient,
  GoneException,
  PostToConnectionCommand,
} from '@aws-sdk/client-apigatewaymanagementapi';
import { del, queryGsi } from './db.js';
import { env } from './env.js';
import { K } from './keys.js';

let client: ApiGatewayManagementApiClient | undefined;
const api = () => (client ??= new ApiGatewayManagementApiClient({ endpoint: env.wsEndpoint }));

export interface Conn {
  connectionId: string;
  userId: string;
  waitingNudgeId?: string;
  activeCallId?: string;
}

export const connectionsFor = (userId: string) => queryGsi<Conn>(`CONNUSER#${userId}`);

export async function postToConnection(connectionId: string, event: unknown): Promise<boolean> {
  try {
    await api().send(new PostToConnectionCommand({ ConnectionId: connectionId, Data: Buffer.from(JSON.stringify(event)) }));
    return true;
  } catch (e) {
    if (e instanceof GoneException || (e as any)?.name === 'GoneException' || (e as any)?.$metadata?.httpStatusCode === 410) {
      await del(K.conn(connectionId)).catch(() => {});
      return false;
    }
    console.warn('ws post failed', connectionId, (e as any)?.name);
    return false;
  }
}

/** Sends an event to every live connection of a user. Returns the number delivered. */
export async function sendToUser(userId: string, event: unknown): Promise<number> {
  const conns = await connectionsFor(userId);
  const results = await Promise.all(conns.map((c) => postToConnection(c.connectionId, event)));
  return results.filter(Boolean).length;
}
