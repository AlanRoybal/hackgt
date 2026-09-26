import { generateKeyPairSync } from 'node:crypto';
import { decodeProtectedHeader, importSPKI, jwtVerify } from 'jose';
import { describe, expect, it } from 'vitest';
import { providerToken } from '../src/lib/apns.js';

describe('APNs provider token', () => {
  it('is an ES256 JWT with kid = key id and iss = team id, verifiable with the key', async () => {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const p8 = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
    const token = await providerToken({ keyId: 'ABC123DEFG', teamId: 'TEAM123456', p8, bundleId: 'com.example.nudge' });
    expect(decodeProtectedHeader(token)).toEqual({ alg: 'ES256', kid: 'ABC123DEFG' });
    const pub = await importSPKI(publicKey.export({ type: 'spki', format: 'pem' }).toString(), 'ES256');
    const { payload } = await jwtVerify(token, pub, { issuer: 'TEAM123456' });
    expect(typeof payload.iat).toBe('number');
  });
});
