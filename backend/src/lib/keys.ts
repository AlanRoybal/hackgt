// DynamoDB key builders for the single-table design (SPEC §3.1).
import { randomBytes, randomUUID } from 'node:crypto';

export const pairKey = (a: string, b: string) => [a, b].sort().join('_');
export const pairMembers = (key: string) => key.split('_') as [string, string];

export const K = {
  user: (id: string) => ({ pk: `USER#${id}`, sk: 'PROFILE' }),
  handle: (h: string) => ({ pk: `HANDLE#${h}`, sk: 'CLAIM' }),
  phone: (hash: string) => ({ pk: `PHONE#${hash}`, sk: 'CLAIM' }),
  device: (id: string, deviceId: string) => ({ pk: `USER#${id}`, sk: `DEVICE#${deviceId}` }),
  avail: (id: string) => ({ pk: `USER#${id}`, sk: 'AVAIL' }),
  freq: (to: string, from: string) => ({ pk: `USER#${to}`, sk: `FREQ#${from}` }),
  friend: (a: string, b: string) => ({ pk: `USER#${a}`, sk: `FRIEND#${b}` }),
  block: (a: string, b: string) => ({ pk: `USER#${a}`, sk: `BLOCK#${b}` }),
  tapToken: (token: string) => ({ pk: `TAP#${token}`, sk: 'META' }),
  tap: (from: string, to: string) => ({ pk: `USER#${from}`, sk: `TAP#${to}` }),
  nudge: (id: string) => ({ pk: `NUDGE#${id}`, sk: 'META' }),
  call: (id: string) => ({ pk: `CALL#${id}`, sk: 'META' }),
  suggestion: (callId: string, suggestionId: string) => ({ pk: `CALL#${callId}`, sk: `SUGG#${suggestionId}` }),
  share: (callId: string, shareId: string) => ({ pk: `CALL#${callId}`, sk: `SHARE#${shareId}` }),
  callLive: (callId: string, userId: string) => ({ pk: `CALL#${callId}`, sk: `LIVE#${userId}` }),
  photo: (id: string, assetHash: string) => ({ pk: `USER#${id}`, sk: `PHOTO#${assetHash}` }),
  topic: (pk: string, id: string) => ({ pk: `PAIR#${pk}`, sk: `TOPIC#${id}` }),
  summary: (pk: string, callId: string) => ({ pk: `PAIR#${pk}`, sk: `SUMMARY#${callId}` }),
  conn: (connId: string) => ({ pk: `CONN#${connId}`, sk: 'META' }),
};

export const segSk = (endMs: number, userId: string, segId: string) =>
  `SEG#${String(Math.max(0, Math.floor(endMs))).padStart(13, '0')}#${userId}#${segId}`;

export const newId = (prefix: string) => `${prefix}_${randomBytes(9).toString('base64url')}`;
export const uuid = () => randomUUID();
