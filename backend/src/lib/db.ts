// Thin DynamoDB DocumentClient helpers for the single table.
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  BatchGetCommand,
  BatchWriteCommand,
  DeleteCommand,
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
  type QueryCommandInput,
} from '@aws-sdk/lib-dynamodb';
import { env } from './env.js';

export const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true, convertClassInstanceToMap: true },
});

export type Key = { pk: string; sk: string };
export type Item = Record<string, any> & Key;

export async function get<T = Item>(key: Key): Promise<T | undefined> {
  const r = await ddb.send(new GetCommand({ TableName: env.table, Key: key }));
  return r.Item as T | undefined;
}

export async function put(item: Item, condition?: string, values?: Record<string, unknown>): Promise<void> {
  await ddb.send(
    new PutCommand({ TableName: env.table, Item: item, ConditionExpression: condition, ExpressionAttributeValues: values }),
  );
}

export async function del(key: Key, condition?: string): Promise<void> {
  await ddb.send(new DeleteCommand({ TableName: env.table, Key: key, ConditionExpression: condition }));
}

/** Sets the given attributes (undefined values are removed). */
export async function update(
  key: Key,
  set: Record<string, unknown>,
  opts: { condition?: string; values?: Record<string, unknown>; names?: Record<string, string> } = {},
): Promise<Item> {
  const names: Record<string, string> = { ...(opts.names ?? {}) };
  const values: Record<string, unknown> = { ...(opts.values ?? {}) };
  const sets: string[] = [];
  const removes: string[] = [];
  Object.entries(set).forEach(([k, v], i) => {
    names[`#u${i}`] = k;
    if (v === undefined) removes.push(`#u${i}`);
    else {
      values[`:u${i}`] = v;
      sets.push(`#u${i} = :u${i}`);
    }
  });
  const expr = [sets.length ? `SET ${sets.join(', ')}` : '', removes.length ? `REMOVE ${removes.join(', ')}` : '']
    .filter(Boolean)
    .join(' ');
  const r = await ddb.send(
    new UpdateCommand({
      TableName: env.table,
      Key: key,
      UpdateExpression: expr,
      ConditionExpression: opts.condition,
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: Object.keys(values).length ? values : undefined,
      ReturnValues: 'ALL_NEW',
    }),
  );
  return r.Attributes as Item;
}

export async function query<T = Item>(input: Omit<QueryCommandInput, 'TableName'>, all = true): Promise<T[]> {
  const out: T[] = [];
  let ExclusiveStartKey: Record<string, any> | undefined;
  do {
    const r = await ddb.send(new QueryCommand({ TableName: env.table, ...input, ExclusiveStartKey }));
    out.push(...((r.Items ?? []) as T[]));
    ExclusiveStartKey = all ? r.LastEvaluatedKey : undefined;
    if (input.Limit && out.length >= input.Limit) break;
  } while (ExclusiveStartKey);
  return out;
}

/** All items in a partition whose sort key begins with `prefix`. */
export const queryPrefix = <T = Item>(pk: string, prefix: string, opts: { desc?: boolean; limit?: number } = {}) =>
  query<T>(
    {
      KeyConditionExpression: 'pk = :pk AND begins_with(sk, :p)',
      ExpressionAttributeValues: { ':pk': pk, ':p': prefix },
      ScanIndexForward: !opts.desc,
      Limit: opts.limit,
    },
    !opts.limit,
  );

/** Every item in a partition. */
export const queryPartition = <T = Item>(pk: string) =>
  query<T>({ KeyConditionExpression: 'pk = :pk', ExpressionAttributeValues: { ':pk': pk } });

export const queryGsi =<T = Item>(gsi1pk: string, prefix?: string, opts: { limit?: number; desc?: boolean } = {}) =>
  query<T>(
    {
      IndexName: 'gsi1',
      KeyConditionExpression: prefix ? 'gsi1pk = :pk AND begins_with(gsi1sk, :p)' : 'gsi1pk = :pk',
      ExpressionAttributeValues: prefix ? { ':pk': gsi1pk, ':p': prefix } : { ':pk': gsi1pk },
      Limit: opts.limit,
      ScanIndexForward: !opts.desc,
    },
    !opts.limit,
  );

export async function batchGet<T = Item>(keys: Key[]): Promise<T[]> {
  const unique = [...new Map(keys.map((k) => [`${k.pk}|${k.sk}`, k])).values()];
  const out: T[] = [];
  for (let i = 0; i < unique.length; i += 100) {
    let req: Record<string, any> | undefined = { [env.table]: { Keys: unique.slice(i, i + 100) } };
    while (req && Object.keys(req).length) {
      const r: any = await ddb.send(new BatchGetCommand({ RequestItems: req }));
      out.push(...((r.Responses?.[env.table] ?? []) as T[]));
      req = r.UnprocessedKeys && Object.keys(r.UnprocessedKeys).length ? r.UnprocessedKeys : undefined;
    }
  }
  return out;
}

export async function batchDelete(keys: Key[]): Promise<void> {
  const unique = [...new Map(keys.map((k) => [`${k.pk}|${k.sk}`, { pk: k.pk, sk: k.sk }])).values()];
  for (let i = 0; i < unique.length; i += 25) {
    let req: Record<string, any> | undefined = {
      [env.table]: unique.slice(i, i + 25).map((Key) => ({ DeleteRequest: { Key } })),
    };
    while (req && Object.keys(req).length) {
      const r: any = await ddb.send(new BatchWriteCommand({ RequestItems: req }));
      req = r.UnprocessedItems && Object.keys(r.UnprocessedItems).length ? r.UnprocessedItems : undefined;
    }
  }
}

export const isConditionalFailure = (e: unknown) => (e as { name?: string })?.name === 'ConditionalCheckFailedException';
