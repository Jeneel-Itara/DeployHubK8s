# DeployHub Session Summary 💾
**Last Updated**: May 11, 2026

---

## 🚀 Project Status: EKS Stack Built, Pending Full Deployment

DeployHub has a complete production-grade AWS architecture implemented in Terraform.
The infrastructure provisions and destroys cleanly. One session needed to complete the full deployment.

---

## 🏗️ Architecture

```
                    jeneeldumasia.codes (Route 53) [Phase 2 — DNS pending]
                           │
              ┌────────────▼────────────┐
              │   AWS Application LB    │
              │   (internet-facing)     │
              └──┬──────────────────┬───┘
                 │                  │
         /  /api │                  │ /grafana
  ┌──────▼───────┴──┐    ┌──────────▼────────┐
  │   EKS Cluster   │    │   ECS Fargate      │
  │   (2 AZs, HA)   │    │   (monitoring)     │
  │                 │    │                    │
  │ ns: deployhub   │    │  • Prometheus      │
  │  • frontend     │    │  • Grafana         │
  │  • backend      │◄───│  • Loki            │
  │  • buildkit     │    │  (scrapes /metrics)│
  │  • mongodb      │    └────────────────────┘
  │                 │
  │ ns: deployhub-  │
  │ apps            │
  │  • user pods    │
  └────────┬────────┘
           │ push/pull
      ┌────▼────┐
      │   ECR   │
      │(private)│
      └─────────┘

Infrastructure: Terraform modules (networking/eks/ecs-monitoring/ecr/dns-acm)
CI/CD:          GitHub Actions (build → Trivy scan → ECR push → EKS deploy)
```

---

## ✅ Completed Features

### Application
1. **FastAPI backend** — async deployment queue, BuildKit orchestration, SSE log streaming
2. **React/Vite frontend** — multi-theme dashboard
3. **MongoDB** — project state persistence
4. **BuildKit in-cluster** — image builds pushed to ECR
5. **Dynamic Ingress** — per-app subdomain routing via Traefik (k3s) / ALB (EKS)
6. **GitHub webhooks** — `POST /api/webhooks/github/{id}` auto-redeploy on push
7. **Smart Dockerfile generation** — detects Node/Python/static, auto-installs system deps
8. **Post-deployment health checks** — pod readiness + HTTP probe, auto-rollback on failure
9. **HPA** — backend scales 1→5 replicas on CPU/memory pressure

### Infrastructure (Terraform)
10. **Module structure** — `networking`, `eks`, `ecs-monitoring`, `ecr`, `dns-acm`
11. **Two environments** — `environments/prod` (EKS+ECS+ALB) and `environments/k3s` (single EC2)
12. **Remote state** — S3 (`deployhub-tfstate-jeneel`) + DynamoDB lock (`deployhub-tfstate-lock-jeneel`)
13. **VPC** — 10.0.0.0/16, 2 public + 2 private subnets, NAT GW per AZ (true HA)
14. **EKS** — managed node groups (t3.medium × 2 AZs), OIDC/IRSA, ALB controller IAM role
15. **ECS Fargate** — Prometheus + Grafana + Loki monitoring stack
16. **ALB** — path-based routing (/ → frontend, /api → backend, /grafana → ECS Grafana)
17. **ECR** — 3 repos with scan-on-push + lifecycle policies
18. **Secrets Manager** — Grafana credentials (no hardcoded passwords)
19. **Kubernetes Secrets + ConfigMap** — all sensitive k8s config externalized

### CI/CD & Observability
20. **GitHub Actions** — `ci.yml` (PR validation) + `deploy.yml` (EKS + k3s deploy jobs)
21. **Trivy scanning** — image vulnerability scan before ECR push
22. **Prometheus metrics** — deployments, failures, health checks, pod restarts, HTTP latency
23. **Grafana dashboard** — pre-provisioned with DeployHub overview + Loki log explorer
24. **Alert rules** — failure rate, health check failures, backend down, pod restart loops
25. **Structured JSON logging** — `log_event()` throughout backend

---

## 🔑 Credentials & Accounts

| Account | Purpose | Credentials |
|---------|---------|-------------|
| Personal AWS (`952994886652`) | EKS production stack | `~/.env.aws` (personal keys) |
| KodeKloud AWS | Practice / k3s testing | New keys each session from KodeKloud UI |

**Personal AWS state bucket**: `deployhub-tfstate-jeneel` (us-east-1)
**Personal AWS DynamoDB lock**: `deployhub-tfstate-lock-jeneel` (us-east-1)

---

## ⚠️ Known Issue — Instance Role Credential Conflict

When running `deploy-eks.sh` from a KodeKloud EC2 instance, the instance IAM role
overrides `.env.aws` credentials. **This is now fixed in the script** — it explicitly
exports credentials from `.env.aws` to override the instance role.

---

## 🏃 Resuming Next Session

### On KodeKloud EC2 (for EKS on personal account):

```bash
# 1. SSH into your KodeKloud EC2 instance
# 2. Clone or pull the repo
git clone https://github.com/Jeneel-Itara/DeployHubK8s.git
cd DeployHubK8s
# OR if already cloned:
git fetch origin && git reset --hard origin/main

# 3. Add your personal AWS credentials
cat > .env.aws << 'EOF'
AWS_ACCESS_KEY_ID=YOUR_PERSONAL_KEY
AWS_SECRET_ACCESS_KEY=YOUR_PERSONAL_SECRET
AWS_DEFAULT_REGION=us-east-1
EOF

# 4. Run the deploy script (handles everything)
chmod +x scripts/deploy-eks.sh
./scripts/deploy-eks.sh
```

The script will:
- Verify it's using your personal account (prints account ID)
- Skip bootstrap if S3 bucket already exists
- Provision VPC → EKS → ECS → ALB (~35 min)
- Install ALB controller via Helm
- Build + push images to ECR
- Apply k8s manifests
- Smoke test

### After deployment, access via ALB DNS:
```
UI:      http://<alb-dns>
API:     http://<alb-dns>/api
Grafana: http://<alb-dns>/grafana  (admin / your-password)
```

### To destroy when done:
```bash
export AWS_ACCESS_KEY_ID=$(grep AWS_ACCESS_KEY_ID .env.aws | cut -d= -f2 | tr -d '[:space:]')
export AWS_SECRET_ACCESS_KEY=$(grep AWS_SECRET_ACCESS_KEY .env.aws | cut -d= -f2 | tr -d '[:space:]')
export AWS_DEFAULT_REGION=us-east-1

cd terraform/environments/prod
terraform destroy -auto-approve
```

---

## 🏃 Next Steps / TODO

- [ ] **Complete EKS deployment** — run `./scripts/deploy-eks.sh` on personal account, get screenshots
- [ ] **DNS Setup** — point `*.jeneeldumasia.codes` to ALB (Phase 2, needs fixed IP/ALB)
- [ ] **SSL** — add `dns-acm` module to `prod/main.tf` once DNS is configured
- [ ] **Terraform remote state for k3s env** — `environments/k3s` still uses local state
- [ ] **Screenshots** — capture EKS console, ALB, ECS tasks, Grafana dashboard for README

---

## 💡 Repo

**GitHub**: https://github.com/Jeneel-Itara/DeployHubK8s
**Local (WSL)**: `~/DeployHubK8s`
