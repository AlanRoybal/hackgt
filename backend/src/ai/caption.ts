// Short searchable photo captions with Nova Lite (multimodal).
import { converse } from './bedrock.js';

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
