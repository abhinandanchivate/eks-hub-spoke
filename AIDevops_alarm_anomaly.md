Below is an **AWS-based production implementation** for this requirement:

```text
Normal CPU during sale event: 75% - 90%
Normal CPU at midnight: 15% - 25%
```

The correct AWS solution is:

```text
CloudWatch Metrics
+ CloudWatch Anomaly Detection
+ CloudWatch Alarms
+ SNS / EventBridge
+ Lambda enrichment
+ Auto Scaling / Runbook action
```

---

# 1. Target Architecture

```text
Spring Boot Payment Service on EKS / ECS / EC2
        |
        | CPU, memory, latency, errors, request count
        v
Amazon CloudWatch Metrics
        |
        v
CloudWatch Anomaly Detection
        |
        | Learns hourly, daily, weekly patterns
        v
CloudWatch Alarm
        |
        v
SNS / EventBridge
        |
        v
Slack / Teams / PagerDuty / Lambda RCA
        |
        v
SRE Action / Auto Scaling / Rollback
```

CloudWatch anomaly detection builds expected-value bands from historical metric behavior and can account for hourly, daily, and weekly patterns. AWS supports enabling it through console, CLI, CloudFormation, or SDKs. ([AWS Documentation][1])

---

# 2. What We Are Implementing

Instead of this traditional rule:

```text
IF CPU > 80%
THEN alert
```

We implement this:

```text
IF CPU is outside its expected CloudWatch anomaly band
THEN alert
```

So the system understands:

| Time / Context | Expected CPU | Actual CPU | Result |
| -------------- | -----------: | ---------: | ------ |
| Sale event     |    75% - 90% |        85% | Normal |
| Sale event     |    75% - 90% |        96% | Alert  |
| Midnight       |    15% - 25% |        22% | Normal |
| Midnight       |    15% - 25% |        60% | Alert  |

---

# 3. Option A: EC2-Based Implementation

Use this when your Spring Boot app runs directly on EC2.

## Step 1: Confirm CPU Metric Exists

EC2 already publishes this metric:

```text
Namespace: AWS/EC2
MetricName: CPUUtilization
Dimension: InstanceId
```

## Step 2: Create CloudWatch Anomaly Detector

```bash
aws cloudwatch put-anomaly-detector \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --stat Average \
  --dimensions Name=InstanceId,Value=i-xxxxxxxxxxxxxxxxx \
  --region ap-south-1
```

`put-anomaly-detector` creates an anomaly detection model for a CloudWatch metric and lets CloudWatch display the expected normal-value band. ([AWS Documentation][2])

---

## Step 3: Create Alarm Using Anomaly Band

Create a file:

```bash
cpu-anomaly-alarm.json
```

```json
{
  "AlarmName": "payment-service-ec2-cpu-anomaly",
  "AlarmDescription": "CPU is outside normal historical baseline for payment-service EC2 instance",
  "ComparisonOperator": "GreaterThanUpperThreshold",
  "EvaluationPeriods": 3,
  "DatapointsToAlarm": 2,
  "TreatMissingData": "notBreaching",
  "Metrics": [
    {
      "Id": "m1",
      "MetricStat": {
        "Metric": {
          "Namespace": "AWS/EC2",
          "MetricName": "CPUUtilization",
          "Dimensions": [
            {
              "Name": "InstanceId",
              "Value": "i-xxxxxxxxxxxxxxxxx"
            }
          ]
        },
        "Period": 300,
        "Stat": "Average"
      },
      "ReturnData": true
    },
    {
      "Id": "ad1",
      "Expression": "ANOMALY_DETECTION_BAND(m1, 2)",
      "Label": "CPU expected band",
      "ReturnData": true
    }
  ],
  "ThresholdMetricId": "ad1",
  "AlarmActions": [
    "arn:aws:sns:ap-south-1:123456789012:payment-alerts"
  ]
}
```

Run:

```bash
aws cloudwatch put-metric-alarm \
  --cli-input-json file://cpu-anomaly-alarm.json \
  --region ap-south-1
```

CloudWatch metric math supports `ANOMALY_DETECTION_BAND`, which returns an upper and lower expected-value range for the metric. ([AWS Documentation][3])

---

# 4. Option B: EKS-Based Implementation

Use this when your Spring Boot app runs on Amazon EKS.

## Step 1: Enable Container Insights

For EKS, enable CloudWatch Container Insights so AWS can collect pod, node, namespace, and cluster-level metrics. Container Insights collects, aggregates, and summarizes metrics and logs from containerized applications and microservices. ([AWS Documentation][4])

Container Insights stores EKS/Kubernetes metrics in the `ContainerInsights` namespace. ([AWS Documentation][5])

Typical EKS CPU metrics:

```text
Namespace: ContainerInsights
MetricName: pod_cpu_utilization
Dimensions:
  ClusterName
  Namespace
  PodName
```

Or at service/workload level depending on how you aggregate.

---

## Step 2: Create Anomaly Detector for Payment Service CPU

For a specific pod:

```bash
aws cloudwatch put-anomaly-detector \
  --namespace ContainerInsights \
  --metric-name pod_cpu_utilization \
  --stat Average \
  --dimensions \
      Name=ClusterName,Value=prod-eks-cluster \
      Name=Namespace,Value=payments \
      Name=PodName,Value=payment-service-abc123 \
  --region ap-south-1
```

However, in production, pod names change frequently. So it is better to create anomaly detection on a **stable aggregated custom metric**, such as:

```text
payment_service_cpu_avg
```

---

# 5. Better Production Pattern for EKS

Instead of alarming on one pod, publish a custom CloudWatch metric for the whole service.

## Custom Metric

```text
Namespace: Payments/Service
MetricName: CpuUtilization
Dimensions:
  ServiceName = payment-service
  Environment = prod
  Region = ap-south-1
```

This avoids the pod-name problem.

---

## Publish Custom CPU Metric

You can publish from a Lambda, sidecar, OpenTelemetry pipeline, or scheduled job.

Example AWS CLI:

```bash
aws cloudwatch put-metric-data \
  --namespace "Payments/Service" \
  --metric-data '[
    {
      "MetricName": "CpuUtilization",
      "Dimensions": [
        {
          "Name": "ServiceName",
          "Value": "payment-service"
        },
        {
          "Name": "Environment",
          "Value": "prod"
        }
      ],
      "Value": 84,
      "Unit": "Percent"
    }
  ]' \
  --region ap-south-1
```

Then create anomaly detection on this custom metric:

```bash
aws cloudwatch put-anomaly-detector \
  --namespace "Payments/Service" \
  --metric-name CpuUtilization \
  --stat Average \
  --dimensions \
      Name=ServiceName,Value=payment-service \
      Name=Environment,Value=prod \
  --region ap-south-1
```

CloudWatch anomaly detection works for AWS service metrics and custom metrics. ([AWS Documentation][1])

---

# 6. CloudWatch Alarm for Service-Level CPU Anomaly

Create:

```bash
payment-service-cpu-anomaly.json
```

```json
{
  "AlarmName": "payment-service-prod-cpu-anomaly",
  "AlarmDescription": "Payment service CPU is outside its learned normal baseline",
  "ComparisonOperator": "GreaterThanUpperThreshold",
  "EvaluationPeriods": 3,
  "DatapointsToAlarm": 2,
  "TreatMissingData": "notBreaching",
  "Metrics": [
    {
      "Id": "m1",
      "MetricStat": {
        "Metric": {
          "Namespace": "Payments/Service",
          "MetricName": "CpuUtilization",
          "Dimensions": [
            {
              "Name": "ServiceName",
              "Value": "payment-service"
            },
            {
              "Name": "Environment",
              "Value": "prod"
            }
          ]
        },
        "Period": 300,
        "Stat": "Average"
      },
      "ReturnData": true
    },
    {
      "Id": "ad1",
      "Expression": "ANOMALY_DETECTION_BAND(m1, 2)",
      "Label": "Expected CPU band",
      "ReturnData": true
    }
  ],
  "ThresholdMetricId": "ad1",
  "AlarmActions": [
    "arn:aws:sns:ap-south-1:123456789012:payment-prod-alerts"
  ]
}
```

Apply:

```bash
aws cloudwatch put-metric-alarm \
  --cli-input-json file://payment-service-cpu-anomaly.json \
  --region ap-south-1
```

---

# 7. Add Business Context: Sale Event vs Midnight

CloudWatch anomaly detection can learn time-based behavior, but for explicit business events like a planned sale, add a custom metric or EventBridge schedule.

## Add Business Context Metric

Create a custom metric:

```text
Namespace: Payments/Business
MetricName: SaleEventActive
Value:
  1 = sale event active
  0 = normal day
```

During sale:

```bash
aws cloudwatch put-metric-data \
  --namespace "Payments/Business" \
  --metric-data '[
    {
      "MetricName": "SaleEventActive",
      "Dimensions": [
        {
          "Name": "Environment",
          "Value": "prod"
        }
      ],
      "Value": 1,
      "Unit": "Count"
    }
  ]' \
  --region ap-south-1
```

After sale:

```bash
aws cloudwatch put-metric-data \
  --namespace "Payments/Business" \
  --metric-data '[
    {
      "MetricName": "SaleEventActive",
      "Dimensions": [
        {
          "Name": "Environment",
          "Value": "prod"
        }
      ],
      "Value": 0,
      "Unit": "Count"
    }
  ]' \
  --region ap-south-1
```

---

# 8. Recommended Alerting Model

Do not alert only on CPU.

Use this production logic:

```text
CPU anomaly
+ Request rate normal or low
+ Latency increasing
+ Error rate increasing
= real incident
```

## Metrics Required

| Metric                   | Source                                         |
| ------------------------ | ---------------------------------------------- |
| CPU utilization          | CloudWatch / Container Insights                |
| Request count            | ALB `RequestCount` or custom metric            |
| p95 latency              | ALB TargetResponseTime / app metric            |
| 5xx errors               | ALB / app metric                               |
| DB connection pool usage | Spring Boot Micrometer custom metric           |
| JVM GC / heap            | Spring Boot Actuator + CloudWatch agent / OTEL |

---

# 9. Example: Lambda Enrichment for Better Alert

CloudWatch alarm sends event to SNS or EventBridge.

Lambda reads:

```text
CPU anomaly alarm
Current CPU
Expected baseline
Request count
Latency
Error rate
Recent deployment version
SaleEventActive metric
```

Then sends a better message:

```text
Payment service CPU anomaly detected.

Environment: prod
Region: ap-south-1
Actual CPU: 60%
Expected CPU: 15% - 25%
Sale event active: No
Request rate: Low
p95 latency: Increased from 350 ms to 1800 ms
5xx errors: Increased
Likely cause: abnormal background processing, retry storm, inefficient query, or stuck thread.
Recommended action: check recent deployment, DB pool, thread dump, and retry traffic.
```

---

# 10. Lambda Pseudo Code

```python
import boto3
from datetime import datetime, timedelta, timezone

cloudwatch = boto3.client("cloudwatch")

def get_metric(namespace, metric_name, dimensions):
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=15)

    response = cloudwatch.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=dimensions,
        StartTime=start,
        EndTime=end,
        Period=300,
        Statistics=["Average"]
    )

    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return None

    latest = sorted(datapoints, key=lambda x: x["Timestamp"])[-1]
    return latest["Average"]

def lambda_handler(event, context):
    cpu = get_metric(
        "Payments/Service",
        "CpuUtilization",
        [
            {"Name": "ServiceName", "Value": "payment-service"},
            {"Name": "Environment", "Value": "prod"}
        ]
    )

    sale_active = get_metric(
        "Payments/Business",
        "SaleEventActive",
        [
            {"Name": "Environment", "Value": "prod"}
        ]
    )

    latency = get_metric(
        "Payments/Service",
        "P95LatencyMs",
        [
            {"Name": "ServiceName", "Value": "payment-service"},
            {"Name": "Environment", "Value": "prod"}
        ]
    )

    error_rate = get_metric(
        "Payments/Service",
        "ErrorRate",
        [
            {"Name": "ServiceName", "Value": "payment-service"},
            {"Name": "Environment", "Value": "prod"}
        ]
    )

    if sale_active == 1:
        context_msg = "Sale event is active. High CPU may be expected if traffic is also high."
    else:
        context_msg = "No sale event active. High CPU during low-traffic window is suspicious."

    message = f"""
Payment Service CPU Anomaly

CPU: {cpu}
Sale Event Active: {sale_active}
P95 Latency: {latency}
Error Rate: {error_rate}

Context:
{context_msg}

Recommended Action:
1. Check recent deployment.
2. Check DB connection pool.
3. Check retry traffic.
4. Check thread dump.
5. Check Kafka lag.
6. Check HPA scaling status.
"""

    print(message)

    return {
        "statusCode": 200,
        "body": message
    }
```

---

# 11. Add Auto Scaling

For ECS or EC2 Auto Scaling, AWS target tracking can scale capacity based on a target metric value, similar to a thermostat maintaining a target. ([AWS Documentation][6])

For EKS, use Kubernetes HPA:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payment-service-hpa
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payment-service
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Important:

```text
Auto Scaling handles capacity.
Anomaly Detection handles abnormal behavior.
```

Do not treat them as the same thing.

---

# 12. Real Production Flow

## During Sale Event

```text
Time: 8:00 PM
SaleEventActive: 1
Expected CPU: 75% - 90%
Actual CPU: 85%
Request rate: high
Latency: normal
Error rate: normal
```

Decision:

```text
No incident.
System is behaving normally for sale traffic.
```

---

## During Midnight

```text
Time: 12:30 AM
SaleEventActive: 0
Expected CPU: 15% - 25%
Actual CPU: 60%
Request rate: low
Latency: increasing
Error rate: increasing
```

Decision:

```text
Raise incident.
CPU is abnormal for this business context.
```

---

# 13. Minimum AWS Services Needed

| Purpose           | AWS Service                                       |
| ----------------- | ------------------------------------------------- |
| Metrics           | Amazon CloudWatch                                 |
| Container metrics | CloudWatch Container Insights                     |
| Baseline learning | CloudWatch Anomaly Detection                      |
| Alerting          | CloudWatch Alarms                                 |
| Notification      | SNS                                               |
| Event routing     | EventBridge                                       |
| Enrichment / RCA  | Lambda                                            |
| Logs              | CloudWatch Logs                                   |
| Dashboard         | CloudWatch Dashboard                              |
| Scaling           | HPA / ECS Service Auto Scaling / EC2 Auto Scaling |

---

# 14. Final Production Recommendation

For your Spring Boot payment application on AWS, implement it like this:

```text
1. Enable CloudWatch Container Insights for EKS.
2. Publish service-level custom metrics:
   - CpuUtilization
   - RequestCount
   - P95LatencyMs
   - ErrorRate
   - DbConnectionUsage
   - KafkaConsumerLag
3. Create CloudWatch anomaly detector on CpuUtilization.
4. Create CloudWatch alarm using ANOMALY_DETECTION_BAND.
5. Send alarm to SNS / EventBridge.
6. Trigger Lambda to enrich the alert with business context.
7. Notify SRE through Slack / Teams / PagerDuty.
8. Use HPA or AWS Auto Scaling for capacity.
9. Use runbooks for investigation and rollback.
```

In simple words:

```text
CloudWatch learns that 85% CPU is normal during sale time,
but 60% CPU is abnormal at midnight.

So the alert is not based on a fixed number.
It is based on expected behavior for that service and time window.
```

[1]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Anomaly_Detection.html?utm_source=chatgpt.com "Using CloudWatch anomaly detection"
[2]: https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/put-anomaly-detector.html?utm_source=chatgpt.com "put-anomaly-detector"
[3]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html?utm_source=chatgpt.com "Using math expressions with CloudWatch metrics"
[4]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html?utm_source=chatgpt.com "Container Insights - Amazon CloudWatch"
[5]: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-metrics-EKS.html?utm_source=chatgpt.com "Amazon EKS and Kubernetes Container Insights metrics"
[6]: https://docs.aws.amazon.com/autoscaling/application/userguide/application-auto-scaling-target-tracking.html?utm_source=chatgpt.com "Target tracking scaling policies for Application Auto Scaling"
