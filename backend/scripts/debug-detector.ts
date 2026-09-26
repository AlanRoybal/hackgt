// Prints the raw detector model output for one transcript (debugging aid).
import { converse } from '../src/ai/bedrock.js';
import { DETECTOR_SYSTEM, formatTranscript } from '../src/ai/detector.js';

const segs = [
  { userId: 'f', text: 'What did you do this weekend?' },
  { userId: 's', text: 'We hiked up to this crazy mountain lake on Saturday, the water was so blue.' },
];
const text = await converse({
  system: DETECTOR_SYSTEM,
  maxTokens: 150,
  messages: [{ role: 'user', content: [{ text: `TODAY: 2026-09-26 (Saturday)\n\nTranscript:\n${formatTranscript(segs, 's')}\n\nJSON:` }] }],
});
console.log(JSON.stringify(text));
