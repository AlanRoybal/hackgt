// APNs HTTP/2 sender with token (ES256 JWT) auth. Key material comes from SSM.
import http2 from 'node:http2';
import { GetParametersCommand, SSMClient } from '@aws-sdk/client-ssm';
import { SignJWT, importPKCS8 } from 'jose';
import { env } from './env.js';

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  p8: string;
  bundleId: string;
}

let configPromise: Promise<ApnsConfig | null> | undefined;
let missingSince = 0;
const MISSING_RETRY_MS = 60_000;

/**
 * Loads `/nudge/<stage>/apns/*`. Null when the key isn't configured yet (no Apple team). A miss is re-checked after
 * a minute so warm containers pick up newly stored keys without a redeploy.
 */
export function apnsConfig(): Promise<ApnsConfig | null> {
  if (missingSince && Date.now() - missingSince > MISSING_RETRY_MS) {
    configPromise = undefined;
    missingSince = 0;
  }
  configPromise ??= (async () => {
    const base = `/nudge/${env.stage}/apns`;
    try {
      const r = await new SSMClient({}).send(
        new GetParametersCommand({ Names: ['keyId', 'teamId', 'p8', 'bundleId'].map((n) => `${base}/${n}`), WithDecryption: true }),
      );
      const v = Object.fromEntries((r.Parameters ?? []).map((p) => [p.Name!.split('/').pop()!, p.Value!]));
      if (!v.keyId || !v.teamId || !v.p8 || !v.bundleId) {
        missingSince = Date.now();
        return null;
      }
      return v as unknown as ApnsConfig;
    } catch (e) {
      console.warn('apns config unavailable', (e as any)?.name);
      missingSince = Date.now();
      return null;
    }
  })();
  return configPromise;
}

let jwtCache: { token: string; at: number } | undefined;

export async function providerToken(cfg: ApnsConfig): Promise<string> {
  if (jwtCache && Date.now() - jwtCache.at < 50 * 60_000) return jwtCache.token;
  const key = await importPKCS8(cfg.p8, 'ES256');
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: cfg.keyId })
    .setIssuer(cfg.teamId)
    .setIssuedAt()
    .sign(key);
  jwtCache = { token, at: Date.now() };
  return token;
}

export type PushType = 'alert' | 'background' | 'voip';
export type ApnsEnv = 'sandbox' | 'production';

export interface ApnsRequest {
  token: string;
  env: ApnsEnv;
  type: PushType;
  payload: unknown;
  expiration?: number; // epoch seconds
  collapseId?: string;
}

export interface ApnsResult {
  status: number;
  reason?: string;
}

const sessions = new Map<string, http2.ClientHttp2Session>();

function session(host: string) {
  let s = sessions.get(host);
  if (!s || s.closed || s.destroyed) {
    s = http2.connect(`https://${host}`);
    s.on('error', () => sessions.delete(host));
    s.on('close', () => sessions.delete(host));
    sessions.set(host, s);
  }
  return s;
}

export async function sendApns(cfg: ApnsConfig, req: ApnsRequest): Promise<ApnsResult> {
  const host = req.env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
  const topic = req.type === 'voip' ? `${cfg.bundleId}.voip` : cfg.bundleId;
  const headers: http2.OutgoingHttpHeaders = {
    ':method': 'POST',
    ':path': `/3/device/${req.token}`,
    authorization: `bearer ${await providerToken(cfg)}`,
    'apns-topic': topic,
    'apns-push-type': req.type,
    'apns-priority': req.type === 'background' ? '5' : '10',
  };
  if (req.expiration !== undefined) headers['apns-expiration'] = String(req.expiration);
  if (req.collapseId) headers['apns-collapse-id'] = req.collapseId;
  const body = JSON.stringify(req.payload);
  return new Promise((resolve) => {
    const stream = session(host).request(headers);
    let status = 0;
    let data = '';
    stream.setTimeout(5000, () => {
      stream.close();
      resolve({ status: 0, reason: 'timeout' });
    });
    stream.on('response', (h) => (status = Number(h[':status'])));
    stream.on('data', (c) => (data += c));
    stream.on('end', () => {
      let reason: string | undefined;
      try {
        reason = data ? JSON.parse(data).reason : undefined;
      } catch {}
      resolve({ status, reason });
    });
    stream.on('error', (e) => resolve({ status: 0, reason: String(e) }));
    stream.end(body);
  });
}
