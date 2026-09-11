const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..');

describe('LiveKit WebRTC Infrastructure & Configuration Unit Tests (Node.js)', () => {

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

  test('2. Validate livekit.yaml WebRTC port allocation and STUN discovery', () => {
    const configPath = path.join(REPO_ROOT, 'livekit.yaml');
    const content = fs.readFileSync(configPath, 'utf8');

    assert.match(content, /port:\s*7880/, 'Signaling port must be set to 7880');
    assert.match(content, /tcp_port:\s*7881/, 'WebRTC ICE TCP fallback port must be set to 7881');
    assert.match(content, /port_range_start:\s*50000/, 'WebRTC UDP start port must be set to 50000');
    assert.match(content, /port_range_end:\s*60000/, 'WebRTC UDP end port must be set to 60000');
    assert.match(content, /use_external_ip:\s*true/, 'use_external_ip must be true for STUN public candidate discovery');
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

  test('5. Validate CloudFormation infrastructure templates structure and 5-stage pipeline', () => {
    const templatePath = path.join(REPO_ROOT, 'template.yaml');
    const pipelinePath = path.join(REPO_ROOT, 'pipeline.yaml');

    const templateContent = fs.readFileSync(templatePath, 'utf8');
    const pipelineContent = fs.readFileSync(pipelinePath, 'utf8');

    // Verify Core Infrastructure
    assert.ok(templateContent.includes('LiveKitSecurityGroup:'), 'template.yaml must define LiveKitSecurityGroup');
    assert.ok(templateContent.includes('LiveKitSecret:'), 'template.yaml must define LiveKitSecret');
    assert.ok(templateContent.includes('LiveKitEnvironment:'), 'template.yaml must define LiveKitEnvironment');

    // Verify CI/CD Pipeline Components
    assert.ok(pipelineContent.includes('LiveKitPipeline:'), 'pipeline.yaml must define LiveKitPipeline');
    assert.ok(pipelineContent.includes('LiveKitCodeBuildTestProject:'), 'pipeline.yaml must define LiveKitCodeBuildTestProject');
    assert.ok(pipelineContent.includes('LiveKitCodeBuildProject:'), 'pipeline.yaml must define LiveKitCodeBuildProject');
    assert.ok(pipelineContent.includes('Name: Test'), 'pipeline.yaml must define Test stage');
    assert.ok(pipelineContent.includes('Name: Build'), 'pipeline.yaml must define Build stage');
    assert.ok(pipelineContent.includes('ManualApproval'), 'pipeline.yaml must define ManualApproval stage');
    assert.ok(pipelineContent.includes('ElasticBeanstalkDeploy'), 'pipeline.yaml must define Deploy stage');
  });

  test('6. Validate Linux kernel UDP buffer tuning in .ebextensions', () => {
    const tuningPath = path.join(REPO_ROOT, '.ebextensions', '01_sysctl_tuning.config');
    const content = fs.readFileSync(tuningPath, 'utf8');

    assert.ok(content.includes('net.core.rmem_max=2500000'), 'UDP receive buffer tuning must be declared (2.5MB)');
    assert.ok(content.includes('net.core.wmem_max=2500000'), 'UDP write buffer tuning must be declared (2.5MB)');
  });

});
