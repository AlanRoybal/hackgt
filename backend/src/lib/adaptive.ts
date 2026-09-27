import { TransactWriteCommand, type TransactWriteCommandInput } from '@aws-sdk/lib-dynamodb';
import { appendResponse, HOUR, type ResponseSample } from '../engine/adaptive.js';
import type { NudgeEvent, MachineNudge } from '../engine/state.js';
import { ddb, get } from './db.js';
import { env } from './env.js';
import type { NudgeItem } from './flows.js';
import { K } from './keys.js';
import type { UserItem } from './users.js';

/** Feedback and the transition commit together: no lost samples or duplicate retry effects. */
export async function commitNudgeTransition(n: NudgeItem, next: MachineNudge, event: NudgeEvent, now = Date.now()): Promise<NudgeItem> {
  const items: NonNullable<TransactWriteCommandInput['TransactItems']> = [{ Update: {
    TableName: env.table, Key: K.nudge(n.id),
    UpdateExpression: 'SET #s = :s, responses = :r, #v = :next',
    ConditionExpression: '#v = :v', ExpressionAttributeNames: { '#s': 'state', '#v': 'version' },
    ExpressionAttributeValues: { ':s': next.state, ':r': next.responses, ':v': n.version, ':next': n.version + 1 },
  } }];
  const feedback: { userId: string; outcome: ResponseSample['outcome']; pause: boolean }[] = [];
  if (event.type === 'respond' && (n.kind === 'auto' || event.action === 'pause')) {
    feedback.push({ userId: event.userId, outcome: event.action === 'accept' ? 'accept' : 'skip', pause: event.action === 'pause' });
  } else if (event.type === 'expire' && n.kind === 'auto') {
    for (const userId of n.participants) if (!n.responses[userId]) feedback.push({ userId, outcome: 'expired', pause: false });
  }
  for (const f of feedback) {
    const user = await get<UserItem>(K.user(f.userId), { consistent: true });
    if (!user) throw new Error('feedback_user_missing');
    const adaptive = n.kind === 'auto' ? appendResponse(user.adaptive, {
      id: n.id, at: new Date(now).toISOString(), offeredAt: n.sentAt ?? n.createdAt, outcome: f.outcome,
    }, now) : user.adaptive ?? { samples: [] };
    items.push({ Update: {
      TableName: env.table, Key: K.user(f.userId),
      UpdateExpression: 'SET adaptive = :a, adaptiveVersion = :next' + (f.pause ? ', nudgePausedUntil = :pause' : ''),
      ConditionExpression: 'attribute_exists(pk) AND ' + (user.adaptiveVersion === undefined ? 'attribute_not_exists(adaptiveVersion)' : 'adaptiveVersion = :v'),
      ExpressionAttributeValues: {
        ':a': adaptive, ':next': (user.adaptiveVersion ?? 0) + 1,
        ...(user.adaptiveVersion === undefined ? {} : { ':v': user.adaptiveVersion }),
        ...(f.pause ? { ':pause': new Date(now + HOUR).toISOString() } : {}),
      },
    } });
  }
  await ddb.send(new TransactWriteCommand({ TransactItems: items }));
  return { ...n, state: next.state, responses: next.responses, version: n.version + 1 };
}
export function isTransitionConflict(error: unknown): boolean {
  const e = error as { name?: string; CancellationReasons?: { Code?: string }[] };
  return e.name === 'TransactionCanceledException' && !!e.CancellationReasons?.some(r => r.Code === 'ConditionalCheckFailed' || r.Code === 'TransactionConflict');
}
