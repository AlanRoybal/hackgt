// Verifies Cognito access tokens outside API Gateway's JWT authorizer (WebSocket $connect).
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { env } from './env.js';

let jwks: ReturnType<typeof createRemoteJWKSet> | undefined;

export async function verifyAccessToken(token: string): Promise<{ sub: string; username: string }> {
  const issuer = `https://cognito-idp.${env.region}.amazonaws.com/${env.userPoolId}`;
  jwks ??= createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));
  const { payload } = await jwtVerify(token, jwks, { issuer });
  if (payload.token_use !== 'access' || payload.client_id !== env.userPoolClientId) throw new Error('wrong token type');
  return { sub: String(payload.sub), username: String(payload.username ?? '') };
}
