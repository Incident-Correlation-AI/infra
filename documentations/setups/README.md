# documentations/setups — Console Setup Chapters (index)

Console-created, click-by-click infrastructure records for the LAD project
(account `776184688152`, region `eu-north-1`). Each chapter documents exactly
what was done in the AWS console.

## Execution order (dependency-safe)

| # | Chapter | Connects |
|---|---|---|
| 3 | `03_LambdaFunctions.md` | Creates the empty compute functions |
| 2 | `02_SQSQueue.md` | Buffers + DLQ, redrive policy |
| 1 | `01_DynamoTable.md` | Incident/incident-state table |
| 4 | `04_IAMPolicies.md` | Functions ↔ queue ↔ table permissions |
| 5 | `05_RuntimeConfig.md` | Env vars, TTL attribute, log retention |
| 6 | `06_EventSourceMapping.md` | Worker actually consumes the queue |
| 7 | `07_APIGateway.md` | HTTPS front door + routes + CORS + throttling |

Nothing below chapter 3 talks to anything; the interconnect chapters are the point.

## Status board (update honestly — never claim success unverified)

- [x] Lambda functions created (`IncidentIngestFn`, `IncidentWorkerFn`)
- [x] SQS queues + redrive (`IncidentMainQueue` → `IncidentDLQ`)
- [x] DynamoDB table + `gsi1` (`IncidentTable`)
- [ ] `IncidentApiFn` created (07_APIGateway.md Part 1)
- [ ] Inline IAM policies attached (04_IAMPolicies.md Parts 1–3)
- [ ] Env vars set on all three functions (05_RuntimeConfig.md Part 1)
- [ ] TTL attribute enabled on `IncidentTable` (05_RuntimeConfig.md Part 2)
- [ ] Log retention set (05_RuntimeConfig.md Part 3)
- [ ] SQS trigger on `IncidentWorkerFn` (06_EventSourceMapping.md)
- [ ] HTTP API + routes + CORS + throttling (07_APIGateway.md)

## Known follow-ups (not console work)

- [ ] `IncidentIngestFn` (click-created leftover from an earlier attempt) **replaced** by the
      new flows above — before demo day, delete or repurpose it so exactly one ingest
      path exists. Deletion protection on `IncidentTable` must be turned OFF before teardown.
- [ ] Programmatic credentials (`aws configure`, IAM user + key) — lets every "Verified by
      command output" claim become an actual verification instead of a best-effort.
- [ ] SSM credential parameters (`/lad/dev/collector-token-hash`, `/lad/dev/admin-password-hash`,
      `/lad/dev/session-secret`) — written by hand with values nobody commits anywhere.
