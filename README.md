# gitops-lab

Minimal GitOps prototype repo for a local kind/minikube + ArgoCD setup.

## Repo layout

- `deployment.yaml`, `service.yaml` — the app ArgoCD watches and reconciles.
  Push this repo (or your fork of it) to GitHub/GitLab; these two files are
  what `argocd-app.yaml` points at.
- `argocd-app.yaml` — **not** watched by ArgoCD itself. Apply it once,
  directly to your cluster, to register the Application:
  ```bash
  kubectl apply -f argocd-app.yaml
  ```

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
