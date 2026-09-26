// Which shared memory a nudge should mention (SPEC NUD-7). Pure so it can be unit tested.

export interface TopicLike {
  id: string;
  title: string;
  status: string;
  followUpAfter?: string; // "YYYY-MM-DD"
  suggestedAt?: string;
  createdAt?: string;
}

export interface PickedTopic {
  id: string;
  title: string;
  /** followUpAfter has passed: the pair is ranked ahead of others. */
  due: boolean;
}

/** A topic suggested in a nudge that never became a call is offered again after this long. */
export const RESUGGEST_MS = 6 * 3_600_000;

/** Topics stop being suggested this long after their follow-up date; they stay in the friend's memories. */
export const TOPIC_EXPIRY_DAYS = 14;

/** Past its follow-up date by more than TOPIC_EXPIRY_DAYS. */
export function isExpired(t: Pick<TopicLike, 'followUpAfter'>, now: number): boolean {
  if (!t.followUpAfter) return false;
  return now - Date.parse(`${t.followUpAfter.slice(0, 10)}T00:00:00Z`) > TOPIC_EXPIRY_DAYS * 86_400_000;
}

function eligible(t: TopicLike, now: number): boolean {
  // A null followUpAfter means the summarizer judged it not worth following up on.
  if (!t.followUpAfter || !t.title || isExpired(t, now)) return false;
  if (t.status === 'open') return true;
  return t.status === 'suggested' && !!t.suggestedAt && now - Date.parse(t.suggestedAt) >= RESUGGEST_MS;
}

/**
 * Due topics first (oldest follow-up date first); otherwise the upcoming topic whose follow-up date is nearest, so
 * alerts carry context without waiting for the date to pass.
 */
export function pickTopic(topics: TopicLike[], now: number): PickedTopic | undefined {
  const today = new Date(now).toISOString().slice(0, 10);
  const best = topics
    .filter((t) => eligible(t, now))
    .sort((x, y) => x.followUpAfter!.localeCompare(y.followUpAfter!) || String(y.createdAt ?? '').localeCompare(String(x.createdAt ?? '')))[0];
  return best ? { id: best.id, title: best.title, due: best.followUpAfter! <= today } : undefined;
}
