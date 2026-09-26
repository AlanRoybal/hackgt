// Smoke-checks Bedrock model access for every model the backend uses.
import { BedrockRuntimeClient, ConverseCommand, InvokeModelCommand } from '@aws-sdk/client-bedrock-runtime';

const br = new BedrockRuntimeClient({ region: 'us-east-1' });

const nova = await br.send(new ConverseCommand({
  modelId: 'amazon.nova-lite-v1:0',
  messages: [{ role: 'user', content: [{ text: 'Reply with exactly: ok' }] }],
}));
console.log('nova-lite:', nova.output?.message?.content?.[0]?.text);

const emb = await br.send(new InvokeModelCommand({
  modelId: 'amazon.titan-embed-image-v1',
  contentType: 'application/json',
  body: JSON.stringify({ inputText: 'a hike in the mountains', embeddingConfig: { outputEmbeddingLength: 1024 } }),
}));
const e = JSON.parse(new TextDecoder().decode(emb.body));
console.log('titan-embed dims:', e.embedding.length);
