# Real EKS Deployment Guide

**Status: Planning document - not yet implemented in this repo**

This guide walks through deploying the KEDA demo to a real AWS EKS cluster,
showing production patterns that differ from the local kind setup. While the
local kind demo is free, EKS has real costs - we'll cover both full production
setup and a cost-conscious "3-hour experiment" approach.

## Table of Contents

- [Cost Reality Check](#cost-reality-check)
- [The 3-Hour Cheap Experiment](#the-3-hour-cheap-experiment)
- [Prerequisites](#prerequisites)
- [Architecture Differences: kind vs EKS](#architecture-differences-kind-vs-eks)
- [Infrastructure Setup (Terraform)](#infrastructure-setup-terraform)
- [Application Changes for Production](#application-changes-for-production)
- [Deployment Steps](#deployment-steps)
- [Production Patterns](#production-patterns)
- [Cost Optimization](#cost-optimization)
- [Troubleshooting](#troubleshooting)

---

## Cost Reality Check

**Let's be honest about AWS costs upfront.**

### Ongoing Costs (if you leave it running)

| Resource | Cost per Month | Notes |
|----------|----------------|-------|
| EKS Control Plane | $73 | Fixed, per cluster |
| EC2 Nodes (t3.medium x2) | ~$60 | ~$0.042/hour/instance |
| Application Load Balancer | ~$20 | If using ALB Ingress Controller |
| NAT Gateway | ~$32 | $0.045/hour + data transfer |
| EBS Volumes (100GB) | ~$10 | For persistent storage |
| Data Transfer | ~$10-50 | Varies widely |
| CloudWatch Logs | ~$5-20 | Depends on volume |
| **Total** | **~$210-265/month** | **If left running!** |

### The Problem

EKS is designed for production workloads that run 24/7. Using it for learning is
like renting a bulldozer to dig a garden hole. It works, but it's expensive.

**The lesson:** Production Kubernetes is operationally complex AND costly. This
is why managed services (ECS, Lambda, Cloud Run) exist for simple workloads.

### The Solution: Time-boxed Experiments

**Costs for a 3-hour experiment:** ~$2-5

The key insight: Most AWS resources are billed by the hour. Spin up, learn,
tear down immediately.

---

## The 3-Hour Cheap Experiment

**Goal:** Experience real EKS deployment for minimal cost (~$3-5 total)

**What you'll learn:**
- Terraform EKS provisioning
- IAM roles for service accounts (IRSA)
- SQS integration with KEDA
- ECR image registry
- Production vs local differences
- Why EKS is expensive (firsthand!)

**What you'll skip:**
- Persistent storage (use emptyDir)
- Monitoring stack (Prometheus/Grafana)
- Log aggregation (Loki)
- Multi-AZ high availability
- Production-grade security

**Timeline:**
```
0:00 - Start Terraform apply (EKS creation: ~15 min)
0:15 - Deploy KEDA, create SQS queue
0:20 - Build & push worker image to ECR
0:25 - Deploy workers, test scaling
0:40 - Send test jobs, watch scaling
1:00 - Explore with k9s, check CloudWatch
1:30 - Document findings, take screenshots
2:45 - START TEARDOWN (important!)
3:00 - Verify terraform destroy completed
```

**Critical: Set a phone alarm for 2:45. Missing teardown = $200+ bill.**

### Experiment Setup

**Before you start:**
1. Set up AWS cost alerts (Budget: $10)
2. Enable MFA on your AWS account
3. Have `terraform destroy` command ready to copy/paste
4. Set multiple alarms/reminders

**Minimal Terraform (3-hour version):**
```hcl
# eks-experiment/main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Use default VPC to save time/cost
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Minimal EKS cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "keda-experiment"
  cluster_version = "1.28"

  # Single-AZ to reduce NAT gateway costs
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = slice(data.aws_subnets.default.ids, 0, 2)

  # Minimal node group
  eks_managed_node_groups = {
    experiment = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }

  # Enable IRSA for KEDA to access SQS
  enable_irsa = true

  tags = {
    Environment = "experiment"
    AutoShutdown = "true"  # Reminder this should be destroyed
  }
}

# SQS queue for KEDA
resource "aws_sqs_queue" "work_queue" {
  name                       = "keda-experiment-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 3600  # 1 hour only

  tags = {
    Environment = "experiment"
  }
}

# IAM role for KEDA to read SQS
module "keda_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "keda-operator"

  role_policy_arns = {
    policy = aws_iam_policy.keda_sqs.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["keda:keda-operator"]
    }
  }
}

resource "aws_iam_policy" "keda_sqs" {
  name = "KEDAOperatorSQSPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.work_queue.arn
      }
    ]
  })
}

# ECR repository for worker image
resource "aws_ecr_repository" "worker" {
  name                 = "keda-worker"
  image_tag_mutability = "MUTABLE"

  # Auto-delete images after experiment
  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Environment = "experiment"
  }
}

# Outputs for kubectl config
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.work_queue.url
}

output "ecr_repository_url" {
  value = aws_ecr_repository.worker.repository_url
}
```

**Deploy commands:**
```bash
# 1. Create infrastructure (~15 min)
cd eks-experiment
terraform init
terraform apply -auto-approve

# 2. Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name keda-experiment

# 3. Install KEDA
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.12.1/keda-2.12.1.yaml

# 4. Build and push worker
cd ../keda-demo
docker build -t worker:latest .
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ECR_URL>
docker tag worker:latest <ECR_URL>/keda-worker:latest
docker push <ECR_URL>/keda-worker:latest

# 5. Deploy worker with SQS scaler
kubectl apply -f eks-worker.yaml

# 6. Test scaling
aws sqs send-message --queue-url <SQS_URL> --message-body "test-task-1"

# 7. Watch scaling
k9s  # Watch pods scale up!

# 8. TEARDOWN (DO NOT SKIP!)
cd ../eks-experiment
terraform destroy -auto-approve
```

### What to Observe During Experiment

**Compare with local kind demo:**

1. **Cluster creation time**
   - kind: 30 seconds
   - EKS: 15+ minutes
   - *Why: AWS provisions control plane, VPC integration, IAM*

2. **Image registry**
   - kind: Local Docker cache
   - EKS: ECR (must push images)
   - *Why: Nodes need to pull from external registry*

3. **Queue integration**
   - kind: RabbitMQ pod (we manage)
   - EKS: SQS (AWS manages)
   - *Why: Managed services reduce operational burden*

4. **IAM/Auth**
   - kind: No auth needed
   - EKS: IRSA for pod→SQS auth
   - *Why: Security - pods shouldn't have hardcoded credentials*

5. **Scaling behavior**
   - kind: Same KEDA logic
   - EKS: Cluster Autoscaler can add nodes
   - *Why: EKS can scale the cluster itself, not just pods*

6. **Logs**
   - kind: `kubectl logs`
   - EKS: `kubectl logs` + CloudWatch Logs
   - *Why: CloudWatch provides persistence, search, alerts*

7. **Cost**
   - kind: $0
   - EKS: ~$1-2/hour minimum
   - *Why: Managed control plane, NAT gateway, EC2 instances*

---

## Prerequisites

### AWS Account Requirements

**Minimum permissions needed:**
- EKS full access
- EC2 full access (VPC, subnets, security groups, instances)
- IAM role creation
- S3 bucket creation
- SQS queue creation
- ECR repository creation
- CloudWatch Logs access

**Recommended: AdministratorAccess** for learning (never in production!)

### Local Tools

```bash
# AWS CLI
brew install awscli
aws configure  # Set credentials

# Terraform
brew install terraform

# kubectl
brew install kubectl

# eksctl (alternative to Terraform)
brew install eksctl

# k9s (for cluster exploration)
brew install derailed/k9s/k9s

# Docker (for building images)
# Install Docker Desktop
```

### Cost Protection Setup

**1. Set up AWS Budget Alerts:**
```bash
aws budgets create-budget \
  --account-id YOUR_ACCOUNT_ID \
  --budget file://budget.json \
  --notifications-with-subscribers file://notifications.json
```

**budget.json:**
```json
{
  "BudgetName": "EKS-Experiment-Alert",
  "BudgetLimit": {
    "Amount": "10",
    "Unit": "USD"
  },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
```

**2. Tag everything with `Environment=experiment`**

**3. Create a "destroy everything" script:**
```bash
#!/bin/bash
# destroy-all.sh
set -e

echo "🔥 DESTROYING ALL EKS EXPERIMENT RESOURCES"
echo "This will delete:"
echo "  - EKS cluster"
echo "  - EC2 instances"
echo "  - SQS queue"
echo "  - ECR repository"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" = "yes" ]; then
  cd eks-experiment
  terraform destroy -auto-approve
  echo "✅ Cleanup complete!"
else
  echo "❌ Cancelled"
fi
```

---

## Architecture Differences: kind vs EKS

### Local kind Demo

```
┌─────────────────────────────────────┐
│  kind cluster (local Docker)        │
│  ┌────────────┐   ┌──────────────┐  │
│  │  RabbitMQ  │   │   Workers    │  │
│  │   (pod)    │───│   (pods)     │  │
│  └────────────┘   └──────────────┘  │
│  ┌────────────┐                     │
│  │    KEDA    │                     │
│  │ (operator) │                     │
│  └────────────┘                     │
└─────────────────────────────────────┘
    ↑
    kubectl port-forward
    ↑
  Your laptop
```

**Characteristics:**
- Everything runs locally
- No external dependencies
- Free
- Not accessible externally
- Perfect for learning basics

### Production EKS

```
┌──────────────────────────────────────────────────────┐
│                    AWS Cloud                         │
│                                                      │
│  ┌─────────────────────────────────────────────┐     │
│  │         VPC (10.0.0.0/16)                   │     │
│  │                                             │     │
│  │  ┌──────────────┐  ┌──────────────┐         │     │
│  │  │  Public      │  │  Private     │         │     │
│  │  │  Subnet      │  │  Subnet      │         │     │
│  │  │              │  │              │         │     │
│  │  │ ┌──────────┐ │  │ ┌──────────┐ │         │     │
│  │  │ │ NAT GW   │ │  │ │  EKS     │ │         │     │
│  │  │ └──────────┘ │  │ │  Nodes   │ │         │     │
│  │  │ ┌──────────┐ │  │ │          │ │         │     │
│  │  │ │   ALB    │ │  │ │ Workers  │ │         │     │
│  │  │ └──────────┘ │  │ └──────────┘ │         │     │
│  │  └──────────────┘  └──────────────┘         │     │
│  │                                             │     │
│  └─────────────────────────────────────────────┘     │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐                  │
│  │  SQS Queue   │  │  S3 Bucket   │                  │
│  └──────────────┘  └──────────────┘                  │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐                  │
│  │  CloudWatch  │  │     ECR      │                  │
│  │     Logs     │  │  (Images)    │                  │
│  └──────────────┘  └──────────────┘                  │
│                                                      │
│  ┌─────────────────────────────────────────────┐     │
│  │     EKS Control Plane (managed by AWS)      │     │
│  │     - API Server                            │     │
│  │     - etcd                                  │     │
│  │     - Controller Manager                    │     │
│  └─────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────┘
```

**Characteristics:**
- Multi-AZ high availability
- Managed control plane
- Integration with AWS services
- Secure (VPC, IAM, security groups)
- Expensive
- Production-ready

### Key Differences

| Aspect | kind | EKS |
|--------|------|-----|
| **Queue** | RabbitMQ pod | AWS SQS (managed) |
| **Storage** | Local volumes | EBS, EFS, S3 |
| **Registry** | Local Docker | ECR (private registry) |
| **Networking** | Docker bridge | VPC with subnets |
| **Load Balancer** | port-forward | ALB/NLB |
| **DNS** | /etc/hosts | Route 53 |
| **Secrets** | Kubernetes secrets | AWS Secrets Manager |
| **Monitoring** | Manual k9s | CloudWatch + Prometheus |
| **Logging** | kubectl logs | CloudWatch Logs + Loki |
| **Auth** | None | IAM, IRSA, OIDC |
| **Cost** | $0 | $200+/month |
| **Startup time** | 30 seconds | 15 minutes |
| **Management** | You manage everything | AWS manages control plane |

---

## Infrastructure Setup (Terraform)

*Full Terraform configs would go here - VPC, EKS, IAM roles, SQS, S3, ECR*

**See eks-experiment/main.tf above for minimal example**

For production, you'd add:
- Multi-AZ VPC with public/private subnets
- NAT Gateways for private subnet internet access
- Security groups with least-privilege rules
- EKS add-ons (VPC CNI, kube-proxy, CoreDNS)
- Cluster Autoscaler
- Metrics Server
- AWS Load Balancer Controller
- EBS CSI Driver for persistent storage
- Secrets encryption with KMS

---

## Application Changes for Production

### Worker Image Changes

**Local kind version (from keda-demo/worker.yaml):**
```python
# Connects to rabbitmq.keda-demo.svc
connection = pika.BlockingConnection(
    pika.ConnectionParameters(
        host="rabbitmq",
        credentials=pika.PlainCredentials("guest", "guest")
    )
)
```

**EKS production version:**
```python
import boto3
import json
import os

# Use IRSA - no hardcoded credentials!
sqs = boto3.client('sqs', region_name='us-east-1')
queue_url = os.environ['SQS_QUEUE_URL']

while True:
    # Long-polling (efficient)
    response = sqs.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=20,
        VisibilityTimeout=300
    )

    if 'Messages' not in response:
        continue

    for message in response['Messages']:
        try:
            # Process work
            body = json.loads(message['Body'])
            process_task(body)

            # Delete message (acknowledge)
            sqs.delete_message(
                QueueUrl=queue_url,
                ReceiptHandle=message['ReceiptHandle']
            )
        except Exception as e:
            # Message will reappear after visibility timeout
            logger.error(f"Failed: {e}")
```

### KEDA ScaledObject Changes

**Local (RabbitMQ):**
```yaml
triggers:
- type: rabbitmq
  metadata:
    host: amqp://guest:guest@rabbitmq.keda-demo.svc:5672
    queueName: work-queue
    value: "5"
```

**EKS (SQS):**
```yaml
triggers:
- type: aws-sqs-queue
  metadata:
    queueURL: https://sqs.us-east-1.amazonaws.com/123456/keda-experiment-queue
    queueLength: "5"
    awsRegion: us-east-1
  authenticationRef:
    name: keda-aws-credentials
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-aws-credentials
spec:
  podIdentity:
    provider: aws-eks  # Uses IRSA, no credentials needed!
```

---

## Deployment Steps

*Full step-by-step would go here*

1. Create infrastructure with Terraform
2. Configure kubectl
3. Install cluster add-ons (KEDA, ALB controller, etc.)
4. Build and push worker image to ECR
5. Deploy worker with SQS ScaledObject
6. Test scaling
7. (Optional) Deploy monitoring and logging
8. **DESTROY when done learning**

---

## Production Patterns

### IAM Roles for Service Accounts (IRSA)

**The problem:** How do pods get AWS credentials without hardcoding?

**The old way (BAD):**
```yaml
env:
- name: AWS_ACCESS_KEY_ID
  value: "AKIAIOSFODNN7EXAMPLE"  # 🚨 NEVER DO THIS
- name: AWS_SECRET_ACCESS_KEY
  value: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

**The new way (GOOD) - IRSA:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keda-operator
  namespace: keda
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/keda-operator
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keda-operator
spec:
  template:
    spec:
      serviceAccountName: keda-operator  # ← This is all you need!
      containers:
      - name: keda
        # No AWS credentials needed - IRSA handles it!
```

**How it works:**
1. EKS creates an OIDC provider
2. You create an IAM role that trusts this OIDC provider
3. Pod assumes the IAM role using its ServiceAccount token
4. AWS SDK automatically uses the assumed role credentials

**Terraform for IRSA:**
```hcl
# See module "keda_irsa" in eks-experiment/main.tf above
```

### SQS Scaling Deep Dive

**Why SQS instead of RabbitMQ?**
- Managed service (no pods to maintain)
- Scales infinitely
- Dead-letter queues built-in
- Integrates with EventBridge, Lambda, SNS
- Pay per request ($0.40 per million requests)

**SQS message lifecycle:**
```
1. Producer sends message to queue
2. KEDA polls SQS.GetQueueAttributes every 15s
3. If queue depth > threshold → scale up workers
4. Worker calls SQS.ReceiveMessage (long-polling)
5. Message becomes "invisible" (VisibilityTimeout)
6. Worker processes message
7. Worker calls SQS.DeleteMessage (ack)
8. If worker crashes, message reappears after timeout
```

**Dead-letter queue (DLQ) for poison messages:**
```hcl
resource "aws_sqs_queue" "dlq" {
  name = "keda-dlq"
}

resource "aws_sqs_queue" "work_queue" {
  name = "keda-work-queue"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3  # After 3 failures → DLQ
  })
}
```

### Cluster Autoscaler

**The scenario:**
- KEDA scales pods from 2 → 50
- But only 10 fit on existing nodes
- What happens to the other 40 pods?

**Answer: Cluster Autoscaler adds nodes!**

```yaml
# Cluster Autoscaler deployment (installed via Helm)
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --set autoDiscovery.clusterName=keda-experiment \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456:role/cluster-autoscaler
```

**How it works:**
1. Pods are "Pending" (can't be scheduled - no resources)
2. Cluster Autoscaler sees pending pods
3. Checks node group max size
4. Launches new EC2 instances
5. Pods get scheduled on new nodes
6. When pods terminate, CA scales down nodes (after 10 min grace period)

**Cost implication:** Autoscaling can get expensive fast! Set max limits.

---

## Cost Optimization

### Strategies for Learning Without Breaking the Bank

**1. Use Spot Instances (60-90% discount)**
```hcl
eks_managed_node_groups = {
  spot = {
    instance_types = ["t3.medium", "t3a.medium"]  # Multiple types
    capacity_type  = "SPOT"
    min_size       = 0
    max_size       = 5
    desired_size   = 2
  }
}
```

**Caveat:** Spot instances can be terminated with 2-minute warning.
Good for: Stateless workers, dev/test
Bad for: Databases, long-running jobs

**2. Time-box Experiments**
- Set a timer before `terraform apply`
- Always run `terraform destroy` when done
- Use AWS Lambda to auto-shutdown resources after X hours

**3. Single-AZ Deployment (Experiments Only)**
- Saves 50% on NAT Gateway costs
- NOT for production (no HA)

**4. S3 Lifecycle Policies**
```hcl
resource "aws_s3_bucket_lifecycle_configuration" "auto_delete" {
  bucket = aws_s3_bucket.renders.id

  rule {
    id     = "auto-delete-old-renders"
    status = "Enabled"

    expiration {
      days = 1  # Delete after 1 day
    }
  }
}
```

**5. CloudWatch Log Retention**
```hcl
resource "aws_cloudwatch_log_group" "workers" {
  name              = "/eks/keda-workers"
  retention_in_days = 1  # Minimum retention
}
```

**6. Use Fargate for KEDA Operator**
```hcl
# KEDA doesn't need much, run it on Fargate (no EC2 costs when idle)
fargate_profiles = {
  keda = {
    name = "keda"
    selectors = [
      { namespace = "keda" }
    ]
  }
}
```

**7. AWS Free Tier (limited but helpful)**
- 750 hours/month t2.micro/t3.micro EC2 (first 12 months)
- 5GB S3 storage
- 1 million SQS requests
- CloudWatch: 10 metrics, 5GB logs

**Free tier won't cover EKS control plane ($73/month), but helps with other costs.**

---

## Troubleshooting

### Common Issues

**1. KEDA can't scale - authentication error**
```
Error: failed to get queue attributes: UnauthorizedOperation
```

**Solution:** Check IRSA setup
```bash
# Verify ServiceAccount annotation
kubectl get sa keda-operator -n keda -o yaml

# Should see:
#   eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/keda-operator

# Verify IAM role trust relationship
aws iam get-role --role-name keda-operator
# Should trust the OIDC provider

# Test from a pod
kubectl run test --rm -it --image=amazon/aws-cli -- sts get-caller-identity
```

**2. Pods stuck "Pending"**
```
Events:
  Warning  FailedScheduling  pod/worker-xyz: 0/2 nodes available: insufficient cpu
```

**Solution:** Cluster Autoscaler might be scaling, or hit node group max
```bash
# Check Cluster Autoscaler logs
kubectl logs -n kube-system deployment/cluster-autoscaler

# Check node group limits
aws eks describe-nodegroup --cluster-name keda-experiment --nodegroup-name experiment
```

**3. Image pull errors**
```
Failed to pull image "123456.dkr.ecr.us-east-1.amazonaws.com/worker:latest":
  rpc error: code = Unknown desc = Error response from daemon:
    pull access denied for 123456.dkr.ecr.us-east-1.amazonaws.com/worker
```

**Solution:** Nodes need ECR access
```bash
# Verify node IAM role has ECR permissions
aws iam list-attached-role-policies --role-name <node-role-name>

# Should include: AmazonEC2ContainerRegistryReadOnly

# Or use IRSA for pull secrets (advanced)
```

**4. SQS messages not processing**
```bash
# Check queue depth
aws sqs get-queue-attributes \
  --queue-url <URL> \
  --attribute-names ApproximateNumberOfMessages

# Check ScaledObject
kubectl get scaledobject -n keda-demo

# Check KEDA operator logs
kubectl logs -n keda deployment/keda-operator
```

**5. Costs higher than expected**
```bash
# Check Cost Explorer
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=SERVICE

# Common culprits:
# - NAT Gateway ($0.045/hour + data transfer)
# - EKS control plane ($0.10/hour = $73/month)
# - Load Balancer ($0.0225/hour)
# - Data transfer (can be huge!)

# Tag resources to track costs
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Environment,Values=experiment
```

---

## Comparison: Local vs EKS

### When to use local kind

* Learning Kubernetes basics
* Testing manifests
* Development workflow
* CI/CD testing
* No cost
* Fast iteration

### When to use EKS

* Production workloads
* Need AWS service integration (SQS, S3, RDS, etc.)
* Multi-team/multi-tenant clusters
* Compliance requirements
* Need HA/disaster recovery
* Scale beyond single machine
* Have budget for managed service

### The Truth

**Most projects don't need Kubernetes at all.**

If your application fits on:
- A single EC2 instance → Use EC2 + systemd
- Serverless pattern → Use Lambda/Fargate
- Simple containers → Use ECS
- Single-region stateless → Use App Runner

**Use Kubernetes when:**
- You have 10+ microservices
- Need multi-cloud portability
- Have dedicated platform team
- Scale justifies complexity

**The keda-demo on kind is perfect for learning. EKS is for when you've
outgrown simpler solutions and have the budget/team to manage it.**

---

## Next Steps

**To implement this for real:**

1. Review the 3-hour experiment plan
2. Set up AWS budget alerts
3. Create the minimal Terraform config
4. Run the experiment (SET TIMERS!)
5. Document what you learned
6. Destroy everything
7. Decide if full production setup is worth the cost

**Future additions to this repo:**
- Full Terraform configs (when ready to spend)
- Worker application (POV-Ray or alternative)
- Helm charts for monitoring stack
- CI/CD pipeline examples
- Multi-environment setup (dev/staging/prod)

---

## Further Reading

- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [EKS Workshop](https://www.eksworkshop.com/)
- [KEDA AWS SQS Scaler Docs](https://keda.sh/docs/scalers/aws-sqs/)
- [Terraform EKS Module](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [AWS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Cluster Autoscaler on EKS](https://docs.aws.amazon.com/eks/latest/userguide/autoscaling.html)

---

**Remember: This guide is about learning production patterns, not running
production workloads. When in doubt, use the 3-hour experiment approach and
destroy everything immediately.**

**The real lesson: Production Kubernetes is powerful but expensive. Choose
the right tool for the job.**
