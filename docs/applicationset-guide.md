# ApplicationSet Guide

## What is an ApplicationSet?

An ApplicationSet is an ArgoCD resource that automates the creation and management of multiple ArgoCD Applications. Instead of manually creating an Application for each environment, cluster, or tenant, you define a template and let the ApplicationSet generate them automatically.

## Key Concepts

### Generators

Generators are the heart of ApplicationSets. They produce a set of parameters that are used to render Application templates. Common generators include:

1. **Git Directory Generator** (used in this repo)
   - Scans directories in a Git repository
   - Creates one Application per directory
   - Perfect for multi-environment setups

2. **List Generator**
   - Define a static list of parameters
   - Good for small, fixed sets of environments

3. **Cluster Generator**
   - Discovers registered clusters automatically
   - Great for multi-cluster deployments

4. **Matrix Generator**
   - Combines multiple generators
   - Example: deploy multiple apps to multiple clusters

5. **Git Files Generator**
   - Reads JSON/YAML files from a repository
   - Each file contains parameters for one Application

### Template Parameters

In the ApplicationSet template, you can use parameters from generators:

- `{{path}}` - full path from git directory generator
- `{{path.basename}}` - just the directory name
- `{{name}}` - from list/cluster generators
- Any custom parameters defined in your generator

## Example Patterns

### Pattern 1: Multi-Environment (This Repo)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: gitops-lab-envs
  namespace: argocd
spec:
  generators:
  - git:
      repoURL: https://github.com/<you>/gitops-lab
      revision: main
      directories:
      - path: envs/*
  template:
    metadata:
      name: 'gitops-lab-{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/gitops-lab
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: false
          selfHeal: false
        syncOptions:
          - CreateNamespace=true
```

### Pattern 2: List Generator (Simple Environments)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: simple-envs
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        replicas: "1"
      - env: staging
        replicas: "2"
      - env: prod
        replicas: "3"
  template:
    metadata:
      name: 'myapp-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/gitops-lab
        targetRevision: main
        path: base
        kustomize:
          replicas:
          - name: gitops-lab
            count: '{{replicas}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{env}}'
      syncPolicy:
        automated: {}
        syncOptions:
          - CreateNamespace=true
```

### Pattern 3: Multi-Cluster (Requires cluster registration)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: multi-cluster-app
  namespace: argocd
spec:
  generators:
  - cluster:
      selector:
        matchLabels:
          environment: production
  template:
    metadata:
      name: 'myapp-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/gitops-lab
        targetRevision: main
        path: base
      destination:
        server: '{{server}}'
        namespace: myapp
      syncPolicy:
        automated: {}
```

### Pattern 4: Matrix Generator (Apps × Environments)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: matrix-example
  namespace: argocd
spec:
  generators:
  - matrix:
      generators:
      - list:
          elements:
          - app: frontend
          - app: backend
      - git:
          repoURL: https://github.com/<you>/gitops-lab
          revision: main
          directories:
          - path: envs/*
  template:
    metadata:
      name: '{{app}}-{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/gitops-lab
        targetRevision: main
        path: 'apps/{{app}}/{{path.basename}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated: {}
        syncOptions:
          - CreateNamespace=true
```

## Usage Tips

### 1. Start Simple
Begin with the git directory generator (like in this repo) before exploring more complex patterns.

### 2. Namespace Strategy
Common strategies:
- One namespace per environment (dev, staging, prod)
- One namespace per tenant
- One namespace per app-environment combination

### 3. Sync Policies
- Start with `automated: false` to manually approve each sync
- Enable `prune: true` only after you're confident in your setup
- Use `selfHeal: true` in production to prevent drift

### 4. Testing
```bash
# Apply the ApplicationSet
kubectl apply -f applicationset.yaml

# Check that Applications were created
kubectl get applications -n argocd

# Watch the sync progress
kubectl get applications -n argocd -w

# Check resources in target namespaces
kubectl get all -n dev
kubectl get all -n staging
kubectl get all -n prod
```

### 5. Debugging

```bash
# Check ApplicationSet status
kubectl get applicationset -n argocd gitops-lab-envs -o yaml

# Check generated Applications
kubectl get applications -n argocd -l app.kubernetes.io/instance=gitops-lab-envs

# View ApplicationSet controller logs
kubectl logs -n argocd deployment/argocd-applicationset-controller
```

## Benefits

1. **DRY Principle**: Define once, deploy many times
2. **Consistency**: Same configuration pattern across all environments
3. **Automation**: Add a new environment by just adding a directory
4. **Scalability**: Easily manage dozens or hundreds of Applications
5. **Multi-tenancy**: Deploy the same app for multiple teams/customers

## Common Pitfalls

1. **Template conflicts**: Ensure generated Application names are unique
2. **Resource quotas**: Multiple environments multiply resource usage
3. **Git repo structure**: Plan your directory layout before creating ApplicationSets
4. **Overly complex generators**: Start simple, add complexity only when needed
5. **Forgotten sync policies**: Remember each generated Application gets its own sync policy

## Advanced Features

### Go Templating
ApplicationSet templates support Go template functions:

```yaml
name: '{{path.basename}}-app'
namespace: '{{path.basename | lower}}'  # lowercase the namespace
```

### Progressive Rollouts
Combine with Argo Rollouts for canary deployments across environments.

### PR-Based Environments
Use Git file generators to create temporary environments for each pull request.

### Monorepo Support
Use path patterns to deploy multiple microservices from a single repository.

## Further Reading

- [Official ArgoCD ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [ApplicationSet Generators Reference](https://argocd-applicationset.readthedocs.io/en/stable/Generators/)
- [Best Practices Guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/applicationset-best-practices/)
