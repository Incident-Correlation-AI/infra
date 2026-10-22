# 📚 Learning Module 7 — The React & TypeScript Dashboard

> **Module goal:** Build a dashboard that renders incidents **truthfully, safely, and accessibly** — driven entirely by the shared API contract, with none of the honesty or security rules violated in the UI.
> **Project tie-in:** You will build `dashboard/` — incident list, incident detail, timeline, evidence, hypotheses, diagnostic checks, lifecycle controls — plus its tests.

**Estimated study time:** 30–40 hours. **Prereq:** Modules 2 (contracts) and 6 (the API). JavaScript/HTML basics assumed.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 React's mental model: UI as a function of state
   - 1.2 JSX, the virtual DOM, and reconciliation (keys!)
   - 1.3 Components, props, and composition
   - 1.4 Hooks and the rules of state
   - 1.5 TypeScript: making the contract a compile-time guarantee
   - 1.6 Server state vs. client state (the fetching model)
   - 1.7 State in the URL (shareable, back/forward-safe)
   - 1.8 Rendering untrusted log data safely (XSS)
   - 1.9 Visualizing honestly: timelines, baselines, and misleading charts
   - 1.10 Accessibility, performance, and testing
   - 1.11 Configuration and security of the deployed bundle
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 React's mental model: UI as a function of state

React (open-sourced by Facebook in 2013) introduced a simple, radical idea:

```
UI = f(state)
```

You don't manipulate the DOM imperatively ("find this element, set its text"). You **declare** what the UI should look like for the current state, and React updates the DOM to match. This is **declarative rendering**, and it's why React scales to complex UIs: you reason about state transitions, not DOM mutations.

The flow:
```
state changes → component re-renders (returns new JSX) → React diffs → minimal DOM update
```

**Why this matters for our dashboard:** the incident list, filters, pagination cursor, and detail view are all *derived from state*. If you model the state correctly (including URL state), the UI is a pure projection and stays consistent. Bugs in dashboards are almost always **state-modeling bugs**, not rendering bugs.

### 1.2 JSX, the virtual DOM, and reconciliation

**JSX** is syntactic sugar: `<Incident id="inc1" />` compiles to `React.createElement(Incident, { id: "inc1" })`. It's not HTML and not a template string — it's a JavaScript expression that yields a lightweight description of the UI (a tree of "elements").

**The virtual DOM** is that description tree. On re-render, React produces a new tree and **reconciles** it against the previous one, computing the minimal set of real DOM operations. Reconciliation is *heuristic* (O(n)) and relies on two assumptions:
1. Elements of different types produce different subtrees.
2. The developer provides **keys** to identify list items.

**Keys — the single most important list concept:**

```tsx
// ❌ index keys: reordering/inserting causes wrong state to be reused
{incidents.map((inc, i) => <IncidentRow key={i} incident={inc} />)}

// ✅ stable identity: React matches items across renders correctly
{incidents.map((inc) => <IncidentRow key={inc.incident_id} incident={inc} />)}
```

With index keys, inserting an incident at the top shifts every index; React reuses DOM (and any internal state, like an expanded row) with the wrong data. **Use the stable `incident_id`.**

### 1.3 Components, props, and composition

A **component** is a function returning JSX. **Props** are inputs, flowing **down** (one-way data flow). **State** is internal, mutable via setters.

**Composition over configuration.** Rather than a mega-component with 20 boolean props, compose small components:

```tsx
<IncidentDetail incident={inc}>
  <IncidentTimeline events={inc.evidence} />
  <EvidenceSection evidence={inc.evidence} />
  <HypothesesSection hypotheses={inc.hypotheses} />
  <DiagnosticChecks checks={inc.diagnosticChecks} />
  <LifecycleControls status={inc.status} onAcknowledge={...} onResolve={...} />
</IncidentDetail>
```

Each piece is testable in isolation and understands one concept. This directly supports the required UI elements in the DevOps spec (timeline, evidence, hypotheses, missing evidence, checks, controls, states).

### 1.4 Hooks and the rules of state

Hooks (2019) let function components hold state and effects. The essentials:

- **`useState`** — a value + setter. Setting triggers a re-render. **Never mutate state directly**; always create new values (`setItems(prev => [...prev, x])`).
- **`useEffect`** — synchronize with external systems (subscriptions, DOM). It runs **after render**. **Not** for data fetching in a modern app (use a data-fetching library — §1.6).
- **`useMemo` / `useCallback`** — memoize expensive computations / stable function identities. Use sparingly; premature memoization adds complexity.
- **`useRef`** — a mutable box that does **not** trigger re-renders (timers, DOM refs).
- **Rules of Hooks:** only call hooks at the top level of components/custom hooks — never inside conditions or loops. The order must be identical every render, because React matches hooks by call order.

**The classic `useEffect` dependency trap:**

```tsx
// ❌ runs every render because a new object is created each time and is a dependency
useEffect(() => { fetchIncidents({ status }); }, [{ status }]);

// ✅ primitive dependency (or memoized object)
useEffect(() => { fetchIncidents(status); }, [status]);
```

**But the right answer for data fetching is a library** that manages caching, retries, deduplication, and loading/error states consistently — which is exactly what this dashboard needs.

### 1.5 TypeScript: the contract as a compile-time guarantee

TypeScript (Microsoft, 2012) adds static types to JS. Our motivation: the shared API contract should become a **compile-time** guarantee. If the API changes shape and the dashboard isn't updated, the build fails — not production.

Core tools you'll use:

- **Interfaces / type aliases** — describe shapes.
- **Generics** — parameterize types (`useIncidents<Incident>()`).
- **Discriminated unions** — model states precisely:
  ```ts
  type LoadState<T> =
    | { status: "idle" }
    | { status: "loading" }
    | { status: "error"; error: string }
    | { status: "success"; data: T };
  ```
  Then **narrow** with `switch (state.status)` and the compiler guarantees you handle every case (exhaustiveness).
- **`strict` mode** — turn it on. `strictNullChecks` alone prevents a huge class of bugs (the `null`/`undefined` handling that mirrors the backend's "missing is not zero" rule).

**Keep types in sync with the contract.** Two viable approaches:
1. **Generate types from `openapi.yaml`** (e.g., `openapi-typescript`) as a build step; commit the output; fail CI on drift (§2.7). This makes the contract the *single source of truth* end to end.
2. **Hand-write types** mirroring the spec, plus a contract test that validates sample API responses against the JSON Schema.

**Recommendation:** generate, because it's mechanical and catches drift. But keep the *semantic* rules (score ≠ probability) in review and tests, since no generator knows the meaning.

### 1.6 Server state vs. client state

A crucial distinction modern React developers must internalize:

| Server state | Client state |
|---|---|
| Lives on the server; can be stale | Lives only in the browser (filters, UI toggles) |
| Incidents, timelines, evidence | Which row is expanded; theme |
| Needs caching, revalidation, retries, dedup | Needs to be locally consistent |
| **Use a data-fetching library** (React Query/SWR) | `useState` / URL |

**React Query (TanStack Query)** and **SWR** give you: caching keyed by query, background revalidation, loading/error/empty states, retry with backoff, request deduplication, and pagination support (including cursors). Hand-rolling this with `useEffect` is where most dashboards accumulate bugs.

```tsx
const { data, status, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
  useInfiniteQuery({
    queryKey: ["incidents", { status: filterStatus, severity: filterSeverity }],
    queryFn: ({ pageParam }) => api.listIncidents({ status: filterStatus, cursor: pageParam }),
    getNextPageParam: (last) => last.next_cursor ?? undefined,
    initialPageParam: undefined,
  });
```

Notice: **the query key encodes the filters**, so changing a filter automatically refetches and caches a separate entry. This is server-state management done right.

### 1.7 State in the URL

Filters and pagination belong in the **URL** (`?status=open&severity=high&cursor=abc`), not only in component state. Why:
- **Shareable links** ("look at this incident list") — essential for an investigation tool.
- **Back/forward** work naturally.
- **Refresh** preserves context.
- The URL becomes a **serializable snapshot** of the view — the same discipline as the backend's deterministic state.

Use the router's search-params API (e.g., React Router's `useSearchParams`) as the source of truth; pass those values into your query keys.

### 1.8 Rendering untrusted log data safely (XSS)

**This is a security requirement, not a style choice.** Log messages are attacker-controlled (any process can write to a log). The spec requires "safe HTML/text rendering of log content."

**The rule: render log-derived text as text, never as HTML.**

```tsx
// ✅ React escapes text content automatically — safe by default
<span className="message">{event.message}</span>

// ❌ DANGER: executes attacker-controlled markup/scripts
<div dangerouslySetInnerHTML={{ __html: event.message }} />
```

**Defense in depth:**
- **Avoid `dangerouslySetInnerHTML` entirely** for log content. If you must render rich content, sanitize with a vetted library (DOMPurify) *and* use a strict allowlist — but for this project, **don't**.
- **Content Security Policy (CSP)** headers as a second layer: disallow inline scripts and untrusted origins.
- **Escape everywhere log strings appear** — evidence lines, timelines, tooltips, chart labels. A tooltip with `dangerouslySetInnerHTML` is just as dangerous as a main field.
- **Test it:** a component test that feeds `<script>alert(1)</script>` and asserts it renders as visible text (Module test list: "malicious markup in log messages renders as text").

⚠️ **The dashboard must never hold secrets.** No AWS keys, no collector tokens. API base URL only. Advanced: if the admin session is a cookie, remember **CORS + credentials** semantics (`credentials: "include"` and a specific origin, never `*`).

### 1.9 Visualizing honestly

Charts can lie. Since this dashboard's entire purpose is *trustworthy investigation*, chart honesty is a first-class requirement.

**Principles:**
- **Label the anomaly score as a score, never a probability.** `"Anomaly score (0.93)"` ✓ ; `"93% likely anomalous"` ✗.
- **Always show the baseline alongside observed values.** An anomalous-looking bar without a baseline is uninterpretable.
- **Don't truncate the y-axis** to exaggerate differences unless clearly stated (a classic misleading-chart technique). If you use a zoom, label it.
- **Consider log scale** for skewed data (latency) and **say so** on the axis.
- **Distinguish missing from zero** in charts: a gap should look like a gap, not a zero bar. (Straight from the backend's "missing is not zero" rule.)
- **Show uncertainty and cold start**: "warming up (12/30 samples)" rather than an empty chart implying calm.
- **Evidence links are visible**: clicking a data point should lead to the supporting event IDs.

**Timeline rendering:** a timeline shows events (or anomalies) along time, often as a lane per host/service. Libraries: **Recharts** (React-friendly, declarative), **visx** (lower-level), **D3** (max control, steeper curve), or even a plain SVG for a simple incident timeline. Start simple; add complexity only when needed.

### 1.10 Accessibility, performance, and testing

**Accessibility (a11y):** an investigation tool is used under stress; accessibility is usability.
- Semantic HTML (`<table>`, `<button>`, `<nav>`), not `div`-soup.
- **Labels** on controls; **focus management** when opening a detail view.
- **ARIA live regions** for async states (`aria-live="polite"` on loading/status) so screen readers announce updates.
- **Color is not the only signal**: severity shown by text + icon + color (color-blind users).
- **Keyboard navigation** for lists and controls.

**Performance:** incident lists can be long.
- **Virtualize** long lists (`react-window`/`react-virtual`) so only visible rows render.
- **Memoize** rows (`React.memo`) if profiling shows re-render cost; measure first (`React DevTools Profiler`).
- **Paginate** server-side (cursor) rather than loading everything.

**Testing:**
- **Component tests** with **React Testing Library** — assert on what the user sees (`getByText`, `getByRole`), not implementation details.
- **Network mocking** with **MSW (Mock Service Worker)** — intercept fetch/XHR and return contract-valid fixtures. This keeps tests fast and realistic, and reuses the same fixtures as the backend (cross-team parity).
- Test **loading/error/empty** states explicitly, plus the **XSS** case and **lifecycle** actions.

### 1.11 Configuration and security of the deployed bundle

- **API base URL by environment** (build-time env var like `VITE_API_BASE_URL`). **No secrets in the bundle** — anything in a frontend bundle is public.
- **CORS** must allow the dashboard origin; never `*` with credentials.
- **CSP** headers (via hosting config: S3+CloudFront response headers policy) to reduce XSS impact.
- **Subresource Integrity / pinned deps** where applicable; keep the dependency tree lean and audited.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Generated types from the contract

```bash
# generate TS types from the canonical OpenAPI (commit the result; fail CI on drift)
npx openapi-typescript ../contracts/openapi.yaml -o src/api/schema.d.ts
```

```ts
// src/api/types.ts
import type { components } from "./schema";
export type Incident = components["schemas"]["Incident"];
export type IncidentEvent = components["schemas"]["Event"];
export type Severity = "low" | "medium" | "high" | "critical";
```

**Walkthrough:** the dashboard now shares the contract's *type* truth. If a field is renamed in `openapi.yaml` and regenerated, the build fails wherever it's used.

### 2.2 A typed API client

```ts
// src/api/client.ts
import type { Incident } from "./types";

const BASE = import.meta.env.VITE_API_BASE_URL;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    credentials: "include",                 // admin session cookie
    headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ApiError(res.status, body?.error?.code ?? "unknown", body?.error?.message ?? res.statusText);
  }
  return res.json() as Promise<T>;
}

export const api = {
  listIncidents: (p: { status?: string; severity?: string; cursor?: string; limit?: number }) => {
    const qs = new URLSearchParams(Object.entries(p).filter(([, v]) => v != null) as [string,string][]);
    return request<{ items: Incident[]; next_cursor: string | null }>(`/api/v1/incidents?${qs}`);
  },
  getIncident: (id: string) => request<Incident>(`/api/v1/incidents/${encodeURIComponent(id)}`),
  acknowledge: (id: string) => request<void>(`/api/v1/incidents/${encodeURIComponent(id)}/acknowledge`, { method: "POST" }),
  resolve: (id: string) => request<void>(`/api/v1/incidents/${encodeURIComponent(id)}/resolve`, { method: "POST" }),
  health: () => request<{ status: string; version: string }>(`/api/v1/health`),
};

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
```

**Walkthrough:** a single `request` wrapper handles errors uniformly (matching `api-errors.schema.json`), and `credentials: "include"` carries the admin session. Typed return values keep components honest.

### 2.3 Incident list with URL state, pagination, and all three states

```tsx
// src/features/incidents/IncidentList.tsx
import { useSearchParams } from "react-router-dom";
import { useInfiniteQuery } from "@tanstack/react-query";
import { api } from "../../api/client";
import { SeverityBadge } from "./SeverityBadge";
import { Spinner, ErrorState, EmptyState } from "../../components/states";

export function IncidentList() {
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? undefined;
  const severity = params.get("severity") ?? undefined;

  const query = useInfiniteQuery({
    queryKey: ["incidents", { status, severity }],
    queryFn: ({ pageParam }) => api.listIncidents({ status, severity, cursor: pageParam }),
    getNextPageParam: (last) => last.next_cursor ?? undefined,
    initialPageParam: undefined as string | undefined,
  });

  if (query.status === "pending") return <Spinner label="Loading incidents…" />;
  if (query.status === "error")   return <ErrorState error={query.error} onRetry={() => query.refetch()} />;

  const items = query.data.pages.flatMap((p) => p.items);
  if (items.length === 0) return <EmptyState message="No incidents match these filters." />;

  return (
    <section aria-label="Incidents">
      <Filters
        status={status} severity={severity}
        onChange={(next) => setParams(cleanParams(next))}   // URL is the source of truth
      />
      <table>
        <thead>
          <tr><th>Severity</th><th>Summary</th><th>Entity</th><th>Status</th><th>Created (UTC)</th></tr>
        </thead>
        <tbody>
          {items.map((inc) => (
            <tr key={inc.incident_id}>                       {/* stable key */}
              <td><SeverityBadge severity={inc.severity} /></td>
              <td><Link to={`/incidents/${inc.incident_id}`}>{inc.summary}</Link></td>
              <td>{inc.affected_entities[0]?.host}</td>
              <td>{inc.status}</td>
              <td>{new Date(inc.created_at).toISOString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {query.hasNextPage && (
        <button onClick={() => query.fetchNextPage()} disabled={query.isFetchingNextPage}>
          {query.isFetchingNextPage ? "Loading more…" : "Load more"}
        </button>
      )}
    </section>
  );
}

function cleanParams(next: Record<string, string | undefined>) {
  const p = new URLSearchParams();
  Object.entries(next).forEach(([k, v]) => v && p.set(k, v));
  return p;
}
```

**Walkthrough:** filters live in **URL search params** (shareable, refresh-safe); React Query caches per filter combination; **all three states** (loading/error/empty) are rendered; keys are stable IDs. This is the reference implementation for the required list screen.

### 2.4 Incident detail: evidence rendered safely + honest semantics

```tsx
// src/features/incidents/IncidentDetail.tsx
import type { Incident } from "../../api/types";

export function IncidentDetail({ incident }: { incident: Incident }) {
  return (
    <article aria-labelledby="inc-title">
      <h1 id="inc-title">{incident.summary}</h1>

      {/* HONEST labels: score is a score, not a probability */}
      <dl className="meta">
        <dt>Severity</dt><dd>{incident.severity}</dd>
        <dt>Detector</dt><dd>{incident.detector}</dd>
        <dt>Anomaly score</dt>
        <dd title="Detector-specific measure, not a probability">{incident.anomaly_score.toFixed(3)}</dd>
        <dt>Model versions</dt>
        <dd>{Object.entries(incident.model_versions).map(([k, v]) => `${k}:${v}`).join(", ") || "n/a"}</dd>
        <dt>Window (UTC)</dt><dd>{incident.windows?.[0]?.start} → {incident.windows?.[0]?.end}</dd>
      </dl>

      <IncidentTimeline incident={incident} />
      <EvidenceSection evidence={incident.evidence} />
      <HypothesesSection hypotheses={incident.hypotheses} />
      <DiagnosticChecks checks={incident.diagnostic_checks} />
      <LifecycleControls incident={incident} />
    </article>
  );
}

function EvidenceSection({ evidence }: { evidence: Incident["evidence"] }) {
  return (
    <section aria-label="Evidence">
      <h2>Supporting evidence ({evidence.supporting_event_ids.length})</h2>
      <ul>
        {evidence.supporting_event_ids.map((id) => (
          <li key={id}><code>{id}</code></li>
        ))}
      </ul>
      {evidence.contradicting_event_ids.length > 0 && (
        <>
          <h2>Contradicting evidence ({evidence.contradicting_event_ids.length})</h2>
          <ul>{evidence.contradicting_event_ids.map((id) => <li key={id}><code>{id}</code></li>)}</ul>
        </>
      )}
    </section>
  );
}

function HypothesesSection({ hypotheses }: { hypotheses: Incident["hypotheses"] }) {
  return (
    <section aria-label="Hypotheses">
      <h2>Hypotheses</h2>
      {hypotheses.map((h, i) => (
        <article key={i}>
          <p><strong>{h.statement}</strong> <em>(confidence: {h.confidence})</em></p>
          <p>Supported by: {h.supporting_event_ids.join(", ") || "—"}</p>
          <p>Contradicted by: {h.contradicting_event_ids.join(", ") || "—"}</p>
          {h.missing_evidence.length > 0 && (
            <p className="missing">Missing evidence: {h.missing_evidence.join(" ")}</p>
          )}
        </article>
      ))}
      {hypotheses.length === 0 && <p>No hypotheses formed. <strong>Unknown</strong> is a valid outcome.</p>}
    </section>
  );
}

function DiagnosticChecks({ checks }: { checks: Incident["diagnostic_checks"] }) {
  return (
    <section aria-label="Recommended diagnostic checks">
      <h2>Recommended checks <span className="hint">(suggestions only — nothing is executed)</span></h2>
      <ol>
        {checks.map((c, i) => (
          <li key={i}>
            {/* log-derived text rendered as TEXT, never HTML */}
            <span>{c.instruction}</span>
            {c.evidence_links?.length ? <small> (evidence: {c.evidence_links.join(", ")})</small> : null}
          </li>
        ))}
      </ol>
    </section>
  );
}
```

**Walkthrough:** every honesty rule appears as UI:
- **"Anomaly score"** labeled as a score, with a tooltip disclaiming probability.
- Diagnostics clearly marked **"nothing is executed"** (the `executes:false` semantic).
- **Contradicting evidence** and **missing evidence** shown — not hidden.
- **"Unknown is a valid outcome"** surfaced when no hypotheses exist.
- All log-derived text is rendered as text (no `dangerouslySetInnerHTML`).

### 2.5 Lifecycle controls with optimistic update guarded by server truth

```tsx
// src/features/incidents/LifecycleControls.tsx
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../../api/client";

export function LifecycleControls({ incident }: { incident: { incident_id: string; status: string } }) {
  const qc = useQueryClient();
  const ack = useMutation({
    mutationFn: () => api.acknowledge(incident.incident_id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["incident", incident.incident_id] }),
  });
  const resolve = useMutation({
    mutationFn: () => api.resolve(incident.incident_id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["incident", incident.incident_id] }),
  });

  return (
    <div role="group" aria-label="Lifecycle actions">
      <button onClick={() => ack.mutate()} disabled={incident.status !== "open" || ack.isPending}>
        {ack.isPending ? "Acknowledging…" : "Acknowledge"}
      </button>
      <button onClick={() => resolve.mutate()} disabled={incident.status === "resolved" || resolve.isPending}>
        {resolve.isPending ? "Resolving…" : "Resolve"}
      </button>
      {(ack.isError || resolve.isError) && <p role="alert">Action failed. Please retry.</p>}
    </div>
  );
}
```

**Walkthrough:** mutations invalidate the incident query so the UI re-renders from **server truth** (including the audit entry the server wrote). We avoid pure optimism for lifecycle state because the server is the authority on audit and transitions; invalidate-and-refetch is simpler and correct.

### 2.6 An honest timeline component

```tsx
// src/features/incidents/IncidentTimeline.tsx
import type { Incident } from "../../api/types";

export function IncidentTimeline({ incident }: { incident: Incident }) {
  const window = incident.windows?.[0];
  if (!window) return null;
  const start = Date.parse(window.start), end = Date.parse(window.end);
  const span = Math.max(end - start, 1);

  return (
    <section aria-label="Incident timeline">
      <h2>Timeline</h2>
      <div className="timeline" role="img"
           aria-label={`Anomaly window from ${window.start} to ${window.end} UTC`}>
        {(incident.anomalies ?? []).map((a, i) => {
          const t = Date.parse(a.at);
          const pct = Math.min(100, Math.max(0, ((t - start) / span) * 100));
          return (
            <div key={i} className="marker" style={{ left: `${pct}%` }}
                 title={`${a.feature}: observed ${a.observed} vs baseline ${a.baseline}`}>
              <span>{a.feature}</span>
            </div>
          );
        })}
      </div>
      <p className="axis-note">
        Window {window.start} → {window.end} UTC. Baseline and observed values shown on hover.
      </p>
    </section>
  );
}
```

**Walkthrough:** the timeline shows the window, plots anomaly markers, and **always shows observed vs. baseline** (via `title`). The axis note names the timezone and the comparison — no unlabeled, misleading visuals. Missing data would be rendered as a **gap**, not a zero (per §1.9).

### 2.7 Contract-parity and XSS tests

```tsx
// src/features/incidents/__tests__/IncidentDetail.test.tsx
import { render, screen } from "@testing-library/react";
import { http, HttpResponse } from "msw";
import { setupServer } from "msw/node";
import { QueryClientProvider, QueryClient } from "@tanstack/react-query";
import { IncidentDetail } from "../IncidentDetail";
import fixture from "../../../../contracts/fixtures/valid/incident_open.json";

const server = setupServer(
  http.get("*/api/v1/incidents/*", () => HttpResponse.json(fixture)),
);

beforeAll(() => server.listen());
afterEach(() => server.resetHandlers());
afterAll(() => server.close());

test("renders anomaly score as a score, not a probability", () => {
  render(<Wrapper><IncidentDetail incident={fixture} /></Wrapper>);
  expect(screen.getByText("Anomaly score")).toBeInTheDocument();
  expect(screen.queryByText(/probability|%/i)).not.toBeInTheDocument();
});

test("malicious markup in a log message renders as text", () => {
  const evil = { ...fixture, diagnostic_checks: [
    { instruction: "<script>alert('xss')</script>", evidence_links: [], executes: false }]};
  render(<Wrapper><IncidentDetail incident={evil} /></Wrapper>);
  // The script payload is visible as text and NOT executed
  expect(screen.getByText("<script>alert('xss')</script>")).toBeInTheDocument();
  expect(document.querySelector("script")).toBeNull();
});

test("shows 'Unknown is a valid outcome' when there are no hypotheses", () => {
  const inc = { ...fixture, hypotheses: [] };
  render(<Wrapper><IncidentDetail incident={inc} /></Wrapper>);
  expect(screen.getByText(/Unknown is a valid outcome/i)).toBeInTheDocument();
});
```

**Walkthrough:** the XSS test asserts both that the payload is visible as text **and** that no `<script>` element exists in the DOM — proving React's escaping held. The fixtures come from the shared `contracts/fixtures/` directory — **the same fixtures the backend uses** — giving cross-team parity.

### 2.8 Environment config and build

```ts
// vite.config.ts (excerpt)
import { defineConfig } from "vite";
export default defineConfig({
  build: { sourcemap: true, outDir: "dist" },
});
```

```bash
# .env.local (NOT committed)
VITE_API_BASE_URL=http://localhost:8080
```

```bash
npm run build   # produces dist/, no secrets inside (verify!)
```

**Verification step:** grep the built bundle for `AWS_`, `SECRET`, `TOKEN` — there should be none. CI can assert this.

---

## 3. Common Pitfalls & Debugging

### 3.1 Index keys on lists

Reordering/insertion reuses wrong DOM/state. **Fix:** stable `incident_id` keys (or event IDs).

### 3.2 Mutating state

`incidents.push(x)` doesn't re-render and hides bugs. **Fix:** immutable updates (`setItems(prev => [...prev, x])`).

### 3.3 `useEffect` data fetching

Hand-rolled fetching drifts into race conditions, stale state, and inconsistent loading. **Fix:** React Query/SWR with query keys. Reserve `useEffect` for genuine external synchronization.

### 3.4 Stale-closure in effects

An effect capturing an old value (e.g., a filter) never updates. **Fix:** include dependencies, or better, move logic into a query key that changes with the filter.

### 3.5 `dangerouslySetInnerHTML` on log data

Instant XSS. **Fix:** render as text; add a CSP; test with `<script>` payloads. Also beware *tooltips* and chart labels.

### 3.6 Calling the score a probability

A UI copy bug that violates a project rule. **Fix:** wording "anomaly score"; test with a query asserting no "%"/"probability" near the score.

### 3.7 Chart lies

Truncated y-axes, missing baseline, zeros for missing data. **Fix:** show baselines, label axes/timezones, gaps for missing, or note the zoom.

### 3.8 Long lists killing performance

Rendering 10,000 rows freezes the tab. **Fix:** server pagination + virtualized rows; profile before optimizing.

### 3.9 CORS/credential confusion

`credentials: "include"` with `AllowOrigins: *` fails silently. **Fix:** explicit origin + `AllowCredentials: true`; verify in local and AWS modes.

### 3.10 Secrets in the bundle

Any `VITE_*` value is public. **Fix:** only non-secret config in frontend env; grep the build in CI.

### 3.11 Date/timezone display bugs

Displaying local time without saying so confuses correlation. **Fix:** display UTC explicitly (`.toISOString()` or labeled) and be consistent with the backend.

### 3.12 Accessibility regressions

Div-based buttons, unlabeled filters, color-only severity. **Fix:** semantic elements, labels, ARIA for async states, icon+text+color for severity.

### 3.13 Debugging toolkit

```bash
npm run dev                       # Vite HMR
npm run build && npx vite preview # production preview
npm test                          # jest/vitest
npx tsc --noEmit                  # type-check only
npx eslint . --max-warnings=0     # lint
npx openapi-typescript ../contracts/openapi.yaml -o src/api/schema.d.ts  # regen types (drift check)
```

- **React DevTools** — inspect component tree, props, and re-render highlights (Profiler).
- **TanStack Query DevTools** — see query keys, cache state, and refetch behavior; invaluable when data "doesn't update."
- **MSW** — reproduce any API state (error, empty, slow) deterministically in tests and in dev.
- **axe DevTools / eslint-plugin-jsx-a11y** — catch accessibility issues early.

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"The Road to React" — Robin Wieruch.** Modern hooks-based React from scratch; read the sections on state, effects, lists/keys, and data fetching.
- **"Fluent React" — Tejas Kumar.** Deeper React mental models: reconciliation, rendering behavior, and the "why" behind the rules (§1.2, §1.4).
- **"Learning React" (2nd ed.) — Banks & Porcello.** Hooks and functional patterns.
- **"Effective TypeScript" — Dan Vanderkam.** Items on discriminated unions, narrowing, and `strict` mode — directly §1.5.
- **"Programming TypeScript" — Boris Cherny.** Generics and type-level thinking.
- **"Refactoring UI" — Wathan & Schoger.** Practical visual design for developer-built UIs (badges, tables, hierarchy) — improves the dashboard's usability.
- **"Web Accessibility Cookbook" — Manuel Matuzović.** Semantic HTML, focus management, ARIA — §1.10.
- **"Inclusive Components" — Heydon Pickering.** Pattern-level accessibility for real components.

### 4.2 Papers, docs & standards

- **React official docs (react.dev)** — read *Describing the UI*, *Adding Interactivity*, *Managing State*, and especially *You Might Not Need an Effect* and *Rules of Hooks*.
- **TanStack Query docs** — "Overview", "Queries", "Infinite Queries", and "Caching" (the server-state model in §1.6).
- **MDN Web Docs — CORS, Fetch, Content Security Policy.** The browser-security primitives.
- **OWASP — Cross Site Scripting Prevention Cheat Sheet** and **DOM based XSS Prevention Cheat Sheet.** The authoritative XSS guidance behind §1.8.
- **WAI-ARIA Authoring Practices Guide (APG)** — patterns for tables, dialogs, and live regions.
- **web.dev — "Learn Performance", "Core Web Vitals".** Rendering performance fundamentals.
- **"openapi-typescript" docs** — the generation approach in §1.5/§2.1.

### 4.3 Videos, talks, courses

- **Dan Abramov — "Overreacted" blog and his React talks** (especially the "mental model" and "algebraic effects" style pieces); the definitive explanation of why hooks work the way they do.
- **Kent C. Dodds — Testing JavaScript / React Testing Library courses (YouTube + his site)** — the testing philosophy in §1.10.
- **TkDodo (Dominik Dorfmeister) — React Query blog series ("Practical React Query").** The best practical guide to server-state management.
- **Theo (t3.gg) and Jack Herrington (YouTube)** — modern React/TypeScript patterns (filter critically; trends move fast).
- **Fireship (YouTube)** — rapid conceptual overviews (good for orientation, not depth).
- **React Conf talks on the React Compiler and concurrent rendering** — where React is heading; useful for future-proofing.

### 4.4 Exercises to internalize this module

1. Generate TS types from `openapi.yaml` and type the API client; break the contract in a scratch branch and confirm the build fails.
2. Build the incident list with URL-driven filters, cursor pagination, and explicit loading/error/empty states.
3. Build the incident detail with timeline, supporting **and** contradicting evidence, hypotheses, missing evidence, and non-executing checks.
4. Write the XSS test: `<script>` in a log message renders as text and creates no `<script>` element.
5. Write a test asserting the score is labeled a score and that no "probability"/"%" copy appears near it.
6. Add the "Unknown is a valid outcome" state and its test.
7. Add MSW-backed component tests for lifecycle actions and error states.
8. Run `axe` and fix every accessibility violation on the list and detail screens.
9. Verify the built bundle contains no secrets; add a CI grep.

---

## 🎓 Closing the Curriculum

You've now walked the full stack this project demands:

| Module | You can now… |
|---|---|
| 1 | Engineer typed, deterministic, boundary-respecting Python |
| 2 | Author and enforce contracts with schema, OpenAPI, and tests |
| 3 | Collect and parse real Linux/Windows logs safely |
| 4 | Detect with robust, transparent baselines and correlate with evidence |
| 5 | Use Isolation Forest honestly and evaluate detectors rigorously |
| 6 | Deploy the same core to a least-privilege serverless AWS stack |
| 7 | Render incidents truthfully, safely, and accessibly |

**The thread through all seven:** *transparent, evidence-backed, and honest.* The system detects without an LLM, explains with templates and evidence, separates score from probability and severity, guards its own baselines, and never claims what it did not verify. That is the standard these materials exist to protect.
