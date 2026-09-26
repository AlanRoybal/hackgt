// Everything in SPEC §4.3, serverless and pay-per-request only.
import { CfnOutput, Duration, RemovalPolicy, Stack, type StackProps } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpJwtAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration, WebSocketLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { SqsEventSource } from 'aws-cdk-lib/aws-lambda-event-sources';
import { NodejsFunction, OutputFormat } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import * as s3vectors from 'aws-cdk-lib/aws-s3vectors';
import * as scheduler from 'aws-cdk-lib/aws-scheduler';
import * as targets from 'aws-cdk-lib/aws-scheduler-targets';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import type { Construct } from 'constructs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = (f: string) => path.join(here, '..', 'src', 'handlers', f);

export interface NudgeStackProps extends StackProps {
  stage: string;
  budgetEmail?: string;
}

export class NudgeStack extends Stack {
  constructor(scope: Construct, id: string, props: NudgeStackProps) {
    super(scope, id, props);
    const { stage } = props;
    const isDev = stage === 'dev';
    const removalPolicy = RemovalPolicy.DESTROY;

    // Data -----------------------------------------------------------------------------------
    const table = new dynamodb.TableV2(this, 'Table', {
      tableName: `Nudge-${stage}`,
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
      billing: dynamodb.Billing.onDemand(),
      timeToLiveAttribute: 'ttl',
      globalSecondaryIndexes: [
        {
          indexName: 'gsi1',
          partitionKey: { name: 'gsi1pk', type: dynamodb.AttributeType.STRING },
          sortKey: { name: 'gsi1sk', type: dynamodb.AttributeType.STRING },
        },
      ],
      removalPolicy,
    });

    const bucket = new s3.Bucket(this, 'Media', {
      bucketName: `nudge-media-${stage}-${this.account}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      lifecycleRules: [{ prefix: 'photos/', expiration: Duration.days(31) }],
      removalPolicy,
      autoDeleteObjects: true,
    });

    const vectorBucketName = `nudge-vectors-${stage}-${this.account}`;
    const vectorBucket = new s3vectors.CfnVectorBucket(this, 'VectorBucket', { vectorBucketName });
    vectorBucket.applyRemovalPolicy(removalPolicy);
    const vectorIndex = new s3vectors.CfnIndex(this, 'VectorIndex', {
      vectorBucketName,
      indexName: 'photos',
      dataType: 'float32',
      dimension: 1024,
      distanceMetric: 'cosine',
      metadataConfiguration: { nonFilterableMetadataKeys: ['caption'] },
    });
    vectorIndex.addResourceDependency(vectorBucket);
    vectorIndex.applyRemovalPolicy(removalPolicy);
    const captionVectorIndex = new s3vectors.CfnIndex(this, 'CaptionVectorIndex', {
      vectorBucketName,
      indexName: 'photo-captions',
      dataType: 'float32',
      dimension: 1024,
      distanceMetric: 'cosine',
    });
    captionVectorIndex.addResourceDependency(vectorBucket);
    captionVectorIndex.applyRemovalPolicy(removalPolicy);

    const dlq = new sqs.Queue(this, 'DeadLetters', { retentionPeriod: Duration.days(4), removalPolicy });
    const delayQueue = new sqs.Queue(this, 'NudgeDelay', {
      visibilityTimeout: Duration.seconds(180),
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
      removalPolicy,
    });
    const summarizeQueue = new sqs.Queue(this, 'Summarize', {
      visibilityTimeout: Duration.seconds(360),
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
      removalPolicy,
    });

    // Auth -----------------------------------------------------------------------------------
    const userPool = new cognito.UserPool(this, 'Users', {
      userPoolName: `nudge-${stage}`,
      selfSignUpEnabled: false,
      signInAliases: { username: true },
      autoVerify: { phone: true },
      standardAttributes: { phoneNumber: { required: false, mutable: true } },
      accountRecovery: cognito.AccountRecovery.NONE,
      removalPolicy,
    });
    const client = userPool.addClient('App', {
      authFlows: { adminUserPassword: true },
      generateSecret: false,
      preventUserExistenceErrors: true,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(60),
    });

    const identityPool = new cognito.CfnIdentityPool(this, 'TranscribeIdentities', {
      identityPoolName: `nudge_${stage}_transcribe`,
      allowUnauthenticatedIdentities: false,
      cognitoIdentityProviders: [{ clientId: client.userPoolClientId, providerName: userPool.userPoolProviderName }],
    });
    const transcribeRole = new iam.Role(this, 'TranscribeRole', {
      assumedBy: new iam.FederatedPrincipal(
        'cognito-identity.amazonaws.com',
        {
          StringEquals: { 'cognito-identity.amazonaws.com:aud': identityPool.ref },
          'ForAnyValue:StringLike': { 'cognito-identity.amazonaws.com:amr': 'authenticated' },
        },
        'sts:AssumeRoleWithWebIdentity',
      ),
      description: 'Authenticated app users: live transcription only',
    });
    transcribeRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['transcribe:StartStreamTranscription', 'transcribe:StartStreamTranscriptionWebSocket'],
        resources: ['*'],
      }),
    );
    new cognito.CfnIdentityPoolRoleAttachment(this, 'TranscribeRoles', {
      identityPoolId: identityPool.ref,
      roles: { authenticated: transcribeRole.roleArn },
    });

    // Compute --------------------------------------------------------------------------------
    const role = new iam.Role(this, 'FnRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole')],
    });
    table.grantReadWriteData(role);
    bucket.grantReadWrite(role);
    bucket.grantDelete(role);
    delayQueue.grantSendMessages(role);
    summarizeQueue.grantSendMessages(role);
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel'],
        resources: [
          `arn:aws:bedrock:${this.region}::foundation-model/amazon.nova-lite-v1:0`,
          `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-image-v1`,
        ],
      }),
    );
    role.addToPolicy(new iam.PolicyStatement({ actions: ['rekognition:DetectModerationLabels', 'rekognition:DetectText'], resources: ['*'] }));
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['chime:CreateMeeting', 'chime:CreateAttendee', 'chime:DeleteMeeting', 'chime:GetMeeting', 'chime:StartMeetingTranscription', 'chime:StopMeetingTranscription'],
        resources: ['*'],
      }),
    );
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: [
          'cognito-idp:AdminCreateUser',
          'cognito-idp:AdminGetUser',
          'cognito-idp:AdminSetUserPassword',
          'cognito-idp:AdminInitiateAuth',
          'cognito-idp:AdminDeleteUser',
          'cognito-idp:AdminUpdateUserAttributes',
        ],
        resources: [userPool.userPoolArn],
      }),
    );
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3vectors:PutVectors', 's3vectors:QueryVectors', 's3vectors:GetVectors', 's3vectors:DeleteVectors', 's3vectors:ListVectors'],
        resources: [`arn:aws:s3vectors:${this.region}:${this.account}:bucket/${vectorBucketName}`, `arn:aws:s3vectors:${this.region}:${this.account}:bucket/${vectorBucketName}/*`],
      }),
    );
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ssm:GetParameter', 'ssm:GetParameters'],
        resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/nudge/${stage}/*`],
      }),
    );

    const wsApi = new apigw.WebSocketApi(this, 'Ws', { apiName: `nudge-ws-${stage}` });
    const wsEndpoint = `https://${wsApi.apiId}.execute-api.${this.region}.amazonaws.com/${stage}`;
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['execute-api:ManageConnections'],
        resources: [`arn:aws:execute-api:${this.region}:${this.account}:${wsApi.apiId}/${stage}/*`],
      }),
    );

    const environment: Record<string, string> = {
      STAGE: stage,
      TABLE_NAME: table.tableName,
      MEDIA_BUCKET: bucket.bucketName,
      USER_POOL_ID: userPool.userPoolId,
      USER_POOL_CLIENT_ID: client.userPoolClientId,
      IDENTITY_POOL_ID: identityPool.ref,
      WS_ENDPOINT: wsEndpoint,
      DELAY_QUEUE_URL: delayQueue.queueUrl,
      SUMMARIZE_QUEUE_URL: summarizeQueue.queueUrl,
      VECTOR_BUCKET: vectorBucketName,
      VECTOR_INDEX: 'photos',
      CAPTION_VECTOR_INDEX: 'photo-captions',
      SIMILARITY_THRESHOLD: '0.37',
      TOS_VERSION: '2026-09-26',
      MEETING_TRANSCRIPTION: 'on',
      NODE_OPTIONS: '--enable-source-maps',
    };

    const fn = (name: string, file: string, handler = 'handler', opts: { timeout?: number; memory?: number } = {}) =>
      new NodejsFunction(this, name, {
        functionName: `nudge-${stage}-${name}`,
        entry: src(file),
        handler,
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        memorySize: opts.memory ?? 512,
        timeout: Duration.seconds(opts.timeout ?? 29),
        role,
        environment,
        logGroup: new logs.LogGroup(this, `${name}Logs`, { retention: logs.RetentionDays.TWO_WEEKS, removalPolicy }),
        bundling: {
          format: OutputFormat.ESM,
          target: 'node22',
          mainFields: ['module', 'main'],
          externalModules: [], // bundle the SDK: the runtime's copy may predate S3 Vectors
          minify: true,
          sourceMap: true,
          banner: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);",
        },
      });

    const authFn = fn('auth', 'auth.ts');
    const meFn = fn('me', 'me.ts');
    const whoopFn = fn('whoop', 'whoop.ts');
    const whoopSyncFn = fn('whoopSync', 'whoop.ts', 'sync', { timeout: 300 });
    new scheduler.Schedule(this, 'WhoopSchedule', {
      schedule: scheduler.ScheduleExpression.rate(Duration.minutes(5)),
      target: new targets.LambdaInvoke(whoopSyncFn, {}),
      description: 'Refresh optional WHOOP availability estimates',
    });
    const friendsFn = fn('friends', 'friends.ts');
    const messagesFn = fn('messages', 'messages.ts');
    const nudgesFn = fn('nudges', 'nudges.ts');
    const callsFn = fn('calls', 'calls.ts');
    const photosFn = fn('photos', 'photos.ts');
    const wsConnectFn = fn('wsConnect', 'ws.ts', 'connect');
    const wsDisconnectFn = fn('wsDisconnect', 'ws.ts', 'disconnect');
    const wsMessageFn = fn('wsMessage', 'ws.ts', 'message');
    const wsTranscriptFn = fn('wsTranscript', 'wsTranscript.ts', 'handler', { memory: 1024 });
    const matcherFn = fn('matcher', 'scheduled.ts', 'matcher', { timeout: 120 });
    const delayFn = fn('delay', 'scheduled.ts', 'delay', { timeout: 60 });
    const summarizerFn = fn('summarizer', 'summarizer.ts', 'handler', { timeout: 60 });
    const indexerFn = fn('photoIndexer', 'photoIndexer.ts', 'handler', { timeout: 120, memory: 1024 });
    const sweepFn = fn('photoSweep', 'photoSweep.ts', 'handler', { timeout: 300 });

    delayFn.addEventSource(new SqsEventSource(delayQueue, { batchSize: 5 }));
    summarizerFn.addEventSource(new SqsEventSource(summarizeQueue, { batchSize: 1 }));
    bucket.addEventNotification(s3.EventType.OBJECT_CREATED, new s3n.LambdaDestination(indexerFn), { prefix: 'photos/' });

    new scheduler.Schedule(this, 'MatcherSchedule', {
      schedule: scheduler.ScheduleExpression.rate(Duration.minutes(5)),
      target: new targets.LambdaInvoke(matcherFn, {}),
      description: 'Nudge matcher',
    });
    new scheduler.Schedule(this, 'SweepSchedule', {
      schedule: scheduler.ScheduleExpression.cron({ minute: '0', hour: '4' }),
      target: new targets.LambdaInvoke(sweepFn, {}),
      description: 'Remove photos older than 30 days',
    });

    // HTTP API ---------------------------------------------------------------------------------
    const authorizer = new HttpJwtAuthorizer('Cognito', `https://cognito-idp.${this.region}.amazonaws.com/${userPool.userPoolId}`, {
      jwtAudience: [client.userPoolClientId],
    });
    const http = new apigw.HttpApi(this, 'Http', { apiName: `nudge-http-${stage}`, defaultAuthorizer: authorizer });
    const integrations = new Map<lambda.IFunction, HttpLambdaIntegration>();
    const route = (method: string, p: string, target: lambda.IFunction, isPublic = false) => {
      if (!integrations.has(target)) integrations.set(target, new HttpLambdaIntegration(`${target.node.id}Int`, target));
      http.addRoutes({
        path: p,
        methods: [method as apigw.HttpMethod],
        integration: integrations.get(target)!,
        ...(isPublic ? { authorizer: new apigw.HttpNoneAuthorizer() } : {}),
      });
    };

    route('POST', '/auth/apple', authFn, true);
    for (const [m, p] of [['GET', '/me/whoop'], ['POST', '/me/whoop/connect'], ['POST', '/me/whoop/callback'],
      ['PATCH', '/me/whoop'], ['DELETE', '/me/whoop']]) route(m, p, whoopFn);
    route('POST', '/auth/refresh', authFn, true);
    if (isDev) route('POST', '/auth/dev', authFn, true);

    for (const [m, p] of [
      ['GET', '/me'], ['PATCH', '/me'], ['DELETE', '/me'], ['POST', '/me/tos'], ['GET', '/handles/{handle}'],
      ['PUT', '/me/handle'], ['POST', '/me/avatar'], ['POST', '/me/phone'], ['POST', '/me/phone/verify'],
      ['DELETE', '/me/phone'], ['POST', '/me/devices'], ['PUT', '/me/availability'], ['PUT', '/me/context'],
      ['POST', '/me/frequency/less'], ['POST', '/me/frequency/undo'], ['GET', '/transcribe/config'],
    ]) route(m, p, meFn);
    if (isDev) route('POST', '/telemetry', meFn);

    for (const [m, p] of [
      ['GET', '/users/search'], ['POST', '/contacts/match'], ['GET', '/friends'], ['GET', '/friend-requests'],
      ['POST', '/friend-requests'], ['POST', '/friend-requests/{userId}/accept'], ['POST', '/friend-requests/{userId}/decline'],
      ['DELETE', '/friend-requests/{userId}'], ['PATCH', '/friends/{userId}'], ['DELETE', '/friends/{userId}'],
      ['GET', '/blocks'], ['POST', '/blocks/{userId}'], ['DELETE', '/blocks/{userId}'],
      ['GET', '/friends/{userId}/memories'], ['DELETE', '/friends/{userId}/topics/{topicId}'],
      ['POST', '/friends/{userId}/topics/{topicId}/dismiss'], ['DELETE', '/friends/{userId}/summaries/{callId}'],
      ['DELETE', '/memories'], ['GET', '/friends/{userId}/calls'], ['POST', '/friends/{userId}/call'],
    ]) route(m, p, friendsFn);

    for (const [m, p] of [
      ['GET', '/conversations'], ['GET', '/friends/{userId}/messages'], ['POST', '/friends/{userId}/messages'],
      ['POST', '/friends/{userId}/messages/read'],
    ]) route(m, p, messagesFn);

    for (const [m, p] of [
      ['GET', '/nudges/active'], ['GET', '/nudges/{id}'], ['POST', '/nudges/{id}/respond'], ['POST', '/nudges/{id}/cancel'],
    ]) route(m, p, nudgesFn);

    for (const [m, p] of [
      ['GET', '/calls/{id}/join'], ['POST', '/calls/{id}/end'], ['GET', '/calls/{id}/summary'], ['POST', '/calls/{id}/shares'],
      ['GET', '/calls/{id}/shares/{shareId}'], ['POST', '/calls/{id}/shares/{shareId}/shown'],
      ['POST', '/calls/{id}/suggestions/{suggestionId}/feedback'],
    ]) route(m, p, callsFn);

    for (const [m, p] of [
      ['POST', '/photos/uploads'], ['GET', '/photos/status'], ['DELETE', '/photos/{assetHash}'], ['DELETE', '/photos'],
    ]) route(m, p, photosFn);

    if (isDev) {
      const devFn = fn('dev', 'dev.ts', 'handler', { timeout: 29 });
      for (const [m, p] of [
        ['POST', '/dev/matcher/run'], ['GET', '/dev/pushes/{userId}'], ['POST', '/dev/nudges/{id}/expire'],
        ['POST', '/dev/calls/{id}/summarize'], ['POST', '/dev/phone/verify'], ['POST', '/dev/photos/sweep'],
      ]) route(m, p, devFn);
    }

    // WebSocket API -----------------------------------------------------------------------------
    wsApi.addRoute('$connect', { integration: new WebSocketLambdaIntegration('WsConnect', wsConnectFn) });
    wsApi.addRoute('$disconnect', { integration: new WebSocketLambdaIntegration('WsDisconnect', wsDisconnectFn) });
    const wsMsg = new WebSocketLambdaIntegration('WsMessage', wsMessageFn);
    wsApi.addRoute('$default', { integration: wsMsg });
    wsApi.addRoute('ping', { integration: wsMsg });
    wsApi.addRoute('waiting', { integration: wsMsg });
    wsApi.addRoute('transcript', { integration: new WebSocketLambdaIntegration('WsTranscript', wsTranscriptFn) });
    const wsStage = new apigw.WebSocketStage(this, 'WsStage', { webSocketApi: wsApi, stageName: stage, autoDeploy: true });

    // Budget: net cost after credits (credits are included by default) above $1 → email.
    if (isDev && props.budgetEmail) {
      new budgets.CfnBudget(this, 'NetCostBudget', {
        budget: {
          budgetName: 'nudge-net-cost',
          budgetType: 'COST',
          timeUnit: 'MONTHLY',
          budgetLimit: { amount: 1, unit: 'USD' },
          costTypes: { includeCredit: true, includeRefund: true },
        },
        notificationsWithSubscribers: [
          {
            notification: { notificationType: 'ACTUAL', comparisonOperator: 'GREATER_THAN', threshold: 100, thresholdType: 'PERCENTAGE' },
            subscribers: [{ subscriptionType: 'EMAIL', address: props.budgetEmail }],
          },
        ],
      });
    }

    new CfnOutput(this, 'Stage', { value: stage });
    new CfnOutput(this, 'Region', { value: this.region });
    new CfnOutput(this, 'HttpApiUrl', { value: http.apiEndpoint });
    new CfnOutput(this, 'WsUrl', { value: wsStage.url });
    new CfnOutput(this, 'UserPoolId', { value: userPool.userPoolId });
    new CfnOutput(this, 'UserPoolClientId', { value: client.userPoolClientId });
    new CfnOutput(this, 'IdentityPoolId', { value: identityPool.ref });
    new CfnOutput(this, 'MediaBucket', { value: bucket.bucketName });
    new CfnOutput(this, 'VectorBucketName', { value: vectorBucketName });
    new CfnOutput(this, 'CaptionVectorIndexName', { value: 'photo-captions' });
    new CfnOutput(this, 'TableName', { value: table.tableName });
  }
}
