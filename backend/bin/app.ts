#!/usr/bin/env node
import { App, Tags } from 'aws-cdk-lib';
import { NudgeStack } from '../lib/nudge-stack.js';

const app = new App();
const stage = (app.node.tryGetContext('stage') as string) ?? 'dev';
const budgetEmail = app.node.tryGetContext('budgetEmail') as string | undefined;

new NudgeStack(app, `Nudge-${stage}`, {
  stage,
  budgetEmail,
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-1' },
});

Tags.of(app).add('project', 'nudge');
