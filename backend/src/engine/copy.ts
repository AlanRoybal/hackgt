// Nudge notification copy (SPEC NUD-7). Each viewer sees their own nickname for the friend.

/** Minutes rounded down to 5; "the next hour" at 60+. */
export function durationPhrase(minutes: number, withNext: boolean): string {
  if (minutes >= 60) return 'the next hour';
  const m = Math.max(5, Math.floor(minutes / 5) * 5);
  return withNext ? `the next ${m} minutes` : `${m} minutes`;
}

export function nudgeCopy(name: string, minutes: number, topicTitle?: string): { title: string; body: string } {
  const title = `A moment to catch up with ${name}?`;
  if (topicTitle) {
    return { title, body: `Your calendars look open for ${durationPhrase(minutes, false)}. Want to follow up about ${topicTitle}?` };
  }
  return { title, body: `Your calendars look open for ${durationPhrase(minutes, true)}. Call?` };
}

/** Copy for a direct "Call now" request. */
export function directCopy(recipientSeesName: string, callerSeesName: string) {
  return {
    recipient: { title: `${recipientSeesName} wants to call`, body: `${recipientSeesName} wants to call. Free?` },
    caller: { title: `Calling ${callerSeesName}`, body: `Waiting for ${callerSeesName}…` },
  };
}
