# Evidence Collection Checklist: LiveKit on Elastic Beanstalk

This checklist details every screenshot, configuration document, and CLI verification required to satisfy the assessment criteria for **Meyi Cloud Solutions Private Limited**.

---

## 1. Assessment Documentation Evidence

- [ ] **Document**: Export of [Workload Assessment](Workload_Assessment.md) justifying Docker + Beanstalk, host networking, and WebRTC dual-path networking.
- [ ] **Diagram**: Export of [Architecture Guide](Architecture_Guide.md) showing the ALB, EC2 host networking, Security Groups, and AWS Secrets Manager integration.
- [ ] **CI/CD Evidence**: GitHub Actions workflow ([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)) and coordinator script ([`deploy.sh`](../deploy.sh)).

---

## 2. AWS Management Console Evidence Screenshots

### A. Elastic Beanstalk Environment Overview
- **Location**: AWS Console $\rightarrow$ Elastic Beanstalk $\rightarrow$ Environments $\rightarrow$ `livekit-production`
- **What to Capture**:
  - Environment Health: **Ok (Green)**
  - Platform: **Docker running on 64bit Amazon Linux 2023**
  - Application Name: `livekit-server`
  - Running Version: Version label

### B. Application Load Balancer & Listeners
- **Location**: EC2 Console $\rightarrow$ Load Balancers $\rightarrow$ Select ALB for `livekit-production`
- **What to Capture**:
  - Load Balancer Type: **Application**
  - Listeners: **HTTP:80** and **HTTPS:443 (ACM Certificate)**
  - Scheme: **Internet-facing**

### C. Load Balancer Target Group & Health Check
- **Location**: EC2 Console $\rightarrow$ Target Groups $\rightarrow$ Select Target Group for `livekit-production`
- **What to Capture**:
  - Health check path: `/`
  - Port: `7880`
  - Status of registered targets: **Healthy (1/1)**

### D. Security Group Rules (Inbound)
- **Location**: EC2 Console $\rightarrow$ Security Groups $\rightarrow$ Select `LiveKitSecurityGroup`
- **What to Capture**:
  - Inbound Rule: **TCP 7880** from `0.0.0.0/0` (Signaling & ALB Health Checks)
  - Inbound Rule: **UDP 50000 - 60000** from `0.0.0.0/0` (WebRTC RTP/SRTP Media)
  - Inbound Rule: **TCP 7881** from `0.0.0.0/0` (WebRTC ICE TCP Fallback)

### E. Auto Scaling & Rolling Deployments
- **Location**: Elastic Beanstalk $\rightarrow$ Configuration $\rightarrow$ Capacity & Rolling updates
- **What to Capture**:
  - Environment type: **Load-balanced**
  - Instances: **Min: 1, Max: 1**
  - Rolling update policy: **Health-based rolling updates**
  - Deployment policy: **Rolling with additional batch**

### F. Secrets Management (AWS Secrets Manager)
- **Location**: AWS Secrets Manager $\rightarrow$ Secrets $\rightarrow$ `livekit-production/livekit-credentials`
- **What to Capture**:
  - Secret Name: `livekit-production/livekit-credentials`
  - Secret Keys: `api_key`, `api_secret` (ensure secret values are masked)

---

## 3. CLI & Functional Verification Evidence

### Health Check Verification
```bash
# Verify ALB Health Endpoint
curl -i http://<your-eb-environment-url>/
# Expected Response: HTTP/1.1 200 OK (OK)
```

### LiveKit Token Generation & Connection Test
```bash
# Fetch API key and secret from Secrets Manager
API_KEY=$(aws secretsmanager get-secret-value --secret-id "livekit-production/livekit-credentials" --query "SecretString" --output text | jq -r .api_key)
API_SECRET=$(aws secretsmanager get-secret-value --secret-id "livekit-production/livekit-credentials" --query "SecretString" --output text | jq -r .api_secret)

# Generate a test access token using livekit-cli
livekit-cli create-token \
  --api-key "$API_KEY" \
  --api-secret "$API_SECRET" \
  --join --room test-room --identity test-user --valid-for 1h

# Test room connectivity over WebSocket & WebRTC
livekit-cli room join \
  --url wss://<your-domain-or-alb> \
  --api-key "$API_KEY" \
  --api-secret "$API_SECRET" \
  --room test-room --identity test-user
```
