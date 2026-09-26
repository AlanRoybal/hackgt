// HTTP API (payload v2) router + error handling.
import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyResultV2 } from 'aws-lambda';

export type Event = APIGatewayProxyEventV2WithJWTAuthorizer;

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

export const bad = (code: string, message?: string) => new HttpError(400, code, message);
export const notFound = (code = 'not_found') => new HttpError(404, code);
export const forbidden = (code = 'forbidden') => new HttpError(403, code);
export const conflict = (code: string) => new HttpError(409, code);

export interface Ctx {
  event: Event;
  userId: string;
  username: string;
  accessToken: string;
  params: Record<string, string>;
  query: Record<string, string>;
  body: any;
}

export type Route = (ctx: Ctx) => Promise<unknown>;

/** A response with a non-200 status. */
export class Res {
  constructor(public status: number, public body?: unknown) {}
}

export function parseBody(event: { body?: string; isBase64Encoded?: boolean }): any {
  if (!event.body) return {};
  const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
  try {
    return JSON.parse(raw);
  } catch {
    throw bad('invalid_json');
  }
}

export const json = (status: number, body?: unknown): APIGatewayProxyResultV2 => ({
  statusCode: status,
  headers: { 'content-type': 'application/json' },
  body: body === undefined ? '' : JSON.stringify(body),
});

/** Builds a Lambda handler dispatching on `routeKey` ("GET /me"). */
export function router(routes: Record<string, Route>, opts: { public?: boolean } = {}) {
  return async (event: Event): Promise<APIGatewayProxyResultV2> => {
    const route = routes[event.routeKey];
    if (!route) return json(404, { error: { code: 'no_route', message: event.routeKey } });
    try {
      const claims = (event.requestContext as any)?.authorizer?.jwt?.claims ?? {};
      const userId = String(claims.sub ?? '');
      if (!opts.public && !userId) throw new HttpError(401, 'unauthorized');
      const auth = event.headers?.authorization ?? event.headers?.Authorization ?? '';
      const ctx: Ctx = {
        event,
        userId,
        username: String(claims.username ?? ''),
        accessToken: auth.replace(/^Bearer\s+/i, ''),
        params: (event.pathParameters ?? {}) as Record<string, string>,
        query: (event.queryStringParameters ?? {}) as Record<string, string>,
        body: parseBody(event),
      };
      const out = await route(ctx);
      if (out instanceof Res) return json(out.status, out.body);
      if (out === undefined) return json(204);
      return json(200, out);
    } catch (e) {
      if (e instanceof HttpError) return json(e.status, { error: { code: e.code, message: e.message } });
      const name = (e as any)?.name;
      if (name === 'NotAuthorizedException') return json(401, { error: { code: 'unauthorized', message: String((e as any).message) } });
      if (name === 'CodeMismatchException') return json(400, { error: { code: 'code_mismatch', message: 'Wrong code' } });
      if (name === 'ExpiredCodeException') return json(400, { error: { code: 'code_expired', message: 'Code expired' } });
      console.error('unhandled', e);
      return json(500, { error: { code: 'internal', message: 'Something went wrong' } });
    }
  };
}
