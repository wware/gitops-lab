# ApplicationSet Quick Reference

## Basic Commands

```bash
# Apply the ApplicationSet
kubectl apply -f applicationset.yaml

# List ApplicationSets
kubectl get applicationsets -n argocd
kubectl get appsets -n argocd  # short form

# List generated Applications
kubectl get applications -n argocd
kubectl get apps -n argocd  # short form

# Describe an ApplicationSet
kubectl describe applicationset -n argocd gitops-lab-envs

# View full YAML
kubectl get applicationset -n argocd gitops-lab-envs -o yaml

# Delete an ApplicationSet (and all generated Apps)
kubectl delete applicationset -n argocd gitops-lab-envs
```

## Generator Types Cheat Sheet

### Git Directory Generator
```yaml
generators:
- git:
    repoURL: https://github.com/user/repo
    revision: main
    directories:
    - path: envs/*
```
**Use when**: Multiple environment directories in Git

### List Generator
```yaml
generators:
- list:
    elements:
    - env: dev
      replicas: "1"
    - env: prod
      replicas: "3"
```
**Use when**: Small, static list of parameters

### Cluster Generator
```yaml
generators:
- cluster:
    selector:
      matchLabels:
        environment: production
```
**Use when**: Deploying to multiple registered clusters

### Git Files Generator
```yaml
generators:
- git:
    repoURL: https://github.com/user/repo
    revision: main
    files:
    - path: "config/*.json"
```
**Use when**: Each config file represents one Application

### Matrix Generator
```yaml
generators:
- matrix:
    generators:
    - list:
        elements:
        - app: frontend
        - app: backend
    - git:
        directories:
        - path: envs/*
```
**Use when**: Combining multiple generators (apps × envs)

## Template Variables

| Variable | Example Value | Description |
|----------|--------------|-------------|
| `{{path}}` | `envs/dev` | Full path from git generator |
| `{{path.basename}}` | `dev` | Directory name only |
| `{{name}}` | `cluster-1` | From list/cluster generator |
| `{{server}}` | `https://k8s.example.com` | Cluster server URL |
| `{{metadata.labels.env}}` | `production` | Cluster label |
| Custom | `{{replicas}}` | Any custom parameter you define |

## Common Template Patterns

```yaml
# Application name with environment
name: 'myapp-{{path.basename}}'

# Namespace matches environment
namespace: '{{path.basename}}'

# Conditional image tag
image: 'myapp:{{env}}-{{git.short_sha}}'

# Path with variable
path: 'apps/{{app}}/overlays/{{env}}'
```

## Debugging

```bash
# Check ApplicationSet controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller

# View ApplicationSet events
kubectl get events -n argocd --field-selector involvedObject.name=gitops-lab-envs

# Verify generated Applications
kubectl get app -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'

# Check specific Application status
kubectl get app -n argocd gitops-lab-dev -o yaml | grep -A 10 status:
```

## Sync Policies

```yaml
# No automation - manual sync required
syncPolicy: {}

# Auto-sync but preserve deleted resources
syncPolicy:
  automated:
    prune: false
    selfHeal: false

# Full automation - recommended for production
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

## Repository Structure Examples

### Multi-Environment (this repo)
```
envs/
├── dev/
│   ├── deployment.yaml
│   └── service.yaml
├── staging/
│   ├── deployment.yaml
│   └── service.yaml
└── prod/
    ├── deployment.yaml
    └── service.yaml
```

### Multi-App + Multi-Env
```
apps/
├── frontend/
│   ├── dev/
│   ├── staging/
│   └── prod/
└── backend/
    ├── dev/
    ├── staging/
    └── prod/
```

### Kustomize-based
```
base/
├── deployment.yaml
└── service.yaml
overlays/
├── dev/
│   └── kustomization.yaml
├── staging/
│   └── kustomization.yaml
└── prod/
    └── kustomization.yaml
```

## Testing Your ApplicationSet

```bash
# 1. Apply to cluster
kubectl apply -f applicationset.yaml

# 2. Wait for Applications to generate
sleep 5

# 3. Verify Applications created
kubectl get app -n argocd | grep gitops-lab

# 4. Sync one Application manually
kubectl patch app -n argocd gitops-lab-dev -p '{"metadata": {"annotations": {"argocd.argoproj.io/refresh": "normal"}}}' --type merge

# 5. Or use argocd CLI
argocd app sync gitops-lab-dev

# 6. Check deployed resources
kubectl get all -n dev
```

## Rollback

```bash
# Delete generated Applications (keeps ApplicationSet)
kubectl delete app -n argocd -l app.kubernetes.io/instance=gitops-lab-envs

# Delete ApplicationSet (deletes all generated Applications)
kubectl delete applicationset -n argocd gitops-lab-envs

# Delete ApplicationSet but preserve Applications
kubectl delete applicationset -n argocd gitops-lab-envs --cascade=orphan
```

## Common Gotchas

1. **ApplicationSet name**: Must be unique in the namespace
2. **Generated App names**: Template must produce unique names
3. **Repo URL**: Must match exactly in all places (no trailing slash)
4. **Path patterns**: Use `envs/*` not `envs/**` for one level
5. **Auto-sync**: Generated apps inherit the syncPolicy from template
6. **Namespace creation**: Add `CreateNamespace=true` to syncOptions

## Performance Tips

- Use `requeueAfterSeconds` to control git polling frequency
- Filter directories with `exclude` patterns to reduce processing
- Use cluster generator with label selectors to target specific clusters
- Combine generators with matrix only when necessary (can be slow)

## Security Considerations

```yaml
# Restrict which namespaces can be targeted
spec:
  template:
    spec:
      destination:
        namespace: 'app-{{path.basename}}'  # prefix to prevent conflicts

# Limit resource creation
spec:
  template:
    spec:
      project: restricted  # use AppProject with restrictions
```

## Next Steps

1. Read `docs/applicationset-guide.md` for detailed patterns
2. Experiment with different generators
3. Try combining generators with matrix
4. Explore progressive sync strategies
5. Integrate with Argo Rollouts for advanced deployments
