# Technical Learnings & Architecture Retrospective: LiveKit on AWS Elastic Beanstalk

**Project**: LiveKit Real-Time WebRTC Media Communications Server  
**Platform**: AWS Elastic Beanstalk (`64bit Amazon Linux 2023 v4.13.7 running Docker`)  
**Region**: `ap-southeast-1`  
**Repository**: [kumaresan0206/livekit-beanstalk](https://github.com/kumaresan0206/livekit-beanstalk.git)  

---

## 1. Executive Summary

Deploying a stateful, low-latency, real-time WebRTC communications server like **LiveKit** onto a PaaS like **AWS Elastic Beanstalk** presents unique architectural and operational challenges compared to standard web microservices. 

This document captures the core architectural patterns, cloud infrastructure lessons, configuration gotchas, and troubleshooting solutions discovered throughout the end-to-end design, implementation, debugging, and verification of this deployment.

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                 DUAL-PATH INGRESS MODEL                 │
                  └─────────────────────────────────────────────────────────┘
                                                │
                 ┌──────────────────────────────┴──────────────────────────────┐
                 │                                                             │
         [ Signaling Path ]                                            [ Media Path ]
                 │                                                             │
        Clients (WSS / HTTPS)                                         Clients (RTP / ICE)
                 │                                                             │
                 ▼                                                             ▼
     Application Load Balancer                                         EC2 Public IP
         (Port 80 / 443)                                           (UDP 50000-60000 / TCP 7881)
                 │                                                             │
                 ▼                                                             │
       Target Group Health Check                                               │
             (Port 7880)                                                       │
                 │                                                             │
                 └──────────────────────────────┬──────────────────────────────┘
                                                │
                                                ▼
                                    ┌───────────────────────┐
                                    │      EC2 Instance     │
                                    │    (Host Network)     │
                                    │                       │
                                    │   ┌───────────────┐   │
                                    │   │ LiveKit Docker│   │
                                    │   │  (Port 7880,  │   │
                                    │   │  7881, 50k+)  │   │
                                    │   └───────────────┘   │
                                    └───────────────────────┘
```

---

## 2. Core Architectural Decisions

### 2.1. Standalone 1-Instance Architecture (Eliminating Redis)
* **Context**: LiveKit supports distributed clustering across multiple nodes via Redis Pub/Sub and Key-Value state storage.
* **Decision**: For cost optimization and simplicity, configured a standalone single-instance deployment (`Min: 1, Max: 1` on `t3.medium`).
* **Learning**: A single modern instance can handle hundreds of concurrent WebRTC tracks without Redis overhead. Eliminating Redis reduced infrastructure costs by ~60%, removed VPC peering complexity, and simplified health management.

### 2.2. Dual-Path Ingress Model
* **Context**: Application Load Balancers (ALB) only terminate HTTP/HTTPS/WebSocket (TCP) traffic and **do not support UDP routing**.
* **Decision**:
  1. **Signaling Traffic (Port 7880 / 443 / 80)**: Routed through the ALB with TLS termination and `/` HTTP health checks.
  2. **Media Traffic (UDP 50000–60000 & TCP 7881)**: Bypasses the ALB completely, connecting directly to the EC2 host via its public IP address (`AssociatePublicIpAddress: true`).
* **Learning**: LiveKit's built-in STUN IP discovery (`use_external_ip: true`) automatically discovers the EC2 instance's public IP and advertises it in WebRTC ICE candidates to clients.

### 2.3. Host Networking vs. Bridge Mode
* **Context**: Docker default bridge networking adds NAT overhead and requires exposing individual port mappings.
* **Decision**: Configured `network_mode: "host"` in `docker-compose.yml`.
* **Learning**: On Elastic Beanstalk AL2023 Docker platform, `docker-compose.yml` is the first-class deployment engine. Host networking attaches the container directly to the host `eth0` network interface, eliminating Docker NAT latency and allowing direct binding across the entire 10,000-port UDP media range.

---

## 3. Security & Secrets Management

### 3.1. Dynamic Credential Generation in AWS Secrets Manager
* **Anti-Pattern Avoided**: Hardcoding API secrets in `livekit.yaml` or passing static plaintext keys in environment variables.
* **Implementation**:
  - CloudFormation uses `AWS::SecretsManager::Secret` with `GenerateSecretString` to generate a 32-character high-entropy cryptographic secret.
  - The secret is stored at `livekit-production/livekit-credentials`.
* **Container Runtime Injection**:
  - Container entrypoint script (`entrypoint.sh`) fetches the secret via AWS CLI on startup.
  - Dynamically injects the credentials into `/tmp/livekit-runtime.yaml` before launching `livekit-server`.
* **Learning**: Keeps source control 100% secret-free, isolates credentials in ephemeral memory, and complies with AWS Security Best Practices.

### 3.2. Scoped IAM Instance Profile
* Scoped `LiveKitEC2Role` permissions strictly to:
  1. `AWSElasticBeanstalkWebTier` (EB core monitoring and log streaming).
  2. `AmazonSSMManagedInstanceCore` (secure SSH-less instance management via AWS Systems Manager).
  3. `secretsmanager:GetSecretValue` constrained strictly to the specific LiveKit secret ARN.

---

## 4. Key Gotchas & Solutions Encountered

### Gotcha 1: IAM Policy ARN Sub-Paths
* **Symptom**: CloudFormation returned `CREATE_FAILED` on `LiveKitServiceRole` with:
  > *"Policy arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy does not exist or is not attachable."*
* **Root Cause**: While `AWSElasticBeanstalkEnhancedHealth` is located under the `/service-role/` sub-path, `AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy` is located at the root `arn:aws:iam::aws:policy/`.
* **Solution**: Corrected the ARN in `template.yaml` to `arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy`.

---

### Gotcha 2: AutoScaling Rolling Update Constraints on 1-Instance Setups
* **Symptom**: CloudFormation environment creation failed with:
  > *"Configuration validation exception: The minimum instances in service for rolling updates (1) should be less than the maximum instance count for the Autoscaling group (1)."*
* **Root Cause**: AWS Auto Scaling enforces a strict mathematical rule: `MinInstancesInService < MaxSize`. When `MaxSize = 1`, setting `MinInstancesInService = 1` is invalid.
* **Solution**: Set `MinInstancesInService: '0'`. Combined with `DeploymentPolicy: RollingWithAdditionalBatch`, Elastic Beanstalk provisions a temporary 2nd instance, verifies its health, and tears down the old instance with zero service disruption.

---

### Gotcha 3: CloudFormation ROLLBACK_COMPLETE Shells
* **Symptom**: Re-running `deploy.sh` after a creation failure failed to update the stack.
* **Root Cause**: When an initial CloudFormation stack creation fails and rolls back, it enters the terminal state `ROLLBACK_COMPLETE`. CloudFormation does not allow updates to stacks in this state.
* **Solution**: Must execute `aws cloudformation delete-stack` and await `stack-delete-complete` before recreating.

---

### Gotcha 4: Empty Option Settings in ALB HTTPS Listeners
* **Symptom**: Specifying conditional HTTPS listeners with empty `SSLCertificateArns: ""` when no certificate was provided caused EB option validator errors.
* **Solution**: Decoupled HTTPS configuration from CloudFormation `template.yaml`. `deploy.sh` dynamically injects `.ebextensions/02_https.config` only when `CERTIFICATE_ARN` is explicitly supplied, ensuring HTTP-only deployments are completely decoupled.

---

### Gotcha 5: Initial Environment Creation vs. Custom Application Rollout
* **Symptom**: Immediately after CloudFormation creation, environment health transitioned to `Severe / Red` with `502 Bad Gateway`.
* **Root Cause**: CloudFormation provisions the environment with AWS's default sample container (which runs on port 8000). Because the ALB target group was configured to monitor `/` on port 7880, the sample container failed health checks until the real LiveKit application version was deployed.
* **Solution**: Normal deployment workflow proceeds by executing `create-application-version` and `update-environment`, which replaces the sample container with LiveKit. Once LiveKit starts on port 7880, health immediately transitions to `Green / Ok`.

---

### Gotcha 6: Cross-Platform Zip Packaging Fallback
* **Symptom**: Deployments on minimal WSL/Ubuntu environments failed with `./deploy.sh: line 71: zip: command not found`.
* **Solution**: Enhanced `deploy.sh` with a zero-dependency fallback chain:
  1. Checks for native `zip` command.
  2. Falls back to Python's built-in standard library `python3 -c "import zipfile..."` (pre-installed in almost all Linux/WSL environments without requiring npm modules).

---

## 5. Summary Checklist for Future Deployments

| Step | Action | Verification |
| :--- | :--- | :--- |
| **1. IaC Provisioning** | Run CloudFormation with explicit Security Group and IAM roles | Stack status `CREATE_COMPLETE` |
| **2. App Packaging** | Package `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `livekit.yaml`, `.ebextensions/` | Zip bundle verified |
| **3. Deployment** | Upload bundle to EB S3 and trigger `update-environment` | Environment health `Green / Ok` |
| **4. Signaling Test** | `curl -i http://<ALB-CNAME>/` | Returns `HTTP/1.1 200 OK` |
| **5. Media Test** | Verify UDP 50000-60000 and TCP 7881 rules on EC2 Security Group | Direct WebRTC media connectivity |
| **6. Teardown** | Delete CloudFormation stack & force delete Secrets Manager secret | Zero lingering AWS costs |
