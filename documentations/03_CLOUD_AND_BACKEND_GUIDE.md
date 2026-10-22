# ☁️ Cloud & Backend Guide — AWS, SAM, Ingestion, Queueing, Persistence

> **Derived from** `docs/CLOUD_SPECIFICATION.md`. Provide a **low-cost, secure** ingestion and incident API, asynchronous processing, durable incident storage, and repeatable AWS deployment using SAM.

⚠️ **Standing disclaimer:** Do **not** assume current runtime compatibility, pricing, quotas, or permissions. Verify all of these in the target AWS account. **Never state that deployment succeeded until commands and results verify it.**

**Read with:** `01_ARCHITECTURE_GUIDE.md` (component boundaries), `05_API_AND_DATA_CONTRACTS_GUIDE.md` (exact shapes).

---

## 1. High-Level Overview & Goals

### 1.1 Goals

| # | Goal |
|---|---|
| C1 | Secure ingestion API with collector authentication and strict validation |
| C2 | Buffered, asynchronous processing via SQS with a dead-letter queue |
| C3 | Durable incident/idempotency/baseline state in DynamoDB, designed around access patterns |
| C4 | Optional S3 for **selected redacted evidence only** |
| C5 | Reproducible deployment via **AWS SAM**, parameterized per environment |
| C6 | Strict **least-privilege** IAM, separate collector vs. admin identities, no secrets in Git or frontend |
| C7 | Local parity: same contracts and detection package, no AWS credentials needed |
| C8 | Measured, inspected cost with documented cleanup |

### 1.2 Proposed services (verify availability and pricing first)

| Service | Role |
|---|---|
| **API Gateway HTTP API** | Public HTTPS front door (cheaper/simpler than REST API for this shape) |
| **Lambda** | Ingestion/API handler; detection worker |
| **SQS** (+ **DLQ**) | Buffered processing; redrive policy |
| **DynamoDB** | Incidents, idempotency/processing state, compact baseline/window state |
| **S3** *(optional)* | Selected redacted evidence |
| **Static hosting** *(optional)* | React dashboard |
| **SAM** | Infrastructure as code |

**Explicitly avoided by default** (unless justified): always-on **EC2**, **Kinesis**, managed search. They add cost and operational surface that this MVP does not need.

### 1.3 Packaging decision — decide early

> "Evaluate FastAPI packaging (e.g. Mangum) early. If FastAPI packaging adds disproportionate complexity, document and implement a **simpler handler design while preserving the API contract**."

Record an ADR after a half-day spike:

| Option | Pros | Cons |
|---|---|---|
| **FastAPI + Mangum on Lambda** | Same app locally and in Lambda; middleware, validation, OpenAPI generation | Cold-start/import weight; binary size; API Gateway ↔ ASGI quirks |
| **Plain handler + hand-written routes** | Lean, fast cold start, fewer moving parts | Duplicate route/validation logic; must still match `openapi.yaml` exactly |

Either is acceptable **as long as the wire contract is identical**. The contract tests (`05_API_...`) are what keep the two lanes honest.

---

## 2. System / Component Architecture & Design Patterns

### 2.1 AWS data path

```
Collector (HTTPS, collector-only creds)
      │
      ▼
API Gateway HTTP API ──► Ingestion Lambda ──► SQS main queue ──► Worker Lambda
      │                        │                                     │
      │                        │ (validate, redact,                  │ (features, detect,
      │                        │  size limits, receipt)              │  correlate, incidents)
      │                        ▼                                     ▼
      │                   (reject w/ reasons)                  DynamoDB tables
      │                                                             │
      └── (admin JWT) ──► Incident API (same or separate Lambda) ◄──┘
                                │
                                └──► optional S3 (redacted evidence refs)
```

**Two Lambdas (or one with two route groups) — decide via ADR.** Recommendation: **separate ingestion and incident/read paths** so their IAM roles and scaling profiles differ (write-heavy vs. read-heavy, different auth sources).

### 2.2 Patterns and why

| Pattern | Where | Notes |
|---|---|---|
| **Buffered decoupling (Queue)** | SQS between API and worker | API can be up while worker is degraded; no data loss on worker crash |
| **Dead-letter queue** | SQS DLQ + redrive policy | Poison messages quarantined, inspected, replayed deliberately |
| **Idempotent consumer** | Worker | SQS is **at-least-once**; duplicates must not create duplicate incidents |
| **Receipt pattern** | Ingestion response | Explicit accepted/rejected counts; "accepted ≠ analyzed" |
| **Access-pattern-first modeling** | DynamoDB | Keys/indexes derived from queries, not from the JSON shape |
| **Least-privilege IAM** | Every role | No wildcard permissions where practical |
| **Configuration outside code** | env vars / SSM params / SAM params | Environment-specific; secrets never in Git |
| **Ports & adapters** | worker ↔ SQS/DynamoDB | Same detection package as local mode |

### 2.3 Ingestion API behavior

#### `POST /api/v1/events/batch`

The ingestion contract, in order of operations:

1. **Authenticate collector identity** (collector-only credential; see §2.5).
2. **Enforce request and event size limits** (batch ≤ 100 events or ≤ 256 KB, whichever first; reject over-limit *before* parse where possible).
3. **Validate** schema, version, timestamps (timezone-aware), required fields.
4. **Redact** where appropriate; **reject unsafe/invalid data** per documented policy.
5. **Preserve stable event IDs**; handle duplicate IDs **idempotently**.
6. **Queue** accepted events.
7. **Return a receipt** with explicit `accepted` and `rejected` counts and per-event rejection reasons.
8. Document whether **partial batch acceptance** is allowed (recommendation: **yes**, with per-event outcomes — it makes collector retry logic simpler and avoids one bad event poisoning a whole batch).
9. Make clear that **accepted-to-queue does not mean analyzed.**

```jsonc
// 202 response sketch (exact shape lives in openapi.yaml)
{
  "receipt_id": "rcpt_01J...",
  "accepted": 97,
  "rejected": 3,
  "results": [
    { "index": 0,  "event_id": "evt_01J...", "status": "accepted" },
    { "index": 12, "event_id": null,          "status": "rejected",
      "reason": "invalid_timestamp", "detail": "event_ts must be timezone-aware" }
  ],
  "note": "Accepted events are queued for asynchronous processing; detection may not have completed."
}
```

#### `GET /api/v1/health`

Return appropriate health status **without leaking secrets or internal configuration**. Good shape:

```jsonc
{ "status": "ok", "mode": "aws", "version": "0.3.0" }   // no ARNs, no bucket names, no env dumps
```

Health should check what it genuinely depends on (e.g., a lightweight DynamoDB `DescribeTable` or a conditional read) — but **do not** turn health into a costly probe on every call; consider caching for a few seconds.

#### Incident endpoints (admin only)

- `GET /api/v1/incidents` — pagination + filters (status, severity, time range)
- `GET /api/v1/incidents/{incident_id}`
- `POST /api/v1/incidents/{incident_id}/acknowledge`
- `POST /api/v1/incidents/{incident_id}/resolve`

Only administrators can read incidents or alter lifecycle state. **Collectors may submit events only.** Authorization is enforced **server-side** (see §2.5 and §6).

### 2.4 Queue and worker

**Configuration coherence is the subtle part.** These four numbers must be chosen together:

```
Lambda timeout (T)
Visibility timeout (V)  ≥  T × maxReceiveCount      (commonly ×2 for safety)
Max event batch size (B)
Worker processing time per message (P)  ⇒  T ≥ B × P + overhead
Redrive: maxReceiveCount (M) → after M failures → DLQ
```

If `V < T`, a slow worker's messages become visible again **while it is still running** — the classic double-processing bug. Our worker is idempotent, which *mitigates* but does not *excuse* a misconfigured visibility timeout.

**Required behaviors:**
- SQS retries with **bounded** retry behavior and a **DLQ**.
- Assume **at-least-once** delivery; the worker is **idempotent** (dedupe by stable event ID, idempotent incident upserts).
- **Durable** deduplication and incident/baseline state (DynamoDB — never Lambda memory).
- Handle **partial processing failures deliberately**: if a batch of 10 succeeds and 2 fail, do **not** ack the whole batch silently. Options (pick, document, test):
  - process individually and ack only successes (preferred with a well-formed handler), or
  - fail the batch and rely on retry + idempotency (simpler but noisier).
- **DLQ inspection/replay guidance** (§5.4).
- **Never lose a message silently after logging an exception.** An exception path must either retry, nack, or move to DLQ — and increment a metric.
- **Operational metrics + structured logs, no secrets.**

```python
# services/worker/handler.py (illustrative)
def handle_sqs(event, ctx, *, queue, store, clock, pipeline):
    failures = 0
    for record in event["Records"]:
        try:
            batch = decode(record["body"])
            results = pipeline.process(batch, clock=clock)   # steps 1–9
            store.record_processed_ids([r.event_id for r in results.ok])
            queue.ack(record)                                # ack only after durable write
        except RetryableError as e:
            failures += 1
            log.warning("retryable_failure", extra={"error_type": type(e).__name__})
            queue.nack(record, retryable=True)               # let SQS retry / eventually DLQ
        except FatalError as e:
            failures += 1
            log.error("fatal_failure", extra={"error_type": type(e).__name__})
            queue.nack(record, retryable=False)              # fast-path to DLQ, no infinite loop
    if failures:
        raise PartialFailure(f"{failures} messages failed")   # metrics + visibility; no silent loss
```

### 2.5 Authentication and secrets

**Two identities, strictly separated:**

| | Collector | Administrator |
|---|---|---|
| Can | `POST /api/v1/events/batch` | read incidents, acknowledge/resolve |
| Cannot | read/list/alter incidents | (per ADR; admin should not need event submission) |
| Credential | revocable per-host token or IAM-signed request | user login (see below) |
| Storage | provisioned/rotated out-of-band | secrets manager / SSM |

**Rules:**
- **Least-privilege IAM**; **revocable** collector credentials (a lost host must be cut off in one step).
- **Do not embed AWS access keys** in collectors or frontend assets. A collector holds its own submission credential — not an AWS access key.
- **Secrets in an appropriate config/secrets mechanism** (SSM Parameter Store/Secrets Manager), **not Git**.
- **HTTPS everywhere** for remote ingestion.
- **Verify CORS and origin configuration** for both local and AWS dashboard modes. Tighten origins to the actual dashboard origin(s); never `*` with credentials.
- **Cognito is optional** — only if it is appropriate for the team and available. **Do not block core implementation on it** without an approved decision. A pragmatic MVP alternative: an admin session established by a single admin credential (hashed secret in SSM), short-lived signed session cookie, all incident routes behind a server-side check. Record the choice in an ADR.

### 2.6 Local parity (non-negotiable)

Local mode must run **without AWS credentials**. Implement queue/storage interfaces with local adapters, keeping the **same schemas and detection/correlation package**. Provide Docker Compose (or equivalent) and a **clean reset command** for demo data. See `04_DEVOPS_...` §5 for the local lane details; the cloud guide's job is to not break the port boundaries that make it possible.

---

## 3. Environment Setup & Prerequisites (AWS lane)

> None of this is required for local mode. Keep it isolated.

### 3.1 Prerequisites

- [ ] AWS account with permissions for: API Gateway, Lambda, SQS, DynamoDB, IAM (roles/policies), CloudFormation, S3 (if used), CloudWatch Logs, (optional) SSM/Secrets Manager.
- [ ] **AWS CLI** configured (`aws sts get-caller-identity` succeeds and shows the *expected* account/role).
- [ ] **SAM CLI** installed.
- [ ] Verified **region** availability of all services.
- [ ] Reviewed **pricing** for the planned workload; **budget/usage alert** configured where available (understand: alerts **do not necessarily stop spending**).
- [ ] Reviewed **quotas** (Lambda concurrency, SQS throughput, DynamoDB RCU/WCU, API Gateway request limits) against the load targets (5 events/s sustained; 25 events/s burst).

### 3.2 SAM project layout

```
infra/
├── template.yaml              # SAM template
├── parameters/
│   ├── dev.json
│   └── demo.json
├── policies/                  # reusable IAM policy documents
└── scripts/
    ├── deploy.sh
    └── teardown.sh
```

### 3.3 Template skeleton (illustrative — verify property names against current SAM docs)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Automated Log Anomaly Detector - core stack

Parameters:
  Env:
    Type: String
    AllowedValues: [dev, demo]
  CollectorTokenParam:
    Type: String
    NoEcho: true
  AdminCredentialParam:
    Type: String
    NoEcho: true

Globals:
  Function:
    Runtime: python3.x          # pin after compatibility verification
    Timeout: 30
    MemorySize: 512
    Tracing: Active
    Environment:
      Variables:
        LAD_MODE: aws
        LAD_ENV: !Ref Env
        INCIDENT_TABLE: !Ref IncidentTable
        MAIN_QUEUE_URL: !Ref MainQueue

Resources:
  HttpApi:
    Type: AWS::Serverless::HttpApi
    Properties:
      CorsConfiguration:
        AllowOrigins: !Ref DashboardOrigin   # never '*' with credentials
        AllowMethods: [GET, POST]
        AllowHeaders: [Authorization, Content-Type]

  IngestFn:
    Type: AWS::Serverless::Function
    Properties:
      Handler: services.api.ingest.handler
      Policies:
        - SQSSendMessagePolicy: { QueueName: !GetAtt MainQueue.QueueName }
      Events:
        Batch:
          Type: HttpApi
          Properties: { ApiId: !Ref HttpApi, Method: POST, Path: /api/v1/events/batch }

  WorkerFn:
    Type: AWS::Serverless::Function
    Properties:
      Handler: services.worker.handler
      Policies:
        - DynamoDBCrudPolicy: { TableName: !Ref IncidentTable }
        - SQSPollerPolicy:   { QueueName: !GetAtt MainQueue.QueueName }
      Events:
        QueueEvent:
          Type: SQS
          Properties:
            Queue: !GetAtt MainQueue.Arn
            BatchSize: 10
            FunctionResponseTypes: [ReportBatchItemFailures]   # enables partial-batch failure

  MainQueue:
    Type: AWS::SQS::Queue
    Properties:
      VisibilityTimeout: 120        # ≥ WorkerFn.Timeout × 2
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt DeadLetterQueue.Arn
        maxReceiveCount: 5

  DeadLetterQueue:
    Type: AWS::SQS::Queue
    Properties:
      MessageRetentionPeriod: 1209600   # 14 days, room for inspection/replay

  IncidentTable:
    Type: AWS::DynamoDB::Table
    Properties:
      BillingMode: PAY_PER_REQUEST      # right-size for a demo workload; measure
      AttributeDefinitions:
        - { AttributeName: pk, AttributeType: S }
        - { AttributeName: sk, AttributeType: S }
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
  ApiUrl:      { Value: !Sub 'https://${HttpApi}.execute-api.${AWS::Region}.amazonaws.com' }
  MainQueueUrl:{ Value: !Ref MainQueue }
  DlqUrl:      { Value: !Ref DeadLetterQueue }
  TableName:   { Value: !Ref IncidentTable }
```

---

## 4. Step-by-Step Implementation Guide (AWS lane)

> **Precondition:** the local vertical slice (Gate 2) works. Do not start AWS work before that, except to secure account access early (risk mitigation: "AWS account delay").

### Step 4.1 — Secure account access + budget alert

1. Confirm `aws sts get-caller-identity` shows the right account.
2. Confirm service quotas (§3.1).
3. Create a **budget/usage alert**. Document that it notifies — it does not necessarily cap spend.
4. Record region choice in an ADR.

### Step 4.2 — SAM skeleton + validation

1. Write `template.yaml` (§3.3 shape) with **least-privilege** policies only.
2. `sam validate --lint`
3. `sam build`
4. Deploy a **minimal stack** (queue + table + health function) to prove the pipeline of deployment itself works before wiring real logic.

```bash
sam validate --lint
sam build
sam deploy --guided \
  --parameter-overrides Env=dev \
  --stack-name lad-dev \
  --resolve-s3
```

**Gate:** `sam deploy` completes and `aws cloudformation describe-stacks --stack-name lad-dev` shows `CREATE_COMPLETE`. That is the only claim allowed at this point — nothing more.

### Step 4.3 — Ingestion Lambda behind API Gateway

1. Implement `POST /api/v1/events/batch` per §2.3 (or reuse the FastAPI app via Mangum if that ADR won).
2. Wire **collector authentication** (see §4.7).
3. Enforce size limits **before** JSON parse where feasible (reject oversized bodies cheaply).
4. Validate against `event.schema.json`; build the receipt with per-event outcomes.
5. Send accepted events to SQS (batch send; respect the 256 KB SQS message limit — a 100-event batch that exceeds it must be chunked).
6. Emit metrics: `ingest_accepted`, `ingest_rejected{reason}`, `ingest_latency_ms`.

**Tests:**
- auth: no/invalid credential → 401; valid collector → 202 with receipt.
- validation: malformed event in a valid batch → partial accept with per-index reasons.
- size: >256 KB batch → documented rejection (or chunking), never a 500.
- **duplicate stable IDs → idempotent** (same receipt semantics; no downstream duplicate incidents).

### Step 4.4 — Worker Lambda + queue wiring

1. Configure `BatchSize`, `FunctionResponseTypes: [ReportBatchItemFailures]`, visibility timeout ≥ 2× function timeout, `maxReceiveCount` → DLQ.
2. Implement the handler per §2.4 (ack **after** durable writes).
3. Load baseline state from DynamoDB at start of invocation; **persist updated baselines before ack** (durability rule).
4. Metrics: `worker_processed`, `worker_failures{type}`, `batch_duration_ms`, `dlq_depth` (or use the SQS queue-depth metric).

**Tests (integration, against real SQS+DynamoDB or a faithful emulator):**
- duplicate delivery → single incident.
- forced worker crash mid-batch → messages retry; no loss; no duplicate incidents.
- poison message (raises `FatalError`) → reaches DLQ after `maxReceiveCount`; everything else processed.

### Step 4.5 — DynamoDB modeling (access patterns first)

Enumerate the access patterns **before** choosing keys:

| # | Access pattern | Query |
|---|---|---|
| A1 | List incidents, newest first | `pk = INCIDENT`, `sk begins_with INCIDENT#`, scan forward/backward |
| A2 | List incidents by status | GSI: `gsi1pk = STATUS#open`, `gsi1sk = <created_at>#<incident_id>` |
| A3 | List incidents by severity | GSI or facet in `sk` (choose one; document) |
| A4 | Get incident by ID | `pk = INCIDENT`, `sk = INCIDENT#<id>` |
| A5 | Check if event ID already processed | `pk = DEDUP#<event_id>`, `sk = META`, with TTL |
| A6 | Read/update baseline for (entity, feature) | `pk = BASELINE#<entity>#<feature>`, `sk = STATE` |
| A7 | Acknowledge/resolve (update + audit append) | update incident item + append audit entry to `sk = AUDIT#<ts>` |

**Single-table design** (recommended for this size) with entity-type prefixes in `pk`/`sk`, one GSI for status/severity listing. Alternatively, three small tables — simpler mental model, more resources; decide via ADR and measure.

**TTL:** enable `ttl` for dedup records and (per policy) old evidence. ⚠️ **TTL deletion is asynchronous** — it can lag by hours and is **not** a hard delete guarantee. If strict cleanup is required, implement a policy that accounts for this (e.g., a periodic sweeper) **and test it**.

**On-demand billing** (`PAY_PER_REQUEST`) is appropriate for a demo-scale workload — but still **measure actual usage**; on-demand ≠ free.

### Step 4.6 — Incident API (admin routes)

1. Implement the four incident endpoints per `openapi.yaml` (pagination, filters).
2. Enforce **admin-only** authorization **server-side** on every route.
3. Acknowledge/resolve write an **audit entry** (actor, action, timestamp) — never silent mutation.
4. Metrics: `incident_read`, `incident_lifecycle{action}`, `authz_denied`.

### Step 4.7 — Auth implementation options (pick via ADR)

| Option | When to use | Notes |
|---|---|---|
| **A. Admin credential + signed session cookie** | Fastest MVP; single admin | Secret in SSM/Secrets Manager; short-lived signed cookie (e.g., itsdangerous/HMAC); all incident routes check server-side |
| **B. Cognito** | If available and the team is comfortable | Adds user management; **do not block** the MVP on it |
| **C. IAM-authenticated HTTP API** | If admin is themselves an AWS user | Convenient but couples dashboard access to AWS sign-in |

Collector auth options:
- **Static bearer token per collector**, stored hashed, compared in constant time; simplest.
- **AWS SigV4** if collectors are AWS-workload-adjacent (usually overkill for OS agents).

**Recommendation:** A for admin, static hashed token for collectors, both behind a small middleware so the check is impossible to forget. Rotation: document how to issue/revoke a collector token in one step.

### Step 4.8 — Optional S3 for redacted evidence

Only if the team can **justify the requirement**. If yes:
- **Least-privilege** bucket policy; block public access; enforce encryption.
- **Retention lifecycle** rule aligned to the 7-day evidence default.
- Worker writes **redacted** evidence only; the incident stores the object pointer.
- Never store complete raw logs by default.

If you cannot articulate the requirement, **skip S3** — fewer resources, less cost, less risk.

### Step 4.9 — Static frontend hosting (optional)

- S3 + CloudFront (or S3 website endpoint) serving the built dashboard.
- **API base URL injected at build time via environment** — never bake secrets into the bundle (there should be none).
- CORS on the API must allow the deployed origin.

### Step 4.10 — Deploy the vertical slice (Gate 3)

```bash
sam build && sam deploy --parameter-overrides Env=dev --stack-name lad-dev
API_URL=$(aws cloudformation describe-stacks --stack-name lad-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)

# verify — do not assume
curl -fsS "$API_URL/api/v1/health"

# then: one real anomaly through the deployed path (collector → API → SQS → worker → DynamoDB)
# and confirm it appears via GET /api/v1/incidents with an admin credential
```

**Gate 3 exit criteria:**
- [ ] Health check green from the deployed URL.
- [ ] A real end-to-end anomaly traverses the AWS path and appears in the incident list.
- [ ] Collector credential gets 403 on `/incidents`.
- [ ] Duplicate submission produces no duplicate incident.
- [ ] DLQ empty (or explained).
- [ ] Dashboard connects to the deployed API.
- [ ] Permission review + cost review done and recorded.

**Never claim the AWS path works until the above checkboxes are backed by command output.**

### Step 4.11 — Rollback & recovery

- `sam deploy` creates a CloudFormation change set; a failed update rolls back automatically (verify `ROLLBACK_COMPLETE` handling — a stack in `ROLLBACK_COMPLETE` must be deleted, not updated).
- Keep previous artifact versions so a redeploy of the last-known-good is fast.
- Document the **manual recovery playbook**: how to replay DLQ messages, how to re-drive a batch, how to restore from a DynamoDB point-in-time recovery if enabled (decide whether PITI is worth it for a demo; if enabled, test restore).

---

## 5. Data Models & State Management (AWS)

### 5.1 Table/item sketch (single-table option)

```jsonc
// Incident
{ "pk": "INCIDENT", "sk": "INCIDENT#01J...", "gsi1pk": "STATUS#open",
  "gsi1sk": "2026-10-17T10:16:02Z#01J...", "entity_type": "incident",
  "status": "open", "severity": "high", "anomaly_score": 0.93,
  "detector": "statistical_baseline", "model_versions": {"statistical_baseline": "rule-set-0002"},
  "ttl": 1794123362 }                     // created + 30d — TTL is best-effort

// Dedup guard
{ "pk": "DEDUP#evt_01J...", "sk": "META", "entity_type": "dedup",
  "receipt_id": "rcpt_...", "ttl": 1733123362 }   // +7d

// Baseline (durable — never Lambda memory)
{ "pk": "BASELINE#host-alpha#svc-pay#http#http_5xx_ratio", "sk": "STATE",
  "entity_type": "baseline", "history": [/* bounded */],
  "cold_start": false, "paused_updates": 2, "updated_at": "..." }
```

### 5.2 Retention (configurable test defaults — not guarantees)

| Data | Default retention |
|---|---|
| Incidents | **30 days** |
| Selected redacted evidence + detailed debug logs | **7 days** |
| Dedup records | ~7 days (longer than max retry horizon) |
| Baseline/window state | Only as long as needed |
| DLQ messages | 14 days (message retention) to allow inspection |

Implement **and test** cleanup. Do not assume TTL is immediate.

### 5.3 Pagination & filtering (incident list)

Use **opaque cursor** pagination (`next_cursor`), never unbounded scans. Filters: `status`, `severity`, `time_from`, `time_to`, `host`. Every filter maps to a documented query (A1–A3). The API contract (`05_API_...`) pins the exact shapes.

### 5.4 DLQ inspection & replay (runbook)

```bash
# inspect
aws sqs receive-message --queue-url "$DLQ_URL" --max-number-of-messages 5 --visibility-timeout 60

# after diagnosing: replay to the main queue
aws sqs send-message --queue-url "$MAIN_QUEUE_URL" --message-body "$BODY"

# then purge the DLQ entry (worker is idempotent, so replay is safe)
aws sqs delete-message --queue-url "$DLQ_URL" --receipt-handle "$RH"
```

Document the human decision point: **never blind-replay a poison message** — fix the cause first, or it will just DLQ again.

---

## 6. Security, Testing, and Deployment Considerations (AWS)

### 6.1 Security controls (cloud-specific)

- 🔐 **Least privilege**: every Lambda role scoped to one queue/table; no `*` on DynamoDB/SQS where a resource ARN is known.
- 🔐 **Separate ingestion and incident roles.**
- 🔐 **No wildcard IAM** where practical; use conditions (`aws:SourceArn`, `aws:SourceAccount`) on resource policies.
- 🔐 **Secrets**: SSM/Secrets Manager; `NoEcho` parameters; never in env var dumps, logs, or the SAM template body committed to Git.
- 🔐 **CORS**: explicit origins for the dashboard; verify in both local and AWS modes.
- 🔐 **HTTPS only**; disable nothing that enforces TLS.
- 🔐 **S3** (if used): block public access, encryption on, lifecycle retention, least-privilege bucket policy.
- 🔐 **CloudWatch logs**: structured, **no secrets, no raw log bodies**. Redaction already happened upstream; do not re-log payloads.
- 🔐 **API throttling** on API Gateway (per-client limits) as cheap abuse protection.
- 🔐 **X-Ray/Tracing** optional; helpful, but do not send sensitive payloads as trace annotations.

### 6.2 Required verification checklist (from the spec — all mandatory)

- [ ] Local API tests
- [ ] Authentication/authorization tests (incl. collector → 403 on incidents)
- [ ] Schema/size validation tests
- [ ] Queue **retry and DLQ** tests
- [ ] **Duplicate-event** tests
- [ ] SAM template **validation/build**
- [ ] Deployed **health check**
- [ ] One **real end-to-end AWS scenario**
- [ ] Dashboard/API connectivity
- [ ] Permission and **cost review**

**Never state that deployment succeeded until commands/results verify it.**

### 6.3 Cost discipline

- Use a **measured workload**; inspect actual service usage after the load tests (5 ev/s × 10 min; 25 ev/s × 60 s).
- **Free-tier rules vary** and do not guarantee zero cost — do not budget on "it'll be free."
- Avoid always-on EC2, Kinesis, managed search unless justified.
- **Budget/usage alerts** where available — they notify; they do **not** necessarily stop spending.
- Identify **persistent resources** (tables, buckets, log groups, DLQ messages) and document teardown.
- Record actual cost for the defined workload and period as a reported metric.

### 6.4 Deployment environments

- Separate **dev** and **demo** environments where feasible (different stacks/parameters), so demo rehearsal cannot clobber dev experiments and vice versa.
- Parameterize via SAM parameters + per-env parameter files; **no env-specific values in the template body**.

### 6.5 Troubleshooting quick reference

| Symptom | Likely cause | Check |
|---|---|---|
| 502 from API GW | Lambda crash / timeout / bad response shape | CloudWatch logs; response must match contract |
| Events accepted, no incidents | Worker role/table name/queue URL; or cold-start baseline | Worker logs; `LAD_*` env; baseline `cold_start` flag |
| Duplicate incidents | Non-idempotent write; visibility timeout < worker timeout | Dedup items; queue config |
| Messages stuck | Visibility timeout too high; worker erroring and nacking to retry | Queue depth; `maxReceiveCount` |
| DLQ filling | Poison message (schema drift, bad encoding) | Inspect DLQ body; fix; replay |
| 403 on incident routes with a collector token | **Expected** — collectors cannot read incidents | Use admin credential |
| CORS errors in dashboard | Origin not in API CORS config | API CORS vs. deployed dashboard origin |
| `ROLLBACK_COMPLETE` stack | Failed create/update rolled back | Delete stack, redeploy cleanly |

---

## 7. Definition of Done (cloud track)

- [ ] `sam validate --lint` and `sam build` clean.
- [ ] Deployed health check returns contract-valid output with no leaked internals.
- [ ] Ingestion authenticates collectors, enforces limits, validates schema, returns a truthful receipt with accepted/rejected counts.
- [ ] SQS + DLQ configured coherently (visibility ≥ timeout × 2, maxReceiveCount → DLQ); retry/DLQ tests pass.
- [ ] Worker is idempotent; duplicate delivery yields no duplicate incidents; acks happen **after** durable writes.
- [ ] DynamoDB modeled around access patterns A1–A7; TTL behavior tested (not assumed).
- [ ] Admin routes are server-side protected; collector gets 403; audit entries written on lifecycle actions.
- [ ] No secrets in Git, logs, or frontend; CORS verified.
- [ ] One real end-to-end AWS scenario verified with command output.
- [ ] Cost measured for the defined workload; teardown documented and executed successfully in a rehearsal.
- [ ] Local mode still runs with **no AWS credentials** (regression-check after every AWS change).

---

*Next:* `04_DEVOPS_COLLECTORS_AND_FRONTEND_GUIDE.md` → `05_API_AND_DATA_CONTRACTS_GUIDE.md`.
