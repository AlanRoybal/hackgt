// Prints recent log lines for one Lambda: npx tsx scripts/logs.ts <fn> [minutes] [filter]
import { CloudWatchLogsClient, DescribeLogGroupsCommand, FilterLogEventsCommand } from '@aws-sdk/client-cloudwatch-logs';

const [fn, minutes = '15', filter = ''] = process.argv.slice(2);
const cw = new CloudWatchLogsClient({ region: 'us-east-1' });
const groups = await cw.send(new DescribeLogGroupsCommand({ logGroupNamePrefix: `Nudge-dev-${fn}Logs` }));
const logGroupName = groups.logGroups?.[0]?.logGroupName;
if (!logGroupName) throw new Error(`no log group for ${fn}`);
let nextToken: string | undefined;
do {
  const r = await cw.send(
    new FilterLogEventsCommand({
      logGroupName,
      startTime: Date.now() - Number(minutes) * 60_000,
      filterPattern: filter || undefined,
      nextToken,
    }),
  );
  for (const e of r.events ?? []) console.log(e.message?.trim());
  nextToken = r.nextToken;
} while (nextToken);
