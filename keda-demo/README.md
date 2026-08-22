# KEDA Demo: Queue-Based Autoscaling

This directory demonstrates **KEDA (Kubernetes Event-Driven Autoscaling)** - automatic pod scaling based on RabbitMQ queue depth.

## What This Demonstrates

- **Scale to zero**: Workers scale down to 0 pods when queue is empty
- **Scale up on demand**: KEDA creates pods when messages arrive (1 pod per 5 messages)
- **GitOps managed**: All manifests tracked in git, managed by ArgoCD
- **Real-world pattern**: Same approach used for production workloads (SQS, Kafka, etc.)

## Architecture

```
┌─────────────┐      ┌──────────────┐      ┌──────────────┐
│  Producer   │─────>│  RabbitMQ    │<─────│ KEDA Scaler  │
│   (Job)     │      │    Queue     │      │              │
└─────────────┘      └──────────────┘      └──────┬───────┘
                           ^                      │
                           │                      v
                     ┌─────┴─────┐         ┌──────────────┐
                     │  Worker   │         │  Worker HPA  │
                     │   Pods    │<────────│  (auto-gen)  │
                     └───────────┘         └──────────────┘
```

## Quick Start

### Deploy the demo:

```bash
# Create namespace
kubectl create namespace keda-demo

# Apply manifests
kubectl apply -f keda-demo/
```

### Watch the scaling magic:

In one terminal, watch the pods:
```bash
kubectl get pods -n keda-demo -w
```

In another terminal, send messages:
```bash
# Send 20 messages to the queue
kubectl create -f keda-demo/producer.yaml

# Watch KEDA metrics
kubectl get scaledobject -n keda-demo

# View the HPA that KEDA creates
kubectl get hpa -n keda-demo
```

### What you'll see:

1. **Initially**: 0 worker pods (rabbitmq pod only)
2. **After sending messages**: Workers scale up (20 messages ÷ 5 per pod = 4 workers)
3. **After processing**: Workers scale back down to 0

## Files

- `rabbitmq.yaml` - RabbitMQ message queue
- `worker.yaml` - Worker deployment + KEDA ScaledObject
- `producer.yaml` - Job to send test messages

## KEDA Configuration

```yaml
spec:
  minReplicaCount: 0           # Scale to zero when idle
  maxReplicaCount: 10          # Cap at 10 workers
  pollingInterval: 15          # Check queue every 15s
  cooldownPeriod: 60           # Wait 60s before scaling down

  triggers:
  - type: rabbitmq
    metadata:
      queueName: work-queue
      value: "5"               # 1 pod per 5 messages
```

## Testing Different Scenarios

### High load (scale to max):
```bash
# Send 100 messages (should create 10 workers, hitting maxReplicaCount)
kubectl create job producer-large --image=python:3.12-slim -n keda-demo -- \
  bash -c "pip install pika && python3 -c 'import pika; c=pika.BlockingConnection(pika.ConnectionParameters(\"rabbitmq\",credentials=pika.PlainCredentials(\"guest\",\"guest\"))); ch=c.channel(); [ch.basic_publish(\"\",\"work-queue\",f\"task-{i}\") for i in range(100)]'"
```

### Slow drain:
```bash
# Send messages slowly to watch gradual scaling
for i in {1..30}; do
  kubectl create job producer-$i --image=python:3.12-slim -n keda-demo -- \
    bash -c "pip install pika && python3 -c 'import pika; c=pika.BlockingConnection(pika.ConnectionParameters(\"rabbitmq\",credentials=pika.PlainCredentials(\"guest\",\"guest\"))); ch=c.channel(); ch.basic_publish(\"\",\"work-queue\",\"task-$i\")'"
  sleep 2
done
```

## Debugging

### Check KEDA logs:
```bash
kubectl logs -n keda -l app=keda-operator
```

### Check ScaledObject status:
```bash
kubectl describe scaledobject queue-worker-scaler -n keda-demo
```

### Check queue depth:
```bash
kubectl exec -it deployment/rabbitmq -n keda-demo -- \
  rabbitmqctl list_queues name messages
```

### Check worker logs:
```bash
kubectl logs -n keda-demo -l app=queue-worker --tail=50 -f
```

### Access RabbitMQ Management UI:
```bash
kubectl port-forward svc/rabbitmq -n keda-demo 15672:15672
# Open: http://localhost:15672 (guest/guest)
```

## Production Considerations

This demo uses RabbitMQ for simplicity. In production, you'd typically use:

- **AWS**: SQS queues with KEDA's `aws-sqs-queue` scaler
- **GCP**: Pub/Sub with KEDA's `gcp-pubsub` scaler
- **Azure**: Service Bus with KEDA's `azure-servicebus` scaler
- **Kafka**: For high-throughput event streams

See [docs/QUEUE-BASED-SCALING.md](../docs/QUEUE-BASED-SCALING.md) for production patterns.

## GitOps Integration

To manage this with ArgoCD:

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keda-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://172.22.0.3:3000/wware/gitops-lab.git
    targetRevision: main
    path: keda-demo
  destination:
    server: https://kubernetes.default.svc
    namespace: keda-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

Now changes to `keda-demo/*.yaml` will auto-deploy via GitOps!

## Cleanup

```bash
kubectl delete namespace keda-demo
```

## Incidental side-quests

I am learning this stuff as I go, and wanted to share some of the things
I've learned. These are the "aha!" moments that made the investment worthwhile.

### The barrier to entry dropped from drywall to cobweb

Before containers and Kubernetes, trying new technology meant:
- Installing dependencies (often breaking your system)
- Fighting with configuration files
- Reading installation guides for hours
- Cleaning up the mess when you were done

Now? `kubectl run rabbitmq --image=rabbitmq:3.12-management --rm -it` and you're
exploring a production-grade message queue 30 seconds later. No installation,
no cleanup, no risk. This is transformative for learning.

### k9s: The Kubernetes TUI you didn't know you needed

There is a wonderful text-UI utility called `k9s` that you'll want to try.

**Installation:**
```bash
# macOS
brew install derailed/k9s/k9s

# Linux
curl -sS https://webinstall.dev/k9s | bash

# Just run it
k9s
```

**What makes it amazing:**
- **Real-time visualization**: Watch pods scale up/down as KEDA reacts to queue depth
- **Instant log access**: Press `l` on any pod to stream logs
- **Shell anywhere**: Press `s` to shell into containers (local or cloud, doesn't matter)
- **Resource jumping**: Type `:pods`, `:deploy`, `:svc`, `:scaledobjects` to navigate
- **Filtering**: Press `/` to filter (try `/queue-worker` to see just your workers)
- **Actions without kubectl**: Delete pods (`d`), view YAML (`y`), edit resources (`e`)

**Pro tip**: While watching this KEDA demo, open k9s and type `:pods`, then filter
with `/keda-demo`. Send messages and watch workers appear in real-time. It's mesmerizing.

**Key shortcuts:**
- `?` - Help (shows all shortcuts for current view)
- `0` - Show all namespaces
- `:containers` - See all containers across all pods
- `ctrl-d` - Delete resource
- `l` - Logs
- `s` - Shell

k9s works identically whether you're exploring a local kind cluster or managing
production infrastructure in AWS. The barrier between "I wonder what's running?"
and actually seeing it vanished.

### RabbitMQ: Message queues with fault tolerance built-in

I was aware RabbitMQ existed but had never really looked at it carefully.
Shelling into the RabbitMQ container during this demo revealed some elegant design.

**Message acknowledgment pattern:**
```python
# Worker receives message
def callback(ch, method, properties, body):
    try:
        process_work(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)  # "I succeeded, delete it"
    except Exception as e:
        ch.basic_nack(requeue=True)  # "I failed, put it back in queue"
```

**What happens if a worker dies mid-processing:**
1. Worker pulls message (marked "unacknowledged" in RabbitMQ)
2. Worker starts processing...
3. Worker crashes/pod deleted/node fails
4. RabbitMQ notices connection dropped **without acknowledgment**
5. Message automatically goes back to "ready" state
6. Another worker picks it up

This is **at-least-once delivery** - RabbitMQ guarantees the message will be
processed, even if workers fail. This pattern enables fault-tolerant processing
at massive scale.

**Inspection commands** (shell into RabbitMQ pod):
```bash
# See queue status
rabbitmqctl list_queues name messages_ready messages_unacknowledged

# List connections (see worker connections)
rabbitmqctl list_connections

# See which worker is processing which message
rabbitmqctl list_consumers
```

**Written in Erlang:**
RabbitMQ is built on Erlang/OTP, a language designed for telecom systems that
can't go down. Erlang's "let it crash" philosophy and supervision trees make
RabbitMQ incredibly resilient. This is why it's trusted for critical
message-passing in banking, telecom, and distributed systems.

**The learning moment:** I didn't install Erlang. I didn't configure RabbitMQ.
I just shelled into a container and explored. That's the new paradigm.

### Container-based exploration as a learning strategy

This demo taught me more about message queues, autoscaling, and Kubernetes
operators in an hour than I'd learn reading docs. Why?

**Hands-on beats reading:**
- Watching workers scale in k9s is more memorable than reading about KEDA
- Shelling into RabbitMQ and running `rabbitmqctl` teaches message semantics
- Killing a worker pod and seeing the message get reprocessed demonstrates fault tolerance

**Zero-cost experimentation:**
- Delete everything: `kubectl delete namespace keda-demo`
- Rebuild it: `kubectl apply -f keda-demo/`
- Try variations: Change `value: "5"` to `value: "10"` in the ScaledObject
- Break things on purpose: Delete workers mid-processing, watch recovery

**Transferable patterns:**
The patterns here aren't RabbitMQ-specific. This same acknowledgment pattern
exists in:
- AWS SQS (ReceiveMessage → Process → DeleteMessage)
- Google Pub/Sub (Pull → Process → Ack)
- Kafka (Consume → Process → Commit offset)

Learning with RabbitMQ in a local cluster taught me how message queues work
everywhere.

### The meta-lesson

The biggest discovery wasn't about KEDA or RabbitMQ. It was realizing that
Kubernetes and containers collapsed the barrier between curiosity and hands-on
experience. Want to try Redis? PostgreSQL? Kafka? Elasticsearch? They're all
30 seconds away:

```bash
kubectl run redis --image=redis:7 --rm -it -- redis-cli
kubectl run postgres --image=postgres:16 --env POSTGRES_PASSWORD=test --rm -it -- psql
kubectl run mongo --image=mongo:7 --rm -it -- mongosh
```

The cost of "I wonder how X works?" dropped from days to seconds.
That's the real revolution.

### Log aggregation: The thing I should have been using all along

A few months ago, I was reading about syslog and had an epiphany: "I should have
been using this all along." For years, I'd built custom "log aggregator" solutions,
reinventing wheels that syslog had solved in the 1980s. Track everything centrally,
correlate events, search across systems. It was all there.

Then I discovered what the Kubernetes world does with logging, and realized syslog
was just the beginning.

**The old syslog epiphany:**
"All my services should send logs to one place. Use standard protocols. Search
centrally instead of SSH-ing to 15 servers."

**The Kubernetes evolution:**
"All my pods already log to stdout. Kubernetes captures it. Ship it to a central
aggregator with automatic metadata (pod name, namespace, labels). Query everything
in one UI."

**What this demo taught me about logging:**

When I ran this KEDA demo, I could:
```bash
# See logs from all 10 worker pods at once
kubectl logs -l app=queue-worker -n keda-demo --tail=100

# Watch them in real-time with k9s (press 'l' on any pod)
# See which worker processed which message
# Correlate worker logs with RabbitMQ logs
```

But here's what made me understand the full picture: **structured logging** and
**log aggregation** in production Kubernetes.

**The pattern (production):**
```
1. Apps write JSON logs to stdout (not to files, not to syslog directly)
2. Kubernetes captures stdout
3. Log shipper (Promtail, Fluent Bit) runs on every node as a DaemonSet
4. Shipper adds Kubernetes metadata (pod, namespace, labels)
5. Ships to central aggregator (Loki, Elasticsearch)
6. Query in Grafana/Kibana with correlation across all services
```

**Why JSON logs matter:**

Traditional logging:
```
2026-08-22 10:15:30 INFO Processing task task-42
```

Structured JSON logging (what production apps use):
```json
{
  "timestamp": "2026-08-22T10:15:30Z",
  "level": "info",
  "message": "processing task",
  "request_id": "abc-123",
  "task_id": "task-42",
  "worker": "queue-worker-f576b4497-pr7zf",
  "queue": "work-queue",
  "message_count": 15
}
```

Now you can query:
- "Show me all logs for request_id abc-123" (across all services!)
- "How many tasks did each worker process in the last hour?"
- "Which tasks failed and why?"

**The syslog lesson, elevated:**

Syslog taught: "Send logs to a central place."
Kubernetes taught: "Send structured logs with rich context, automatic metadata,
and built-in correlation."

**What runs in this KEDA demo vs. production:**

| This Demo | Production (Loki Stack) |
|-----------|-------------------------|
| `kubectl logs` (manual) | Promtail DaemonSet (automatic) |
| Lost when pod deleted | Persistent storage (10GB+ retention) |
| One namespace at a time | Query across all namespaces/clusters |
| Plain text logs | Structured JSON with metadata |
| No alerting | Alert on error patterns |

**How to level up this demo with log aggregation:**

```bash
# Install Loki stack (takes 2 minutes)
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --set grafana.enabled=true \
  --set promtail.enabled=true

# Get Grafana password
kubectl get secret loki-grafana -o jsonpath="{.data.admin-password}" | base64 -d

# Port forward
kubectl port-forward svc/loki-grafana 3000:80

# Open http://localhost:3000, add Loki data source: http://loki:3100
# Query: {app="queue-worker"} | json
```

Now you have:
- All worker logs in one view
- Search by task_id, request_id, pod name
- Graphs of message processing over time
- Alerts when workers crash
- Retention beyond pod lifetime

**The integration with this KEDA demo:**

Imagine correlating:
1. **KEDA metrics**: "At 10:15, queue depth spiked to 100 messages"
2. **Kubernetes events**: "KEDA scaled workers from 1 to 10"
3. **Worker logs**: "Worker-7 processed task-42, took 5.2 seconds"
4. **RabbitMQ logs**: "Queue emptied at 10:18"

With Loki + Prometheus + Grafana, you see all of this in one dashboard.

**The realization:**

My "log aggregator" projects from years ago were solving a real problem, but
in isolation. The Kubernetes ecosystem solved it at ecosystem scale:
- Standard protocols (stdout/stderr)
- Automatic metadata enrichment
- Built-in correlation (labels, request IDs)
- Integrated with metrics (Prometheus) and tracing (OpenTelemetry)

Syslog was the right instinct. Kubernetes logging is syslog's final form.

**Further reading:**

For a deep dive on structured logging, log aggregation patterns, and implementing
Loki/EFK stacks in Kubernetes, see the comprehensive guide in the k8s-hack repo:
https://github.com/wware/k8s-hack/blob/main/LOGGING.md

That guide covers:
- Structured JSON logging implementation (FastAPI example)
- Request ID correlation across services
- EFK vs Loki comparison
- Distributed tracing with OpenTelemetry
- Log retention strategies
- Cost management for high-volume logging
