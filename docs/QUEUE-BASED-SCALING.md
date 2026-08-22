# Queue-Based Auto-scaling in Kubernetes

## Overview

Standard Kubernetes HPA (Horizontal Pod Autoscaler) scales based on CPU/memory. For queue-based scaling, you need custom metrics. The best approach is **KEDA** (Kubernetes Event-Driven Autoscaling).

## KEDA: Event-Driven Autoscaling

KEDA extends Kubernetes to scale workloads based on external event sources like:
- Message queues (RabbitMQ, Kafka, SQS, Azure Service Bus, etc.)
- Databases (PostgreSQL, Redis)
- HTTP traffic patterns
- Cron schedules
- Custom metrics (Prometheus, Datadog, etc.)

### How KEDA Works

1. **ScaledObject** defines scaling rules (queue name, threshold, min/max replicas)
2. **KEDA operator** watches queue metrics
3. **Scales deployment** from 0→N based on queue depth
4. **Scale to zero**: Can scale to 0 replicas when queue is empty (saves resources)

### Installation

```bash
# Install KEDA using kubectl
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.12.1/keda-2.12.1.yaml

# Or using Helm (preferred for production)
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

### Example: RabbitMQ Queue Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: rabbitmq-scaler
  namespace: default
spec:
  scaleTargetRef:
    name: worker-deployment  # Your deployment name
  minReplicaCount: 0         # Can scale to zero when queue empty
  maxReplicaCount: 30        # Maximum pods
  pollingInterval: 30        # How often to poll queue (seconds)
  cooldownPeriod: 300        # Wait before scaling down (seconds)

  triggers:
  - type: rabbitmq
    metadata:
      host: amqp://guest:password@rabbitmq.default.svc.cluster.local:5672
      queueName: work-queue
      queueLength: "5"       # Scale up when queue has >5 messages per pod
```

### Example: AWS SQS Queue Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-scaler
spec:
  scaleTargetRef:
    name: worker-deployment
  minReplicaCount: 1
  maxReplicaCount: 20

  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123456/my-queue
      queueLength: "10"      # Target 10 messages per replica
      awsRegion: us-east-1
    authenticationRef:
      name: keda-aws-credentials  # Secret with AWS creds
```

### Example: Kafka Topic Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-scaler
spec:
  scaleTargetRef:
    name: consumer-deployment
  minReplicaCount: 1
  maxReplicaCount: 50

  triggers:
  - type: kafka
    metadata:
      bootstrapServers: kafka.kafka.svc.cluster.local:9092
      consumerGroup: my-consumer-group
      topic: events
      lagThreshold: "100"    # Scale when consumer lag > 100 messages
```

### Example: PostgreSQL Table Row Count

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: postgres-scaler
spec:
  scaleTargetRef:
    name: processor-deployment
  minReplicaCount: 0
  maxReplicaCount: 10

  triggers:
  - type: postgresql
    metadata:
      connectionFromEnv: DATABASE_URL
      query: "SELECT COUNT(*) FROM jobs WHERE status = 'pending'"
      targetQueryValue: "5"  # Scale to handle 5 pending jobs per pod
```

### Example: Redis List Length

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: redis-scaler
spec:
  scaleTargetRef:
    name: worker-deployment
  minReplicaCount: 1
  maxReplicaCount: 20

  triggers:
  - type: redis
    metadata:
      address: redis.default.svc.cluster.local:6379
      listName: task-queue
      listLength: "10"       # Target 10 items per replica
```

## Alternative: Custom Metrics with Prometheus + HPA

If you already have Prometheus, you can expose queue metrics and use HPA:

### 1. Expose Queue Metrics to Prometheus

```python
# Example: Python worker exposing queue metrics
from prometheus_client import Gauge, start_http_server
import pika

queue_depth = Gauge('work_queue_depth', 'Number of messages in queue')

def update_queue_metrics():
    connection = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    channel = connection.channel()
    method_frame = channel.queue_declare(queue='work-queue', passive=True)
    queue_depth.set(method_frame.method.message_count)
    connection.close()

# Expose metrics on :8000/metrics
start_http_server(8000)
```

### 2. Create ServiceMonitor (if using Prometheus Operator)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: queue-metrics
spec:
  selector:
    matchLabels:
      app: queue-monitor
  endpoints:
  - port: metrics
```

### 3. Install Prometheus Adapter

```bash
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://prometheus-server.monitoring.svc
```

### 4. Create HPA with Custom Metric

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker-deployment
  minReplicas: 1
  maxReplicas: 30
  metrics:
  - type: External
    external:
      metric:
        name: work_queue_depth
      target:
        type: AverageValue
        averageValue: "10"  # Target 10 messages per pod
```

## Decision Tree: Which Approach?

```
Do you already have Prometheus + custom metrics infrastructure?
├─ YES → Use Prometheus + HPA (less overhead)
└─ NO  → Use KEDA (easier, purpose-built)

Do you need scale-to-zero capability?
└─ YES → Must use KEDA (HPA requires minReplicas: 1)

Are you using a standard queue system (RabbitMQ, Kafka, SQS)?
└─ YES → KEDA has built-in scalers (zero custom code)
```

## GitOps Integration

To manage KEDA with ArgoCD:

```yaml
# applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: keda-scalers
  namespace: argocd
spec:
  generators:
  - git:
      repoURL: http://172.22.0.3:3000/wware/gitops-lab.git
      revision: main
      directories:
      - path: keda-scalers/*
  template:
    metadata:
      name: 'scaler-{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: http://172.22.0.3:3000/wware/gitops-lab.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Then organize scalers by service:

```
keda-scalers/
├── email-processor/
│   ├── deployment.yaml
│   └── scaledobject.yaml  # RabbitMQ trigger
├── image-resizer/
│   ├── deployment.yaml
│   └── scaledobject.yaml  # SQS trigger
└── report-generator/
    ├── deployment.yaml
    └── scaledobject.yaml  # PostgreSQL trigger
```

## Best Practices

1. **Set reasonable min/max replicas** - Prevent cost explosion or starvation
2. **Tune polling interval** - Balance responsiveness vs API load (30-60s typical)
3. **Add cooldown period** - Prevent thrashing (300s = 5min typical)
4. **Monitor scaling events** - Use Prometheus + Grafana to track scaling behavior
5. **Test scale-to-zero** - Ensure cold-start latency is acceptable
6. **Use secrets for credentials** - Never hardcode queue passwords in ScaledObject

## Debugging

```bash
# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator

# View ScaledObject status
kubectl describe scaledobject rabbitmq-scaler

# Check current HPA (KEDA creates these automatically)
kubectl get hpa

# Watch scaling in action
kubectl get pods -w

# View KEDA metrics
kubectl get --raw /apis/external.metrics.k8s.io/v1beta1 | jq
```

## Real-World Example: Image Processing Pipeline

```yaml
# Deployment: image processor workers
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-processor
spec:
  replicas: 1  # KEDA will override this
  selector:
    matchLabels:
      app: image-processor
  template:
    metadata:
      labels:
        app: image-processor
    spec:
      containers:
      - name: worker
        image: myregistry/image-processor:v1.2.3
        env:
        - name: SQS_QUEUE_URL
          value: https://sqs.us-east-1.amazonaws.com/123456/images
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
---
# ScaledObject: scale based on SQS queue depth
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: image-processor-scaler
spec:
  scaleTargetRef:
    name: image-processor
  minReplicaCount: 0          # Scale to zero at night
  maxReplicaCount: 100        # Handle traffic spikes
  pollingInterval: 30
  cooldownPeriod: 300

  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123456/images
      queueLength: "10"        # 1 pod per 10 images
      awsRegion: us-east-1
    authenticationRef:
      name: aws-credentials
---
# Secret: AWS credentials for KEDA
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: AKIA...
  AWS_SECRET_ACCESS_KEY: ...
---
# TriggerAuthentication: reference for KEDA
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: aws-credentials
spec:
  secretTargetRef:
  - parameter: awsAccessKeyID
    name: aws-credentials
    key: AWS_ACCESS_KEY_ID
  - parameter: awsSecretAccessKey
    name: aws-credentials
    key: AWS_SECRET_ACCESS_KEY
```

This setup will:
- Scale to 0 pods when queue is empty (save $$$)
- Scale to 10 pods when 100 images queued
- Scale to 100 pods during traffic spike (1000+ images)
- Self-heal if manually modified (ArgoCD manages the manifests)

## Further Reading

- **KEDA Docs**: https://keda.sh/docs/
- **KEDA Scalers**: https://keda.sh/docs/scalers/ (50+ built-in integrations)
- **Prometheus Adapter**: https://github.com/kubernetes-sigs/prometheus-adapter
- **ArgoCD + KEDA**: https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/
