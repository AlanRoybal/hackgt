// Cognito user management and server-side token minting (D-3).
import { randomBytes } from 'node:crypto';
import {
  AdminCreateUserCommand,
  AdminDeleteUserCommand,
  AdminGetUserCommand,
  AdminInitiateAuthCommand,
  AdminSetUserPasswordCommand,
  AdminUpdateUserAttributesCommand,
  CognitoIdentityProviderClient,
  InitiateAuthCommand,
  UpdateUserAttributesCommand,
  VerifyUserAttributeCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { env } from './env.js';

export const cognito = new CognitoIdentityProviderClient({});

export interface Tokens {
  accessToken: string;
  idToken: string;
  refreshToken?: string;
  expiresIn: number;
}

const attr = (attrs: { Name?: string; Value?: string }[] | undefined, name: string) => attrs?.find((a) => a.Name === name)?.Value;

/** Returns the user's `sub`, creating the Cognito user if needed. */
export async function ensureUser(username: string): Promise<{ sub: string; created: boolean }> {
  try {
    const u = await cognito.send(new AdminGetUserCommand({ UserPoolId: env.userPoolId, Username: username }));
    return { sub: attr(u.UserAttributes, 'sub')!, created: false };
  } catch (e) {
    if ((e as any)?.name !== 'UserNotFoundException') throw e;
  }
  try {
    const r = await cognito.send(
      new AdminCreateUserCommand({ UserPoolId: env.userPoolId, Username: username, MessageAction: 'SUPPRESS' }),
    );
    return { sub: attr(r.User?.Attributes, 'sub')!, created: true };
  } catch (e) {
    if ((e as any)?.name !== 'UsernameExistsException') throw e;
    const u = await cognito.send(new AdminGetUserCommand({ UserPoolId: env.userPoolId, Username: username }));
    return { sub: attr(u.UserAttributes, 'sub')!, created: false };
  }
}

const randomPassword = () => `${randomBytes(24).toString('base64url')}Aa1!`;

/** Sets a fresh random password and signs in with it (identity already proven by the caller). */
export async function mintTokens(username: string): Promise<Tokens> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    const password = randomPassword();
    try {
      await cognito.send(
        new AdminSetUserPasswordCommand({ UserPoolId: env.userPoolId, Username: username, Password: password, Permanent: true }),
      );
      const r = await cognito.send(
        new AdminInitiateAuthCommand({
          UserPoolId: env.userPoolId,
          ClientId: env.userPoolClientId,
          AuthFlow: 'ADMIN_USER_PASSWORD_AUTH',
          AuthParameters: { USERNAME: username, PASSWORD: password },
        }),
      );
      const a = r.AuthenticationResult!;
      return { accessToken: a.AccessToken!, idToken: a.IdToken!, refreshToken: a.RefreshToken, expiresIn: a.ExpiresIn ?? 3600 };
    } catch (e) {
      // A concurrent sign-in may have rotated the password between our two calls; retry.
      lastErr = e;
      if ((e as any)?.name !== 'NotAuthorizedException') throw e;
    }
  }
  throw lastErr;
}

export async function refreshTokens(refreshToken: string): Promise<Tokens> {
  const r = await cognito.send(
    new InitiateAuthCommand({
      ClientId: env.userPoolClientId,
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      AuthParameters: { REFRESH_TOKEN: refreshToken },
    }),
  );
  const a = r.AuthenticationResult!;
  return { accessToken: a.AccessToken!, idToken: a.IdToken!, expiresIn: a.ExpiresIn ?? 3600 };
}

export const deleteCognitoUser = (username: string) =>
  cognito.send(new AdminDeleteUserCommand({ UserPoolId: env.userPoolId, Username: username }));

/** Starts phone verification; Cognito sends the SMS code. */
export const startPhoneVerification = (accessToken: string, phone: string) =>
  cognito.send(new UpdateUserAttributesCommand({ AccessToken: accessToken, UserAttributes: [{ Name: 'phone_number', Value: phone }] }));

export const confirmPhone = (accessToken: string, code: string) =>
  cognito.send(new VerifyUserAttributeCommand({ AccessToken: accessToken, AttributeName: 'phone_number', Code: code }));

export async function getPhone(username: string): Promise<{ phone?: string; verified: boolean }> {
  const u = await cognito.send(new AdminGetUserCommand({ UserPoolId: env.userPoolId, Username: username }));
  return { phone: attr(u.UserAttributes, 'phone_number'), verified: attr(u.UserAttributes, 'phone_number_verified') === 'true' };
}

export const adminSetPhone = (username: string, phone: string | null) =>
  cognito.send(
    new AdminUpdateUserAttributesCommand({
      UserPoolId: env.userPoolId,
      Username: username,
      UserAttributes: phone
        ? [
            { Name: 'phone_number', Value: phone },
            { Name: 'phone_number_verified', Value: 'true' },
          ]
        : [{ Name: 'phone_number', Value: '' }],
    }),
  );
