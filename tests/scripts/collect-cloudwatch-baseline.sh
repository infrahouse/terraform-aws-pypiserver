#!/usr/bin/env bash

set -euo pipefail

# Collect CloudWatch metrics for baseline stress test

OUTPUT_DIR="tests/results/baseline"
mkdir -p "$OUTPUT_DIR"

# Time window for your stress test (adjust as needed)
START_TIME="2025-12-28T13:37:50Z"
END_TIME="2025-12-28T14:02:32Z"

# Get resource IDs from terraform
EFS_ID=fs-09347145c7275e303
SERVICE_ARN=arn:aws:ecs:us-west-2:303467602807:service/pypiserver/pypiserver
ALB_ARN=arn:aws:elasticloadbalancing:us-west-2:303467602807:loadbalancer/app/pypise20251227223323974600000011/3d27d5b42c8b3339
CLUSTER_NAME=pypiserver
SERVICE_NAME=pypiserver
ALB_NAME=app/pypise20251227223323974600000011/3d27d5b42c8b3339


echo "Collecting CloudWatch metrics..."
echo "EFS: $EFS_ID"
echo "Service: $SERVICE_NAME"
echo "Cluster: $CLUSTER_NAME"

# EFS Burst Credits
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name BurstCreditBalance \
  --dimensions Name=FileSystemId,Value=$EFS_ID \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --statistics Average Minimum \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-efs-burst-credits.json"

# EFS IO Limit
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name PercentIOLimit \
  --dimensions Name=FileSystemId,Value=$EFS_ID \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --statistics Average Maximum \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-efs-io-limit.json"

# ECS Memory Utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ServiceName,Value=$SERVICE_NAME Name=ClusterName,Value=$CLUSTER_NAME \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --statistics Average Maximum \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-ecs-memory.json"

# ECS CPU Utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=$SERVICE_NAME Name=ClusterName,Value=$CLUSTER_NAME \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --statistics Average Maximum \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-ecs-cpu.json"

# ALB Target Response Time (Average and Maximum)
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=$ALB_NAME \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --statistics Average Maximum \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-alb-response-time.json"

# ALB Target Response Time (Percentiles)
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=$ALB_NAME \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --period 300 \
  --extended-statistics p95 p99 \
  --region us-west-2 \
  --output json > "$OUTPUT_DIR/cloudwatch-alb-response-time-percentiles.json"

echo "✓ CloudWatch metrics saved to $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR"/cloudwatch-*.json
