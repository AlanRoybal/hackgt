// Short searchable photo and video captions with Nova Lite (multimodal).
import { converse, extractJson } from './bedrock.js';

const SYSTEM = `You write short captions for personal camera-roll photos so they can be found later by what people say in conversation.
Describe concrete, searchable content: the main subject, activity, setting, notable objects, food, animals, weather, time of day, and any readable sign or landmark name.
One or two plain sentences, at most 40 words. No speculation about names or feelings. No preamble.`;

export async function captionImage(jpeg: Buffer): Promise<string> {
  const text = await converse({
    system: SYSTEM,
    maxTokens: 120,
    messages: [
      {
        role: 'user',
        content: [{ image: { format: 'jpeg', source: { bytes: new Uint8Array(jpeg) } } }, { text: 'Caption this photo.' }],
      },
    ],
  });
  return text.trim().replace(/^caption:\s*/i, '');
}

const VIDEO_SYSTEM = `You write short captions for short personal camera-roll videos so they can be found later by what people say in conversation.
Describe concrete, searchable content: the main subject, what happens, setting, notable objects, food, animals, weather, time of day, and any readable sign or landmark name.
Also judge whether the clip shows nudity, sexual content, graphic violence, or a readable document with private data (IDs, cards, bank or medical details).
Return JSON only: {"caption": "one or two plain sentences, at most 40 words", "sensitive": false}`;

export interface VideoCaption {
  caption: string;
  sensitive: boolean;
}

export function parseVideoCaption(text: string): VideoCaption | undefined {
  const v = extractJson<{ caption?: unknown; sensitive?: unknown }>(text);
  if (!v || typeof v.caption !== 'string' || !v.caption.trim()) return undefined;
  return { caption: v.caption.trim().replace(/^caption:\s*/i, ''), sensitive: v.sensitive === true };
}

/** Captions the clip itself (Nova Lite reads mp4) so motion and events are searchable, not just the poster frame. */
export async function captionVideo(mp4: Buffer): Promise<VideoCaption | undefined> {
  const text = await converse({
    system: VIDEO_SYSTEM,
    maxTokens: 160,
    messages: [
      {
        role: 'user',
        content: [{ video: { format: 'mp4', source: { bytes: new Uint8Array(mp4) } } }, { text: 'Caption this video.' }],
      },
    ],
  });
  return parseVideoCaption(text);
}
