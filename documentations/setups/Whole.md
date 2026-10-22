Here is the complete, end-to-end documentation of everything we did to set up your AWS infrastructure. 

I have written this as a professional **Runbook / Setup Guide**. You can save this as `AWS_Infrastructure_Setup_Guide.md`. It includes every step, every piece of code, the exact errors we encountered, and how we fixed them.

***

# IncidentCorrelationAI — AWS Infrastructure Setup Runbook

## 📋 Overview
This document provides a complete, reproducible guide for building the serverless ingestion and processing pipeline for the IncidentCorrelationAI project. It covers the configuration of DynamoDB, SQS, Lambda, API Gateway, IAM, and the end-to-end verification of the system.

**Architecture Flow:**
`Client (curl) -> API Gateway -> Ingest Lambda -> SQS -> Worker Lambda -> DynamoDB`

---

## 🛠️ Step 1: Database (Amazon DynamoDB)
**Purpose:** Store incidents, deduplication records, and baseline state.

1.  Navigate to **DynamoDB** in the AWS Console.
2.  Click **Create table**.
3.  **Table name:** `IncidentTable`
4.  **Partition key:** `pk` (String)
5.  **Sort key:** `sk` (String)
6.  **Table class:** DynamoDB Standard.
7.  **Capacity mode:** On-Demand (ensures Free Tier compliance).
8.  **Secondary indexes:** Create a Global Secondary Index (GSI) to allow querying by status.
    *   **Index name:** `gsi1`
    *   **Partition key:** `gsi1pk` (String)
    *   **Sort key:** `gsi1sk` (String)
    *   **Attribute projections:** All
9.  **Security:** Leave Encryption on AWS-owned key. Turn **Deletion protection ON**.
10. Click **Create table**.

---

## 📬 Step 2: Message Queues (Amazon SQS)
**Purpose:** Buffer incoming logs and catch failed processing attempts (Dead-Letter Queue).

*Note: The AWS Console requires creating the DLQ first before linking it to the Main Queue.*

1.  Navigate to **SQS**.
2.  **Create the DLQ:**
    *   Type: **Standard**
    *   Name: `IncidentDLQ`
    *   Leave defaults and click **Create queue**. Copy its ARN for the next step.
3.  **Create the Main Queue:**
    *   Type: **Standard**
    *   Name: `IncidentMainQueue`
    *   **Visibility timeout:** `120` seconds.
    *   **Dead-letter queue:** Enabled. Paste the `IncidentDLQ` ARN.
    *   **Maximum receives:** `5`
    *   **Encryption:** Enable SSE-SQS (Optional but recommended).
    *   Click **Create queue**.

---

## ⚡ Step 3: Compute (AWS Lambda)
**Purpose:** Run the Python code for ingestion and anomaly detection.

1.  Navigate to **Lambda** -> **Event Functions** -> **Create function**.
2.  Select **Author from scratch**.
3.  **Function name:** `IncidentIngestFn`
    *   **Runtime:** Python 3.12
    *   Leave architecture as `x86_64`.
    *   Leave permissions as default (auto-create role).
    *   Click **Create**.
4.  Repeat the process to create the second function: `IncidentWorkerFn`.

---

## 🔐 Step 4: IAM Permissions
**Purpose:** Allow the Lambdas to communicate with SQS and DynamoDB.

1.  Go to **Lambda** -> `IncidentIngestFn` -> **Configuration** -> **Permissions**.
2.  Click the **Role name** link to open the IAM Console.
3.  Click **Add permissions** -> **Attach policies**.
    *   Attach **`AmazonSQSFullAccess`**.
4.  Repeat this process for `IncidentWorkerFn`, but attach **both** `AmazonSQSFullAccess` and `AmazonDynamoDBFullAccess`.
    *   *(Note: If the functions are already using `PowerUserAccess`, they already have these permissions and this step can be skipped).*

---

## 💻 Step 5: Lambda Code Deployment

### 1. Ingestion Function Code (`IncidentIngestFn`)
This function receives HTTP requests, parses the JSON, and pushes it to SQS.

1.  Go to `IncidentIngestFn` -> **Code** tab.
2.  Paste the following code (replace the `QUEUE_URL` with your actual SQS URL):
```python
import json
import boto3
import uuid

sqs = boto3.client('sqs')
QUEUE_URL = 'https://sqs.[your-region].amazonaws.com/[your-account-id]/IncidentMainQueue'

def lambda_handler(event, context):
    try:
        if 'body' not in event:
            return {"statusCode": 400, "body": json.dumps({"error": "No body provided"})}
        body = json.loads(event['body'])
        events = body.get('events', [])
        if not events:
            return {"statusCode": 400, "body": json.dumps({"error": "No events found"})}
        
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(events))

        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "receipt_id": str(uuid.uuid4()),
                "accepted": len(events),
                "rejected": 0,
                "note": "Accepted events are queued; detection may not have completed."
            })
        }
    except Exception as e:
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}
```
3.  Click **Deploy**.

### 2. Worker Function Code (`IncidentWorkerFn`)
This function polls SQS, processes the logs, and saves incidents to DynamoDB.

1.  Go to `IncidentWorkerFn` -> **Code** tab.
2.  Paste the following code:
```python
import json
import boto3
import uuid
from datetime import datetime, timezone

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('IncidentTable') 

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            events = json.loads(record['body'])
            
            # Handle double-encoded JSON from SQS
            if isinstance(events, str):
                events = json.loads(events)
            if not isinstance(events, list):
                events = [events]

            # Simple Anomaly Detection (Mock)
            is_anomaly = False
            for ev in events:
                msg = str(ev.get('message', '')).lower() if isinstance(ev, dict) else str(ev).lower()
                if 'error' in msg or 'fail' in msg or 'test' in msg:
                    is_anomaly = True
                    break
            
            if is_anomaly:
                incident_id = str(uuid.uuid4())
                now = datetime.now(timezone.utc).isoformat()
                
                table.put_item(
                    Item={
                        'pk': 'INCIDENT',
                        'sk': f'INCIDENT#{incident_id}',
                        'gsi1pk': 'STATUS#open',
                        'gsi1sk': f'{now}#{incident_id}',
                        'incident_id': incident_id,
                        'status': 'open',
                        'severity': 'high',
                        'detector': 'statistical_baseline_mock',
                        'created_at': now,
                        'summary': f"Anomaly detected in batch of {len(events)} events."
                    }
                )
                print(f"✅ Created incident: {incident_id}")
        except Exception as e:
            print(f"❌ Error processing record: {str(e)}")
            raise e 

    return {"statusCode": 200, "body": "Worker finished processing"}
```
3.  Click **Deploy**.

### 3. Add the SQS Trigger
1.  On `IncidentWorkerFn`, look at the **Function overview** diagram.
2.  Click **+ Add trigger**.
3.  Select **SQS**, choose `IncidentMainQueue`.
4.  Ensure **Activate trigger** is checked.
5.  Click **Add**.
6.  *Crucial Check:* Ensure the state changes to **Enabled**.

---

## 🚪 Step 6: API Gateway
**Purpose:** Expose the Ingestion Lambda to the internet.

1.  Navigate to **API Gateway**.
2.  Under **HTTP API**, click **Build**.
3.  **API name:** `IncidentCorrelationAI-API`
4.  Click **Next**.
5.  Under **Integrations**, click **Add integration**.
    *   Select **Lambda**.
    *   Choose `IncidentIngestFn`.
    *   Click **Add**.
6.  Click **Next**.
7.  **Configure routes:**
    *   Method: `POST`
    *   Resource path: `/api/v1/events/batch`
    *   Integration target: `IncidentIngestFn`
    *   Click **Next**.
8.  **Stages:** Leave as `$default` and click **Next**.
9.  Click **Create**.
10. Go to **Stages** on the left menu, click `$default`, and copy the **Invoke URL** (e.g., `https://[id].execute-api.[region].amazonaws.com`).

---

## 🧪 Step 7: Verification and Troubleshooting

### 1. End-to-End Test
Run this in your terminal (ensure your system clock is synchronized via `sudo timedatectl set-ntp true` to avoid AWS signature errors):

```bash
curl -X POST https://[your-api-id].execute-api.[region].amazonaws.com/api/v1/events/batch \
-H "Content-Type: application/json" \
-d '{
  "events": [
    {
      "event_id": "test-001",
      "message": "CRITICAL ERROR: Database connection failed!"
    }
  ]
}'
```
*Expected Result:* `202 Accepted` with a `receipt_id`.
*Verification:* Go to DynamoDB -> `IncidentTable` -> **Explore table items** to see the new row.

### 2. Testing the Dead-Letter Queue (DLQ)
To prove the DLQ works, we intentionally caused a failure:
1.  Temporarily change the Worker code table name to `IncidentTableFake` and deploy.
2.  Temporarily change the `IncidentMainQueue` **Visibility timeout** to `2 seconds` and **Maximum receives** to `2`.
3.  Run the `curl` command. The Lambda will fail twice.
4.  SQS moves the message to `IncidentDLQ`.
5.  Poll the DLQ in the SQS console to see the message.
6.  **CRITICAL CLEANUP:** Change the code back to `IncidentTable` and SQS settings back to `120s` / `5 receives`.

### ⚠️ Key Issues Encountered & Solved During Setup
*   **Clock Drift:** `Signature not yet current` error. Fixed by syncing Fedora's system clock (`sudo timedatectl set-ntp true` and `sudo chronyc makestep`).
*   **UI Updates:** The AWS Console frequently changed layout (e.g., Lambda "Event Functions", API Gateway integrations). We adapted by using the latest workflows.
*   **Malformed JSON in Manual Tests:** When testing Lambda manually, double-encoded JSON strings caused `AttributeError`. Fixed by writing robust Python code that checks `isinstance(events, str)` and parses twice if necessary.
*   **Stuck SQS Trigger:** The trigger initially got stuck in a `Creating` state with `Activate trigger: No`. Fixed by ensuring the Lambda had proper IAM roles, deleting the broken trigger, and creating a new one.Here is the complete, end-to-end documentation of everything we did to set up your AWS infrastructure. 

I have written this as a professional **Runbook / Setup Guide**. You can save this as `AWS_Infrastructure_Setup_Guide.md`. It includes every step, every piece of code, the exact errors we encountered, and how we fixed them.

***

# IncidentCorrelationAI — AWS Infrastructure Setup Runbook

## 📋 Overview
This document provides a complete, reproducible guide for building the serverless ingestion and processing pipeline for the IncidentCorrelationAI project. It covers the configuration of DynamoDB, SQS, Lambda, API Gateway, IAM, and the end-to-end verification of the system.

**Architecture Flow:**
`Client (curl) -> API Gateway -> Ingest Lambda -> SQS -> Worker Lambda -> DynamoDB`

---

## 🛠️ Step 1: Database (Amazon DynamoDB)
**Purpose:** Store incidents, deduplication records, and baseline state.

1.  Navigate to **DynamoDB** in the AWS Console.
2.  Click **Create table**.
3.  **Table name:** `IncidentTable`
4.  **Partition key:** `pk` (String)
5.  **Sort key:** `sk` (String)
6.  **Table class:** DynamoDB Standard.
7.  **Capacity mode:** On-Demand (ensures Free Tier compliance).
8.  **Secondary indexes:** Create a Global Secondary Index (GSI) to allow querying by status.
    *   **Index name:** `gsi1`
    *   **Partition key:** `gsi1pk` (String)
    *   **Sort key:** `gsi1sk` (String)
    *   **Attribute projections:** All
9.  **Security:** Leave Encryption on AWS-owned key. Turn **Deletion protection ON**.
10. Click **Create table**.

---

## 📬 Step 2: Message Queues (Amazon SQS)
**Purpose:** Buffer incoming logs and catch failed processing attempts (Dead-Letter Queue).

*Note: The AWS Console requires creating the DLQ first before linking it to the Main Queue.*

1.  Navigate to **SQS**.
2.  **Create the DLQ:**
    *   Type: **Standard**
    *   Name: `IncidentDLQ`
    *   Leave defaults and click **Create queue**. Copy its ARN for the next step.
3.  **Create the Main Queue:**
    *   Type: **Standard**
    *   Name: `IncidentMainQueue`
    *   **Visibility timeout:** `120` seconds.
    *   **Dead-letter queue:** Enabled. Paste the `IncidentDLQ` ARN.
    *   **Maximum receives:** `5`
    *   **Encryption:** Enable SSE-SQS (Optional but recommended).
    *   Click **Create queue**.

---

## ⚡ Step 3: Compute (AWS Lambda)
**Purpose:** Run the Python code for ingestion and anomaly detection.

1.  Navigate to **Lambda** -> **Event Functions** -> **Create function**.
2.  Select **Author from scratch**.
3.  **Function name:** `IncidentIngestFn`
    *   **Runtime:** Python 3.12
    *   Leave architecture as `x86_64`.
    *   Leave permissions as default (auto-create role).
    *   Click **Create**.
4.  Repeat the process to create the second function: `IncidentWorkerFn`.

---

## 🔐 Step 4: IAM Permissions
**Purpose:** Allow the Lambdas to communicate with SQS and DynamoDB.

1.  Go to **Lambda** -> `IncidentIngestFn` -> **Configuration** -> **Permissions**.
2.  Click the **Role name** link to open the IAM Console.
3.  Click **Add permissions** -> **Attach policies**.
    *   Attach **`AmazonSQSFullAccess`**.
4.  Repeat this process for `IncidentWorkerFn`, but attach **both** `AmazonSQSFullAccess` and `AmazonDynamoDBFullAccess`.
    *   *(Note: If the functions are already using `PowerUserAccess`, they already have these permissions and this step can be skipped).*

---

## 💻 Step 5: Lambda Code Deployment

### 1. Ingestion Function Code (`IncidentIngestFn`)
This function receives HTTP requests, parses the JSON, and pushes it to SQS.

1.  Go to `IncidentIngestFn` -> **Code** tab.
2.  Paste the following code (replace the `QUEUE_URL` with your actual SQS URL):
```python
import json
import boto3
import uuid

sqs = boto3.client('sqs')
QUEUE_URL = 'https://sqs.[your-region].amazonaws.com/[your-account-id]/IncidentMainQueue'

def lambda_handler(event, context):
    try:
        if 'body' not in event:
            return {"statusCode": 400, "body": json.dumps({"error": "No body provided"})}
        body = json.loads(event['body'])
        events = body.get('events', [])
        if not events:
            return {"statusCode": 400, "body": json.dumps({"error": "No events found"})}
        
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(events))

        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "receipt_id": str(uuid.uuid4()),
                "accepted": len(events),
                "rejected": 0,
                "note": "Accepted events are queued; detection may not have completed."
            })
        }
    except Exception as e:
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}
```
3.  Click **Deploy**.

### 2. Worker Function Code (`IncidentWorkerFn`)
This function polls SQS, processes the logs, and saves incidents to DynamoDB.

1.  Go to `IncidentWorkerFn` -> **Code** tab.
2.  Paste the following code:
```python
import json
import boto3
import uuid
from datetime import datetime, timezone

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('IncidentTable') 

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            events = json.loads(record['body'])
            
            # Handle double-encoded JSON from SQS
            if isinstance(events, str):
                events = json.loads(events)
            if not isinstance(events, list):
                events = [events]

            # Simple Anomaly Detection (Mock)
            is_anomaly = False
            for ev in events:
                msg = str(ev.get('message', '')).lower() if isinstance(ev, dict) else str(ev).lower()
                if 'error' in msg or 'fail' in msg or 'test' in msg:
                    is_anomaly = True
                    break
            
            if is_anomaly:
                incident_id = str(uuid.uuid4())
                now = datetime.now(timezone.utc).isoformat()
                
                table.put_item(
                    Item={
                        'pk': 'INCIDENT',
                        'sk': f'INCIDENT#{incident_id}',
                        'gsi1pk': 'STATUS#open',
                        'gsi1sk': f'{now}#{incident_id}',
                        'incident_id': incident_id,
                        'status': 'open',
                        'severity': 'high',
                        'detector': 'statistical_baseline_mock',
                        'created_at': now,
                        'summary': f"Anomaly detected in batch of {len(events)} events."
                    }
                )
                print(f"✅ Created incident: {incident_id}")
        except Exception as e:
            print(f"❌ Error processing record: {str(e)}")
            raise e 

    return {"statusCode": 200, "body": "Worker finished processing"}
```
3.  Click **Deploy**.

### 3. Add the SQS Trigger
1.  On `IncidentWorkerFn`, look at the **Function overview** diagram.
2.  Click **+ Add trigger**.
3.  Select **SQS**, choose `IncidentMainQueue`.
4.  Ensure **Activate trigger** is checked.
5.  Click **Add**.
6.  *Crucial Check:* Ensure the state changes to **Enabled**.

---

## 🚪 Step 6: API Gateway
**Purpose:** Expose the Ingestion Lambda to the internet.

1.  Navigate to **API Gateway**.
2.  Under **HTTP API**, click **Build**.
3.  **API name:** `IncidentCorrelationAI-API`
4.  Click **Next**.
5.  Under **Integrations**, click **Add integration**.
    *   Select **Lambda**.
    *   Choose `IncidentIngestFn`.
    *   Click **Add**.
6.  Click **Next**.
7.  **Configure routes:**
    *   Method: `POST`
    *   Resource path: `/api/v1/events/batch`
    *   Integration target: `IncidentIngestFn`
    *   Click **Next**.
8.  **Stages:** Leave as `$default` and click **Next**.
9.  Click **Create**.
10. Go to **Stages** on the left menu, click `$default`, and copy the **Invoke URL** (e.g., `https://[id].execute-api.[region].amazonaws.com`).

---

## 🧪 Step 7: Verification and Troubleshooting

### 1. End-to-End Test
Run this in your terminal (ensure your system clock is synchronized via `sudo timedatectl set-ntp true` to avoid AWS signature errors):

```bash
curl -X POST https://[your-api-id].execute-api.[region].amazonaws.com/api/v1/events/batch \
-H "Content-Type: application/json" \
-d '{
  "events": [
    {
      "event_id": "test-001",
      "message": "CRITICAL ERROR: Database connection failed!"
    }
  ]
}'
```
*Expected Result:* `202 Accepted` with a `receipt_id`.
*Verification:* Go to DynamoDB -> `IncidentTable` -> **Explore table items** to see the new row.

### 2. Testing the Dead-Letter Queue (DLQ)
To prove the DLQ works, we intentionally caused a failure:
1.  Temporarily change the Worker code table name to `IncidentTableFake` and deploy.
2.  Temporarily change the `IncidentMainQueue` **Visibility timeout** to `2 seconds` and **Maximum receives** to `2`.
3.  Run the `curl` command. The Lambda will fail twice.
4.  SQS moves the message to `IncidentDLQ`.
5.  Poll the DLQ in the SQS console to see the message.
6.  **CRITICAL CLEANUP:** Change the code back to `IncidentTable` and SQS settings back to `120s` / `5 receives`.

### ⚠️ Key Issues Encountered & Solved During Setup
*   **Clock Drift:** `Signature not yet current` error. Fixed by syncing Fedora's system clock (`sudo timedatectl set-ntp true` and `sudo chronyc makestep`).
*   **UI Updates:** The AWS Console frequently changed layout (e.g., Lambda "Event Functions", API Gateway integrations). We adapted by using the latest workflows.
*   **Malformed JSON in Manual Tests:** When testing Lambda manually, double-encoded JSON strings caused `AttributeError`. Fixed by writing robust Python code that checks `isinstance(events, str)` and parses twice if necessary.
*   **Stuck SQS Trigger:** The trigger initially got stuck in a `Creating` state with `Activate trigger: No`. Fixed by ensuring the Lambda had proper IAM roles, deleting the broken trigger, and creating a new one.