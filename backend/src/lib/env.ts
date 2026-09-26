// Environment configuration injected by the CDK stack.

const req = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing env ${k}`);
  return v;
};

export const env = {
  get stage() { return process.env.STAGE ?? 'dev'; },
  get isDev() { return (process.env.STAGE ?? 'dev') === 'dev'; },
  get region() { return process.env.AWS_REGION ?? 'us-east-1'; },
  get table() { return req('TABLE_NAME'); },
  get bucket() { return req('MEDIA_BUCKET'); },
  get userPoolId() { return req('USER_POOL_ID'); },
  get userPoolClientId() { return req('USER_POOL_CLIENT_ID'); },
  get identityPoolId() { return process.env.IDENTITY_POOL_ID ?? ''; },
  get wsEndpoint() { return req('WS_ENDPOINT'); },
  get delayQueueUrl() { return req('DELAY_QUEUE_URL'); },
  get summarizeQueueUrl() { return req('SUMMARIZE_QUEUE_URL'); },
  get vectorBucket() { return req('VECTOR_BUCKET'); },
  get vectorIndex() { return process.env.VECTOR_INDEX ?? 'photos'; },
  get currentTosVersion() { return process.env.TOS_VERSION ?? '2026-09-26'; },
  get similarityThreshold() { return Number(process.env.SIMILARITY_THRESHOLD ?? '0.37'); },
};
