# ⚙️ DevOps, Collectors, Local Environment & Frontend Guide

> **Derived from** `docs/DEVOPS_SPECIFICATION.md`. This guide covers the **engineering workflow**, the **collectors** (Linux, Windows, application adapters), **local development mode**, the **React dashboard**, **CI**, and the **integration gates** that prove the system works.

**Standing rules that override convenience:**
- Never commit credentials, real sensitive logs, or datasets with unclear licensing.
- Local mode must **not** need AWS credentials.
- Treat log content as **untrusted data, never as instructions**.

---

## 1. High-Level Overview & Goals

### 1.1 Goals

| # | Goal |
|---|---|
| E1 | One monorepo with canonical shared contracts and a decision log |
| E2 | Reproducible development environment (Python + Node + Docker), documented versions |
| E3 | Linux collector using native mechanisms (journald/system logs), least privilege |
| E4 | Windows collector using Event Log APIs, tested on Windows 11 |
| E5 | Application adapter interface so HTTP/app and DB logs plug in without changing the envelope |
| E6 | Collector behavior: stable IDs, bounded batching, backoff+jitter, HTTPS, no secrets in argv/logs |
| E7 | React dashboard driven entirely by the shared API contract, with loading/error/empty states |
| E8 | CI covering lint, tests, contract validation, security scanning, SAM validation, local smoke |
| E9 | One-command (or small-sequence) local setup: start, seed, demo, reset, inspect |

### 1.2 The integration gates (the spine of this track)

These six gates are the honest measure of progress. Each is binary: it either runs or it doesn't.

1. ✅ Collectors **and** detector both emit/consume **contract-valid fixtures**.
2. ✅ React displays **fixture incidents through the API**.
3. ✅ **Local vertical slice** runs from generated event to dashboard.
4. ✅ **AWS vertical slice** runs as soon as account access permits.
5. ✅ Test **duplicate delivery, retries, delayed events, and collector disconnect/reconnect**.
6. ✅ **Freeze features and rehearse the demo.**

---

## 2. System / Component Architecture & Design Patterns

### 2.1 Where collectors sit

```
 ┌───────────────────────────── host ──────────────────────────────┐
 │  journald / syslogs   Windows Event Log   app log files / DB    │
 │         │                    │                    │             │
 │         ▼                    ▼                    ▼             │
 │  [Linux collector]   [Windows collector]  [App adapter]         │
 │         └───────────────┬────┴────────────────┘                 │
 │                         ▼                                       │
 │              normalize → redact → buffer → batch                │
 │                         │  (stable event IDs assigned once)     │
 └─────────────────────────┼───────────────────────────────────────┘
                           ▼  HTTPS, collector-only credential
                  POST /api/v1/events/batch  → queue → worker
```

**Collectors are intentionally dumb.** They collect, normalize, redact, and ship. They do **not** detect, do **not** read incidents, do **not** hold long-term state. This keeps the blast radius of a compromised collector to "junk events," which validation and dedup limit.

### 2.2 Shared adapter interface (application adapters)

Define one interface so HTTP/application and database logs can be added **without changing the universal envelope**:

```python
# collectors/app_adapters/base.py (illustrative)
from typing import Protocol, Iterable, Any

class AppAdapter(Protocol):
    name: str
    def supports(self, raw: Any) -> bool: ...
    def extract_timestamp(self, raw: Any): ...
    def to_envelope(self, raw: Any, ts) -> "Event": ...
    def provides(self) -> set[str]:
        """Which optional features this source can supply, e.g. {'http_5xx_ratio','latency_p95'}."""
```

**Start with** application logs that provide **HTTP status, route/template, duration, and request ID**. Add **database timeout events** through logs or a **controlled simulator**.

⚠️ **Do not claim arbitrary HTTPS payload visibility.** Encrypted traffic does not reveal application details without authorized endpoint/application telemetry. This is a physical/encryption fact, not a limitation to "solve."

### 2.3 Design patterns

| Pattern | Where |
|---|---|
| **Adapter/Ports** | each OS/app source adapts into one envelope; core never sees OS-specific shapes |
| **Producer with bounded buffer** | collector buffer + batch flush |
| **Retry with exponential backoff + jitter** | network send path |
| **Idempotency by stable ID** | assigned once, reused across retries |
| **Configuration object** | endpoint, identity, sources, redaction, limits — one validated config |
| **UI composition** | dashboard: list/detail/timeline components fed only by API responses |
| **Pipeline in CI** | lint → unit → contract → integration → security → SAM validate → smoke |

---

## 3. Environment Setup & Prerequisites

### 3.1 Prerequisites

- [ ] **Python** — supported 3.x; document the exact version **after verifying library compatibility** (journald bindings, Windows Event Log libs, scikit-learn, FastAPI).
- [ ] **Node.js + npm/pnpm** — document version after verifying React/Vite/TypeScript compatibility.
- [ ] **Docker + Compose** — local dependencies.
- [ ] **Linux machine** with journald access (most distros default).
- [ ] **Windows 11 machine** for the Windows collector (test on Windows 11 as specified).
- [ ] `make` or an equivalent task runner.
- [ ] *(AWS lane only)* AWS CLI + SAM CLI — see `03_CLOUD_...`.

### 3.2 Repository workflow

- **One monorepo.** Shared schemas and OpenAPI are **canonical**; tracks read them, never fork them.
- **Short-lived branches**, pull requests, code review, and tests for behavior changes.
- **Decision log** (`docs/decisions/`) — every non-obvious choice gets an ADR.
- **Never commit** credentials, real sensitive logs, or datasets with unclear licensing.

### 3.3 Development environment files

```bash
# .env.example — non-secret examples ONLY
LAD_MODE=local
LAD_API_BASE_URL=http://localhost:8080
LAD_STORAGE_BACKEND=local
LAD_QUEUE_BACKEND=local
LAD_LOG_LEVEL=INFO
LAD_DASHBOARD_PORT=5173
LAD_COLLECTOR_ENDPOINT=http://localhost:8080/api/v1/events/batch
LAD_COLLECTOR_ID=host-dev
# LAD_COLLECTOR_TOKEN=   # injected at runtime, never committed
```

```makefile
# Makefile (tooling contract)
setup:          ## install python + node deps, copy env
lint:           ## formatters + linters, python and frontend
test:           ## unit tests
contract:       ## validate fixtures against JSON Schema + OpenAPI
integration:    ## API → queue → worker → store, local adapters
security:       ## authz boundaries, redaction, secret scanning
local-up:       ## start local API, worker, storage
seed-normal:    ## generate normal synthetic traffic (fixed seed)
seed-anomaly:   ## generate a labeled anomaly scenario (fixed seed)
demo-reset:     ## clear demo data, documented + reversible
dashboard:      ## start React dev server
smoke:          ## local end-to-end smoke: seed → API → dashboard reachable
sam-validate:   ## sam validate + build (AWS lane only)
deploy:         ## parameterized deploy (AWS lane only)
teardown:       ## documented cleanup (AWS lane only)
```

Every target must be **safe to run twice** and print what it is about to do.

---

## 4. Step-by-Step Implementation Guide

### 4.1 Linux collector

**Use supported native mechanisms:** journald / system logs and selected application logs.

**Permissions & least privilege:**
- Document exactly which group/capability is needed (e.g., membership in `systemd-journal` to read journald).
- **Do not require root** unless a specific source genuinely requires it; **isolate privileged access** where possible (e.g., a dedicated user + group, or a narrowly-scoped helper).
- The collector runs as a **dedicated unprivileged user** with only the submission credential.

**Preserve source metadata:** unit, journal fields, timestamp, severity. These become envelope fields and optional attributes — do not flatten them into a message string and lose structure.

**Redact before remote transmission** (tokens, passwords, session IDs) — and again server-side (defense in depth).

```python
# collectors/linux/collector.py (illustrative sketch)
import systemd.journal as journal   # verify binding choice during setup

def run(cfg: CollectorConfig) -> None:
    buf = BoundedBuffer(max_events=cfg.max_events, max_bytes=cfg.max_bytes)
    reader = journal.Reader()
    reader.this_boot()
    reader.log_level("info")            # documented, configurable
    reader.seek_tail()                  # start at "now" by default; ADR if historical
    while True:
        for entry in reader:
            ev = normalize_linux(entry)         # envelope + metadata preserved
            ev = redact(ev)
            buf.add(ev)
            if buf.ready(max_events=100, max_bytes=262144):
                send_with_backoff(cfg.endpoint, buf.drain(), credential=cfg.token)
        reader.process()
```

**Documented requirements:** which journal fields are preserved; the flush interval; behavior when the buffer fills; how to run a test event; how to verify the collector is shipping (`--dry-run` printing envelopes is a great demo aid).

**Tests:** unit tests over recorded journal fixtures (contract-valid), plus a platform test on a real Linux host that emits a known event and asserts it appears via `GET /api/v1/events`-style visibility (or via the incident path if that's the observable).

### 4.2 Windows collector

**Use** Windows Event Log APIs (e.g., `pywin32`/`win32evtlog`, or an established collection mechanism — verify during setup). **Test on Windows 11.**

**Document:**
- supported **channels** (e.g., System, Application; avoid broad sensitive channels without a defined need)
- **permissions** needed to read them
- installation / startup (service vs. scheduled task)
- configuration format
- how to **run a test event** (e.g., `Write-EventLog` or `eventcreate`) to prove the path end-to-end

**Preserve:** provider, channel, event ID, timestamp, level, and relevant structured fields.

⚠️ **Avoid collecting broad sensitive channels without a defined need.** Data minimization is a security control, not a nice-to-have.

```powershell
# collectors/windows/test-event.ps1 — prove the pipeline on Windows 11
Write-EventLog -LogName Application -Source "LADTest" -EventId 1001 -EntryType Information `
  -Message "LAD pipeline test event $(Get-Date -Format o)"
```

**Tests:** platform test on Windows 11 emitting a known event and asserting contract validity + arrival. If a channel is unavailable in the test environment, **record the limitation** rather than fabricating a result.

### 4.3 Application adapters

1. Implement the `AppAdapter` interface (§2.2).
2. Start with an **HTTP access-log adapter** (status, route/template, duration, request ID).
3. Add a **database timeout adapter** via logs or a **controlled simulator** (the simulator is also how scenario 3 — DB timeout → HTTP 500 spike — gets generated deterministically).
4. Register adapters by config; the envelope does not change when adapters are added.

### 4.4 Collector behavior (the contract every collector must honor)

| Behavior | Requirement |
|---|---|
| **Stable event IDs** | Assigned **once** at creation; **survive retries**; persisted across restarts for in-flight buffers |
| **Batching** | ≤ **100 events** or ≤ **256 KB**, whichever occurs first |
| **Flush interval** | Short and documented (e.g., 2–5 s); configurable |
| **Local buffer** | **Bounded**; defined behavior when full (drop-oldest or block — choose, document, and **metric the drops**) |
| **Retry** | Exponential backoff **with jitter**; bounded attempts; then dead-letter locally / log + drop with metric |
| **Transport** | **HTTPS only** |
| **Credentials** | Collector-only permissions; **never** in command lines or logs; injected at runtime |
| **Configuration** | endpoint, identity, enabled sources, redaction rules, limits |
| **Enrollment/rotation** | Documented procedure to enroll a host and to **revoke/rotate** a credential in one step |

```python
# collectors/common/batching.py (illustrative)
def flush_loop(cfg, queue_out):
    while True:
        time.sleep(cfg.flush_interval_s)
        batch = cfg.buffer.drain(max_events=100, max_bytes=262144)
        if not batch:
            continue
        for attempt in itertools.count():
            try:
                post(cfg.endpoint, batch, token=cfg.token, timeout=cfg.request_timeout_s)
                METRICS.inc("collector_sent", len(batch))
                break
            except RetryableHttpError as e:
                delay = min(cfg.backoff_base_s * 2 ** attempt, cfg.backoff_max_s)
                jitter = random.uniform(0, delay * 0.3)      # jitter avoids thundering herd
                METRICS.inc("collector_retry")
                time.sleep(delay + jitter)
            except FatalHttpError:
                cfg.buffer.dead_letter(batch)                # do NOT loop forever
                METRICS.inc("collector_dead_lettered", len(batch))
                break
```

⚠️ **Buffer-full behavior is a correctness decision, not an implementation detail.** Dropping oldest loses the earliest evidence of an incident; blocking can wedge the host's log pipeline. Choose deliberately, document it, and surface `dropped_total` so data loss is **never silent**.

### 4.5 React dashboard

**Rule:** the dashboard is a **pure consumer of the shared API contract.** It holds no secrets, makes no detection decisions, and enforces nothing security-critical (it may *hide* UI, but the server decides).

**Required screens & elements:**
- **Incident list** — filters (status, severity, time range), **pagination** (cursor-based), severity badges, empty/loading/error states.
- **Incident detail** — timeline, evidence (supporting **and** contradicting), hypotheses with confidence + missing evidence, diagnostic checks (clearly non-executing), **acknowledge/resolve** controls, audit trail.
- **Uncertainty surfacing** — observed vs. baseline values, detector name(s), model versions, cold-start/"warming up" state.
- **Honesty in copy** — never label a score as a probability; never state root cause without evidence; "Unknown" hypothesis is shown as a valid outcome.

**Configuration:** API base URL **by environment**; **no secret keys in the bundle**. Verify CORS against the API config in both local and AWS modes.

**Security-critical rendering:** log-derived text is attacker-controlled. Escape it safely.

```tsx
// dashboard/src/components/EvidenceLine.tsx (illustrative)
// NEVER use dangerouslySetInnerHTML with log-derived content.
export function EvidenceLine({ event }: { event: IncidentEvent }) {
  return (
    <li className="evidence">
      {/* React escapes by default — keep it that way */}
      <code>{event.event_id}</code>
      <span>{event.timestamp}</span>
      <span className="message">{event.message}</span>   {/* rendered as text, always */}
    </li>
  );
}
```

```tsx
// data fetching with explicit loading/error/empty states
export function IncidentList() {
  const { data, status, error, fetchNextPage } = useIncidents({ /* filters from URL */ });
  if (status === "loading") return <Spinner aria-live="polite" />;
  if (status === "error")   return <ErrorState message={error.message} retry={fetchNextPage} />;
  if (!data.items.length)   return <EmptyState />;
  return <>{/* table + cursor pagination */}</>;
}
```

**State management:** keep filter/pagination state in the **URL query string** so links are shareable and back/forward work. Prefer a data-fetching library (React Query/SWR) over hand-rolled `useEffect` fetching; it gives you caching, retries, and loading states consistently.

**Tests:** component tests for list/detail states (loading/error/empty), an XSS test asserting `<script>` in a log message renders as **text**, and a contract test asserting the client matches `openapi.yaml` shapes.

### 4.6 CI pipeline (minimum required)

```yaml
# .github/workflows/ci.yaml (illustrative; adapt to your CI system)
jobs:
  lint:
    steps: [checkout, setup-python, setup-node, make lint]
  unit:
    steps: [checkout, make test]
  contract:
    steps: [checkout, make contract]          # fixtures vs JSON Schema + OpenAPI
  frontend:
    steps: [checkout, cd dashboard && npm ci && npm test && npm run build]
  integration:
    steps: [checkout, make integration]       # local adapters, no AWS creds
  security:
    steps: [checkout, make security]          # secret scanning + authz/redaction tests
  sam:
    steps: [checkout, make sam-validate]      # sam validate + build only; no deploy
  smoke:
    steps: [checkout, make smoke]             # local end-to-end: seed → API → dashboard reachable
```

**Minimums:** formatting/linting · Python unit tests · frontend tests + build · schema and OpenAPI validation · contract tests · synthetic scenario tests · security/secret scanning where feasible · SAM build/template validation · local integration smoke test.

⚠️ The CI **must not** require AWS credentials for anything except an explicitly separate, protected deploy job. If a PR check needs cloud access, the local-parity guarantee is already eroding.

### 4.7 Local setup & the demo path

Provide a **documented one-command or small-command sequence** that can:

1. **start** local services (API, worker, storage, queue adapters),
2. **generate** normal and anomalous data (fixed seeds, labeled synthetic),
3. **run** the pipeline,
4. **open** the dashboard,
5. **reset** data (clean demo reset, documented + reversible),
6. **inspect** logs.

```bash
make local-up        # API + worker + local storage/queue
make seed-normal     # fixed-seed normal traffic → zero/minimal incidents
make seed-anomaly    # e.g., scenario 3: db timeouts → HTTP 500 spike
make dashboard       # dev server; open the printed URL
make demo-reset      # wipe demo incidents/baselines, documented
```

**Confirm this whole path works with all `AWS_*` credentials unset.** A negative test — `env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN make smoke` — is a cheap, honest verification.

---

## 5. Step-by-Step Integration Gates (in order)

1. **Fixture parity:** collectors and detector both emit/consume **contract-valid fixtures**. (`make contract` green on both sides.)
2. **Dashboard on fixtures:** React displays fixture incidents **through the API** (not mocked at the component level for this gate).
3. **Local vertical slice:** generated event → real local ingestion → queue/storage → detection/correlation → dashboard. **No seeded incidents directly into storage.**
4. **AWS vertical slice:** as soon as account access permits (see `03_CLOUD_...`).
5. **Failure injection:** duplicate delivery, retries, delayed events, collector disconnect/reconnect. Assert no loss, no duplicate incidents, and correct recovery.
6. **Freeze + rehearse:** feature freeze, docs, deployment rehearsal, demo. (Baseline plan reserved the final days for hardening and rehearsal — reconfirm dates.)

---

## 6. Data Models & State Management (this track)

### 6.1 Collector state

| State | Durability | Notes |
|---|---|---|
| Pending (unsent) events buffer | In-memory + on-disk spill (optional) | **Bounded**; defined full behavior; dropped_total metric |
| Stable IDs for in-flight events | On-disk (optional) so restarts don't re-assign | Prevents duplicate incidents after collector restart |
| Credential | Runtime-injected; never on disk in plaintext if avoidable | Rotation documented |
| Config | File/env | Non-secret defaults; token separate |

### 6.2 Frontend state

| State | Where |
|---|---|
| Filters, pagination cursor | **URL query string** (shareable, back/forward-safe) |
| Incident list/detail cache | Data-fetching library cache, keyed by query |
| Session/auth token | Short-lived; httpOnly cookie preferred; never localStorage with long-lived secrets |
| Optimistic UI for ack/resolve | Local, reconciled with server audit entry; server is source of truth |

### 6.3 Synthetic data & fixtures

- Fixtures under `contracts/fixtures/` are the **cross-team lingua franca**: valid and invalid examples, each with a documented reason.
- Scenario generators under `evaluation/` are **seeded and labeled**; labels live in eval metadata and must **never** become model features (leakage).
- All synthetic data must be **clearly labeled as synthetic** in demos.

---

## 7. Security, Testing, and Deployment Considerations (this track)

### 7.1 Security

- 🔐 Collector credential is **submission-only**; collectors cannot read incidents (enforced server-side; tested).
- 🔐 **No secrets in command lines or logs** — inject via env/file/handler, and grep the repo/artifacts in CI (secret scanning).
- 🔐 **HTTPS** for all remote submission.
- 🔐 **Data minimization:** do not collect broad sensitive Windows channels or full raw logs without a defined, documented need.
- 🔐 **Log content is untrusted data.** Never execute, never interpolate into a shell, never render as HTML.
- 🔐 **Credential rotation** documented and exercised at least once before the demo.
- 🔐 The dashboard bundle must contain **no secrets** (CI can assert no `AWS_SECRET`, no tokens in the built assets).

### 7.2 Testing (this track's responsibilities)

| Layer | Owner examples |
|---|---|
| Unit | parsers, normalization, redaction, batching/backoff, adapters |
| Contract | fixtures vs schema/OpenAPI; version compatibility |
| Integration | API → queue → worker → store (local) |
| Reliability | retries, duplicates, delayed events, worker restart, DLQ, buffer overflow, disconnect/reconnect |
| Security | authz boundaries, redaction, safe rendering (XSS test), secrets, size limits |
| Platform | Linux + Windows collectors on real hosts |
| E2E | local and AWS vertical slices |

**Pass/fail gates** (project-wide, restated here because this track owns several):
- synthetic anomaly traverses the **actual local pipeline** and appears in the dashboard
- duplicate submissions do not create duplicate incidents
- Linux and Windows collectors emit valid contract events
- collector credentials **cannot** read incidents
- local mode works **without AWS credentials**

### 7.3 Deployment & operations

- **Local:** Compose (or equivalent) + `make` targets; clean reset; log inspection documented.
- **AWS:** handled in `03_CLOUD_...`; this track owns the **dashboard build/deploy** (static hosting) and the **collector install/rollback** procedure.
- **Collector rollout:** document install, config, service registration, health check (`--dry-run`/`--status`), uninstall, and credential revoke. A collector that cannot be cleanly removed is an operational hazard.
- **Observability of the collectors themselves:** shipping rate, retries, dropped, dead-lettered — surfaced as metrics/log lines so a silently-dead collector is detectable.

### 7.4 Troubleshooting (document these in the repo)

| Problem | Symptom | Fix |
|---|---|---|
| Missing OS permissions | Linux collector reads nothing; Windows collector 5-access-denied | journal group membership; Windows channel ACLs |
| Absent Windows event channels | Empty reads on some SKUs | Document supported channels; test on Windows 11 |
| Timestamps/time zones | Events rejected for `invalid_timestamp`; skewed windows | Ensure tz-aware; normalize to UTC at the boundary |
| Invalid schema | 422s with field paths | Validate against `contracts/fixtures`; fix mapping |
| API URL/CORS | Dashboard network errors | `.env` base URL; API CORS origins |
| Expired credentials | 401/403 from ingestion | Rotate/revoke procedure; runtime injection |
| Queue/DLQ failures | Messages stuck or DLQ filling | Visibility timeout; poison message; replay runbook |
| SAM packaging | Build/deploy errors | `sam validate --lint`; dependency size; layers |
| AWS quotas | Throttling on load tests | Verify quotas; record limitation honestly |
| Local port conflicts | `local-up` fails | Document ports; provide override env |

---

## 8. Definition of Done (DevOps/collectors/frontend track)

- [ ] Monorepo with canonical contracts, decision log, and no committed secrets (CI-enforced).
- [ ] Documented, verified Python/Node versions; `.env.example` non-secret only.
- [ ] Linux and Windows collectors emit **contract-valid** events on real hosts; least-privilege documented; test-event procedure documented.
- [ ] App adapter interface stable; HTTP adapter + DB simulator ready for scenario generation.
- [ ] Collector honors stable IDs, ≤100 events/≤256 KB batching, bounded buffer with **metric'd** drop behavior, backoff+jitter, HTTPS-only, no secrets in argv/logs.
- [ ] Dashboard shows list/detail/timeline/evidence/hypotheses/checks with loading/error/empty states; XSS test passes; no secrets in bundle.
- [ ] CI green end-to-end **without AWS credentials**.
- [ ] `make local-up / seed-normal / seed-anomaly / dashboard / demo-reset / smoke` all work; the whole path verified with AWS env unset.
- [ ] All six integration gates checked with real command output (no fabricated results).

---

*Next:* `05_API_AND_DATA_CONTRACTS_GUIDE.md`.
