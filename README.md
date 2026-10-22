# LAD Infra — AWS Serverless (SAM)

Infrastructure-as-code for the project's AWS lane. **This is the only owner of AWS
resources**; console-created leftovers (e.g. `IncidentIngestFn`) are discarded once
the stack deploys. Local-mode (no AWS) is a backend concern and untouched by this folder.

## Resources (per `documentations/03_CLOUD_AND_BACKEND_GUIDE.md`)

| Resource | Purpose |
|---|---|
| API Gateway HTTP API | Public HTTPS front door; CORS pinned to dashboard origin; throttled |
| IngestFn Lambda | `POST /api/v1/events/batch` (collector-only) + `GET /api/v1/health` |
| IncidentApiFn Lambda | Admin-only incident list/detail/ack/resolve, audit writes |
| WorkerFn Lambda | SQS consumer: features → detection → correlate → incidents |
| SQS main queue | Buffered decoupling; visibility 120s ≥ 2× worker timeout |
| SQS DLQ | Poison messages; 14d retention for inspection/replay |
| DynamoDB (single table) | Incidents, dedup records, baseline state; TTL `ttl`; GSI for status listing |

## SAM (reference/template only)

While the account runs console/CLI-managed resources, `template.yaml` and
`parameters/{dev,demo}.json` remain a **validated reference** of the target
architecture (`sam validate --lint` green). Do not deploy SAM *and* console
resources for the same names simultaneously.

## Prerequisites

- AWS SSO profile configured on this machine
- CLI tools: `aws`, `sam` (in `~/.local/bin`)
- Handler names (`services.api.ingest.handler`, `services.api.incidents.handler`,
  `services.worker.handler`) and env contract must match what the backend team ships.

## Two ways to reach the same result

**A. CLI provisioning (preferred now)** — `scripts/provision.sh`:
reuses existing console resources, attaches scoped IAM policies, uploads
placeholder smoke handlers, wires the SQS trigger + API Gateway (6 routes,
CORS, throttling), enables TTL, then verifies end-to-end and prints evidence.
Idempotent — safe to re-run.

```bash
aws configure          # you type credentials; keys never go through chat
./infra/scripts/provision.sh
```

Chapters `04_…07_` in `documentations/setups/` are the console-click
alternative — the script is the same wiring automated.

**B. Console clicking** — follow those chapters if CLI creds are unavailable.

## Conventions

- Stacks: `lad-dev` / `lad-demo` (parameter files in `infra/parameters/`)
- Never deploy with `'*'` CORS; dashboard origin is explicit.
- Any manual console change is a drift bug: fix the template, redeploy.
