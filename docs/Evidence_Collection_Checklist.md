# Evidence Collection Checklist: LiveKit on Elastic Beanstalk

This checklist details every screenshot, configuration document, AWS Console view, and CLI verification command required to satisfy the deployment and CI/CD assessment criteria for **Meyi Cloud Solutions Private Limited**.

---

## 1. Assessment Documentation Evidence

- [ ] **Workload Assessment**: [`docs/Workload_Assessment.md`](Workload_Assessment.md) justifying Docker + Beanstalk, host networking, and WebRTC dual-path ingress.
- [ ] **Architecture Guide**: [`docs/Architecture_Guide.md`](Architecture_Guide.md) showing the ALB, EC2 host networking, Security Groups, and AWS Secrets Manager integration.
- [ ] **Technical Learnings**: [`docs/Learnings.md`](Learnings.md) documenting technical retrospective and resolved gotchas.
- [ ] **Architecture Diagram**: [`diagram/architecture.eraserdiagram`](../diagram/architecture.eraserdiagram) visualizing end-to-end traffic flow.
- [ ] **CI/CD Infrastructure**: [`pipeline.yaml`](../pipeline.yaml) (CloudFormation) and [`buildspec.yml`](../buildspec.yml) (CodeBuild spec).

---

## 2. AWS Management Console Evidence Screenshots

### A. AWS CodePipeline CI/CD Pipeline (Complete 4-Stage Execution)
- **Location**: AWS Console $\rightarrow$ **CodePipeline** $\rightarrow$ Pipelines $\rightarrow$ `livekit-production-pipeline`
- **What to Capture**:
  - **Source Stage**: Status: **Succeeded** (Action: `GitHubSource`, commit hash, branch `main`).
  - **Build Stage**: Status: **Succeeded** (Action: `PackageArtifacts` executing automated unit tests in CodeBuild).
  - **Approve Stage**: Status: **Succeeded / Approved** (Action: `ManualApproval` checkpoint).
  - **Deploy Stage**: Status: **Succeeded** (Action: `ElasticBeanstalkDeploy`, Application: `livekit-server`, Environment: `livekit-production`).
  - Pipeline Execution ID and timestamp.

### B. AWS CodeBuild Project & Unit Test Execution Logs
- **Location**: AWS Console $\rightarrow$ **CodeBuild** $\rightarrow$ Build projects $\rightarrow$ `livekit-production-package-build` $\rightarrow$ Build history
- **What to Capture**:
  - Build Status: **Succeeded**
  - Build Phase Details: `PRE_BUILD` (running Python unit tests), `BUILD`, `UPLOAD_ARTIFACTS` all marked as **SUCCESS**.
  - Tail logs confirming `Ran 6 tests in ... OK` and `All automated unit tests and integrity checks passed successfully`.

### C. AWS CodeStar Connection (GitHub Integration)
- **Location**: AWS Console $\rightarrow$ **Developer Tools** $\rightarrow$ Settings $\rightarrow$ **Connections**
- **What to Capture**:
  - Connection Name: `livekit-production-github-conn`
  - Status: **Available** (Green)
  - Provider: **GitHub**

### D. Elastic Beanstalk Environment Overview
- **Location**: AWS Console $\rightarrow$ **Elastic Beanstalk** $\rightarrow$ Environments $\rightarrow$ `livekit-production`
- **What to Capture**:
  - Environment Health: **Ok (Green)**
  - Platform: **Docker running on 64bit Amazon Linux 2023**
  - Application Name: `livekit-server`
  - Running Version: Deployed application version label

### E. Application Load Balancer & Listeners
- **Location**: EC2 Console $\rightarrow$ **Load Balancers** $\rightarrow$ Select ALB for `livekit-production`
- **What to Capture**:
  - Load Balancer Type: **Application**
  - Listeners: **HTTP:80** (and **HTTPS:443** if ACM certificate is attached)
  - Scheme: **Internet-facing**

### F. Load Balancer Target Group & Health Check
- **Location**: EC2 Console $\rightarrow$ **Target Groups** $\rightarrow$ Select Target Group for `livekit-production`
- **What to Capture**:
  - Health check path: `/`
  - Port: `7880`
  - Status of registered targets: **Healthy (1/1)**

### G. Dedicated WebRTC Security Group Rules (Inbound)
- **Location**: EC2 Console $\rightarrow$ **Security Groups** $\rightarrow$ Select `LiveKitSecurityGroup`
- **What to Capture**:
  - Inbound Rule: **TCP 7880** from `0.0.0.0/0` (LiveKit Signaling & ALB Health Checks)
  - Inbound Rule: **UDP 50000 - 60000** from `0.0.0.0/0` (WebRTC RTP/SRTP Media)
  - Inbound Rule: **TCP 7881** from `0.0.0.0/0` (WebRTC ICE TCP Fallback)

### H. Secrets Management (AWS Secrets Manager)
- **Location**: AWS Secrets Manager $\rightarrow$ Secrets $\rightarrow$ `livekit-production/livekit-credentials`
- **What to Capture**:
  - Secret Name: `livekit-production/livekit-credentials`
  - Secret Keys: `api_key`, `api_secret` (masked)
  - KMS Encryption details

---

## 3. CLI & Functional Verification Evidence

### 1. CodePipeline Status Verification
```bash
aws codepipeline get-pipeline-state \
  --name livekit-production-pipeline \
  --region ap-southeast-1 \
  --query "stageStates[*].[stageName, latestExecution.status, latestExecution.pipelineExecutionId]" \
  --output table
```

### 2. Elastic Beanstalk Health Status
```bash
aws elasticbeanstalk describe-environments \
  --environment-names livekit-production \
  --region ap-southeast-1 \
  --query "Environments[0].[EnvironmentName, Status, Health, HealthStatus, VersionLabel]" \
  --output table
```

### 3. LiveKit HTTP Signaling Health Check
```bash
CNAME=$(aws elasticbeanstalk describe-environments \
  --environment-names livekit-production \
  --region ap-southeast-1 \
  --query "Environments[0].CNAME" \
  --output text)

curl -i "http://${CNAME}/"
# Expected Response: HTTP/1.1 200 OK (OK)
```

### 4. LiveKit Token Generation & Connection Test
```bash
# 1. Fetch auto-generated API credentials from Secrets Manager
API_KEY=$(aws secretsmanager get-secret-value --secret-id "livekit-production/livekit-credentials" --region ap-southeast-1 --query "SecretString" --output text | jq -r .api_key)
API_SECRET=$(aws secretsmanager get-secret-value --secret-id "livekit-production/livekit-credentials" --region ap-southeast-1 --query "SecretString" --output text | jq -r .api_secret)

# 2. Generate test access token
livekit-cli create-token \
  --api-key "$API_KEY" \
  --api-secret "$API_SECRET" \
  --join --room test-room --identity test-user --valid-for 1h

# 3. Join test room over WebSockets & WebRTC
livekit-cli room join \
  --url "ws://${CNAME}" \
  --api-key "$API_KEY" \
  --api-secret "$API_SECRET" \
  --room test-room --identity test-user
```
