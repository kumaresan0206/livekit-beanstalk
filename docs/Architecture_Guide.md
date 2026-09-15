# Architecture Guide: LiveKit on AWS Elastic Beanstalk (Custom VPC & Shared ALB)

## 1. Network & Traffic Flow Topology

```mermaid
flowchart TD
    subgraph Clients ["End Users / WebRTC Clients"]
        UserA["WebRTC Client A"]
        Admin["App Server / Admin API"]
    end

    subgraph CustomVPC ["Custom VPC: 10.0.0.0/16 (Public Subnets Dual AZ)"]
        subgraph Ingress ["Edge Ingress & Decoupled Shared ALB Tier"]
            ALB["Custom ALB: livekit-production-alb\n- Listener :443 (HTTPS + ACM TLS Offload)\n- Listener :80 (HTTP 301 Redirect to :443)"]
            ALBSG["ALB Security Group\nInbound: TCP 443 & 80 from 0.0.0.0/0"]
            DirectMedia["LiveKit EC2 Security Group Direct Ingress\n(UDP: 50000-60000 RTP, TCP: 7881 ICE)"]
        end

        subgraph EB_Environment ["Elastic Beanstalk Environment: livekit-production"]
            EB_Process["EB Default Process / Target Group\n(Port: 7880 HTTP, Health Check: /)"]
            subgraph ASG ["Compute & Runtime (Auto Scaling Group)"]
                EC2["EC2 Instance (t3.medium default / c6i.large)\nPlatform: AL2023 Docker (Host Network)\nDocker: livekit-server (Pinned v1.8.3)"]
            end
        end

        subgraph IAM_Security ["Security & Governance"]
            IAM["IAM Instance Profile\nPolicy: secretsmanager:GetSecretValue"]
            SecretsManager["AWS Secrets Manager\nSecret: livekit-production/livekit-credentials\n- api_key (Unique Stack ID)\n- api_secret (32-char Cryptographic Random)"]
        end
    end

    UserA -- "1. WebSocket Signaling (WSS:443)" --> ALB
    Admin -- "1. Admin REST API (HTTPS:443)" --> ALB
    UserA -. "HTTP:80 (Redirect to 443)" .-> ALB

    ALB -- "2. Forward to EB Process" --> EB_Process
    EB_Process -- "3. Proxy Port 7880" --> EC2

    UserA == "4. Direct RTP Media (UDP:50000-60000)" ==> DirectMedia
    UserA == "5. Direct ICE TCP Fallback (TCP:7881)" ==> DirectMedia
    DirectMedia ==> "Direct Host Network Bypass" ==> EC2

    EC2 -. "Read Secrets on Boot" .-> SecretsManager
    IAM -. "Grants Access" .-> EC2
```

---

## 2. Ingress & Port Allocation Mapping

| Port Range | Protocol | Routing Path | Purpose | Security Justification |
| :--- | :--- | :--- | :--- | :--- |
| **443** | TCP (HTTPS/WSS) | Client $\rightarrow$ `livekit-production-alb` $\rightarrow$ EC2:7880 | Signaling, Room token authentication, WebSockets, and health checks | TLS terminated at ALB with ACM SSL certificate |
| **80** | TCP (HTTP) | Client $\rightarrow$ `livekit-production-alb` $\rightarrow$ Redirect 443 | Automatic HTTP $\rightarrow$ HTTPS 301 redirection | Secure transport enforcement |
| **7880** | TCP (HTTP) | ALB $\rightarrow$ EC2 Container | Backend signaling listener and `/` healthcheck target | **Restricted strictly to ALB Security Group** |
| **7881** | TCP | Client $\rightarrow$ EC2 Instance Directly | WebRTC ICE over TCP fallback | Direct host ingress (Accepted WebRTC standard) |
| **50000–60000** | UDP | Client $\rightarrow$ EC2 Instance Directly | WebRTC RTP/SRTP Audio and Video media packets | Direct host ingress (Accepted WebRTC standard) |

---

## 3. Network & Infrastructure Ownership

The deployment provisions an isolated **Custom VPC (10.0.0.0/16)**:
- **Custom VPC & Subnets**: CloudFormation provisions `CustomVPC`, `InternetGateway`, and two public subnets across availability zones (`PublicSubnet1` in AZ a, `PublicSubnet2` in AZ b).
- **Shared Custom ALB**: CloudFormation provisions `livekit-production-alb` and listeners (HTTPS 443 with ACM offloading, HTTP 80 with 301 redirect).
- **EB Target Management**: Elastic Beanstalk dynamically creates the target group for `process:default` on port `7880`, registers/deregisters EC2 instances in the Auto Scaling Group, and injects listener rules to `livekit-production-alb`.

---

## 4. Security & Secrets Architecture

### Credential Generation
Credentials are created by AWS Secrets Manager at stack creation:
- **`api_key`**: Environment-derived identifier (`LK_${AWS::StackName}_${AWS::Region}`).
- **`api_secret`**: 32-character cryptographically random string generated via Secrets Manager's `GenerateSecretString`.

### EC2 IAM Instance Profile Policy
The Elastic Beanstalk EC2 instance profile is configured with least-privilege permissions, matching [`template.yaml`](../template.yaml) exactly:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "the exact ARN returned by the SecretsManagerSecretArn CloudFormation output"
    }
  ]
}
```

---

## 5. Standalone Compute & Resiliency

- **Capacity**: Baseline is set to **1 instance (`Min: 1, Max: 1`)**. Standalone mode removes Redis clustering overhead while delivering high performance.
- **Rolling Deployments**: Configured with `RollingWithAdditionalBatch` to ensure automated health-verified rollouts during application updates.
