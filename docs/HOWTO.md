# GitOps Lab: Complete HOWTO

This is a hands-on guide for setting up a complete GitOps workflow on your laptop using kind (Kubernetes-in-Docker) and ArgoCD. By the end, you'll understand the full GitOps loop: git → ArgoCD → cluster, with automatic reconciliation and drift detection.

---

## Table of Contents

1. [Prerequisites & Initial Setup](#procedure-1-prerequisites--initial-setup)
2. [Install ArgoCD](#procedure-2-install-argocd)
3. [Create Your GitOps Repository](#procedure-3-create-your-gitops-repository)
4. [Point ArgoCD at Your Repo](#procedure-4-point-argocd-at-your-repo)
5. [Prove It's Real](#procedure-5-prove-its-real)
6. [Understanding ApplicationSets](#understanding-applicationsets)
7. [Multi-Environment Setup with ApplicationSets](#procedure-6-multi-environment-setup-with-applicationsets)
8. [Database Considerations](#database-considerations)

---

## What is GitOps?

GitOps is a way of managing Kubernetes where:

1. **Git is the source of truth** - All your cluster configuration lives in a git repository
2. **A controller watches git** - ArgoCD (or Flux) runs *inside* your cluster and continuously polls the git repo
3. **The controller reconciles** - When git changes, the controller applies those changes to your cluster
4. **Drift is detected** - If someone manually changes something in the cluster, ArgoCD notices and can revert it

**Key insight**: All the active machinery lives *inside* your Kubernetes cluster. Git is just passive storage. The GitOps controller (ArgoCD) polls git every few minutes, compares what it finds to the cluster state, and reconciles any differences.

This is the same control-loop pattern that Kubernetes itself uses (see [WHY_KUBERNETES.md](WHY_KUBERNETES.md) § 2.2), just pointed at git instead of etcd.

For the complete architectural explanation, see [GITOPS.md](GITOPS.md).

---

## Procedure 1: Prerequisites & Initial Setup

This guide assumes you're on Linux (Mint, Ubuntu, etc.). Adapt as needed for macOS.

### 1.1 Install Docker

```bash
# Install Docker if not already present
sudo apt install docker.io

# Add your user to docker group (log out/in after this!)
sudo usermod -aG docker $USER
```

**Important**: Log out and back in for the group change to take effect.

### 1.2 Install kubectl

```bash
# Download latest kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Install it
sudo install kubectl /usr/local/bin/

# Verify
kubectl version --client
```

### 1.3 Install kind

```bash
# Download kind
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64

# Install it
sudo install kind /usr/local/bin/

# Verify
kind version
```

### 1.4 Create a Kubernetes Cluster

```bash
kind create cluster --name gitops-lab
```

This creates a local Kubernetes cluster running in Docker. It takes about 30-60 seconds.

### 1.5 Verify the Cluster

```bash
kubectl cluster-info
kubectl get nodes
```

You should see one node named `gitops-lab-control-plane` in Ready status.

---

## Procedure 2: Install ArgoCD

ArgoCD is the GitOps controller that will watch your git repository and reconcile your cluster to match it.

### 2.1 Install ArgoCD into the Cluster

```bash
# Create namespace for ArgoCD
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for it to be ready (takes 1-2 minutes)
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```

### 2.2 Access the ArgoCD UI

ArgoCD provides a web UI for visualizing your applications and their sync status.

```bash
# Port-forward the ArgoCD server to your localhost
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

**Important**: Leave this running in one terminal (it will occupy that terminal). The port-forward doesn't persist - if you close the terminal or Ctrl+C, you'll need to run it again to access the UI.

In another terminal:

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo  # adds newline
```

Now open **https://localhost:8080** in your browser:
- **Important**: Use `https://` not `http://`
- Your browser will warn about an untrusted certificate (self-signed) - click "Advanced" → "Proceed" or "Accept the Risk"
- Username: `admin`
- Password: (the value from above)

You should see the ArgoCD UI with no applications yet.

---

## Procedure 3: Create Your GitOps Repository

You need a git repository containing Kubernetes manifests for ArgoCD to watch.

### Option A: Use GitHub

1. Fork this repository (https://github.com/wware/gitops-lab) to your own GitHub account
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-username>/gitops-lab
   cd gitops-lab
   ```

**When to use**: Learning GitOps patterns, sharing repos, eventually deploying to real cloud clusters.

### Option B: Use Local Gitea (Recommended for Local Development)

Gitea gives you a full GitHub-like experience (web UI, multiple repos, users) running entirely on your laptop.

#### 1. Run Gitea

```bash
docker run -d --name gitea \
  -p 3000:3000 \
  -p 2222:22 \
  -v gitea-data:/data \
  gitea/gitea:latest
```

Wait ~10 seconds, then visit http://localhost:3000. Click through the install wizard (defaults are fine) and create an admin account.

#### 2. Find your Docker bridge IP

ArgoCD running in the cluster needs to reach Gitea on your host. `localhost` won't work (it would mean "the pod itself").

```bash
ip -4 addr show docker0 | grep inet
# Typically shows: inet 172.17.0.1/16
```

That IP (`172.17.0.1`) is how ArgoCD will reach your host.

**Note**: If kind nodes are on a different Docker network, find the gateway IP:
```bash
docker network inspect kind | grep Gateway
# Use that IP instead of 172.17.0.1
```

#### 3. Create repo and push

1. In Gitea UI: **+ → New Repository**, name it `gitops-lab`, don't initialize with README
2. Clone this repo and push to Gitea:
   ```bash
   git clone https://github.com/wware/gitops-lab
   cd gitops-lab
   git remote add gitea http://localhost:3000/<your-gitea-username>/gitops-lab.git
   git push gitea main
   ```

Your repository URL for ArgoCD will be:
```
http://172.17.0.1:3000/<your-gitea-username>/gitops-lab.git
```

**Troubleshooting**: If ArgoCD can't reach Gitea later:

```bash
# Ensure both containers are on the same network
docker network inspect bridge | grep gitea
docker network inspect bridge | grep kind

# Verify Gitea is reachable from kind
docker exec -it gitops-lab-control-plane curl http://172.17.0.1:3000

# If kind nodes are on a different Docker network, find the gateway IP:
docker network inspect kind | grep Gateway
# Then use that IP instead of 172.17.0.1 in your repoURL
```

**When to use**: Fully local development with a nice UI, multiple repos, experimenting without touching GitHub.

### What's in the Repo

The minimal structure needed:

```
gitops-lab/
├── deployment.yaml       # A simple nginx deployment
├── service.yaml          # A service to expose it
├── argocd-app.yaml       # Tells ArgoCD about this repo (applied manually once)
└── envs/                 # For multi-environment setup (optional)
    ├── dev/
    ├── staging/
    └── prod/
```

---

## Procedure 4: Point ArgoCD at Your Repo

Now we tell ArgoCD to watch your repository and reconcile the cluster to match it.

### 4.1 Update the Application Manifest

Edit `argocd-app.yaml` and change the `repoURL` to match your choice from Procedure 3.

**For GitHub (Option A):**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitops-lab
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-username>/gitops-lab
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
```

**For Gitea (Option B):**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitops-lab
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://172.17.0.1:3000/<your-gitea-username>/gitops-lab.git
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
```

**Note**: We start with `automated.prune: false` and `selfHeal: false` so you can watch each sync manually and understand what's happening. You can flip these to `true` later.

### 4.2 Apply the Application

This is the **only** manual `kubectl apply` you'll do. After this, everything flows through git → ArgoCD.

```bash
kubectl apply -f argocd-app.yaml
```

### 4.3 Check the ArgoCD UI

Refresh https://localhost:8080. You should see a new application called `gitops-lab` with status `OutOfSync` (yellow).

Click on it to see:
- What resources are defined in git
- What's currently in the cluster (nothing yet)
- The diff between them

### 4.4 Sync It

Click the **Sync** button in the UI, then **Synchronize**.

ArgoCD will apply all the manifests from your git repo to the cluster. After a few seconds, you should see:
- Status changes to `Synced` (green)
- The deployment and service appear in the resource tree

### 4.5 Verify the Deployment

```bash
# Check pods
kubectl get pods

# Check service
kubectl get svc

# See the app (if service type is LoadBalancer or you port-forward)
kubectl port-forward svc/gitops-lab 8081:80
# Visit http://localhost:8081 in your browser
```

---

## Procedure 5: Prove It's Real

Now we test the GitOps loop: git → ArgoCD → cluster.

### 5.1 Test: Change Propagation (Git → Cluster)

1. **Edit a manifest in git**:
   ```bash
   # In your gitops-lab directory
   vim deployment.yaml
   # Change replicas: 2 to replicas: 3
   ```

2. **Commit and push**:
   ```bash
   git add deployment.yaml
   git commit -m "Scale to 3 replicas"

   # If using GitHub (Option A):
   git push

   # If using Gitea (Option B):
   git push gitea main
   ```

3. **Wait and watch**:
   - ArgoCD polls git every 3 minutes by default
   - Or click **Refresh** in the UI to force immediate poll
   - You'll see `OutOfSync` appear (yellow)
   - Click **Sync** to apply the change

4. **Verify**:
   ```bash
   kubectl get pods
   # Should now show 3 pods instead of 2
   ```

**What just happened**: You changed the source of truth (git), ArgoCD noticed, and you approved the change. The cluster now matches git.

### 5.2 Test: Drift Detection (Manual Change → Alert)

1. **Manually change something in the cluster**:
   ```bash
   kubectl scale deployment/gitops-lab --replicas=5
   ```

2. **Watch the UI**:
   - After a few seconds, the application shows `OutOfSync` (yellow)
   - Click in to see the diff: git says 3 replicas, cluster has 5
   - This is **drift detection** - ArgoCD knows cluster state doesn't match git

3. **What happens next depends on your sync policy**:
   - With `selfHeal: false` (current): ArgoCD just alerts you, doesn't auto-fix
   - With `selfHeal: true`: ArgoCD would automatically scale back to 3

4. **Manually revert the drift**:
   - Click **Sync** in the UI
   - ArgoCD scales back to 3 replicas to match git

**What just happened**: Someone (you) made a manual change outside of git. ArgoCD detected it and flagged it as drift. You chose to reconcile back to git's version.

### 5.3 Test: Auto-Sync and Self-Heal (Optional)

If you want ArgoCD to automatically apply changes and revert drift:

1. **Edit `argocd-app.yaml`**:
   ```yaml
   syncPolicy:
     automated:
       prune: true       # Auto-delete resources removed from git
       selfHeal: true    # Auto-revert manual changes
   ```

2. **Apply the change**:
   ```bash
   kubectl apply -f argocd-app.yaml
   ```

3. **Now test**:
   - Change replicas in git, push → ArgoCD applies automatically (no manual sync needed)
   - `kubectl scale deployment/gitops-lab --replicas=7` → ArgoCD reverts to git's value within seconds

**Warning**: `prune: true` is powerful but dangerous. If you remove a resource from git (or change the path), ArgoCD will **delete** it from the cluster. Use with caution.

---

## Understanding ApplicationSets

**ApplicationSets** automate the creation of multiple ArgoCD Applications from a single template. Instead of manually creating separate `Application` manifests for dev, staging, and prod, you define one `ApplicationSet` that generates all three automatically.

Think of it as a loop:

```python
for env in ['dev', 'staging', 'prod']:
    create_application(
        name=f'myapp-{env}',
        path=f'envs/{env}',
        namespace=env
    )
```

**Key benefits**:
- One manifest instead of three (or dozens)
- Add new environment = create new directory (no ArgoCD config changes)
- Update all environments at once by changing the template

For a complete explanation of generators, template parameters, and advanced patterns, see **[applicationset-guide.md](applicationset-guide.md)**.

---

## Procedure 6: Multi-Environment Setup with ApplicationSets

This repository includes an example ApplicationSet that automatically deploys to dev, staging, and prod environments.

### 6.1 Understand the Repository Structure

```
gitops-lab/
├── argocd-app.yaml           # Single-app Application (from Procedure 4)
├── applicationset.yaml       # Multi-env ApplicationSet
├── deployment.yaml           # Root-level manifests (for single app)
├── service.yaml
└── envs/                     # Multi-environment manifests
    ├── dev/
    │   ├── deployment.yaml   # 1 replica, minimal resources
    │   └── service.yaml
    ├── staging/
    │   ├── deployment.yaml   # 2 replicas, medium resources
    │   └── service.yaml
    └── prod/
        ├── deployment.yaml   # 3 replicas, higher resources
        └── service.yaml
```

### 6.2 Examine the ApplicationSet

Look at `applicationset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: gitops-lab-envs
  namespace: argocd
spec:
  # Git directory generator scans envs/* and creates one app per directory
  generators:
  - git:
      repoURL: https://github.com/<you>/gitops-lab
      revision: main
      directories:
      - path: envs/*              # Matches envs/dev, envs/staging, envs/prod
  template:
    metadata:
      name: 'gitops-lab-{{path.basename}}'  # Creates: gitops-lab-dev, gitops-lab-staging, gitops-lab-prod
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/gitops-lab
        targetRevision: main
        path: '{{path}}'          # Each app points to its own directory
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'  # Each app deploys to its own namespace
      syncPolicy:
        automated:
          prune: false
          selfHeal: false
        syncOptions:
          - CreateNamespace=true  # Auto-create dev, staging, prod namespaces
```

**How it works**:
1. Generator scans git repo and finds 3 directories: `envs/dev`, `envs/staging`, `envs/prod`
2. For each directory, it renders the template with `path=envs/dev`, `path.basename=dev`, etc.
3. Three Applications are created automatically

### 6.3 Update the ApplicationSet Repo URL

Edit `applicationset.yaml` and change the `repoURL` (appears twice) to your repository:

```yaml
repoURL: https://github.com/<your-username>/gitops-lab
```

### 6.4 Apply the ApplicationSet

```bash
kubectl apply -f applicationset.yaml
```

### 6.5 Watch the Magic Happen

```bash
# Check the ApplicationSet
kubectl get applicationsets -n argocd

# Check generated Applications
kubectl get applications -n argocd

# You should see:
# - gitops-lab (from Procedure 4)
# - gitops-lab-dev (generated)
# - gitops-lab-staging (generated)
# - gitops-lab-prod (generated)
```

In the ArgoCD UI (https://localhost:8080), you should now see four applications.

### 6.6 Sync the Environments

Each generated Application starts `OutOfSync`. Click into each one and sync it:

1. Click `gitops-lab-dev` → Sync
2. Click `gitops-lab-staging` → Sync
3. Click `gitops-lab-prod` → Sync

Alternatively, sync all at once:

```bash
# If you have argocd CLI installed
argocd app sync -l app.kubernetes.io/instance=gitops-lab-envs
```

### 6.7 Verify All Environments

```bash
# Check all namespaces
kubectl get pods --all-namespaces

# Check each environment
kubectl get pods -n dev       # Should see 1 pod
kubectl get pods -n staging   # Should see 2 pods
kubectl get pods -n prod      # Should see 3 pods

# See resource differences
kubectl get deployment -n dev -o yaml | grep -A 5 resources
kubectl get deployment -n prod -o yaml | grep -A 5 resources
```

### 6.8 Test: Add a New Environment

The power of ApplicationSets: adding a new environment requires zero changes to ArgoCD configuration.

1. **Create a new environment directory**:
   ```bash
   mkdir -p envs/qa
   cp envs/dev/deployment.yaml envs/qa/
   cp envs/dev/service.yaml envs/qa/
   ```

2. **Edit the QA manifests** (change replicas, resources, labels as desired):
   ```bash
   vim envs/qa/deployment.yaml
   # Change env: dev to env: qa, set replicas: 2, etc.
   ```

3. **Commit and push**:
   ```bash
   git add envs/qa/
   git commit -m "Add QA environment"
   git push
   ```

4. **Watch ArgoCD**:
   - Wait ~3 minutes or click Refresh in the UI
   - A new application `gitops-lab-qa` appears automatically!
   - Sync it and you have a fourth environment

**What just happened**: The git directory generator re-scanned the repo, found a new directory, and created a new Application. No changes to `applicationset.yaml` were needed.

### 6.9 Test: Update All Environments at Once

Change something in the ApplicationSet template to affect all environments:

1. **Edit `applicationset.yaml`**:
   ```yaml
   syncPolicy:
     automated:
       prune: false
       selfHeal: true    # Change from false to true for all environments
   ```

2. **Apply**:
   ```bash
   kubectl apply -f applicationset.yaml
   ```

3. **Result**: All generated Applications now have `selfHeal: true`. One change, three (or four) apps updated.

---

## Database Considerations

A common question: "How do databases fit into GitOps?"

### The Short Answer

**Database infrastructure** (the existence of the DB instance) and **app connection config** (how to reach the DB) are GitOps-managed. The **database's data** is not.

### The Detailed Breakdown

| Concern | GitOps or Not? | How? |
|---------|----------------|------|
| **DB instance creation** | Usually not GitOps | Use Terraform/Pulumi to create RDS/Cloud SQL instance |
| **App connection config** | Yes, GitOps | ConfigMaps/Secrets in git with DB endpoint, port, etc. |
| **DB credentials** | Yes, GitOps (but encrypted) | Use External Secrets Operator or Sealed Secrets |
| **Schema migrations** | Hybrid | Often a Kubernetes Job with PreSync hook, or in CI before deploy |
| **Backups, HA, failover** | Not GitOps | Use managed service (RDS) or DB operator (CloudNativePG) |

### Why Not GitOps the Database Itself?

GitOps is great for things where "reapply desired state" is safe and idempotent. A Deployment fits this model: if you delete a pod, Kubernetes recreates it to match desired state.

A database's *data* doesn't fit this model:
- Reapplying "desired state" won't restore deleted data
- Reconciliation loops don't help with schema migrations (one-time imperative actions)
- Backup/restore needs explicit tooling, not continuous reconciliation

### The Common Pattern

1. **Provision DB outside GitOps**: Use Terraform to create an RDS instance
2. **Store connection info in GitOps**: ConfigMap with DB hostname, port
3. **Store credentials securely**: External Secrets Operator pulls from AWS Secrets Manager
4. **Schema migrations**: Kubernetes Job with ArgoCD PreSync hook (git-triggered, not continuously reconciled)
5. **Backups/HA**: Managed service handles this, or use a DB operator

### Example: External Secrets Operator

Instead of storing DB passwords in git (bad!), you store a *reference* to a secret vault:

```yaml
# In git (safe to commit)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: db-credentials
  data:
  - secretKey: password
    remoteRef:
      key: prod/db/password
```

ArgoCD syncs this `ExternalSecret`. The External Secrets Operator reads it, fetches the actual password from AWS Secrets Manager, and creates a regular Kubernetes `Secret`. Your app uses that `Secret`.

Result: Git has no secrets, just pointers. The vault manages rotation and access control.

For more details, see **[WHY_KUBERNETES.md](WHY_KUBERNETES.md) § 7.5** on StatefulSets and the database problem.

---

## Next Steps

You now have a working GitOps setup! Here's what to explore next:

### Learn More About GitOps Architecture
- Read [GITOPS.md](GITOPS.md) for the complete architectural explanation
- Understand pull vs. push, multi-cluster patterns, and secrets management

### Experiment with ArgoCD Features
- Try `prune: true` and `selfHeal: true` (carefully!)
- Set up notifications (Slack, email) for sync failures
- Explore the App of Apps pattern for managing multiple applications

### Try ApplicationSet Advanced Patterns
- Matrix generator (deploy multiple apps to multiple clusters)
- Cluster generator (auto-discover clusters)
- Git files generator (one JSON/YAML file per environment with custom parameters)
- See `docs/applicationset-guide.md` and `docs/applicationset-examples.yaml`

### Add Real Security
- Set up External Secrets Operator
- Use Sealed Secrets for simple cases
- Rotate ArgoCD admin password and set up SSO

### Deploy a Real Application
- Replace `nginxdemos/hello` with your own app
- Add ConfigMaps and Secrets
- Set up Ingress for external access
- Add HorizontalPodAutoscaler

### Multi-Cluster GitOps
- Spin up a second kind cluster
- Register it with ArgoCD
- Use one ApplicationSet to deploy to both clusters

---

## Common Issues and Troubleshooting

### ArgoCD UI shows 404 or won't load

**Symptom**: Visiting localhost:8080 shows "404 Not Found" or connection refused

**Fix**:
1. **Did you start the port-forward?** This is required and doesn't persist between terminal sessions:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
   Leave this running in a terminal (it will occupy that terminal).

2. Make sure you're using **https://** not http://: `https://localhost:8080`

3. Accept the browser's security warning (self-signed certificate)

### ArgoCD shows "ComparisonError" or can't reach git

**Symptom**: Application shows red status, error about git clone failure

**Fix**:
1. If using GitHub, check the repo URL is correct and public (or add credentials)
2. If using Gitea:
   - Verify Gitea is running: `docker ps | grep gitea`
   - Check you're using the Docker bridge IP (`172.17.0.1`), not `localhost`
   - Test from within the cluster: `kubectl run -it --rm test --image=alpine -- sh -c "apk add curl && curl http://172.17.0.1:3000"`
   - Ensure kind and Gitea are on the same Docker network (see Procedure 3, Option B troubleshooting)
3. Check ArgoCD logs for details:
   ```bash
   kubectl logs -n argocd deployment/argocd-repo-server
   ```

### Applications stay "OutOfSync"

**Symptom**: After syncing, status immediately reverts to OutOfSync

**Fix**:
1. Check for server-side defaulting (Kubernetes adds fields not in your manifests)
2. Use ArgoCD's diff ignore annotations for fields that always change
3. Check if another controller (HPA, etc.) is modifying resources

### Drift keeps recurring

**Symptom**: You sync, but manual changes keep reappearing

**Fix**:
1. Someone (or something) is still making manual changes
2. Enable `selfHeal: true` to auto-revert
3. Or investigate who/what is changing things (check audit logs, CI pipelines)

### ApplicationSet doesn't generate applications

**Symptom**: ApplicationSet exists but no Applications appear

**Fix**:
1. Check generator is finding matches:
   ```bash
   kubectl logs -n argocd deployment/argocd-applicationset-controller
   ```
2. Verify git paths are correct (case-sensitive!)
3. Check repo URL is correct and accessible

---

## Summary

You've learned:

1. **GitOps fundamentals**: Git as source of truth, pull-based reconciliation
2. **ArgoCD setup**: Install, configure, access UI
3. **Application management**: Create, sync, detect drift
4. **ApplicationSets**: Auto-generate applications from templates
5. **Multi-environment patterns**: One manifest, many environments
6. **Local development**: Use Gitea for fully local GitOps
7. **Real-world considerations**: Databases, secrets, migrations

The key insight: **GitOps is Kubernetes' reconciliation pattern applied to git**. The controller continuously re-asserts git as truth, giving you declarative infrastructure with automatic drift detection and trivial rollback.

For deeper dives:
- **[GITOPS.md](GITOPS.md)** - Complete architectural explanation
- **[WHY_KUBERNETES.md](WHY_KUBERNETES.md)** - Kubernetes fundamentals
- **[applicationset-guide.md](applicationset-guide.md)** - ApplicationSet generators, patterns, and advanced features
- **[applicationset-quickref.md](applicationset-quickref.md)** - Quick reference

Now go experiment! The best way to learn GitOps is to:
1. Make changes in git
2. Watch ArgoCD reconcile
3. Make manual changes in the cluster
4. Watch ArgoCD detect drift
5. Break things intentionally and see how the system recovers
