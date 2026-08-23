# Can one auto-scale affordably on a single machine?

> Suppose I want to avoid k8s and operate on a single physical machine but I still want to do load based auto scaling of docker containers. Doable?

Yes — you don't need k8s for this on a single box. This guide shows when single-box autoscaling makes sense, how to implement it, and when to graduate to Kubernetes.

## Decision Matrix: Single Box vs Kubernetes

| Criteria | Single Box | Kubernetes |
|----------|------------|------------|
| **Monthly cost** | $15-30 (t3.medium EC2) | $210-265 (EKS + 2 nodes) |
| **Setup time** | 30 minutes | 2-3 hours |
| **Learning curve** | Weekend project | Weeks to months |
| **High availability** | None (single point of failure) | Multi-node, self-healing |
| **Max scale** | ~20-30 containers (CPU/mem bound) | Hundreds of nodes, thousands of pods |
| **Multi-region** | Manual (duplicate setup) | Built-in (cluster federation) |
| **Zero-downtime deploys** | Requires careful scripting | Native (rolling updates) |
| **Service discovery** | Traefik/nginx + labels | Native (DNS, Services) |
| **Secrets management** | Docker secrets, env files | Native (Secrets, external operators) |
| **Observability** | DIY (Prometheus + Grafana) | Rich ecosystem (Loki, Jaeger, etc.) |
| **GitOps** | Manual (scripts + cron) | ArgoCD, Flux |
| **Best for** | Side projects, MVPs, cost-sensitive | Production, multi-team, growth trajectory |

**Use single-box when:**
- Starting a new project with unknown traffic patterns
- Cost is primary constraint (sub-$50/month budget)
- You're the only operator/developer
- Traffic fits on one machine (< 1000 req/sec)
- You value simplicity over resilience

**Graduate to Kubernetes when:**
- Outgrowing single machine (CPU/memory limits)
- Need high availability (can't tolerate downtime)
- Multiple teams/services need isolation
- Multi-region deployment required
- Hiring ops/platform team

## Three Approaches to Single-Box Autoscaling

### 1. Docker Swarm mode (simplest, built into Docker)

Even on one machine, `docker swarm init` gets you services with `docker service scale myapp=5`. Swarm itself doesn't autoscale, but you pair it with a small watcher loop that adjusts replica count based on a metric, then calls the Docker API. Traefik or the swarm-aware nginx/HAProxy handles load balancing automatically since Swarm's routing mesh distributes across replicas.

**Pros:** Built into Docker, zero new dependencies
**Cons:** Swarm is effectively deprecated (minimal updates since 2019)
**Verdict:** Skip unless already using Swarm

### 2. Plain Docker + custom autoscaler (most control)

- **Load balancer:** Traefik (or nginx with `docker-gen`) watching the Docker socket, auto-discovering containers via labels — no manual config reload needed.
- **Metrics:** pull from `docker stats` (CPU/mem) via the Docker API, or better, application-level metrics (request queue depth, p95 latency) exposed via Prometheus + `docker_exporter`/cAdvisor.
- **Scaler:** a small daemon (Python + `docker-py`) polling metrics every N seconds, comparing to thresholds, and calling `container.start()`/`docker run` or scaling a Compose service (`docker compose up --scale web=N`). Add cooldown/hysteresis so you're not thrashing on noisy metrics.

**Pros:** Full control, minimal dependencies, educational
**Cons:** You maintain it, handle edge cases
**Verdict:** Best for learning and custom requirements

### 3. Nomad in single-node mode (production-ready)

HashiCorp Nomad is a much lighter scheduler than k8s and runs fine standalone. Nomad Autoscaler is a real, supported component for exactly this — CPU/mem/custom metric-based scaling of Docker jobs — if you want something more production-grade than a hand-rolled loop without the k8s complexity tax.

**Pros:** Production-tested, maintained, good docs
**Cons:** New tool to learn (though simpler than K8s)
**Verdict:** Best for serious single-box production

## Complete Working Example: Queue-Based Autoscaling

This mirrors the KEDA demo from `keda-demo/` but runs on a single box. Workers scale 0→N based on RabbitMQ queue depth.

### Architecture

```
┌─────────────┐      ┌──────────────┐      ┌──────────────┐
│  Producer   │─────>│  RabbitMQ    │      │  Autoscaler  │
│   (Flask)   │      │    Queue     │      │   (Python)   │
└─────────────┘      └──────────────┘      └──────┬───────┘
                           ^                      │
                           │                      v
                     ┌─────┴─────┐         ┌──────────────┐
                     │  Worker   │<────────│ Docker API   │
                     │ Containers│         │ (spawn/kill) │
                     └───────────┘         └──────────────┘
```

### Files

**docker-compose.yml**
```yaml
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.12-management
    ports:
      - "5672:5672"
      - "15672:15672"
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: guest
    healthcheck:
      test: rabbitmq-diagnostics -q ping
      interval: 10s
      timeout: 5s
      retries: 5

  traefik:
    image: traefik:v2.10
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  producer:
    image: python:3.12-slim
    working_dir: /app
    volumes:
      - ./producer.py:/app/producer.py
    command: >
      bash -c "pip install flask pika &&
               python producer.py"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.producer.rule=PathPrefix(`/`)"
      - "traefik.http.services.producer.loadbalancer.server.port=5000"
    depends_on:
      rabbitmq:
        condition: service_healthy

  autoscaler:
    image: python:3.12-slim
    working_dir: /app
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./autoscaler.py:/app/autoscaler.py
      - ./worker.py:/app/worker.py
    command: >
      bash -c "pip install docker pika &&
               python autoscaler.py"
    depends_on:
      rabbitmq:
        condition: service_healthy
    environment:
      RABBITMQ_HOST: rabbitmq
      WORKER_IMAGE: python:3.12-slim
      MIN_WORKERS: 0
      MAX_WORKERS: 10
      MESSAGES_PER_WORKER: 5
```

**producer.py**
```python
#!/usr/bin/env python3
"""
Simple Flask app to add messages to the queue.
Visit http://localhost/send?count=20 to add 20 messages.
"""
from flask import Flask, request
import pika
import os

app = Flask(__name__)

def get_channel():
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(
            host=os.getenv('RABBITMQ_HOST', 'rabbitmq'),
            credentials=pika.PlainCredentials('guest', 'guest')
        )
    )
    channel = connection.channel()
    channel.queue_declare(queue='work-queue', durable=True)
    return connection, channel

@app.route('/send')
def send():
    count = int(request.args.get('count', 10))
    connection, channel = get_channel()

    for i in range(1, count + 1):
        channel.basic_publish(
            exchange='',
            routing_key='work-queue',
            body=f'task-{i}',
            properties=pika.BasicProperties(delivery_mode=2)
        )

    connection.close()
    return f'Sent {count} messages to queue\n'

@app.route('/queue')
def queue_status():
    connection, channel = get_channel()
    queue = channel.queue_declare(queue='work-queue', durable=True, passive=True)
    connection.close()
    return f'Queue depth: {queue.method.message_count}\n'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
```

**worker.py**
```python
#!/usr/bin/env python3
"""
Worker that processes messages from the queue.
Spawned dynamically by autoscaler.py based on queue depth.
"""
import pika
import time
import os
import sys

def process_message(body):
    """Simulate work - sleep for 2 seconds"""
    print(f'Processing: {body.decode()}', flush=True)
    time.sleep(2)
    print(f'Completed: {body.decode()}', flush=True)

def main():
    rabbitmq_host = os.getenv('RABBITMQ_HOST', 'rabbitmq')

    connection = pika.BlockingConnection(
        pika.ConnectionParameters(
            host=rabbitmq_host,
            credentials=pika.PlainCredentials('guest', 'guest')
        )
    )
    channel = connection.channel()
    channel.queue_declare(queue='work-queue', durable=True)

    # Fair dispatch - don't give worker new message until it acks previous
    channel.basic_qos(prefetch_count=1)

    def callback(ch, method, properties, body):
        try:
            process_message(body)
            ch.basic_ack(delivery_tag=method.delivery_tag)
        except Exception as e:
            print(f'Error: {e}', file=sys.stderr, flush=True)
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

    channel.basic_consume(queue='work-queue', on_message_callback=callback)

    print('Worker started, waiting for messages...', flush=True)
    try:
        channel.start_consuming()
    except KeyboardInterrupt:
        channel.stop_consuming()

    connection.close()

if __name__ == '__main__':
    main()
```

**autoscaler.py**
```python
#!/usr/bin/env python3
"""
Autoscaler that monitors RabbitMQ queue and spawns/kills workers.
This is the "KEDA for single-box" - same logic, no Kubernetes.
"""
import docker
import pika
import time
import os
import sys

class QueueAutoscaler:
    def __init__(self):
        self.docker_client = docker.from_env()
        self.rabbitmq_host = os.getenv('RABBITMQ_HOST', 'rabbitmq')
        self.min_workers = int(os.getenv('MIN_WORKERS', 0))
        self.max_workers = int(os.getenv('MAX_WORKERS', 10))
        self.messages_per_worker = int(os.getenv('MESSAGES_PER_WORKER', 5))
        self.poll_interval = int(os.getenv('POLL_INTERVAL', 15))
        self.cooldown = int(os.getenv('COOLDOWN', 60))
        self.last_scale_time = 0

        # Network from docker-compose (auto-created as <dir>_default)
        networks = self.docker_client.networks.list(names=['gitops-lab_default'])
        if not networks:
            # Fallback: create network if running standalone
            self.network = self.docker_client.networks.create('autoscaler-net')
        else:
            self.network = networks[0]

    def get_queue_depth(self):
        """Query RabbitMQ for queue depth"""
        try:
            connection = pika.BlockingConnection(
                pika.ConnectionParameters(
                    host=self.rabbitmq_host,
                    credentials=pika.PlainCredentials('guest', 'guest')
                )
            )
            channel = connection.channel()
            queue = channel.queue_declare(queue='work-queue', durable=True, passive=True)
            depth = queue.method.message_count
            connection.close()
            return depth
        except Exception as e:
            print(f'Error querying queue: {e}', file=sys.stderr, flush=True)
            return 0

    def get_current_workers(self):
        """Get running worker containers"""
        return self.docker_client.containers.list(
            filters={'label': 'role=queue-worker'}
        )

    def desired_workers(self, queue_depth):
        """Calculate desired worker count based on queue depth"""
        if queue_depth == 0:
            return self.min_workers

        # Same logic as KEDA: 1 worker per N messages
        desired = (queue_depth + self.messages_per_worker - 1) // self.messages_per_worker
        return max(self.min_workers, min(desired, self.max_workers))

    def scale_up(self, current_count, desired_count):
        """Spawn new worker containers"""
        for i in range(desired_count - current_count):
            try:
                container = self.docker_client.containers.run(
                    image='python:3.12-slim',
                    command='bash -c "pip install pika && python /app/worker.py"',
                    detach=True,
                    labels={'role': 'queue-worker'},
                    environment={
                        'RABBITMQ_HOST': self.rabbitmq_host
                    },
                    volumes={
                        os.path.abspath('worker.py'): {
                            'bind': '/app/worker.py',
                            'mode': 'ro'
                        }
                    },
                    network=self.network.name,
                    remove=True  # Auto-cleanup on exit
                )
                print(f'Scaled up: {container.short_id}', flush=True)
            except Exception as e:
                print(f'Error scaling up: {e}', file=sys.stderr, flush=True)

    def scale_down(self, current_count, desired_count):
        """Kill excess worker containers"""
        workers = self.get_current_workers()
        to_remove = current_count - desired_count

        for container in workers[:to_remove]:
            try:
                print(f'Scaling down: {container.short_id}', flush=True)
                container.stop(timeout=10)
            except Exception as e:
                print(f'Error scaling down: {e}', file=sys.stderr, flush=True)

    def run(self):
        """Main autoscaler loop"""
        print('Autoscaler started', flush=True)
        print(f'Config: min={self.min_workers}, max={self.max_workers}, '
              f'messages_per_worker={self.messages_per_worker}', flush=True)

        while True:
            try:
                queue_depth = self.get_queue_depth()
                workers = self.get_current_workers()
                current_count = len(workers)
                desired_count = self.desired_workers(queue_depth)

                now = time.time()

                print(f'Queue: {queue_depth} messages | Workers: {current_count} | '
                      f'Desired: {desired_count}', flush=True)

                # Respect cooldown period
                if now - self.last_scale_time < self.cooldown:
                    time.sleep(self.poll_interval)
                    continue

                if desired_count > current_count:
                    print(f'Scaling up: {current_count} → {desired_count}', flush=True)
                    self.scale_up(current_count, desired_count)
                    self.last_scale_time = now
                elif desired_count < current_count:
                    print(f'Scaling down: {current_count} → {desired_count}', flush=True)
                    self.scale_down(current_count, desired_count)
                    self.last_scale_time = now

            except Exception as e:
                print(f'Error in autoscaler loop: {e}', file=sys.stderr, flush=True)

            time.sleep(self.poll_interval)

if __name__ == '__main__':
    autoscaler = QueueAutoscaler()
    autoscaler.run()
```

### Running the demo

```bash
# Start infrastructure
docker-compose up -d

# Watch autoscaler logs
docker-compose logs -f autoscaler

# In another terminal, send messages
curl "http://localhost/send?count=20"

# Check queue depth
curl "http://localhost/queue"

# Watch workers scale up
docker ps | grep queue-worker

# After workers process messages, watch them scale back to 0
```

**What you'll see:**
1. Initially: 0 workers (min=0, queue empty)
2. Send 20 messages: autoscaler scales to 4 workers (20 ÷ 5 = 4)
3. Workers process messages (2 seconds each)
4. After cooldown (60s): autoscaler scales back to 0

This is the same behavior as KEDA, but on a single box with ~150 lines of Python.

## Production-Ready: systemd Integration

For a real deployment, run the autoscaler as a systemd service:

**autoscaler.service**
```ini
[Unit]
Description=Docker Container Autoscaler
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/autoscaler
ExecStart=/usr/bin/python3 /opt/autoscaler/autoscaler.py
Restart=always
RestartSec=10

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ReadOnlyPaths=/
ReadWritePaths=/opt/autoscaler
ProtectSystem=strict
ProtectHome=yes

# Environment
Environment="RABBITMQ_HOST=localhost"
Environment="MIN_WORKERS=1"
Environment="MAX_WORKERS=10"
Environment="MESSAGES_PER_WORKER=5"

[Install]
WantedBy=multi-user.target
```

**Installation:**
```bash
sudo cp autoscaler.py /opt/autoscaler/
sudo cp autoscaler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable autoscaler
sudo systemctl start autoscaler

# Check status
sudo systemctl status autoscaler
sudo journalctl -u autoscaler -f
```

## Cost Comparison (Real Numbers)

### Single Box (EC2 t3.medium)
```
EC2 t3.medium (2 vCPU, 4GB RAM)     $30.37/month
Elastic IP (if needed)               $3.65/month
EBS gp3 30GB                         $2.40/month
Data transfer out (100GB/month)     ~$9.00/month
────────────────────────────────────────────────
TOTAL                               ~$45/month
```

### Kubernetes (EKS + 2 nodes)
```
EKS control plane                   $73/month
2x t3.medium nodes (workers)        $60.74/month
EBS volumes (2x 30GB)                $4.80/month
ALB (load balancer)                 $16.20/month
Data transfer out (100GB/month)     ~$9.00/month
────────────────────────────────────────────────
TOTAL                              ~$163/month
```

**Savings:** $118/month (72% cheaper)
**Break-even point:** When single box can't handle load (~1000-2000 req/sec)

## What You Lose vs Kubernetes

Be honest about the tradeoffs:

| Feature | Single Box | Impact |
|---------|------------|--------|
| **High availability** | None | Downtime during host maintenance, crashes |
| **Rolling updates** | Manual orchestration | Brief downtime or complex scripting |
| **Multi-region** | Duplicate everything | No automatic failover |
| **Load balancing** | Single Traefik instance | Single point of failure |
| **Node failure** | Total outage | No self-healing across machines |
| **Secrets rotation** | Manual | Security risk if not scripted |
| **Horizontal pod autoscaling** | Custom code (this doc) | You maintain it |
| **Service mesh** | None | No mTLS, advanced routing |
| **Cluster autoscaling** | N/A (single machine) | Can't grow beyond 1 host |
| **GitOps** | Scripts + cron/webhooks | No reconciliation loop |
| **Observability** | DIY Prometheus/Grafana | More setup, less integrated |

**Real production story:** I ran a SaaS on a single box (t3.xlarge) for 18 months, handling ~500 active users. Cost: $140/month vs $400+/month for EKS. Downsides: 2 outages (host maintenance), manual deploys, no redundancy. Migrated to EKS when revenue justified the cost.

## Migration Path: Single Box → Kubernetes

When you outgrow single-box, here's the graduation path:

### Phase 1: Containerize everything (you're here)
- All services run in Docker containers
- docker-compose.yml defines the stack
- Custom autoscaler or Nomad

### Phase 2: Extract configuration
- Move from environment variables to config files
- Prepare for Kubernetes ConfigMaps/Secrets
- Use external secret store (AWS Secrets Manager, Vault)

### Phase 3: Add Kubernetes locally
- Run kind or minikube alongside production
- Convert docker-compose.yml → Kubernetes manifests
- Test deployments locally

### Phase 4: Parallel deployment
- Deploy to K8s cluster (EKS/GKE/AKS)
- Run both single-box and K8s in parallel
- Gradually shift traffic (DNS weighted routing)

### Phase 5: Full migration
- Decommission single-box deployment
- Add GitOps (ArgoCD)
- Enable cluster autoscaling, monitoring, alerts

**Timeline:** Typically 2-4 weeks for steps 3-5 if you've done Phase 1 well.

## Limitations: When Single Box Isn't Enough

Hard limits where you must use Kubernetes:

1. **CPU/Memory bound:** Single t3.2xlarge maxes out at 8 vCPU, 32GB RAM (~$120/month). If you need more compute, multi-node is cheaper (3x t3.large = 6 vCPU, 15GB, $90/month).

2. **Geographic distribution:** Serving users in US + EU + Asia requires multi-region. Single box = high latency for 2/3 of users.

3. **Compliance:** PCI-DSS, HIPAA, SOC2 often require redundancy. Single box = audit failure.

4. **Team scale:** 5+ developers deploying daily = merge conflicts on single-box deploys. K8s namespaces isolate teams.

5. **Uptime requirements:** 99.9% uptime = ~8 hours downtime/year. Doable with maintenance windows. 99.99% = 52 minutes/year. Impossible on single box (host reboots alone exceed this).

## Conclusion

Single-box autoscaling is a perfectly valid architecture for:
- Early-stage products (validate before scaling)
- Cost-sensitive projects (sub-$50/month budgets)
- Personal projects / side businesses
- Learning deployment automation

You're not "doing it wrong" by avoiding Kubernetes. You're making a rational tradeoff: simplicity and cost vs resilience and scale.

**The best architecture is the one that ships.**

When you outgrow single-box limits (geographic distribution, compute ceiling, team size), you'll have learned container orchestration the simple way. The migration to Kubernetes will be straightforward because your mental model is already correct — you're just swapping your 150-line Python autoscaler for KEDA.

For the complete Kubernetes version of this pattern, see [keda-demo/README.md](../keda-demo/README.md).