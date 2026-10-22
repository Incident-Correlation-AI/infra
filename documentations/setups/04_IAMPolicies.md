# AWS Infrastructure Setup Guide: IAM Permissions

This document details the exact steps taken to connect the Lambda functions to SQS and DynamoDB using least-privilege IAM policies.

*Prerequisite:* `IncidentIngestFn`, `IncidentWorkerFn`, and (see 07_APIGateway.md Part 1) `IncidentApiFn` exist; SQS queues and the DynamoDB table exist.

*Why first:* function roles must have permissions **before** the SQS trigger and API integrations start sending work, otherwise messages fail silently or land in the DLQ.

---

## How permissions attach in this architecture

| Function | Needs permission to | Because |
|---|---|---|
| `IncidentIngestFn` | `sqs:SendMessage` → `IncidentMainQueue` | Validated batches are enqueued for async processing |
| `IncidentWorkerFn` | `sqs:ReceiveMessage / DeleteMessage / ChangeMessageVisibility / GetQueueAttributes` → `IncidentMainQueue` | Worker consumes the queue |
| `IncidentWorkerFn` | DynamoDB CRUD + Query → `IncidentTable` (+ its `gsi1` index) | Incidents, dedup state, baselines persist for its writes |
| `IncidentApiFn` | DynamoDB CRUD + Query → `IncidentTable` (+ `gsi1`) | Admin read/lifecycle routes |

API Gateway → Lambda invocation permission is **added automatically** by the console when you pick "Lambda proxy integration", so nothing to grant there manually.

*Note:* `Secrets manager/SSM reads` (`ssm:GetParameter`) can be added later with the token parameters; flag in RuntimeConfig.md.

---

## Step-by-Step Instructions

### Part 1: Allow `IncidentIngestFn` to enqueue into the main queue

1. In the AWS Management Console, search for and select **IAM**.
2. Left-hand menu → **Roles**. Find the role that begins with `IncidentIngestFn-role-` and click it.
3. Click **Add permissions → Inline policy** (or **Create inline policy** inside the Permissions tab).
4. Switch to the **JSON** editor and paste **exactly**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SendToIncidentMainQueue",
      "Effect": "Allow",
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:eu-north-1:776184688152:IncidentMainQueue"
    }
  ]
}
```

5. Name it `IncidentIngestFn-sqs-send`, then **Create policy**.

### Part 2: Allow `IncidentWorkerFn` to consume the queue and write incidents

1. Back in **Roles**, open the role that begins with `IncidentWorkerFn-role-`.
2. **Add permissions → Create inline policy → JSON** and paste **exactly**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ConsumeIncidentMainQueue",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:eu-north-1:776184688152:IncidentMainQueue"
    },
    {
      "Sid": "IncidentTableCRUD",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:ConditionCheckItem"
      ],
      "Resource": [
        "arn:aws:dynamodb:eu-north-1:776184688152:table/IncidentTable",
        "arn:aws:dynamodb:eu-north-1:776184688152:table/IncidentTable/index/gsi1"
      ]
    }
  ]
}
```

3. Name it `IncidentWorkerFn-consume-and-write`, then **Create policy**.

### Part 3: Create `IncidentApiFn`'s DynamoDB policy

Run this **after** the function exists (created in APIGateway.md Part 1), same steps on the role `IncidentApiFn-role-`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IncidentTableCRUD",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:ConditionCheckItem"
      ],
      "Resource": [
        "arn:aws:dynamodb:eu-north-1:776184688152:table/IncidentTable",
        "arn:aws:dynamodb:eu-north-1:776184688152:table/IncidentTable/index/gsi1"
      ]
    }
  ]
}
```

Name it `IncidentApiFn-table-access`.

---

## Expected Outcome

Each function role carries an inline, resource-scoped policy. No wildcards (`*`), no `sqs:*`, no table-level `dynamodb:*`. Permission boundaries mirror the docs: **collectors can only enqueue; only the worker/api touch incidents.**

---

**Next Steps:** set function environment variables (05_RuntimeConfig.md), then the SQS trigger (06_EventSourceMapping.md).
