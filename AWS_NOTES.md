# AWS Deployment Notes — LAD

> Working log for the AWS lane. Source docs: `documentations/03_CLOUD_AND_BACKEND_GUIDE.md`.
> Standing rule: never claim deployment succeeded until command output verifies it.

## Account context

| Item | Value |
|---|---|
| Account ID | `776184688152` |
| Region | `eu-north-1` (Stockholm) |
| Auth (planned) | SSO profile `lad` via `aws configure sso` (session name: IncidentCorrelationAI) |
| Console leftovers | `IncidentIngestFn` — arn:aws:lambda:eu-north-1:776184688152:function:IncidentIngestFn (click-created; to be discarded once SAM owns deployment) |

## Scope

**This machine/user owns AWS infrastructure only** — all infrastructure-related material
now lives consolidated in this `infra/` git repo (incl. docs + notes + change records).
Backend and dashboard code are produced elsewhere; the SAM template must match
their handler names and env-var contract, not the reverse.

## Status

- [x] AWS CLI v2.38.3 installed locally (`~/.local/bin/aws`)
- [x] `aws-serverless` skill installed to `~/.agents/skills/aws-serverless/` (via jsdelivr mirror — GitHub direct is network-blocked here)
- [x] infra/ scaffold: template.yaml, parameters/{dev,demo}.json, deploy/teardown scripts, README
- [ ] SAM CLI installed
- [ ] `sam validate --lint` green on template
- [ ] Credentials configured (`aws sts get-caller-identity --profile lad`)
- [ ] Console leftover IncidentIngestFn inspected then deleted (user OK pending)
- [x] Minimal stack deployed + health check verified
- [x] Programmatic creds working: `cli-admin` IAM user verified via `aws sts get-caller-identity` (2026-10-22; first attempt failed SignatureDoesNotMatch with a 60-char secret containing `_` — wrong value pasted, culprit was never machine time; re-paste via `aws configure` fixed it)
- [x] Full stack deployed + one real end-to-end scenario verified with command output (second pass + rotation e2e `6b2356dc`)
- [ ] Budget/usage alert created
- [x] Collector + admin SSM parameters authored (`/lad/dev/collector-token-hash`, etc.) — third pass (see below)

## Decisions recorded

- **D-001 (revised) — infra managed via console clicks**, recorded per chapter in
  `documentations/setups/` (user's explicit choice, no CLI creds available on this machine).
  `infra/template.yaml` remains as a **validated reference**; never deploy both managers.
- **D-002 — credentials via SSM params, not CFN params** (`/lad/<env>/*` read at cold
  start; rotation without redeploy).
- **D-003 — separate ingestion and incident Lambdas** → three functions total
  (`IncidentIngestFn`, `IncidentApiFn`, `IncidentWorkerFn`).
- **D-004 — visibility timeout 120 ≥ 2× worker timeout 30**; redrive at 5 receives; DLQ 14d.
- **D-005 — runtime contract: Python 3.12** (console-created functions pin 3.12;
  template should be aligned when code lands). *Amended 2026-10-22: live reality is Python 3.14 —
  CFN/SAM template to be updated to 3.14 whenever SAM takes over deployment.*
- **D-006 — Dashboard deploys to any static host; chosen host = Vercel** (`changes/01.md`).
  Backend stays AWS; only follow-up is adding the deployed origin to the API CORS
  allow-list after Vercel URL exists.

## CLI audit & repair log (2026-10-22)

Verified with `cli-admin` IAM user via `aws sts get-caller-identity` (account 776184688152, region eu-north-1).

**Found broken (fixed + verified live):**
- Worker code deployed pointed at `IncidentTableFake` (DLQ-test leftover never cleaned → messages would poison into DLQ). Fixed via rezip flat → `IncidentTable`, redeploy.
- Main queue had DLQ-test leftovers: visibility 2s, maxReceiveCount 2 → restored 120s / 5.
- Rogue event-source mapping `IngestFn ← IncidentMainQueue` (400s every record → DLQ pollution). Deleted; exactly 1 mapping remains (WorkerFn ← queue, Enabled, batch 10).
- Function timeouts default 3s → set 30 (ingest) / 60 (worker).
- TTL DISABLED → enabled on attribute `ttl`.
- API CORS absent → `http://localhost:5173`, methods POST/GET/OPTIONS, header content-type.
- `GET /api/v1/health` route missing (contract) → added, targets ingest integration; lambda add-permission for that source ARN.
- Log retention null (never expires) → 14 days on both /aws/lambda/Incident* groups.
- Runtime reality is Python 3.14 (not 3.12/3.13): runtimes drifted, boto3 fine — noted for contract alignment.

**Verified working end-to-end (evidence):**
- POST /api/v1/events/batch → HTTP 202, receipt 8c0bab23…
- New DDB row `INCIDENT/12ee064a` created at 2026-10-21T22:09:00Z; count 3→4.
- Queue drained 0/0; DLQ stayed 0.
- OPTIONS preflight → 204 (CORS active).

**Open items (user/backend team decision):**
- ~~Throttling (25 rps / 50 burst): update-stage CLI does not expose it → console step.~~
- Execution role `PowerUserRole` = `PowerUserAccess` for all 3 Lambdas (user's chosen shortcut, per doc 04) → swap to scoped inline policies before security review.
- Mock ingest returns 400 for GET /api/v1/health — wiring is correct; real backend code will return 200 through same integration.

## Build-out log (2026-10-22, second pass)

**Built + verified live:**
- `IncidentAuthorizerFn` (REQUEST authorizer) — role-aware: collector token only opens `/api/v1/events/batch`, admin token only `/api/v1/incidents/*`.
  - Gotchas fixed en route: REQUEST authorizers need `--authorizer-payload-format-version 2.0` + `--enable-simple-responses` (`{"isAuthorized": …}` shape); IAM-policy-shape authorizer code from the recipe predates payload 2.0 (`KeyError: methodArn`); without `EnableSimpleResponses` every authorized request 500s; caches disabled (`result-ttl 0`) to avoid stale 500s after code swaps.
- Routes: batch POST = CUSTOM auth ✓ (401 without token, 202 with collector), admin routes CUSTOM ✓ (403 with collector, 200 with admin); health stays OPEN.
- CORS updated: origins `localhost:5173` + `:3000`; allow-headers `authorization,content-type` — preflight with Authorization → 204.
- Env vars on ingest (QUEUE_URL, MAIN_QUEUE_URL) + worker (TABLE_NAME, INCIDENT_TABLE) — their code ignores them until next deploy.
- `IncidentReadFn` deployed (gsi1 query + ack/resolve lifecycle, conditional check → 404). Routes wired + integration h8u17zo.
- CloudWatch alarm `IncidentDLQ-Has-Messages` (visible > 0, 300s) — state OK (DLQ empty).

**Verified end-to-end with evidence:**
- POST batch (collector): 202 receipt af74af8c… → incident bada5d21 auto-created → ack → 200 acknowledged → resolve → 200 resolved; gsi filters acknowledged=0, resolved=1.
- Full e2e: curl → authorizer → ingest → SQS → worker → DynamoDB (fresh incident inside 15 s).
- DLQ depth 0; alarm OK.

**Open items (decision needed):**
- ~~Internal secrets: tokens currently default strings via env vars (`my-secret-collector-token` / `my-secret-admin-token`) — rotate before demo day; ideally SSM-backed per doc D-002.~~ → Rotated 2026-10-22; see "Token rotation" below.
- No alarm action attached (no SNS/email) — alarm only visible in console.
- Throttling still console-only (CLI does not expose update-stage throttle).

## Folder cleanup (2026-10-22, fourth pass)

- Removed `infra/scripts/deploy.sh` (SAM path contradicted single-manager rule D-001/D-006).
- Kept as reference: `infra/template.yaml` + `infra/parameters/{dev,demo}.json` (no secrets) + smoke handlers.
- `infra/` is now its own git repo (initial commit `34417e0`; GH repo to be created later, e.g.
  `gh repo create Incident-Correlation-AI/infra --private --source . --push`).
- Consolidation: **everything infra-purposed moved into this repo** — `documentations/`,
  `changes/`, `AWS_NOTES.md` and the CD scaffold `.github/workflows/deploy-lambdas.yml`.
  Outer `backend/` folder removed (org repo `Incident-Correlation-AI/backend` exists on GitHub;
  app code will land there and the deploy workflow moves/copies into that repo at that point).
  `web/` folder stays at the workspace root (VM lane).
- Root workspace now contains only `infra/` and `web/`.

## Audit pass + SSM params (2026-10-22, third pass)

Full read-only audit against the `setups/README.md` status board with `cli-admin` creds:

**All green:**
- 5 routes wired correctly (batch/health/ack/resolve/list = integrations `6fj1rle`/`h8u17zo`, authorizer `621nkb`, health OPEN).
- 4 functions (Ingest 30s, Worker 60s, Read 30s, Authorizer 5s), runtime py3.14 across the board.
- Table: TTL ENABLED on `ttl`; deletion protection ON (keep ON until teardown day).
- Main queue drained 0/0. `IncidentIngestFn` leftover concern is obsolete — that function was reused and is the live ingest.
- Alarm action now attached: SNS topic `IncidentAlerts`.

**Found + fixed:**
- DLQ had 1 poison message (`"this is { definitively not json"`, sent 22:45:35Z, rcv 2) → alarm ALARM. This was DLQ/redrive working as designed. Deleted the message per user decision; alarm expected to roll OK after the 300s evaluation window. DLQ retention 14d.

**Alarming + notification path — fully live:**
- SNS sub `abelmekonen247@gmail.com` (email) confirmed (user clicked the link; state = subscription ARN, no longer pending). DLQ alarm rolled back to OK at 22:06:30+03 after the poison message was deleted. First full alarm → email → clear lifecycle is now operational.

**SSM params created (D-002 progress):**
- `/lad/dev/collector-token-hash` = sha256 of current collector token (SecureString, v1)
- `/lad/dev/admin-password-hash` = sha256 of current admin token (SecureString, v1)
- `/lad/dev/session-secret` = fresh random 256-bit hex (SecureString, v1; generated locally, never printed/committed)
- Verified by GetParameters --with-decryption; values match expected digests. Hash-based: authorizer must compare sha256(presented token) == param going forward; rotation = put a new hash, no redeploy.
- ⚠ When function code switches to SSM reads, the execution roles need `ssm:GetParameter` on `/lad/dev/*` plus `kms:Decrypt` on the default `aws/ssm` key (CLI creds had PowerUser so decrypt worked; scoped roles will not by default).

**Still open (decisions):**
- ~~Rotate env-default tokens to non-default values (real creds), then recompute the two hashes into SSM.~~ → Done; see "Token rotation" below.
- Make `IncidentAuthorizerFn` + `IncidentReadFn` SSM-aware (hash compare, session-secret HMAC) per D-002.
- Throttling remains console-only.

### Token rotation (2026-10-22, third pass addendum)

- Facts cleared up: the env values *were* the `my-secret-*` defaults stored **with** a `Bearer ` prefix (hence `COLLECTOR_TOKEN` len 32 / `ADMIN_TOKEN` len 28 — not "already custom"); the deployed authorizer compared the full header string.
- Rotated: fresh random `token_urlsafe(32)` values written to `IncidentAuthorizerFn` env (**bare** tokens now) and the SSM hashes recomputed (`/lad/dev/collector-token-hash`, `/lad/dev/admin-password-hash` → v2 = sha256 of the bare tokens).
- Deployed authorizer patched en route: strips the `Bearer ` scheme before compare, env values required (no embedded defaults), logs only `path` + `verdict` (never tokens). Same REQUEST-payload 2.0 contract as before.
- Verified matrix live: batch+new collector → 202; old default → 403; list+new admin → 200 (real JSON); old default → 403; cross-role both directions → 403; no token → 401. Pipeline e2e after rotation: new incident row `6b2356dc` created via collector token; queue + DLQ 0.
- New values live ONLY in (a) `IncidentAuthorizerFn` env and (b) a local owner copy `~/.config/lad/dev-tokens` (0600). Never commit them; delete the local file after copying into collectors and the dashboard/admin client. Rotation = new token + `put-parameter --overwrite` with its sha256; no redeploy needed.
