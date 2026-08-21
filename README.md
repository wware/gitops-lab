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

**Start here**: For a complete step-by-step guide, see [docs/HOWTO.md](docs/HOWTO.md)

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

---

## Philosophy

This repository is designed around a core belief: **you learn best by working with production-like patterns, not dumbed-down examples**.

Everything here could run in production (with the changes above). The patterns scale. The structure is realistic. The only simplifications are for speed of iteration (local cluster, simple app, manual secrets), not architectural shortcuts.

Fork it. Break it. Deploy your own app. Add a database. Try multi-cluster. The foundation is solid.
