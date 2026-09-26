// Scheduler + SQS entry points: matcher (every 5 min), nudge delay queue (pre-check, expiry).
import type { SQSEvent } from 'aws-lambda';
import { expireNudge, precheck, runMatcher } from '../lib/matcher.js';

export const matcher = async () => {
  const r = await runMatcher();
  console.log(JSON.stringify({ msg: 'matcher', considered: r.considered, created: r.created.length }));
  return r;
};

export const delay = async (event: SQSEvent) => {
  for (const rec of event.Records) {
    const msg = JSON.parse(rec.body) as { kind: 'precheck' | 'expire'; nudgeId: string };
    try {
      if (msg.kind === 'precheck') await precheck(msg.nudgeId);
      else if (msg.kind === 'expire') await expireNudge(msg.nudgeId);
    } catch (e) {
      // Invalid-state errors mean someone already responded; nothing to retry.
      if ((e as any)?.status === 409) continue;
      throw e;
    }
  }
};
