// Picks which eligible pairs get a nudge this run (SPEC NUD-6). Each user gets at most one.

export interface CandidatePair {
  pairKey: string;
  a: string;
  b: string;
  hasDueTopic: boolean;
  lastCallAt?: string;
}

export function rankPairs(pairs: CandidatePair[]): CandidatePair[] {
  const lastCall = (p: CandidatePair) => (p.lastCallAt ? Date.parse(p.lastCallAt) : -Infinity);
  return [...pairs].sort((x, y) => {
    if (x.hasDueTopic !== y.hasDueTopic) return x.hasDueTopic ? -1 : 1;
    const lx = lastCall(x);
    const ly = lastCall(y);
    if (lx !== ly) return lx < ly ? -1 : 1;
    return x.pairKey.localeCompare(y.pairKey);
  });
}

/** Greedy selection: best-ranked pairs first, skipping anyone already chosen. */
export function choosePairs(pairs: CandidatePair[]): CandidatePair[] {
  const used = new Set<string>();
  const out: CandidatePair[] = [];
  for (const p of rankPairs(pairs)) {
    if (used.has(p.a) || used.has(p.b)) continue;
    used.add(p.a);
    used.add(p.b);
    out.push(p);
  }
  return out;
}
