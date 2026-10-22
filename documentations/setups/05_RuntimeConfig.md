# AWS Infrastructure Setup Guide: Runtime Configuration (Env Vars, TTL, Log Retention)

Small but decisive settings: resource names the code will read, the TTL attribute the contract requires, and log retention (default is *forever*, which hides cost).

---

## Part 1: Environment variables on the functions

*Why:* code must discover resources by configuration, never hard-code names into the bundle.

1. AWS Console → **Lambda** → Event Functions/Functions → `IncidentIngestFn` → **Configuration → Environment variables → Edit**.

2. Add:

| Key | Value |
|---|---|
| `LAD_MODE` | `aws` |
| `LAD_ENV` | `dev` |
| `LAD_LOG_LEVEL` | `INFO` |
| `LAD_SSM_PREFIX` | `/lad/dev` |
| `INCIDENT_TABLE` | `IncidentTable` |
| `MAIN_QUEUE_URL` | *(paste from SQS console: `IncidentMainQueue` → the full `https://sqs.eu-north-1.amazonaws.com/776184688152/IncidentMainQueue` URL)* |
| `DLQ_URL` | *(same source: `IncidentDLQ` URL)* |

3. **Save**. Repeat **identically** on `IncidentWorkerFn` (and on `IncidentApiFn` once it exists).

---

## Part 2: TTL attribute on `IncidentTable`

*Why:* dedup records (~7d) and incident retention (30d) rely on the `ttl` attribute. The original 01_DynamoTable.md step did not include TTL — this completes it.

1. AWS Console → **DynamoDB** → Tables → **`IncidentTable`**.
2. Tab: **General information** → **Features** (or *Edit table → Time to live*, depending on UI).
3. Find **Turn on time to live**:
   * **Time to live attribute:** `ttl`
4. **Enable**. Status should change to *Active*.

---

## Part 3: CloudWatch log retention on the Lambda log groups

*Why:* retention defaults to `Never expire` — unwanted cost after the demo.

1. AWS Console → search **CloudWatch** → **Logs → Log groups**.
2. For each `/aws/lambda/IncidentIngestFn`, `/aws/lambda/IncidentWorkerFn` (and later `IncidentApiFn`):
   3. Select the group → **Actions → Edit retention settings** → `2 weeks` → **Set**.

---

## Expected Outcome

Functions get a config surface the code can read; the table honors the contract's retention policy; logs self-clean after 14 days. Medium: none of this breaks anything if absent *today* — but TTL must exist before incidents are created at scale, and it's testable only after messy data exists.
