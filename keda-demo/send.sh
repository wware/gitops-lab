#!/bin/bash

# kubectl run sender-2 --image=python:3.12-slim --rm -i --restart=Never -n keda-demo --     bash -c "pip install pika && python3 -c 'import pika; 
# c=pika.BlockingConnection(pika.ConnectionParameters(\"rabbitmq\",credentials=pika.PlainCredentials(\"guest\",\"guest\"))); ch=c.channel();'"

kubectl run sender-2 --image=python:3.12-slim --rm -i --restart=Never -n keda-demo -- \
bash -c "pip install pika && python3 -c 'import pika; c=pika.BlockingConnection(pika.ConnectionParameters(\"rabbitmq\",credentials=pika.PlainCredentials(\"guest\",\"guest\"))); ch=c.channel(); ch.queue_declare(queue=\"work-queue\",durable=True); [ch.basic_publish(\"\",\"work-queue\",f\"task-{i}\".encode()) for i in range(20)]'"

