# AWS Infrastructure Setup Guide: SQS Trigger on the Worker

This document details the exact steps taken to make `IncidentWorkerFn` consume messages from `IncidentMainQueue`. An SQS trigger (event source mapping) is what actually invokes the worker — without it, enqueued events are never processed.

*Prerequisite:* the inline policy from 04_IAMPolicies.md (Part 2) is attached to `IncidentWorkerFn`'s role, and the environment variables from 05_RuntimeConfig.md (Part 2) are set.

---

## Step-by-Step Instructions

1. In the AWS Management Console, search for and select **Lambda**.
2. Left-hand menu → **Event Functions** (or **Functions**) → open **`IncidentWorkerFn`**.
3. Under **Triggers** (Configuration tab → Triggers, depending on UI), click **Add trigger**.
4. **Source:** **Simple Queue Service (SQS)**.
5. **SQS queue:** select `IncidentMainQueue`.
6. **Configuration:**
   * **Batch size:** `10` — worker processes up to 10 messages per invocation.
   * *(Additional settings dropdown):*
     * **Maximum batching window:** `5` seconds — small events can group up for efficiency without hurting latency.
     * **Report batch item failures:** **check this** — with partial failure reports, one poison message no longer fails/acks its 9 healthy neighbors. The docs' worker code must implement `ReportBatchItemFailures` response shape to match; the backend team must confirm this before demo.
     * **Concurrency limit:** leave unset (default).
7. Click **Save**. The trigger state should show **Enabled** after a few seconds.

---

## Expected Outcome

`IncidentWorkerFn` polls `IncidentMainQueue` (batch of up to 10 every ~5s when messages exist). A redrive policy already sends messages to `IncidentDLQ` after **5** failed receive attempts (set at queue creation), and `Visibility timeout = 120s ≥ 2 × the 30s function timeout` prevents the classic double-processing bug.

---

## Verification (honest, pre-code)

With no code uploaded yet, don't expect processing. Once backend code ships:

- `aws sqs get-queue-attributes --queue-url <MainQueueUrl> --attribute-names ApproximateNumberOfMessages NotVisible`
   - `NotVisible` counts in-flight messages the worker holds.
- Any message that fails 5 times must appear **only** in `IncidentDLQ`, never loop in the main queue.
