# gitops-lab

**A hands-on learning lab for GitOps + ArgoCD, structured as a production-like template you can fork and extend.**

## What This Is

This repository serves two purposes:

1. **Educational**: Learn GitOps patterns by running a complete local setup (kind + ArgoCD + multi-environment deployment)
2. **Template**: A minimal, well-structured starting point for real GitOps deployments

The structure is intentionally production-like (not a toy example), but simplified:
- **Real patterns**: Application/ApplicationSet, multi-environment, drift detection, auto-sync/self-heal
- **Intentional simplifications**: nginxdemos/hello instead of real apps, no secrets management, local cluster
- **Path to production**: See [What Changes for Production](#what-changes-for-production) below

---

## Learning Track: Production Deployment Patterns

**Goal:** Make informed decisions about deploying Kubernetes applications in production.

**Time:** 3-5 hours total | **Prerequisites:** Basic Kubernetes knowledge ([start here](https://github.com/wware/k8s-hack) if new to K8s)

### Core Track: GitOps Foundations

#### 1. Local GitOps Setup
**Do:** [docs/HOWTO.md](docs/HOWTO.md) - Set up kind + ArgoCD + Gitea
**Insight:** GitOps inverts control: instead of `kubectl apply`, you push to git and ArgoCD reconciles. Git becomes the control plane.
**Verify:** ArgoCD UI shows your app, changing `deployment.yaml` triggers sync
**Time:** 45 minutes
**Why this matters:** Pull-based deployments are more secure and auditable than push-based CI/CD

#### 2. Drift Detection & Self-Healing
**Do:** `kubectl scale deployment/gitops-lab --replicas=5`, watch ArgoCD flag it as OutOfSync
**Insight:** Cluster state vs git state is *always* visible. Enable self-heal and ArgoCD auto-reverts manual changes.
**Verify:** ArgoCD shows diff, self-heal brings it back to git's `replicas: 3`
**Time:** 15 minutes
**Going deeper:** [docs/GITOPS.md](docs/GITOPS.md) explains reconciliation loops

#### 3. Multi-Environment Deployment
**Do:** `kubectl apply -f applicationset.yaml` - Deploy dev/staging/prod from one config
**Insight:** ApplicationSets eliminate YAML duplication. One template generates three Applications.
**Verify:** `kubectl get applications -n argocd` shows three apps
**Time:** 20 minutes
**Going deeper:** [docs/applicationset-guide.md](docs/applicationset-guide.md)

#### 4. Queue-Based Autoscaling (KEDA)
**Do:** [keda-demo/README.md](keda-demo/README.md) - Deploy RabbitMQ + workers, send messages
**Insight:** Autoscaling doesn't require always-on infrastructure. Workers scale 0→N based on actual work (queue depth), not CPU guesses.
**Verify:** Send 20 messages → 4 workers spawn → process queue → scale to 0
**Time:** 45 minutes
**Why this matters:** Most production workloads are bursty. Scale-to-zero saves money.

---

### Decision Point: Choose Your Deployment Model

**Time to make a cost/complexity tradeoff.** Read all three docs, then pick one to implement:

#### Option A: Single-Box Autoscaling ($45/month)
**Read:** [docs/SINGLE_BOX_AUTOSCALE.md](docs/SINGLE_BOX_AUTOSCALE.md)
**Best for:** Side projects, MVPs, solo developer, <1000 req/sec
**Insight:** You don't need Kubernetes. Docker + Python autoscaler + systemd is simpler and cheaper.
**Time:** 2 hours to implement
**Trade-off:** No high availability, manual deploys, single point of failure

#### Option B: AWS Auto Scaling Groups ($10/month)
**Read:** [docs/AWS_AUTOSCALING.md](docs/AWS_AUTOSCALING.md)
**Best for:** Batch workloads (rendering, transcoding), scale-to-zero, cost-sensitive
**Insight:** AWS-native autoscaling (ASG + SQS) gives you KEDA-like behavior without Kubernetes complexity.
**Time:** 3 hours to implement (Terraform + worker script)
**Trade-off:** AWS lock-in, 60-120 second scaling lag, Spot interruptions

#### Option C: Real EKS Deployment ($163+/month)
**Read:** [docs/REAL_EKS_DEPLOY.md](docs/REAL_EKS_DEPLOY.md)
**Best for:** Production apps, multi-region, team scale, high availability
**Insight:** EKS cost is justified when you need: always-on services, multi-env, compliance, or >3 developers.
**Time:** 3 hours for experiment, 2 weeks for production-ready
**Trade-off:** Expensive, complex, but industry-standard and portable

**Can't decide?** Decision matrix in each doc compares cost/setup/scale/HA/GitOps.

---

### Side Quests (Optional Deep Dives)

#### A. EKS Emulation (Local Multi-Node)
**Read:** [docs/EKS_EMULATION.md](docs/EKS_EMULATION.md)
**Do:** Set up kubeadm across 2-3 home LAN machines, add MetalLB
**Insight:** 90% of EKS behavior is just Kubernetes. Practice multi-node mechanics without AWS costs.
**Time:** 3-4 hours
**When to do this:** Before spending on EKS, after outgrowing single-box

#### B. Queue-Based Scaling Deep Dive
**Read:** [docs/QUEUE-BASED-SCALING.md](docs/QUEUE-BASED-SCALING.md)
**Insight:** SQS, Kafka, Redis—same pattern everywhere. Learn once, use across AWS/GCP/Azure.
**When to do this:** After KEDA demo, before choosing deployment model

#### C. Kubernetes Logging
**Read:** [k8s-hack/LOGGING.md](https://github.com/wware/k8s-hack/blob/main/LOGGING.md) (in sibling repo)
**Insight:** Stdout → DaemonSet → Loki is the evolution of syslog. Structured JSON logs + automatic metadata = correlation nirvana.
**When to do this:** When you have >3 services and grep-ing kubectl logs becomes painful

---

### Graduation: Production Checklist

After completing the core track + one deployment option, you should be able to:

- [ ] Explain why GitOps is pull-based, not push-based
- [ ] Demonstrate drift detection and self-healing
- [ ] Deploy the same app to dev/staging/prod with ApplicationSets
- [ ] Scale workloads based on queue depth (not just CPU)
- [ ] Make a cost-informed decision: single-box vs ASG vs EKS
- [ ] Justify *not* using Kubernetes (when appropriate)

**What's missing for real production?** See [What Changes for Production](#what-changes-for-production) below:
- Secrets management (External Secrets, SOPS)
- Monitoring (Prometheus, Grafana, Loki)
- Alerting (AlertManager, PagerDuty)
- RBAC, network policies, image scanning

---

### Cross-Repo Learning Path

**Recommended order for complete Kubernetes journey:**

1. **[k8s-hack](https://github.com/wware/k8s-hack)** - Learn Kubernetes fundamentals (Deployments, Services, StatefulSets)
2. **[k8s-hack/WHY_KUBERNETES.md](https://github.com/wware/k8s-hack/blob/main/WHY_KUBERNETES.md)** - Understand when (and when not) to use K8s
3. **gitops-lab** (this repo) - Learn production deployment patterns (GitOps, KEDA, cost decisions)
4. **[k8s-hack/LOGGING.md](https://github.com/wware/k8s-hack/blob/main/LOGGING.md)** - Add observability (logs, metrics, traces)

**Total time:** Weekend project → production-ready knowledge in ~10-15 hours

---

## Repo layout

- `deployment.yaml`, `service.yaml` — the app ArgoCD watches and reconciles.
  Push this repo (or your fork of it) to GitHub/GitLab; these two files are
  what the ArgoCD Application points at.
- `argocd-app.yaml.example` — template for the ArgoCD Application manifest.
  Copy to `argocd-app.yaml`, update the `repoURL` to your repository, then apply once:
  ```bash
  cp argocd-app.yaml.example argocd-app.yaml
  # Edit argocd-app.yaml to update repoURL
  kubectl apply -f argocd-app.yaml
  ```
  Note: `argocd-app.yaml` is in `.gitignore` to avoid circular dependencies (the Application should not manage itself)

## Quick setup

```bash
# cluster
kind create cluster --name gitops-lab

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# UI access
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
# -> login at https://localhost:8080 as admin
```

Edit `repoURL` in `argocd-app.yaml` to point at your fork, then:

```bash
kubectl apply -f argocd-app.yaml
```

## Test the loop

1. **Sync**: in the ArgoCD UI, the app should show `OutOfSync` → click Sync,
   or `argocd app sync gitops-lab` if you install the CLI.
2. **Change propagation**: edit `replicas:` in `deployment.yaml`, commit, push.
   Wait for ArgoCD's poll (~3 min) or hit Refresh — it should show the diff.
3. **Drift detection**: `kubectl scale deployment/gitops-lab --replicas=5`.
   ArgoCD flags `OutOfSync`. Flip `selfHeal: true` in `argocd-app.yaml` and
   reapply to see it auto-revert instead of just alerting.

## ApplicationSet example

This repo also includes an ApplicationSet example that deploys to multiple environments:

```bash
kubectl apply -f applicationset.yaml
```

The ApplicationSet uses the **git directory generator** to automatically create three Applications:
- `gitops-lab-dev` → deploys `envs/dev/` to `dev` namespace (1 replica)
- `gitops-lab-staging` → deploys `envs/staging/` to `staging` namespace (2 replicas)
- `gitops-lab-prod` → deploys `envs/prod/` to `prod` namespace (3 replicas)

Check the created applications:
```bash
kubectl get applications -n argocd
kubectl get applicationsets -n argocd
```

To add a new environment, just create a new directory under `envs/` with manifests and the ApplicationSet will automatically pick it up on the next sync.

## KEDA demo (queue-based autoscaling)

See [keda-demo/](keda-demo/) for a hands-on demo of **KEDA (Kubernetes Event-Driven Autoscaling)** - automatic pod scaling based on queue depth.

This demonstrates:
- **Scale to zero**: Workers scale down to 0 pods when queue is empty
- **Scale on demand**: Pods created automatically when messages arrive
- **Real-world pattern**: Same approach for AWS SQS, Kafka, Redis, etc.

Quick start:
```bash
# Install KEDA
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.12.1/keda-2.12.1.yaml

# Deploy demo
kubectl create namespace keda-demo
kubectl apply -f keda-demo/

# Send messages and watch scaling
kubectl run sender --image=python:3.12-slim --rm -i --restart=Never -n keda-demo -- \
  bash -c "pip install pika && python3 -c 'import pika; c=pika.BlockingConnection(pika.ConnectionParameters(\"rabbitmq\",credentials=pika.PlainCredentials(\"guest\",\"guest\"))); ch=c.channel(); ch.queue_declare(queue=\"work-queue\",durable=True); [ch.basic_publish(\"\",\"work-queue\",f\"task-{i}\".encode()) for i in range(20)]'"

# Watch workers scale up
kubectl get pods -n keda-demo -w
```

See [docs/QUEUE-BASED-SCALING.md](docs/QUEUE-BASED-SCALING.md) for production patterns with AWS SQS, Kafka, and more.

## Notes

- `automated.prune`/`selfHeal` start `false` on purpose — sync manually at
  first so you see each diff before it applies.
- Swap `nginxdemos/hello` for your own image once the mechanics are proven out.
- The ApplicationSet pattern is powerful for managing multiple environments, clusters, or tenants from a single configuration.

---

## What Changes for Production

To use this as a template for real deployments:

### Must Change

- **Replace `nginxdemos/hello`** with your actual application images (with immutable tags, not `latest`)
- **Add secrets management**: External Secrets Operator, Sealed Secrets, or SOPS (never commit plaintext secrets to git)
- **Update `repoURL`** in `argocd-app.yaml` and `applicationset.yaml` to your organization's repository
- **Add ingress/TLS**: Set up ingress-nginx or cloud-native ingress with cert-manager for HTTPS
- **Set resource requests/limits** based on actual application needs (current values are minimal placeholders)

### Should Add

- **Infrastructure as Code**: Terraform/Pulumi for EKS/GKE/AKS cluster provisioning
- **Monitoring stack**: Prometheus, Grafana, Loki for metrics and logs
- **AlertManager**: Notifications for ArgoCD sync failures, degraded apps
- **RBAC policies**: Multi-team access control for namespaces and ArgoCD projects
- **Backup strategy**: Velero for cluster state, plus database-specific backups
- **Network policies**: Restrict pod-to-pod traffic for security
- **Image scanning**: Integrate Trivy or similar into your CI pipeline

### Nice to Have

- **Progressive delivery**: Argo Rollouts or Flagger for canary/blue-green deployments
- **Multi-cluster setup**: Separate clusters for dev/staging/prod with one ArgoCD control plane
- **Policy enforcement**: OPA/Gatekeeper or Kyverno for compliance (PodSecurityStandards, resource quotas, etc.)
- **GitOps for infrastructure**: Use Crossplane or similar to manage cloud resources declaratively

### What Stays the Same

The **patterns** proven here translate directly to production:
- Git as source of truth
- Pull-based reconciliation (ArgoCD runs in-cluster)
- ApplicationSets for multi-environment management
- Drift detection and self-healing
- Declarative configuration in version-controlled YAML

The difference is **scale, security, and operational maturity**, not the fundamental architecture.

---

## Documentation

- **[docs/HOWTO.md](docs/HOWTO.md)** - Complete hands-on HOWTO (start here!)
- **[docs/GITOPS.md](docs/GITOPS.md)** - GitOps architecture deep dive
- **[docs/WHY_KUBERNETES.md](docs/WHY_KUBERNETES.md)** - Kubernetes fundamentals and when to use it
- **[docs/applicationset-guide.md](docs/applicationset-guide.md)** - ApplicationSet patterns and examples
- **[docs/QUEUE-BASED-SCALING.md](docs/QUEUE-BASED-SCALING.md)** - KEDA and queue-based autoscaling patterns

---

## Philosophy

This repository is designed around a core belief: **you learn best by working with production-like patterns, not dumbed-down examples**.

Everything here could run in production (with the changes above). The patterns scale. The structure is realistic. The only simplifications are for speed of iteration (local cluster, simple app, manual secrets), not architectural shortcuts.

Fork it. Break it. Deploy your own app. Add a database. Try multi-cluster. The foundation is solid.
