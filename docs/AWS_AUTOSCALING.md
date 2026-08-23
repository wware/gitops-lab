# AWS Auto Scaling Groups: Queue-Driven EC2 Autoscaling

> I want to run batch workloads (video rendering, data processing, etc.) on AWS that scale based on queue depth, ideally to zero when idle. How do I do this without Kubernetes?

Use **AWS Auto Scaling Groups (ASG)** with **SQS queue-based scaling**. This gives you KEDA-like behavior (scale 0→N based on queue depth) using AWS-native services, with 70% cost savings via Spot instances.

## Use Cases

This pattern is ideal for:
- **Batch processing**: Video rendering, image processing, data transformation
- **Bursty workloads**: Irregular traffic patterns (idle for hours, then spike)
- **Cost-sensitive**: Scale to zero when idle, use Spot instances for 70% savings
- **Stateless workers**: Each job is independent, no shared state

**Not suitable for:**
- Real-time/latency-sensitive workloads (ASG scaling takes 1-3 minutes)
- Stateful applications (databases, caches)
- Always-on services (better to use ECS/Fargate or single box)

## Architecture: POV-Ray Render Farm

This example demonstrates a complete render farm that:
1. Accepts scene descriptions uploaded to S3
2. Renders frames using POV-Ray on EC2 Spot instances
3. Scales 0→N workers based on SQS queue depth
4. Assembles final video with FFmpeg
5. Costs ~$5-10 for a typical render job

```
┌─────────────────┐
│   S3 Bucket     │
│  (input scenes) │
└────────┬────────┘
         │
         v
┌─────────────────┐      ┌──────────────────┐
│  Lambda/Script  │─────>│   SQS Queue      │
│  (create jobs)  │      │ (frame render    │
└─────────────────┘      │     tasks)       │
                         └────────┬─────────┘
                                  │
                         ┌────────┴─────────┐
                         │   CloudWatch     │
                         │  (queue depth)   │
                         └────────┬─────────┘
                                  │
                                  v
                         ┌─────────────────┐
                         │  Auto Scaling   │
                         │     Group       │
                         │ (target: queue  │
                         │  depth / cores) │
                         └────────┬─────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
              ┌─────v──────┐            ┌──────v──────┐
              │  EC2 Spot  │            │  EC2 Spot   │
              │  Worker 1  │            │  Worker 2   │
              │ (POV-Ray)  │   ...      │  (POV-Ray)  │
              └─────┬──────┘            └──────┬──────┘
                    │                          │
                    └────────────┬─────────────┘
                                 │
                                 v
                        ┌─────────────────┐
                        │   S3 Bucket     │
                        │ (output frames) │
                        └────────┬────────┘
                                 │
                                 v
                        ┌─────────────────┐
                        │  Lambda/Script  │
                        │ (FFmpeg combine)│
                        └────────┬────────┘
                                 │
                                 v
                        ┌─────────────────┐
                        │   S3 Bucket     │
                        │  (final video)  │
                        └─────────────────┘
```

## Complete Implementation

### Terraform Configuration

**terraform/main.tf**
```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "povray-render-farm"
}

# S3 Buckets
resource "aws_s3_bucket" "input_scenes" {
  bucket = "${var.project_name}-input-scenes"
}

resource "aws_s3_bucket" "output_frames" {
  bucket = "${var.project_name}-output-frames"
}

resource "aws_s3_bucket" "final_videos" {
  bucket = "${var.project_name}-final-videos"
}

# SQS Queue for render jobs
resource "aws_sqs_queue" "render_queue" {
  name                       = "${var.project_name}-render-queue"
  visibility_timeout_seconds = 900  # 15 minutes per frame
  message_retention_seconds  = 86400 # 24 hours
  receive_wait_time_seconds  = 20   # Long polling

  tags = {
    Name = "POV-Ray Render Queue"
  }
}

# Dead Letter Queue for failed jobs
resource "aws_sqs_queue" "render_dlq" {
  name = "${var.project_name}-render-dlq"
}

resource "aws_sqs_queue_redrive_policy" "render_queue_redrive" {
  queue_url = aws_sqs_queue.render_queue.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.render_dlq.arn
    maxReceiveCount     = 3
  })
}

# IAM Role for EC2 instances
resource "aws_iam_role" "worker_role" {
  name = "${var.project_name}-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "${var.project_name}-worker-policy"
  role = aws_iam_role.worker_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.render_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.input_scenes.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.output_frames.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "${var.project_name}-worker-profile"
  role = aws_iam_role.worker_role.name
}

# Security Group
resource "aws_security_group" "worker_sg" {
  name        = "${var.project_name}-worker-sg"
  description = "Security group for render farm workers"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Render Farm Workers"
  }
}

# Launch Template
resource "aws_launch_template" "worker" {
  name_prefix   = "${var.project_name}-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "c5.xlarge"  # 4 vCPU, optimized for compute

  iam_instance_profile {
    name = aws_iam_instance_profile.worker_profile.name
  }

  vpc_security_group_ids = [aws_security_group.worker_sg.id]

  # Request Spot instances
  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price = "0.10"  # ~70% discount vs on-demand
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    queue_url    = aws_sqs_queue.render_queue.url
    input_bucket = aws_s3_bucket.input_scenes.id
    output_bucket = aws_s3_bucket.output_frames.id
    region       = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "POV-Ray Worker"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "workers" {
  name                = "${var.project_name}-workers"
  vpc_zone_identifier = data.aws_subnets.default.ids
  min_size            = 0
  max_size            = 20
  desired_capacity    = 0

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "POV-Ray Worker"
    propagate_at_launch = true
  }
}

# Target Tracking Scaling Policy (queue-based)
resource "aws_autoscaling_policy" "scale_on_queue" {
  name                   = "${var.project_name}-scale-on-queue"
  autoscaling_group_name = aws_autoscaling_group.workers.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_dimension {
        name  = "QueueName"
        value = aws_sqs_queue.render_queue.name
      }

      metric_name = "ApproximateNumberOfMessagesVisible"
      namespace   = "AWS/SQS"
      statistic   = "Average"
    }

    # Target: 10 messages per instance (4 vCPU * 2.5 frames)
    target_value = 10.0
  }
}

# Data sources
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Outputs
output "queue_url" {
  value = aws_sqs_queue.render_queue.url
}

output "input_bucket" {
  value = aws_s3_bucket.input_scenes.id
}

output "output_bucket" {
  value = aws_s3_bucket.output_frames.id
}

output "final_bucket" {
  value = aws_s3_bucket.final_videos.id
}
```

### EC2 User Data Script

**terraform/user_data.sh**
```bash
#!/bin/bash
set -e

# Install dependencies
apt-get update
apt-get install -y povray awscli jq

# Environment from Terraform
QUEUE_URL="${queue_url}"
INPUT_BUCKET="${input_bucket}"
OUTPUT_BUCKET="${output_bucket}"
REGION="${region}"

# Worker script
cat > /home/ubuntu/worker.sh << 'WORKER_SCRIPT'
#!/bin/bash
set -e

QUEUE_URL="$1"
INPUT_BUCKET="$2"
OUTPUT_BUCKET="$3"
REGION="$4"

echo "Worker started: $(date)"
echo "Queue: $QUEUE_URL"
echo "Input: s3://$INPUT_BUCKET"
echo "Output: s3://$OUTPUT_BUCKET"

# Process messages until queue is empty
while true; do
  # Receive message (long polling)
  MESSAGE=$(aws sqs receive-message \
    --queue-url "$QUEUE_URL" \
    --region "$REGION" \
    --wait-time-seconds 20 \
    --max-number-of-messages 1 \
    --output json)

  # Check if queue is empty
  if [ "$(echo "$MESSAGE" | jq -r '.Messages | length')" = "0" ]; then
    echo "Queue empty, shutting down"
    break
  fi

  # Parse message
  RECEIPT_HANDLE=$(echo "$MESSAGE" | jq -r '.Messages[0].ReceiptHandle')
  BODY=$(echo "$MESSAGE" | jq -r '.Messages[0].Body')

  SCENE_KEY=$(echo "$BODY" | jq -r '.scene_key')
  FRAME_NUMBER=$(echo "$BODY" | jq -r '.frame_number')
  OUTPUT_KEY=$(echo "$BODY" | jq -r '.output_key')

  echo "Processing frame $FRAME_NUMBER from $SCENE_KEY"

  # Download scene file
  aws s3 cp "s3://$INPUT_BUCKET/$SCENE_KEY" /tmp/scene.pov --region "$REGION"

  # Render frame with POV-Ray
  povray /tmp/scene.pov \
    +W1920 +H1080 \
    +A0.3 \
    +KFF1 +KFI"$FRAME_NUMBER" +KF"$FRAME_NUMBER" \
    +O/tmp/frame.png \
    -D

  # Upload rendered frame
  aws s3 cp /tmp/frame.png "s3://$OUTPUT_BUCKET/$OUTPUT_KEY" --region "$REGION"

  # Delete message from queue
  aws sqs delete-message \
    --queue-url "$QUEUE_URL" \
    --receipt-handle "$RECEIPT_HANDLE" \
    --region "$REGION"

  echo "Completed frame $FRAME_NUMBER"

  # Cleanup
  rm -f /tmp/scene.pov /tmp/frame.png
done

echo "Worker finished: $(date)"
WORKER_SCRIPT

chmod +x /home/ubuntu/worker.sh

# Run worker (will exit when queue is empty)
/home/ubuntu/worker.sh "$QUEUE_URL" "$INPUT_BUCKET" "$OUTPUT_BUCKET" "$REGION"

# Self-terminate when done (scale to zero)
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id "$INSTANCE_ID" \
  --should-decrement-desired-capacity \
  --region "$REGION"
```

### Job Submission Script

**submit_render.py**
```python
#!/usr/bin/env python3
"""
Submit a POV-Ray scene for rendering.

Usage:
    ./submit_render.py scene.pov --frames 120 --fps 30

This will:
1. Upload scene.pov to S3
2. Create 120 SQS messages (one per frame)
3. ASG will scale up to render frames
4. Trigger FFmpeg combine when all frames complete
"""
import boto3
import json
import argparse
from pathlib import Path

def submit_render(scene_file: Path, frames: int, fps: int):
    s3 = boto3.client('s3')
    sqs = boto3.client('sqs')

    # Get config from Terraform outputs
    # (In practice, store these in SSM Parameter Store or env vars)
    queue_url = "https://sqs.us-east-1.amazonaws.com/123456789/povray-render-farm-render-queue"
    input_bucket = "povray-render-farm-input-scenes"
    output_bucket = "povray-render-farm-output-frames"

    # Upload scene file
    scene_key = f"scenes/{scene_file.name}"
    print(f"Uploading {scene_file} to s3://{input_bucket}/{scene_key}")
    s3.upload_file(str(scene_file), input_bucket, scene_key)

    # Submit frame render jobs
    job_id = scene_file.stem
    print(f"Submitting {frames} frames for job {job_id}")

    for frame_num in range(1, frames + 1):
        message = {
            "job_id": job_id,
            "scene_key": scene_key,
            "frame_number": frame_num,
            "total_frames": frames,
            "fps": fps,
            "output_key": f"frames/{job_id}/frame_{frame_num:04d}.png"
        }

        sqs.send_message(
            QueueUrl=queue_url,
            MessageBody=json.dumps(message)
        )

        if frame_num % 10 == 0:
            print(f"Submitted {frame_num}/{frames} frames")

    print(f"\nJob submitted! Monitor at:")
    print(f"  Queue: {queue_url}")
    print(f"  Frames: s3://{output_bucket}/frames/{job_id}/")
    print(f"\nASG will scale up automatically. When complete, run:")
    print(f"  ./combine_video.py {job_id} --fps {fps}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Submit POV-Ray render job")
    parser.add_argument("scene", type=Path, help="POV-Ray scene file (.pov)")
    parser.add_argument("--frames", type=int, required=True, help="Number of frames")
    parser.add_argument("--fps", type=int, default=30, help="Frames per second")

    args = parser.parse_args()
    submit_render(args.scene, args.frames, args.fps)
```

### Video Assembly Script

**combine_video.py**
```python
#!/usr/bin/env python3
"""
Combine rendered frames into final video using FFmpeg.

Usage:
    ./combine_video.py my-animation --fps 30
"""
import boto3
import subprocess
import argparse
from pathlib import Path
import tempfile

def combine_video(job_id: str, fps: int):
    s3 = boto3.client('s3')

    output_bucket = "povray-render-farm-output-frames"
    final_bucket = "povray-render-farm-final-videos"

    # Download all frames
    print(f"Downloading frames for job {job_id}")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # List and download frames
        paginator = s3.get_paginator('list_objects_v2')
        frame_count = 0

        for page in paginator.paginate(Bucket=output_bucket, Prefix=f"frames/{job_id}/"):
            if 'Contents' not in page:
                continue

            for obj in page['Contents']:
                key = obj['Key']
                if key.endswith('.png'):
                    filename = Path(key).name
                    s3.download_file(output_bucket, key, str(tmpdir / filename))
                    frame_count += 1

                    if frame_count % 10 == 0:
                        print(f"Downloaded {frame_count} frames")

        print(f"Total frames: {frame_count}")

        # Combine with FFmpeg
        output_file = tmpdir / f"{job_id}.mp4"

        print("Encoding video with FFmpeg...")
        subprocess.run([
            "ffmpeg",
            "-framerate", str(fps),
            "-pattern_type", "glob",
            "-i", str(tmpdir / "frame_*.png"),
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-crf", "18",
            str(output_file)
        ], check=True)

        # Upload final video
        final_key = f"videos/{job_id}.mp4"
        print(f"Uploading to s3://{final_bucket}/{final_key}")
        s3.upload_file(str(output_file), final_bucket, final_key)

        print(f"\nVideo complete!")
        print(f"  s3://{final_bucket}/{final_key}")

        # Generate presigned URL for download
        url = s3.generate_presigned_url(
            'get_object',
            Params={'Bucket': final_bucket, 'Key': final_key},
            ExpiresIn=3600
        )
        print(f"\nDownload URL (expires in 1 hour):")
        print(f"  {url}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Combine rendered frames into video")
    parser.add_argument("job_id", help="Job ID (scene name)")
    parser.add_argument("--fps", type=int, default=30, help="Frames per second")

    args = parser.parse_args()
    combine_video(args.job_id, args.fps)
```

## Deployment

```bash
# Initialize Terraform
cd terraform
terraform init

# Deploy infrastructure
terraform apply

# Submit a render job
./submit_render.py examples/spaceship.pov --frames 240 --fps 30

# Watch ASG scale up
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names povray-render-farm-workers \
  --query 'AutoScalingGroups[0].[DesiredCapacity,MinSize,MaxSize]'

# Monitor queue depth
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw queue_url) \
  --attribute-names ApproximateNumberOfMessages

# When rendering completes, combine video
./combine_video.py spaceship --fps 30
```

## How Scaling Works

### Scale-Up Trigger
1. SQS queue receives messages (one per frame)
2. CloudWatch reports `ApproximateNumberOfMessagesVisible`
3. Target Tracking policy compares to target (10 messages/instance)
4. ASG launches EC2 Spot instances (takes ~90 seconds)
5. Instances start processing frames immediately

**Example:**
- 120 frames submitted → 120 messages in queue
- Target: 10 messages/instance
- ASG scales to: 120 ÷ 10 = 12 instances

### Scale-Down Trigger
1. Workers process messages, delete from queue
2. Queue depth drops
3. Target Tracking recalculates desired capacity
4. Workers finish queue, self-terminate
5. ASG returns to 0 instances

**Scale-to-Zero:**
- Workers check for messages with 20-second long polling
- If queue empty, worker calls `terminate-instance-in-auto-scaling-group`
- This decrements desired capacity, allowing true scale-to-zero

## Cost Breakdown

### Example: 240-frame animation (8-second video @ 30fps)

**Compute (Spot instances):**
```
Instance: c5.xlarge (4 vCPU, 8GB RAM)
Spot price: ~$0.034/hour (70% discount vs $0.17 on-demand)
Render time: 2 minutes/frame

Total frames: 240
Parallel workers: 12 instances (240 ÷ 10 target)
Wall time: 240 frames ÷ 12 workers ÷ (60/2 frames/hour) = 0.67 hours

Cost: 12 instances * $0.034/hour * 0.67 hours = $0.27
```

**Storage:**
```
Input scene: 50KB (negligible)
Output frames: 240 * 2MB = 480MB
S3 storage: 480MB * $0.023/GB = $0.01
S3 PUT requests: 240 * $0.005/1000 = $0.001
```

**SQS:**
```
Messages: 240 frames
Cost: 240 * $0.40/million = $0.0001 (free tier covers this)
```

**Total: ~$0.28 for the entire render job**

### Monthly costs (assuming 10 videos/month):
```
Compute: $2.80
Storage (cumulative): ~$5.00
Data transfer: ~$2.00
──────────────────────
TOTAL: ~$10/month
```

**Compared to always-on single box:** $45/month
**Savings:** $35/month (77% cheaper)

## Monitoring and Debugging

### Check ASG status
```bash
aws autoscaling describe-auto-scaling-activities \
  --auto-scaling-group-name povray-render-farm-workers \
  --max-records 10
```

### Check queue depth
```bash
aws sqs get-queue-attributes \
  --queue-url $(terraform output -raw queue_url) \
  --attribute-names All \
  | jq '.Attributes.ApproximateNumberOfMessages'
```

### Check failed jobs (DLQ)
```bash
aws sqs receive-message \
  --queue-url $(terraform output -raw dlq_url) \
  --max-number-of-messages 10
```

### View worker logs (CloudWatch)
```bash
aws logs tail /aws/ec2/povray-workers --follow
```

### SSH into a worker (for debugging)
```bash
# Find instance IP
INSTANCE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=POV-Ray Worker" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# SSH (requires key in launch template)
ssh ubuntu@$INSTANCE_IP

# Check worker logs
tail -f /var/log/cloud-init-output.log
```

## Optimization Strategies

### 1. Use Larger Instances for Complex Scenes
Complex scenes benefit from more CPU cores:
```hcl
instance_type = "c5.4xlarge"  # 16 vCPU
target_value = 40.0  # 40 messages/instance (16 cores * 2.5)
```

### 2. Adjust Spot Price Threshold
Lower max price = cheaper but more interruptions:
```hcl
max_price = "0.05"  # Aggressive savings, higher interruption risk
```

### 3. Enable Spot Instance Diversification
Use multiple instance types to reduce interruptions:
```hcl
mixed_instances_policy {
  instances_distribution {
    on_demand_base_capacity                  = 0
    on_demand_percentage_above_base_capacity = 0
    spot_allocation_strategy                 = "capacity-optimized"
  }

  launch_template {
    launch_template_specification {
      launch_template_id = aws_launch_template.worker.id
      version            = "$Latest"
    }

    override {
      instance_type = "c5.xlarge"
    }
    override {
      instance_type = "c5a.xlarge"
    }
    override {
      instance_type = "c6i.xlarge"
    }
  }
}
```

### 4. Use S3 Transfer Acceleration
For large scene files or remote uploads:
```bash
aws s3 cp scene.pov s3://bucket/scene.pov --region us-east-1 --endpoint-url https://bucket.s3-accelerate.amazonaws.com
```

### 5. Pre-bake AMI with POV-Ray
Faster worker startup (skip `apt-get install povray`):
```bash
# Build custom AMI with Packer
packer build povray-ami.pkr.hcl

# Reference in launch template
image_id = "ami-xxxxx"  # Your custom AMI
```

## Advantages vs Single Box

| Feature | Single Box | AWS ASG |
|---------|------------|---------|
| **Scale-to-zero** | Manual shutdown | Automatic |
| **Cost when idle** | $45/month | $0/month |
| **Max parallelism** | ~4 workers (1 box) | 20+ workers (configurable) |
| **Fault tolerance** | None | Auto-replace failed instances |
| **Render time (240 frames)** | ~8 hours (4 workers) | ~40 minutes (12 workers) |
| **Spot instance savings** | N/A | 70% discount |
| **Setup complexity** | Low | Medium |

## Advantages vs Kubernetes/KEDA

| Feature | Kubernetes + KEDA | AWS ASG |
|---------|-------------------|---------|
| **Monthly baseline cost** | $163+ (EKS) | $0 (scale-to-zero) |
| **Setup complexity** | High | Medium |
| **Scaling speed** | 30-60 seconds | 60-120 seconds |
| **Vendor lock-in** | Low (portable) | High (AWS-only) |
| **Maintenance** | Cluster upgrades | Minimal |
| **Learning curve** | Weeks | Days |
| **Best for** | Multi-service platform | Single workload type |

## When to Graduate to Kubernetes

Move to Kubernetes/EKS when:

1. **Multiple workload types**: Rendering + transcoding + thumbnails → K8s manages all
2. **Always-on services**: Web UI, API, database → EKS baseline cost is justified
3. **Complex orchestration**: DAG workflows (Argo Workflows), scheduled jobs (CronJobs)
4. **Team scale**: 5+ developers, need namespaces/RBAC isolation
5. **Multi-region**: Need to run in US + EU + Asia simultaneously

**But for single-purpose batch workloads?** ASG + SQS is simpler and cheaper.

## Limitations and Gotchas

### 1. Scaling Latency
ASG takes 1-3 minutes to launch instances. For latency-sensitive workloads, consider:
- Fargate (faster startup, more expensive)
- Keep min_size = 1 (sacrifice scale-to-zero for faster response)

### 2. Spot Instance Interruptions
Spot instances can be terminated with 2-minute warning. Mitigation:
- Handle interruptions gracefully (return message to queue)
- Use Spot Instance Interruption Notice handler
- Enable mixed instance types for better availability

### 3. SQS Visibility Timeout
If workers crash, messages become visible again after timeout:
```hcl
visibility_timeout_seconds = 900  # Must exceed max render time
```

### 4. S3 Eventual Consistency
Rare race condition: worker finishes, deletes message, but S3 upload still in progress.
Mitigation: use S3 Transfer Acceleration or verify upload before delete.

### 5. Cost Runaway Protection
Without max_size limit, bugs could spawn hundreds of instances:
```hcl
max_size = 20  # Hard cap to prevent billing surprises
```

Add CloudWatch alarm for unexpected scaling:
```hcl
resource "aws_cloudwatch_metric_alarm" "high_instance_count" {
  alarm_name          = "asg-instance-count-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "GroupDesiredCapacity"
  namespace           = "AWS/AutoScaling"
  period              = "60"
  statistic           = "Average"
  threshold           = "10"
  alarm_description   = "Alert if ASG scales above 10 instances"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.workers.name
  }
}
```

## Conclusion

AWS Auto Scaling Groups with SQS-based scaling provide a sweet spot between single-box simplicity and Kubernetes power:

- **Cheaper than single box** when idle (scale-to-zero)
- **Simpler than Kubernetes** (no cluster to manage)
- **Faster than single box** when rendering (horizontal scale)
- **More reliable than single box** (auto-replace failures)

**Perfect for:**
- Batch workloads (rendering, transcoding, data processing)
- Cost-sensitive projects (<$20/month vs $163+ for EKS)
- Teams comfortable with AWS but not ready for Kubernetes

**Not suitable for:**
- Always-on services (better: single box or Fargate)
- Latency-sensitive workloads (ASG startup lag)
- Multi-cloud portability requirements

For the complete single-box autoscaling approach, see [SINGLE_BOX_AUTOSCALE.md](SINGLE_BOX_AUTOSCALE.md).

For the Kubernetes version with KEDA, see [REAL_EKS_DEPLOY.md](REAL_EKS_DEPLOY.md) and [keda-demo/README.md](../keda-demo/README.md).
