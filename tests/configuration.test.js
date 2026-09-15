const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..');

describe('LiveKit Signaling Infrastructure Unit Tests (Node.js)', () => {

  test('1. Verify all required deployment and IaC files exist', () => {
    const requiredFiles = [
      'Dockerfile',
      'docker-compose.yml',
      'entrypoint.sh',
      'livekit.yaml',
      'template.yaml',
      'pipeline.yaml',
      'buildspec.yml',
      'buildspec-test.yml',
      path.join('.ebextensions', '01_sysctl_tuning.config')
    ];

    for (const file of requiredFiles) {
      const fullPath = path.join(REPO_ROOT, file);
      assert.ok(fs.existsSync(fullPath), `Required file is missing: ${file}`);
    }
  });

  test('2. Validate livekit.yaml signaling port allocation and STUN discovery', () => {
    const configPath = path.join(REPO_ROOT, 'livekit.yaml');
    const content = fs.readFileSync(configPath, 'utf8');

    assert.match(content, /port:\s*7880/, 'Signaling port must be set to 7880');
    assert.match(content, /use_external_ip:\s*true/, 'use_external_ip must be true for candidate discovery');
  });

  test('3. Validate docker-compose.yml enforces Host Networking Mode', () => {
    const composePath = path.join(REPO_ROOT, 'docker-compose.yml');
    const content = fs.readFileSync(composePath, 'utf8');

    assert.match(content, /network_mode:\s*["']?host["']?/, 'docker-compose must declare network_mode: "host"');
    assert.match(content, /container_name:\s*livekit-server/, 'container_name must be livekit-server');
    assert.match(content, /restart:\s*always/, 'restart policy must be always');
  });

  test('4. Validate entrypoint.sh shell syntax and fail-closed secrets retrieval', () => {
    const entrypointPath = path.join(REPO_ROOT, 'entrypoint.sh');
    const content = fs.readFileSync(entrypointPath, 'utf8');

    assert.ok(content.startsWith('#!/bin/sh'), 'entrypoint.sh must have valid shebang');
    assert.ok(content.includes('set -e'), 'entrypoint.sh must include set -e for fail-closed behavior');
    assert.ok(content.includes('secretsmanager get-secret-value'), 'entrypoint.sh must retrieve secrets from AWS Secrets Manager');
    assert.ok(content.includes('livekit-server'), 'entrypoint.sh must execute livekit-server');
  });

  test('5. Validate CloudFormation 100% ALB-Managed Ingress, Route 53, and Auto-Validated ACM', () => {
    const templatePath = path.join(REPO_ROOT, 'template.yaml');
    const pipelinePath = path.join(REPO_ROOT, 'pipeline.yaml');

    const templateContent = fs.readFileSync(templatePath, 'utf8');
    const pipelineContent = fs.readFileSync(pipelinePath, 'utf8');

    // 1. Existing VPC & Subnets Parameters
    assert.ok(templateContent.includes('VpcId:'), 'template.yaml must define VpcId parameter');
    assert.ok(templateContent.includes('PublicSubnets:'), 'template.yaml must define PublicSubnets parameter');

    // 2. Custom Shared ALB (livekit-production-alb) & Listeners
    assert.ok(templateContent.includes('CustomALB:'), 'template.yaml must define CustomALB');
    assert.ok(templateContent.includes('ALBSecurityGroup:'), 'template.yaml must define ALBSecurityGroup');
    assert.ok(templateContent.includes('ALBHttpRedirectListener:'), 'template.yaml must define HTTP 80 redirect listener');
    assert.ok(templateContent.includes('ALBHttpsListener:'), 'template.yaml must define HTTPS 443 listener');
    assert.ok(templateContent.includes('LiveKitCertificate:'), 'template.yaml must define auto-validated ACM certificate');
    assert.ok(templateContent.includes('LiveKitDnsRecord:'), 'template.yaml must define LiveKitDnsRecord Route 53 alias');

    // 3. Shared ALB Elastic Beanstalk Option Settings
    assert.ok(templateContent.includes('LoadBalancerIsShared'), 'template.yaml must enable LoadBalancerIsShared: true');
    assert.ok(templateContent.includes('SharedLoadBalancer'), 'template.yaml must configure SharedLoadBalancer option setting');
    assert.ok(templateContent.includes('aws:elbv2:listener:443'), 'template.yaml must configure aws:elbv2:listener:443');
    assert.ok(templateContent.includes('aws:elbv2:listenerrule:default'), 'template.yaml must configure listener rule for shared ALB');
    assert.ok(templateContent.includes('aws:elasticbeanstalk:environment:process:default'), 'template.yaml must configure default EB process on 7880');

    // 4. 100% ALB-Restricted Security Group (Zero public bypass)
    assert.ok(templateContent.includes('SourceSecurityGroupId: !Ref ALBSecurityGroup'), 'Port 7880 must be restricted strictly to ALBSecurityGroup');
    assert.ok(!templateContent.includes('FromPort: 50000'), 'UDP 50000-60000 bypass rule must be removed');
    assert.ok(!templateContent.includes('FromPort: 7881'), 'TCP 7881 bypass rule must be removed');

    // 5. CI/CD Pipeline Components
    assert.ok(pipelineContent.includes('LiveKitPipeline:'), 'pipeline.yaml must define LiveKitPipeline');
    assert.ok(pipelineContent.includes('LiveKitCodeBuildTestProject:'), 'pipeline.yaml must define LiveKitCodeBuildTestProject');
    assert.ok(pipelineContent.includes('LiveKitCodeBuildProject:'), 'pipeline.yaml must define LiveKitCodeBuildProject');
  });

  test('6. Validate Linux kernel UDP buffer tuning in .ebextensions', () => {
    const tuningPath = path.join(REPO_ROOT, '.ebextensions', '01_sysctl_tuning.config');
    const content = fs.readFileSync(tuningPath, 'utf8');

    assert.ok(content.includes('net.core.rmem_max=2500000'), 'UDP receive buffer tuning must be declared (2.5MB)');
    assert.ok(content.includes('net.core.wmem_max=2500000'), 'UDP write buffer tuning must be declared (2.5MB)');
  });

});
