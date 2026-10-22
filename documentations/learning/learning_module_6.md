# 📚 Learning Module 6 — AWS Serverless & SAM: Lambda, SQS, DynamoDB, API Gateway, IAM

> **Module goal:** Deploy the *same* Python core to a durable, cheap, least-privilege AWS stack — and understand every moving part well enough to debug it at 2 a.m.
> **Project tie-in:** You will build `infra/template.yaml`, the ingestion and worker Lambdas, the DynamoDB access layer, and the deploy/teardown runbooks.

⚠️ **Standing rule:** Do not assume current runtime compatibility, pricing, quotas, or permissions. **Verify in the target account. Never state that deployment succeeded until commands and results verify it.**

**Estimated study time:** 30–40 hours. **Prereq:** Modules 1–2; familiarity with HTTP and JSON.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 What "serverless" actually means (and its history)
   - 1.2 The Lambda execution model: cold starts, concurrency, statelessness
   - 1.3 API Gateway: HTTP API vs. REST API, and the ASGI bridge
   - 1.4 SQS: delivery semantics, visibility, DLQ, partial batch failure
   - 1.5 DynamoDB: access-pattern-first modeling, keys, indexes, TTL, conditional writes
   - 1.6 IAM: roles, policies, and least privilege that's actually enforceable
   - 1.7 SAM & CloudFormation: the IaC model, build, deploy, outputs, parameters
   - 1.8 Observability & secrets
   - 1.9 Cost model and the discipline of measuring
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 What "serverless" means, and its brief history

"Serverless" doesn't mean no servers; it means **you don't provision, patch, or scale them**. Two defining properties:

1. **Managed compute (FaaS):** you upload a function; the provider runs it on demand and scales it. You pay per invocation and per GB-second, not per idle hour.
2. **Event-driven** and **stateless:** functions react to events (HTTP, queue, schedule) and don't keep durable state in the runtime. Durability lives in managed services (DynamoDB, S3).

**History:** AWS Lambda launched in **2014** (code you deploy and forget). API Gateway followed, then SAM (2016) as a thin CloudFormation transform to make serverless IaC readable. The pattern matured into **event-driven architectures**: API → queue → worker → store, which is exactly this project's shape.

**Why serverless fits this project:**
- Spiky log volume — bursts of 25 events/s then quiet. Per-invocation billing avoids paying for idle EC2.
- Bounded scope — the spec explicitly avoids always-on EC2, Kinesis, and managed search.
- Natural fit for the pipeline: **API decouples from discovery** via a queue.

**Why it's genuinely hard:**
- **Cold starts** add latency and make state-in-memory a trap.
- **At-least-once** delivery everywhere; idempotency is mandatory.
- **Distributed debugging** across API GW, Lambda, SQS, DynamoDB.
- **IAM** is fiddly and easy to over-grant.

### 1.2 The Lambda execution model

**Lifecycle of a function:**
```
INIT (cold): boot runtime → import modules → create handler → run handler → freeze
WARM:                 reuse container → run handler → freeze
COLD again: container evicted → INIT again
```

Key facts:
- **Stateless by design.** Anything you cache in module scope *may* persist across warm invocations, and *may* vanish without warning. **Never rely on memory for durable state** (the spec: "never rely on Lambda process memory for persistence"). Use it only as a *cache* with a correctness fallback.
- **Cold starts** are dominated by **import weight** and runtime init. Importing `scikit-learn` at module top adds real latency to *every* cold start. **Lazy-import heavy detectors** and gate them behind the experiment flag.
- **Concurrency:** each concurrent invocation gets its own container (up to account/function limits). If the worker reads SQS with high concurrency, watch for **hot partitions in DynamoDB** (below).
- **Timeouts:** default 3 s, max 15 min. Set explicitly; the queue's visibility timeout must exceed it.
- **Memory:** 128 MB–10 GB; **CPU scales roughly with memory**. More memory can be *cheaper* (faster completion) for CPU-bound work.
- **Ephemeral storage** `/tmp` (512 MB–10 GB): fine for scratch, not for durable state.
- **Payload limits:** synchronous 6 MB; async 256 KB; SQS message 256 KB (the batch limit in this project is 100 events / 256 KB — deliberately aligned).

**SnapStart / Provisioned Concurrency** exist to mitigate cold starts for latency-sensitive paths; evaluate cost before adopting. The spec's posture is to *measure* and avoid always-on services unless justified.

### 1.3 API Gateway: HTTP API vs. REST API, and the ASGI bridge

**HTTP API** is cheaper, lower-latency, and simpler than **REST API**. It supports JWT authorizers, but **fewer** features (no request validation models, no API keys in the same way, limited WAF integration). For this project's six endpoints, **HTTP API** is the right default; verify feature needs before choosing.

**The ASGI bridge.** The project uses FastAPI, an ASGI framework, but Lambda expects a handler `def handler(event, context)`. **Mangum** adapts ASGI apps to the Lambda/API-GW event shape:

```python
# services/api/lambda_handler.py
from mangum import Mangum
from services.api.main import app

handler = Mangum(app, lifespan="off")   # one adapter object; no server process
```

**Decision recorded in an ADR:** FastAPI+Mangum vs. a plain handler. The spec says evaluate early and, if DNS-heavy packaging "adds disproportionate complexity," implement a simpler handler **preserving the same contract**. Contract tests are what make that swap safe.

**Response correctness matters.** API Gateway HTTP API requires a specific response shape; a malformed response yields **502**. Mangum handles the translation for FastAPI; a hand-rolled handler must return `{"statusCode", "headers", "body"}` correctly.

### 1.4 SQS: delivery semantics, visibility, DLQ, partial batch failure

**Standard queues** give **at-least-once** delivery and best-effort ordering. That is the project's assumed baseline: **the worker must be idempotent**.

**Visibility timeout** is the crucial knob. When a consumer receives a message, it becomes invisible for a duration; if the consumer doesn't delete it in time, it becomes visible again and is redelivered. So:

```
visibility_timeout  ≥  function_timeout × (retries within a batch) × safety_factor
```

If `visibility_timeout < function_timeout`, a slow worker's messages reappear **while it's still working** → extra redeliveries (mitigated by idempotency, but wasteful and confusing). Common guidance: set visibility to ~2× the Lambda timeout.

**Redrive policy / DLQ:** after `maxReceiveCount` failures, the message moves to the **dead-letter queue**. This prevents poison messages from looping forever. The project uses a DLQ with 14-day retention for inspection and deliberate replay.

**Partial batch failure.** Lambda's SQS integration can report **per-message** failures via `ReportBatchItemFailures`, so a batch of 10 where 2 fail only retries the 2:

```python
# services/worker/handler.py
def handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            process(record)
        except RetryableError:
            failures.append({"itemIdentifier": record["messageId"]})
        except FatalError:
            failures.append({"itemIdentifier": record["messageId"]})  # → DLQ
    return {"batchItemFailures": failures}
```

Requires `FunctionResponseTypes: [ReportBatchItemFailures]` in the event source mapping. Without it, one bad message fails the whole batch.

**Never lose a message silently after logging an exception.** An exception path must retry, nack, or DLQ — and increment a metric.

### 1.5 DynamoDB: access-pattern-first modeling

**The rule:** enumerate queries **before** choosing keys. DynamoDB is not a relational database; it's a key-value + sorted-collection store with indexes. Tables are designed *around access patterns*.

**Core concepts:**
- **Partition key (PK)** — determines which physical partition stores the item; hashed for distribution.
- **Sort key (SK)** — optional; items with the same PK are stored sorted by SK, enabling range queries.
- **Query** — fetch items by PK (+ SK condition). Efficient, single-partition.
- **Scan** — read the whole table. Expensive; avoid in request paths.
- **GSI (Global Secondary Index)** — an alternate PK/SK pair over the same data; eventually consistent by default; queries the index then fetches from the base table.
- **LSI (Local Secondary Index)** — alternate SK, same PK; must be created with the table; strongly consistent reads available.
- **Capacity modes:** **on-demand** (pay per request; auto-scales) vs. **provisioned** (set RCU/WCU + autoscaling). On-demand is the right default for a demo workload — but **measure**; on-demand ≠ free.
- **TTL** — an attribute (epoch seconds); DynamoDB deletes expired items **asynchronously** (can lag hours). So TTL is *not* a hard-delete guarantee; if strict cleanup matters, add a sweeper and **test** it.
- **Conditional writes** — `ConditionExpression` enables idempotent/optimistic writes (e.g., "only if `attribute_not_exists(pk)`").
- **Hot partitions** — a single PK hammered by many requests throttles. With per-event dedup keyed by `event_id`, partition distribution is naturally good; but avoid keys like `pk="INCIDENT"` taking *all* writes (this project's incident listing does exactly that — an acceptable read pattern at demo scale, but a scaling caveat to document).

**The project's access patterns (recap from the cloud guide):**

| # | Pattern | Key design |
|---|---|---|
| A1 | List incidents newest-first | `pk=INCIDENT`, SK sorted by created_at |
| A2 | List by status | GSI `gsi1pk=STATUS#open` |
| A3 | List by severity | GSI or SK facet |
| A4 | Get incident by ID | `pk=INCIDENT`, `sk=INCIDENT#<id>` |
| A5 | Dedup event ID | `pk=DEDUP#<event_id>`, TTL |
| A6 | Baseline by entity+feature | `pk=BASELINE#<entity>#<feature>` |
| A7 | Ack/resolve + audit | update incident + append `AUDIT#<ts>` |

**Single-table vs. multi-table:** single-table packs many entity types into one table with prefixed keys; it's flexible and cheap but harder to reason about. Multi-table is simpler but uses more resources. **Decide via ADR and measure**; for a demo either is fine.

**Read consistency:** queries on the base table can be strongly consistent; GSIs are eventually consistent. For incident listing, eventual consistency is acceptable (document it).

### 1.6 IAM: least privilege that's enforceable

**Principals, roles, policies.** Lambda assumes a **role**; the role has **policies** (JSON) granting `Action` on `Resource`. Least privilege means: one action per need, one resource ARN where known, and **conditions** where useful.

```jsonc
// ingestion function policy: only send to THIS queue
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sqs:SendMessage",
    "Resource": "arn:aws:sqs:us-east-1:123456789012:lad-dev-main"
  }]
}
```

```jsonc
// worker function policy: only what the worker needs, on THIS table + queue
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:Query"],
     "Resource":["arn:aws:dynamodb:us-east-1:123456789012:table/lad-dev-incidents",
                 "arn:aws:dynamodb:us-east-1:123456789012:table/lad-dev-incidents/index/*"]},
    {"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],
     "Resource":"arn:aws:sqs:us-east-1:123456789012:lad-dev-main"}
  ]
}
```

**Rules from the spec:** separate **collector** and **administrator** identities; collectors cannot read incidents; no wildcard IAM where practical; secrets in SSM/Secrets Manager, not Git; HTTPS; verify CORS.

**Resource policies** (queue/bucket policies) can add a second layer: e.g., restrict a queue to `aws:SourceArn` of the ingestion function, so a leaked role elsewhere can't post to it.

### 1.7 SAM & CloudFormation: the IaC model

**CloudFormation** is AWS's declarative IaC engine — templates describe resources; the engine computes the diff and applies it, with **rollback on failure**. **SAM** is a *transform* (`AWS::Serverless-2016-10-31`) that expands `AWS::Serverless::Function`/`::HttpApi` into CloudFormation resources — far less boilerplate.

**Lifecycle:**
```
sam validate --lint   # syntax + best practices
sam build             # bundle deps into .aws-sam/build
sam deploy --guided   # package + upload + create/update the CloudFormation stack
```

**Parameters & outputs** make environments reusable:
- Parameters: `Env`, `CollectorTokenParam` (NoEcho), `AdminCredentialParam` (NoEcho).
- Outputs: `ApiUrl`, `MainQueueUrl`, `DlqUrl`, `TableName` — consumed by scripts and the dashboard.

**Stack states to know:**
- `CREATE_COMPLETE` / `UPDATE_COMPLETE` — healthy.
- `ROLLBACK_COMPLETE` — a create/update failed and rolled back; a stack in this state **must be deleted**, not updated.
- `UPDATE_ROLLBACK_COMPLETE` — update failed, reverted to previous.

**Environments:** separate `dev` and `demo` stacks where feasible; parameterize everything; no env-specific values in the template body.

### 1.8 Observability & secrets

**CloudWatch Logs** collects Lambda logs. **Structured JSON logs** (not free text) make them queryable:

```python
import json, logging
log = logging.getLogger("lad")
log.info(json.dumps({"event": "ingest", "accepted": 97, "rejected": 3, "request_id": rid}))
```

**CloudWatch Metrics / EMF** — emit custom metrics (accepted, rejected, processed, dlq_depth) as structured logs that CloudWatch turns into metrics (Embedded Metric Format), or use the AWS SDK.

**X-Ray** — distributed tracing across API GW → Lambda → SQS → DynamoDB. Helpful but **never annotate with sensitive payloads**; trace IDs and timing only.

**Secrets:** SSM Parameter Store (SecureString) or Secrets Manager. Inject via environment variables or fetch at runtime. Never bake into the template body committed to Git; use `NoEcho` params and out-of-band provisioning.

**Redaction still applies** — logs from Lambda must not contain secrets or raw log bodies; redaction happened upstream (Module 3), and the worker must not re-log payloads.

### 1.9 Cost model and the discipline of measuring

Serverless bills by **invocations + duration (GB-s)** for Lambda, **requests + data** for API GW, **requests + storage** for SQS, and **RCU/WCU or requests** for DynamoDB. Free tiers exist but **vary and don't guarantee zero cost**.

**Discipline:**
- Use a **measured workload** (5 events/s × 10 min; 25 events/s × 60 s) and inspect **actual** usage afterward.
- Avoid always-on EC2/Kinesis/managed search unless justified.
- Budget/usage alerts **notify** — they don't necessarily stop spending.
- Identify **persistent resources** (tables, buckets, log groups, DLQ messages) and document teardown.
- Report **actual cost** for the defined workload/period as a metric.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 A SAM template with coherent queue/worker config

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Automated Log Anomaly Detector - core stack

Parameters:
  Env: { Type: String, AllowedValues: [dev, demo] }
  CollectorTokenParam: { Type: String, NoEcho: true }
  DashboardOrigin: { Type: String }

Globals:
  Function:
    Runtime: python3.12            # pin after verifying compatibility
    Timeout: 30
    MemorySize: 512
    Architectures: [x86_64]
    Environment:
      Variables:
        LAD_MODE: aws
        LAD_ENV: !Ref Env
        INCIDENT_TABLE: !Ref IncidentTable

Resources:
  HttpApi:
    Type: AWS::Serverless::HttpApi
    Properties:
      CorsConfiguration:
        AllowOrigins: [ !Ref DashboardOrigin ]
        AllowMethods: [GET, POST, OPTIONS]
        AllowHeaders: [Authorization, Content-Type]

  IngestFn:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: ../
      Handler: services.api.lambda_handler.handler
      Policies:
        - SQSSendMessagePolicy: { QueueName: !GetAtt MainQueue.QueueName }
        - SSMParameterReadPolicy: { ParameterName: !Sub "lad/${Env}/collector-token-hash" }
      Events:
        Batch:
          Type: HttpApi
          Properties: { ApiId: !Ref HttpApi, Method: POST, Path: /api/v1/events/batch }
        Health:
          Type: HttpApi
          Properties: { ApiId: !Ref HttpApi, Method: GET, Path: /api/v1/health }

  WorkerFn:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: ../
      Handler: services.worker.handler.handler
      Timeout: 60                                   # visibility below must exceed this ×2
      MemorySize: 1024
      Policies:
        - DynamoDBCrudPolicy: { TableName: !Ref IncidentTable }
        - SQSPollerPolicy: { QueueName: !GetAtt MainQueue.QueueName }
      Environment:
        Variables:
          MAIN_QUEUE_URL: !Ref MainQueue
          DETECTOR_ISOLATION_FOREST: shadow
      Events:
        QueueEvent:
          Type: SQS
          Properties:
            Queue: !GetAtt MainQueue.Arn
            BatchSize: 10
            FunctionResponseTypes: [ReportBatchItemFailures]

  IncidentApiFn:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: ../
      Handler: services.api.incidents_handler.handler
      Policies:
        - DynamoDBReadPolicy: { TableName: !Ref IncidentTable }
        - DynamoDBCrudPolicy: { TableName: !Ref IncidentTable }
        - SSMParameterReadPolicy: { ParameterName: !Sub "lad/${Env}/admin-credential-hash" }
      Events:
        List:   { Type: HttpApi, Properties: { ApiId: !Ref HttpApi, Method: GET,  Path: /api/v1/incidents } }
        Get:    { Type: HttpApi, Properties: { ApiId: !Ref HttpApi, Method: GET,  Path: /api/v1/incidents/{incident_id} } }
        Ack:    { Type: HttpApi, Properties: { ApiId: !Ref HttpApi, Method: POST, Path: /api/v1/incidents/{incident_id}/acknowledge } }
        Resolve:{ Type: HttpApi, Properties: { ApiId: !Ref HttpApi, Method: POST, Path: /api/v1/incidents/{incident_id}/resolve } }

  MainQueue:
    Type: AWS::SQS::Queue
    Properties:
      VisibilityTimeout: 120                        # ≈ 2 × WorkerFn.Timeout
      MessageRetentionPeriod: 345600                # 4 days
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt DeadLetterQueue.Arn
        maxReceiveCount: 5

  DeadLetterQueue:
    Type: AWS::SQS::Queue
    Properties:
      MessageRetentionPeriod: 1209600               # 14 days for inspection/replay

  IncidentTable:
    Type: AWS::DynamoDB::Table
    Properties:
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - { AttributeName: pk,     AttributeType: S }
        - { AttributeName: sk,     AttributeType: S }
        - { AttributeName: gsi1pk, AttributeType: S }
        - { AttributeName: gsi1sk, AttributeType: S }
      KeySchema:
        - { AttributeName: pk, KeyType: HASH }
        - { AttributeName: sk, KeyType: RANGE }
      GlobalSecondaryIndexes:
        - IndexName: gsi1
          KeySchema:
            - { AttributeName: gsi1pk, KeyType: HASH }
            - { AttributeName: gsi1sk, KeyType: RANGE }
          Projection: { ProjectionType: ALL }
      TimeToLiveSpecification: { AttributeName: ttl, Enabled: true }

Outputs:
  ApiUrl:      { Value: !Sub "https://${HttpApi}.execute-api.${AWS::Region}.amazonaws.com" }
  MainQueueUrl:{ Value: !Ref MainQueue }
  DlqUrl:      { Value: !Ref DeadLetterQueue }
  TableName:   { Value: !Ref IncidentTable }
```

**Walkthrough of the coherence:**
- `WorkerFn.Timeout: 60` and `MainQueue.VisibilityTimeout: 120` satisfy **visibility ≥ timeout × 2**. Change one, change the other.
- `FunctionResponseTypes: [ReportBatchItemFailures]` enables partial-batch retry — matching the worker returning `batchItemFailures`.
- `DETECTOR_ISOLATION_FOREST: shadow` runs the experiment without user-visible incidents (Module 5).
- Policies are **named, scoped policies** (`SQSSendMessagePolicy`, `DynamoDBCrudPolicy`) — no wildcard admins.
- CORS origin is a parameter, not `*`.

### 2.2 Ingestion Lambda: validate, dedupe, enqueue, receipt

```python
# services/api/ingest.py
import json, os, boto3, hashlib, hmac
from datetime import datetime, timezone
from lad.contracts import EventIn, to_core_event, validate_batch_limits

_sqs = None
def sqs():
    global _sqs
    if _sqs is None:
        _sqs = boto3.client("sqs")            # constructed lazily (not at import)
    return _sqs

def authorize(event) -> str:
    auth = event.get("headers", {}).get("authorization") or \
           event.get("headers", {}).get("Authorization")
    if not auth or not auth.startswith("Bearer "):
        raise ApiError("unauthenticated", 401)
    presented = auth.split(" ", 1)[1]
    expected_hash = os.environ["COLLECTOR_TOKEN_HASH"]         # sha256 hex
    presented_hash = hashlib.sha256(presented.encode()).hexdigest()
    if not hmac.compare_digest(presented_hash, expected_hash):  # constant-time
        raise ApiError("unauthenticated", 401)
    return "collector"

def handler(event, context):
    try:
        authorize(event)
        body = json.loads(event["body"] or "{}")
        events = body.get("events", [])
        validate_batch_limits(events)                           # ≤100 / ≤256KB
    except ApiError as e:
        return error_response(e)
    except (json.JSONDecodeError, KeyError):
        return error_response(ApiError("bad_request", 400))

    results, accepted = [], []
    for i, item in enumerate(events):
        try:
            ev = EventIn.model_validate(item)
            accepted.append(to_core_event(ev))
            results.append({"index": i, "event_id": ev.event_id, "status": "accepted"})
        except Exception as ve:
            results.append({"index": i, "event_id": None, "status": "rejected",
                            "reason": "validation_failed", "detail": first_error(ve)})

    # enqueue in SQS-compatible chunks (256 KB SQS limit)
    sent = 0
    for chunk in chunk_for_sqs(accepted, max_bytes=250_000):
        r = sqs().send_message_batch(QueueUrl=os.environ["MAIN_QUEUE_URL"],
                                     Entries=[{"Id": str(n), "MessageBody": e.to_json()}
                                              for n, e in enumerate(chunk)])
        sent += len(r.get("Successful", []))

    return {
        "statusCode": 202,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({
            "receipt_id": new_receipt_id(),
            "accepted": sent,
            "rejected": len(results) - sum(1 for r in results if r["status"] == "accepted"),
            "results": results,
            "note": "Accepted events are queued; detection may not have completed.",
        }),
    }
```

**Walkthrough:**
- **Lazy client** construction keeps cold-start import light and keeps the handler testable (mock `sqs()`).
- **Constant-time** token comparison (`hmac.compare_digest`) avoids timing leaks.
- **Per-event validation** enables partial acceptance (Module 2).
- **SQS chunking**: a 100-event batch can exceed 256 KB; `send_message_batch` has its own limits (≤10 entries per call, ≤256 KB total), so we chunk by count *and* bytes.
- `accepted` is derived from **actual enqueue results**, not the validated count — the receipt tells the truth.

### 2.3 Worker Lambda: idempotent, durability-before-ack

```python
# services/worker/handler.py
import json, os, boto3
from lad.pipeline import build_pipeline
from lad.adapters.aws.dynamo import DynamoStore
from lad.adapters.aws.sqs import SqsQueue

_pipeline = None
def pipeline():
    global _pipeline
    if _pipeline is None:
        _pipeline = build_pipeline(
            store=DynamoStore(os.environ["INCIDENT_TABLE"]),
            queue=SqsQueue(os.environ["MAIN_QUEUE_URL"]),
            detector_if=os.environ.get("DETECTOR_ISOLATION_FOREST", "off"))
    return _pipeline

def handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            pipeline().process_one(body)         # dedupe → features → detect → correlate → persist
            # ack happens implicitly when we DON'T report failure and the batch is fully processed
        except RetryableError:
            failures.append({"itemIdentifier": record["messageId"]})
        except FatalError:
            failures.append({"itemIdentifier": record["messageId"]})   # let SQS redrive → DLQ
        except Exception:
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
```

**Walkthrough:** the pipeline persists baseline/incident state **before** returning success (durability-before-ack). Any unhandled exception is reported as a batch item failure so SQS retries and eventually DLQs — **no silent loss**. Idempotency lives in the pipeline (dedupe by `event_id`, conditional upserts).

### 2.4 DynamoDB idempotent dedup + incident upsert

```python
# src/lad/adapters/aws/dynamo.py
import boto3, os
from botocore.exceptions import ClientError

class DynamoStore:
    def __init__(self, table_name: str):
        self.table = boto3.resource("dynamodb").Table(table_name)

    def claim_event(self, event_id: str, ttl_epoch: int) -> bool:
        """Returns True if we are the first to claim this event ID (idempotency)."""
        try:
            self.table.put_item(
                Item={"pk": f"DEDUP#{event_id}", "sk": "META", "ttl": ttl_epoch},
                ConditionExpression="attribute_not_exists(pk)")
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise

    def upsert_incident(self, incident: dict) -> None:
        incident["pk"] = "INCIDENT"
        incident["sk"] = f"INCIDENT#{incident['incident_id']}"
        incident["gsi1pk"] = f"STATUS#{incident['status']}"
        incident["gsi1sk"] = f"{incident['created_at']}#{incident['incident_id']}"
        incident.setdefault("ttl", created_plus_days(incident["created_at"], 30))
        self.table.put_item(Item=incident)

    def page_incidents(self, *, status=None, limit=25, cursor=None):
        from boto3.dynamodb.conditions import Key
        kwargs = {"Limit": limit}
        if status:
            kwargs["IndexName"] = "gsi1"
            kwargs["KeyConditionExpression"] = Key("gsi1pk").eq(f"STATUS#{status}")
        else:
            kwargs["KeyConditionExpression"] = Key("pk").eq("INCIDENT")
        if cursor:
            kwargs["ExclusiveStartKey"] = decode_cursor(cursor)
        resp = self.table.query(**kwargs)
        return {"items": resp["Items"],
                "next_cursor": encode_cursor(resp.get("LastEvaluatedKey"))}
```

**Walkthrough:**
- `claim_event` uses a **conditional put** for idempotency: the first caller wins; duplicates are a no-op. This is the durable dedup that makes at-least-once safe.
- `upsert_incident` writes the GSI keys so listing-by-status (pattern A2) is a single Query, not a Scan.
- `page_incidents` uses **cursor pagination** via `LastEvaluatedKey` — the API contract's opaque cursor.
- TTL is set to 30 days for incidents (best-effort deletion, per the async-TTL caveat).

### 2.5 Deploy, verify, and tear down (honest commands)

```bash
# 1) validate + build
sam validate --lint
sam build

# 2) deploy (guided first time)
sam deploy --guided \
  --stack-name lad-dev \
  --parameter-overrides Env=dev DashboardOrigin=https://dashboard.example \
  --capabilities CAPABILITY_IAM --resolve-s3

# 3) VERIFY — never assume
API_URL=$(aws cloudformation describe-stacks --stack-name lad-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
curl -fsS "$API_URL/api/v1/health"

# 4) one real event end-to-end
curl -fsS -X POST "$API_URL/api/v1/events/batch" \
  -H "Authorization: Bearer $COLLECTOR_TOKEN" -H "Content-Type: application/json" \
  -d '{"events":[{"schema_version":"1.0","event_id":"evt_demo_1",...}]}'

# 5) confirm the incident appears (admin credential)
curl -fsS "$API_URL/api/v1/incidents?status=open" -H "Cookie: lad_session=$ADMIN_SESSION"

# 6) cost/usage review
aws ce get-cost-and-usage --time-period Start=2026-10-01,End=2026-10-18 \
  --granularity DAILY --metrics BlendedCost

# 7) tear down when done
sam delete --stack-name lad-dev --no-prompts
```

**Walkthrough:** every claim about the AWS path is backed by a command whose output you can see. `sam delete` removes the stack; **verify no orphaned resources remain** (S3 objects from `--resolve-s3`, CloudWatch log groups, DLQ messages).

---

## 3. Common Pitfalls & Debugging

### 3.1 Visibility timeout < function timeout

Messages reappear mid-processing → redeliveries. **Fix:** `VisibilityTimeout ≥ FunctionTimeout × 2`; keep them in one place (parameters or a comment in the template) so they move together.

### 3.2 State in Lambda memory

A baseline cached in module scope resets unpredictably between containers, producing inconsistent scores. **Fix:** durable store (DynamoDB/local); memory only as a cache with a correctness fallback.

### 3.3 Import weight → cold starts

`import sklearn` at module top slows ingestion too. **Fix:** lazy imports; gate the detector; measure cold-start duration.

### 3.4 `502` from API Gateway

Usually a malformed response (wrong `statusCode`/`body` shape) or a crash. **Fix:** verify the response contract; check CloudWatch logs; test Mangum vs. plain handler.

### 3.5 Whole-batch retries on one bad message

Without `ReportBatchItemFailures`, one poison message retries the whole batch. **Fix:** enable partial batch failures and return `batchItemFailures`.

### 3.6 Silent message loss

A `try/except: log; return` that neither retries nor DLQs drops events. **Fix:** every exception path retries, nacks, or DLQs — and increments a metric.

### 3.7 DynamoDB hot partitions / scans

A `Scan` in the incident list, or a single PK taking all writes, throttles at scale. **Fix:** Query by designed keys; note scaling caveats for the single-`pk=INCIDENT` listing.

### 3.8 TTL is not immediate

Assuming TTL deletes instantly misleads retention tests. **Fix:** document async TTL; add a sweeper if strict cleanup is required; test that behavior within the lag window.

### 3.9 IAM surprises

A policy that looks right but omits the GSI ARN (`table/index/*`) breaks queries. Omit `sqs:GetQueueAttributes` and the poller misbehaves. **Fix:** test each function's real calls; add only the needed actions; use the exact resource ARNs.

### 3.10 Secrets in templates/logs

Committing a token in `template.yaml`, or logging it in a handler, leaks it. **Fix:** `NoEcho` params, SSM/Secrets Manager, structured logs with no payloads, secret scanning in CI.

### 3.11 CORS errors

Dashboard origin not in `CorsConfiguration`. **Fix:** parameterize the origin; verify local and AWS modes.

### 3.12 `ROLLBACK_COMPLETE` stack

Attempting to update a stack in this state fails. **Fix:** delete and redeploy.

### 3.13 Debugging toolkit

```bash
# function logs (tail)
sam logs -n WorkerFn --stack-name lad-dev --tail

# invoke locally with a synthetic event
sam local invoke WorkerFn -e events/sqs_sample.json

# run the API locally
sam local start-api

# inspect queue depth and DLQ
aws sqs get-queue-attributes --queue-url "$MAIN_QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 1

# inspect a table item
aws dynamodb get-item --table-name lad-dev-incidents \
  --key '{"pk":{"S":"INCIDENT"},"sk":{"S":"INCIDENT#inc_01J..."}}'
```

- **X-Ray traces** show where latency lives across the hop chain.
- **`sam local`** lets you develop handlers without deploying — a huge time-saver.
- **CloudWatch Logs Insights** turns structured logs into queries (`fields @timestamp, accepted | stats sum(accepted)`).

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"The DynamoDB Book" — Alex DeBrie.** The definitive guide to access-pattern-first modeling, single-table design, GSIs, and TTL. Read the *single-table design* and *indexes* chapters before touching `template.yaml`.
- **"Amazon Web Services in Action" (3rd ed.) — Wittig & Wittig.** Ch. on *Lambda*, *SQS*, *DynamoDB*, and *IAM* — excellent conceptual coverage.
- **"AWS Lambda in Action" — Danilo Poccia.** Event-driven patterns and the execution model (§1.2).
- **"Serverless Architectures on AWS" — Sbarski & Kroonenburg.** API GW + Lambda patterns and cold-start discussion.
- **"AWS Certified Solutions Architect Study Guide" — Piper & Clinton.** A structured tour of IAM, VPC (context), and service limits.
- **"Cloud Native Patterns" — Cornelia Davis.** Event-driven and idempotency patterns generally.
- **"Designing Data-Intensive Applications" — Kleppmann.** Ch. 11 *Stream Processing* — at-least-once vs. exactly-once, and why idempotency is the practical answer.

### 4.2 Papers & docs

- **AWS docs: "Lambda execution environment" and "Understanding Lambda scaling behavior."** The authoritative statements on cold starts and concurrency.
- **AWS docs: "Amazon SQS visibility timeout" and "Using Lambda with Amazon SQS."** Read the partial-batch-failure section carefully.
- **AWS docs: "Best practices for DynamoDB"** and the **DynamoDB Developer Guide** sections on partition keys and TTL.
- **AWS docs: "IAM best practices" and "Grant least privilege."**
- **AWS Well-Architected Framework — Security, Reliability, Cost Optimization pillars.** Frame every major design decision here.
- **"The Amazon Builders' Library"** — articles on timeouts, retries, and backoff (including the famous "Exponential Backoff and Jitter").

### 4.3 Videos, talks, courses

- **AWS re:Invent** — sessions on *DynamoDB data modeling* (Rick Houlihan's talks are legendary), *Lambda performance*, and *event-driven architectures*. Search "re:Invent DynamoDB single table".
- **Yan Cui (theburningmonk)** — YouTube/blog on serverless production patterns, cold starts, and Lambda observability. One of the best independent sources.
- **Alex DeBrie — DynamoDB talks and the "DynamoDB Guide" website.**
- **"Serverless Land" (AWS)** — patterns and sample templates.
- **A Cloud Guru / Adrian Cantrill — AWS courses** for the certification-level foundation.
- **Marc Brooker's blog** (AWS) — distributed systems and reliability, directly applicable to queue semantics.

### 4.4 Exercises to internalize this module

1. Deploy a minimal stack (queue + table + health fn) and verify `CREATE_COMPLETE` with `describe-stacks`.
2. Implement the ingestion handler with constant-time auth and truthful receipts; test partial acceptance.
3. Implement the worker with `ReportBatchItemFailures`; inject a poison message and prove the rest are processed and the poison reaches the DLQ.
4. Model incidents in DynamoDB and implement cursor pagination; test the GSI listing.
5. Implement `claim_event` idempotency; prove a duplicate submission creates no duplicate incident.
6. Set up CORS, deploy the dashboard against the API, and verify connectivity.
7. Run the load targets (5 ev/s × 10 min; 25 ev/s × 60 s); record loss, duplication, latency, and cost.
8. Perform a full teardown and verify no orphaned resources remain.

---

*Next module:* **[Module 7 — The React & TypeScript Dashboard](learning_module_7.md)** — rendering truthfully, safely, and accessibly.
