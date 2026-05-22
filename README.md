# EKS Hub-Spoke Architecture — Complete Deployment

## Architecture Summary

```
Internet
  │
  ├─ Route 53 (DNS)
  ├─ CloudFront (CDN + TLS + WAF)
  ├─ WAF v2 (OWASP, Bot Control, Rate limiting)
  └─ ALB (ALB Ingress Controller)
        │
┌───── SPOKE VPC (10.1.0.0/16) ─────────────────────────────┐
│  Public Subnets                                             │
│    ├─ NAT Gateway (x3 AZ)                                   │
│    ├─ Internet Gateway                                       │
│    └─ TGW Attachment ──────────────── Transit Gateway ───┐  │
│  Private Subnets (EKS)                VPC Endpoints       │  │
│    ├─ EKS Control Plane               (ECR, S3, SSM)      │  │
│    ├─ Microservice A (Node.js)                            │  │
│    │    └─ HPA, PDB, NetworkPolicy                        │  │
│    ├─ Microservice B (Python)                             │  │
│    │    └─ HPA, PDB, NetworkPolicy                        │  │
│  DB Subnets                                               │  │
│    ├─ RDS PostgreSQL (Multi-AZ)                           │  │
│    └─ ElastiCache Redis                                   │  │
└───────────────────────────────────────────────────────────┘  │
                                                               │
┌───── HUB VPC (10.0.0.0/16) ──────────────────────────────┐  │
│    ├─ Transit Gateway (TGS) ◄──────────────────────────────┘ │
│    ├─ AWS Network Firewall (stateful L3-L7)                   │
│    └─ Shared Services (DNS, Secrets, Logging)                 │
│                                                              │
│    Spoke attachments:                                        │
│      ├─ Production Spoke (10.1.0.0/16)                      │
│      ├─ Dev/Staging Spokes                                   │
│      ├─ On-prem via Direct Connect                          │
│      └─ Security VPC                                        │
└──────────────────────────────────────────────────────────────┘
```

## Security Layers (Defense in Depth)

| Layer | Control | Details |
|-------|---------|---------|
| Edge | AWS WAF v2 | OWASP CRS, SQLi, XSS, Bot Control (targeted) |
| Edge | AWS Shield Advanced | DDoS protection, cost protection |
| DNS | Route 53 | Health checks, failover routing |
| CDN | CloudFront | TLS 1.3 only, WAF ACL attached |
| LB | ALB | HTTPS only, access logs, drop invalid headers |
| Network | Network Firewall (Hub) | Stateful L3-L7, east-west + egress |
| Network | NAT Gateway | Outbound-only for private subnets |
| Network | Security Groups | Least-privilege, SG-referenced rules |
| K8s | NetworkPolicy | Pod-to-pod ingress/egress allowlists |
| K8s | Pod Security Standards | `restricted` profile enforced |
| K8s | IRSA | Zero long-lived credentials on pods |
| Data | RDS Encryption | AES-256, Multi-AZ |
| Data | KMS | EKS secrets encrypted, key rotation |
| Data | Secrets Manager | DB creds, auto-rotation via External Secrets |
| Container | Non-root user | UID 1000/1001, read-only rootfs |
| Container | ECR Scan | Scan on push enabled |
| Routing | Hub-Spoke | All inter-VPC traffic via Hub Firewall |

## File Structure

```
eks-hub-spoke/
├── 00-prerequisites.sh          # Tool installation
├── deploy.sh                    # Full deployment commands
├── Dockerfiles.txt              # Both Dockerfiles
├── terraform/
│   ├── hub-vpc/main.tf          # Hub VPC, TGW, Network Firewall
│   ├── spoke-vpc/main.tf        # Spoke VPC, EKS, RDS, SGs
│   └── waf/main.tf              # WAF v2, Bot Control, Shield
├── k8s/
│   ├── microservice-a/
│   │   └── deployment.yaml      # Deployment, SVC, HPA, PDB, NetPol
│   ├── microservice-b/
│   │   └── deployment.yaml      # Deployment, SVC, HPA, PDB, NetPol
│   └── ingress/
│       └── alb-ingress.yaml     # ALB Ingress + ClusterSecretStore
├── microservice-a/
│   └── src/app.js               # Node.js + Express + pg pool
└── microservice-b/
    └── src/main.py              # Python FastAPI + asyncpg
```

## Deployment Order

```
Phase 1  →  Hub VPC (Terraform)         ~10 min
Phase 2  →  Spoke VPC + EKS + RDS       ~20 min
Phase 3  →  WAF (Terraform)             ~5 min
Phase 4  →  EKS addons (OIDC, CSI)     ~5 min
Phase 5  →  Helm addons (ALB, ESO)     ~10 min
Phase 6  →  Build + Push images         ~5 min
Phase 7  →  IRSA roles                  ~2 min
Phase 8  →  Apply K8s manifests         ~3 min
Phase 9  →  Verify                      ~2 min
```

## Key Commands for Day-2 Operations

```bash
# Scale a deployment
kubectl scale deployment microservice-a -n microservice-a --replicas=5

# Check HPA status
kubectl describe hpa microservice-a-hpa -n microservice-a

# View logs
kubectl logs -n microservice-a -l app=microservice-a --tail=100 -f

# Exec into a pod
kubectl exec -it -n microservice-a deployment/microservice-a -- sh

# Check RDS connectivity from pod
kubectl exec -it -n microservice-a deployment/microservice-a -- \
  nc -zv $DB_HOST 5432

# Rolling restart (pick up new image)
kubectl rollout restart deployment/microservice-a -n microservice-a

# View Secrets Manager sync status
kubectl get externalsecret -A

# Firewall rule logs (via CloudWatch)
aws logs filter-log-events \
  --log-group-name /aws/network-firewall/hub-network-firewall \
  --filter-pattern "DROP"

# WAF blocked requests
aws wafv2 get-sampled-requests \
  --web-acl-arn $WAF_ACL_ARN \
  --rule-metric-name RateLimitPerIP \
  --scope REGIONAL \
  --time-window StartTime=$(date -d '1 hour ago' +%s),EndTime=$(date +%s) \
  --max-items 100
```

## Cost Estimate (ap-south-1, monthly)

| Component | Est. Cost |
|-----------|-----------|
| EKS cluster | ~$73 |
| 5x m5.large nodes | ~$340 |
| RDS PostgreSQL r6g.large Multi-AZ | ~$250 |
| NAT Gateways (3x) | ~$100 |
| Transit Gateway | ~$50 |
| Network Firewall | ~$65 |
| WAF + Bot Control | ~$30+ |
| ALB | ~$20 |
| **Total** | **~$930/month** |
