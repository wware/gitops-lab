# Connecting GitOps to an Existing Kubernetes Repository

This guide shows how to use ArgoCD to manage an existing Kubernetes project (like `../k8s-hack`) using GitOps principles.

## Overview

You already have:
- A working ArgoCD installation in your `gitops-lab` cluster
- Experience with Applications and ApplicationSets
- Local Gitea running at `http://172.22.0.3:3000`

Now you want to:
- Point ArgoCD at a different repository (your existing k8s project)
- Have ArgoCD manage those resources
- Use GitOps to deploy and update your application

## Prerequisites

1. **Existing Kubernetes manifests** - Your repository should contain valid k8s YAML files
2. **Git repository** - Your code should be in a git repository (local or remote)
3. **Working ArgoCD** - Complete the main HOWTO.md setup first

## Approach: Two Options

### Option A: Local Repository via Gitea

If your existing repo is local (like `../k8s-hack`), push it to your local Gitea instance.

**Steps:**

1. **Create a new repository in Gitea**
   - Navigate to `http://localhost:3000` (port-forward if needed)
   - Click the `+` icon → "New Repository"
   - Name it (e.g., `k8s-hack`)
   - Make it public or private as needed

2. **Push your existing repository to Gitea**
   ```bash
   cd ../k8s-hack

   # Add Gitea as a remote (if not already configured)
   git remote add gitea http://wware:PASSWORD@localhost:3000/wware/k8s-hack.git

   # Push your code
   git push gitea main
   ```

3. **Create an ArgoCD Application manifest**

   Create a file `argocd-k8s-hack.yaml` (DO NOT commit to the watched repo):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: k8s-hack
     namespace: argocd
   spec:
     project: default
     source:
       # Gitea repository URL (from inside the kind network)
       repoURL: http://172.22.0.3:3000/wware/k8s-hack.git
       targetRevision: main
       # Path within the repo where your manifests live
       path: .  # or manifests/, deploy/, k8s/, etc.
     destination:
       server: https://kubernetes.default.svc
       # Namespace where your app will be deployed
       namespace: default  # or create a new namespace
     syncPolicy:
       automated:
         prune: false  # Start with false, enable later
         selfHeal: false  # Start with false, enable later
       syncOptions:
         - CreateNamespace=true
   ```

4. **Apply the Application**
   ```bash
   kubectl apply -f argocd-k8s-hack.yaml
   ```

5. **Verify in ArgoCD UI**
   - Port-forward: `kubectl port-forward svc/argocd-server -n argocd 8080:443`
   - Navigate to `https://localhost:8080`
   - You should see your new `k8s-hack` Application

### Option B: Remote Repository (GitHub, GitLab, etc.)

If your repository is already on GitHub or another git host:

1. **Create an ArgoCD Application manifest**

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: k8s-hack
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/wware/k8s-hack  # Your GitHub URL
       targetRevision: main
       path: .  # Path to manifests in your repo
     destination:
       server: https://kubernetes.default.svc
       namespace: default
     syncPolicy:
       automated:
         prune: false
         selfHeal: false
       syncOptions:
         - CreateNamespace=true
   ```

2. **Apply it**
   ```bash
   kubectl apply -f argocd-k8s-hack.yaml
   ```

## Repository Structure Considerations

ArgoCD works best when your Kubernetes manifests are organized clearly. Common patterns:

### Pattern 1: Flat Structure
```
k8s-hack/
├── deployment.yaml
├── service.yaml
├── configmap.yaml
└── ingress.yaml
```
Use `path: .` in your Application spec.

### Pattern 2: Dedicated Directory
```
k8s-hack/
├── src/
├── tests/
└── k8s/
    ├── deployment.yaml
    ├── service.yaml
    └── configmap.yaml
```
Use `path: k8s` in your Application spec.

### Pattern 3: Multi-Environment
```
k8s-hack/
├── base/
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    ├── staging/
    └── prod/
```
Use Kustomize or create separate Applications for each environment.

## Finding the Right Path

If you're not sure where your manifests are:

```bash
cd ../k8s-hack
find . -name "*.yaml" -o -name "*.yml" | grep -v node_modules | grep -v .git
```

This shows all YAML files in your repo. Look for Kubernetes manifests (files with `kind: Deployment`, `kind: Service`, etc.).

## Working with Local Docker Images (kind clusters)

If your application uses locally-built Docker images (like `k8s-toy-api:local`), kind clusters won't have access to them by default.

### The Problem

You'll see `ImagePullBackOff` errors:
```bash
kubectl get pods
# NAME                       READY   STATUS             RESTARTS   AGE
# toy-api-846775567-cwlzz    0/1     ImagePullBackOff   0          2m
```

This happens because kind runs in containers and doesn't automatically have access to your host's Docker images.

### The Solution

Load your local images into the kind cluster:

```bash
# Build your image (if not already built)
cd ../k8s-hack
docker build -t k8s-toy-api:local .

# Load it into the kind cluster
kind load docker-image k8s-toy-api:local --name gitops-lab

# Verify it loaded
docker exec -it gitops-lab-control-plane crictl images | grep toy-api
```

**After loading the image**, the pods should automatically restart and pull successfully. If they don't restart on their own:

```bash
# Force a restart by deleting the pods (deployment will recreate them)
kubectl delete pods -l app=toy-api
```

### Alternative: Use imagePullPolicy: Never

If you're frequently rebuilding, you can set `imagePullPolicy: Never` in your deployment:

```yaml
spec:
  containers:
  - name: toy-api
    image: k8s-toy-api:local
    imagePullPolicy: Never  # Don't try to pull, use local image only
```

This tells Kubernetes to never try pulling from a registry and only use what's already loaded in the cluster.

**Important:** When you rebuild your image, you must reload it into kind and restart the pods:
```bash
docker build -t k8s-toy-api:local .
kind load docker-image k8s-toy-api:local --name gitops-lab
kubectl rollout restart deployment/toy-api
```

## Accessing Your Deployed Application

Once your application is running (all pods show `Running` status), you need to access it. There are several ways:

### Method 1: Port Forwarding (Easiest)

Forward a local port to your service:

```bash
# Forward to a service
kubectl port-forward svc/toy-api 8082:8000

# Or forward directly to a pod
kubectl port-forward pod/toy-api-846775567-cwlzz 8082:8000
```

**Then visit:** `http://localhost:8082`

**Tips:**
- Use a different port (8082) if 8080/8081 are already in use
- The format is `LOCAL_PORT:CONTAINER_PORT`
- Port-forward runs in foreground; Ctrl+C to stop

### Method 2: NodePort Service

If your service is type `NodePort`, find the assigned port:

```bash
kubectl get svc toy-api
# NAME      TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)          AGE
# toy-api   NodePort   10.96.120.45    <none>        8000:30080/TCP   5m
```

The NodePort is `30080` in this example. Access it via:

```bash
# Get the kind cluster's IP (usually 127.0.0.1 for kind)
kubectl cluster-info

# Visit the NodePort
curl http://localhost:30080
```

**Or visit in browser:** `http://localhost:30080`

### Method 3: Ingress (Advanced)

For production-like access, set up an Ingress controller:

```bash
# Install nginx ingress for kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for it to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

Then create an Ingress resource in your repo:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: toy-api-ingress
spec:
  rules:
  - host: toy-api.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: toy-api
            port:
              number: 8000
```

Add to `/etc/hosts`:
```
127.0.0.1 toy-api.local
```

**Visit:** `http://toy-api.local`

### Quick Reference: Common Port Forwards

```bash
# ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Visit: https://localhost:8080

# Your application (adjust service name and ports)
kubectl port-forward svc/toy-api 8082:8000
# Visit: http://localhost:8082

# PostgreSQL (if you need direct DB access)
kubectl port-forward svc/postgres 5432:5432
# Connect: psql -h localhost -p 5432 -U youruser

# Gitea
docker exec gitea sh -c 'netstat -tln | grep 3000'
# Visit: http://localhost:3000 (if mapped in docker run)
```

### Finding Your Service's Port

If you're not sure what port your service uses:

```bash
# List all services
kubectl get svc

# Describe a specific service
kubectl describe svc toy-api

# See the port mapping
kubectl get svc toy-api -o jsonpath='{.spec.ports[0].port}'
```

The output shows the port your service listens on inside the cluster. Use that as the second number in your port-forward command.

## Common Issues and Solutions

### Issue: "ImagePullBackOff" on local images

**Cause:** kind cluster doesn't have access to locally-built Docker images.

**Solution:** Load the image into kind (see "Working with Local Docker Images" section above).

### Issue: "ComparisonError: path does not exist"

**Cause:** The `path` in your Application spec doesn't exist in the repository.

**Solution:**
- Verify the path exists: `ls -la` in your repo
- Update the Application's `source.path` field
- Reapply: `kubectl apply -f argocd-k8s-hack.yaml`

### Issue: "OutOfSync" status

**Cause:** Resources in the cluster don't match what's in git.

**Solution:** This is normal! Click "Sync" in the ArgoCD UI or run:
```bash
kubectl patch application k8s-hack -n argocd --type merge -p '{"operation":{"sync":{}}}'
```

### Issue: "Degraded" health status

**Cause:** Pods aren't starting, resources have errors.

**Solution:**
- Check the ArgoCD UI for specific error messages
- Inspect pods: `kubectl get pods -n <namespace>`
- Check logs: `kubectl logs <pod-name> -n <namespace>`

### Issue: Gitea repository "not found"

**Cause:** ArgoCD can't reach Gitea or wrong IP address.

**Solution:**
- Verify Gitea is on the kind network: `docker network inspect kind | grep -A 5 gitea`
- Check the IP in your Application's `repoURL` matches
- Test connectivity from a pod:
  ```bash
  kubectl run git-test --image=alpine/git --rm -it --restart=Never -- \
    ls-remote http://172.22.0.3:3000/wware/k8s-hack.git HEAD
  ```

## Testing the GitOps Loop

Once your Application is synced and healthy:

1. **Make a change in your repository**
   ```bash
   cd ../k8s-hack
   # Edit a manifest, e.g., change replica count
   git add .
   git commit -m "Test GitOps: increase replicas"
   git push gitea main  # or origin, depending on your setup
   ```

2. **Wait for ArgoCD to detect the change** (default: 3 minutes)
   - Or force a refresh: Click "Refresh" in the ArgoCD UI
   - Or via CLI: `kubectl patch application k8s-hack -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'`

3. **Observe the sync**
   - ArgoCD shows "OutOfSync"
   - If `automated.prune: false` and `selfHeal: false`, you must manually click "Sync"
   - If automated, ArgoCD syncs automatically

4. **Verify in your cluster**
   ```bash
   kubectl get pods -n <namespace>
   # You should see the changes applied
   ```

## Enabling Automation

Once you trust the setup, enable automated sync:

```bash
kubectl patch application k8s-hack -n argocd --type merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {
        "prune": true,
        "selfHeal": true
      }
    }
  }
}'
```

**What this does:**
- **selfHeal: true** - If someone manually changes resources in the cluster, ArgoCD reverts them to match git
- **prune: true** - If you delete a manifest from git, ArgoCD deletes the resource from the cluster

## Advanced: Multiple Environments for Your Existing Repo

If you want dev/staging/prod environments for your existing repo, create an ApplicationSet:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: k8s-hack-envs
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
      name: 'k8s-hack-{{env}}'
    spec:
      project: default
      source:
        repoURL: http://172.22.0.3:3000/wware/k8s-hack.git
        targetRevision: main
        path: .
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{env}}'
      syncPolicy:
        automated:
          prune: false
          selfHeal: false
        syncOptions:
          - CreateNamespace=true
```

This creates three Applications: `k8s-hack-dev`, `k8s-hack-staging`, `k8s-hack-prod`.

## Next Steps

1. **Start simple** - Get one Application working with manual sync
2. **Test the loop** - Make changes, push, sync, verify
3. **Enable automation** - Once confident, turn on automated sync
4. **Add more repos** - Create Applications for other projects
5. **Explore advanced patterns** - Kustomize overlays, Helm charts, multi-cluster

## Resources

- ArgoCD official docs: https://argo-cd.readthedocs.io/
- This repo's HOWTO: [docs/HOWTO.md](HOWTO.md)
- ApplicationSet guide: [docs/applicationset-guide.md](applicationset-guide.md)

## Key Principle

**Git is the source of truth.** Whatever is in your git repository's main branch is what will be deployed. If you want to change something in your cluster, change it in git and push. ArgoCD handles the rest.

---

## Quick Reference: Complete Workflow

### Initial Setup (One Time)

```bash
# 1. Push your repo to Gitea
cd ../k8s-hack
git remote add gitea http://wware:PASSWORD@localhost:3000/wware/k8s-hack.git
git push gitea main

# 2. Create Application manifest (outside the repo)
cat > argocd-k8s-hack.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: k8s-hack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://172.22.0.3:3000/wware/k8s-hack.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF

# 3. Apply the Application
kubectl apply -f argocd-k8s-hack.yaml

# 4. If using local Docker images, load them
docker build -t k8s-toy-api:local .
kind load docker-image k8s-toy-api:local --name gitops-lab

# 5. Access your application
kubectl port-forward svc/toy-api 8082:8000
# Visit: http://localhost:8082/api/v1/healthz
```

### Daily Development Workflow

```bash
# Make changes to your code
cd ../k8s-hack
# ... edit files ...

# Rebuild Docker image (if code changed)
docker build -t k8s-toy-api:local .
kind load docker-image k8s-toy-api:local --name gitops-lab

# Update manifests and push to Gitea
git add .
git commit -m "Update deployment configuration"
git push gitea main

# Watch ArgoCD detect and sync changes
kubectl get applications -n argocd -w
# Or refresh manually in UI

# Restart deployment to pick up new image
kubectl rollout restart deployment/toy-api
```

### Common Commands

```bash
# Check application status
kubectl get applications -n argocd
kubectl describe application k8s-hack -n argocd

# Check deployed resources
kubectl get pods,svc,deploy -n default

# View logs
kubectl logs -f deployment/toy-api
kubectl logs -f -l app=toy-api  # All pods with label

# Force ArgoCD to sync
kubectl patch application k8s-hack -n argocd \
  --type merge -p '{"operation":{"sync":{}}}'

# Delete and recreate (if needed)
kubectl delete application k8s-hack -n argocd
kubectl apply -f argocd-k8s-hack.yaml

# Port forwards (each in separate terminal)
kubectl port-forward svc/argocd-server -n argocd 8080:443  # ArgoCD UI
kubectl port-forward svc/toy-api 8082:8000                 # Your app
kubectl port-forward svc/postgres 5432:5432                # Database
```

### Debugging Tips

```bash
# Check why a pod is failing
kubectl describe pod <pod-name>
kubectl logs <pod-name>
kubectl logs <pod-name> --previous  # Previous container logs

# Test connectivity inside cluster
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://toy-api:8000/api/v1/healthz

# Check if image is loaded in kind
docker exec -it gitops-lab-control-plane crictl images | grep toy-api

# See what ArgoCD is comparing
kubectl get application k8s-hack -n argocd -o yaml

# Force refresh (re-check git repo)
kubectl patch application k8s-hack -n argocd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Understanding kind Networking

With kind clusters, **NodePorts don't work the same way** as regular Kubernetes:
- NodePort services are accessible inside the Docker network, not directly on localhost
- **Solution:** Always use `kubectl port-forward` for accessing services
- Alternative: Configure kind with `extraPortMappings` when creating the cluster

### Discovering API Endpoints

If you get 404 errors, your API might not be at the root path:

```bash
# Check logs to see what paths are being hit
kubectl logs -f deployment/toy-api | grep path

# Common API patterns:
# /api/v1/healthz
# /api/v1/docs
# /docs
# /swagger
# /health
# /ready

# Test from inside the cluster
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://toy-api:8000/  # Try different paths
```
