# Application & Workload Assessment

## Assessment Metadata
- **Customer / Organization**: Meyi Cloud Solutions Private Limited
- **Application Name**: LiveKit Real-Time WebRTC Communications Server (`livekit-server`)
- **Target Platform**: AWS Elastic Beanstalk (Docker on 64-bit Amazon Linux 2023 v4.13.7)
- **Deployment Mode**: 1-Instance Standalone Architecture (Min: 1, Max: 1) in Customer Default Multi-AZ VPC
- **Assessment Date**: September 2026

---

## 1. Executive Summary
This document provides the formal architectural assessment for deploying the **LiveKit Real-Time WebRTC Communications Platform** for **Meyi Cloud Solutions Private Limited** on **AWS Elastic Beanstalk**.

The workload is designed as a **1-Instance Standalone Deployment (`Min: 1, Max: 1`)** to maximize cost efficiency, eliminate external Redis clustering overhead, and provide dedicated compute capacity for real-time WebRTC audio/video communications.

---

## 2. Workload Characteristics & Architectural Solutions

| Attribute | Workload Requirement | Architectural Solution |
| :--- | :--- | :--- |
| **Networking & Protocols** | WebSocket (WSS:443), HTTP (7880), WebRTC ICE (TCP:7881), WebRTC RTP Media (UDP:50000-60000) | **Dual-Path Ingress**:<br>• **ALB**: Terminates HTTPS/WSS (Port 443) and proxies signaling to container port 7880.<br>• **Host Networking & Direct Security Group**: UDP 50000-60000 and TCP 7881 bypass the ALB directly to the EC2 host network interface. |
| **Network & VPC Boundary** | Pre-existing infrastructure | Deployed into the **Customer's Default Regional VPC**. VPC CIDR, multi-AZ subnets, Internet Gateways, and route tables are owned and managed by the customer account. |
| **Firewall & Port Acceptance** | Direct WebRTC media routing | **Accepted Design**: Ingress rules for UDP 50000–60000 (RTP media) and TCP 7881 (ICE fallback) from `0.0.0.0/0` are an accepted architectural necessity for direct client-to-server WebRTC audio/video transport. |
| **Public IP Discovery** | WebRTC requires public IP advertisement to clients | Configured `rtc.use_external_ip: true` with STUN discovery and `AssociatePublicIpAddress: 'true'` on the EC2 instance. |
| **Docker Host Networking** | Bridge NAT introduces latency and port-mapping overhead on 10,000 UDP ports | Deployment uses `docker-compose.yml` with `network_mode: "host"` for native kernel network performance. |
| **Secrets Governance** | Credentials managed without plaintext values in code | The environment-derived `api_key` and cryptographically random `api_secret` are stored in **AWS Secrets Manager** and resolved at runtime via the IAM instance profile. |
| **Resilience & Updates** | High availability and automated rollouts | Configured `RollingWithAdditionalBatch` deployment policy and ALB `/` health checking. |

---

## 3. Instance Sizing & Capacity Justification

- **1-Instance Standalone Architecture**: Fixed at `Min: 1, Max: 1`. Standalone mode eliminates the need for an external Redis state mesh, drastically lowering AWS infrastructure spend while remaining fully capable of serving 100+ concurrent WebRTC participants.
- **Compute Sizing**:
  - **Production Baseline**: `t3.medium` (2 vCPU, 4GB RAM) for the assessed standalone workload.
  - **Capacity Expansion**: A larger compute-optimized instance can be evaluated later if measured CPU, memory, or packet-rate demand exceeds the baseline.

---

## 4. Assessment Compliance Matrix

| Assessment Requirement | Implementation Detail | Compliance Status |
| :--- | :--- | :--- |
| **Application Packaging** | Multi-stage Dockerfile (pinned `v1.8.3`) with `docker-compose.yml` host networking | Full Compliance |
| **Infrastructure as Code (IaC)** | Pure AWS CloudFormation Template ([`template.yaml`](../template.yaml)) + [`.ebextensions/`](../.ebextensions/) | Full Compliance |
| **Load Balancing & TLS** | Application Load Balancer with Port 443 HTTPS/WSS (ACM certificate) and Port 80 | Full Compliance |
| **Security & Secrets** | AWS Secrets Manager (environment-derived API key and auto-generated cryptographic API secret) + Scoped IAM Instance Profile | Full Compliance |
| **Health Monitoring** | ALB Target Group health checks on `/` (Port 7880) | Full Compliance |
| **Deployment Strategy** | Health-based rolling updates (`RollingWithAdditionalBatch`) | Full Compliance |
| **CI/CD Integration** | Automated GitHub Actions workflow ([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)) executing [`deploy.sh`](../deploy.sh) | Full Compliance |
