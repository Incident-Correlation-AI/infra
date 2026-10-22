# 📚 Learning Module 1 — Python Engineering for Reliable Backend Pipelines

> **Module goal:** Take a capable Python programmer and make them fluent in the *engineering* practices this project demands: typed domain models, clean package boundaries, reproducible environments, and a test suite that runs the same way on a laptop and in CI.
> **Project tie-in:** You will build `src/lad/` — the shared core that both the AWS worker and the local worker run unchanged.

**Estimated study time:** 25–35 hours (read + exercises). **Prereq:** comfortable with functions, classes, dicts, and `pip`.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 What "backend engineering" actually means in Python
   - 1.2 The Python execution model (bytecode, the GIL, imports)
   - 1.3 Packaging & environments: from `setup.py` to `pyproject.toml`
   - 1.4 The type system: annotations, `typing`, structural vs. nominal typing
   - 1.5 Data modeling: `dataclass`, `NamedTuple`, pydantic — and when to use which
   - 1.6 Boundaries and dependency direction (Ports & Adapters in Python)
   - 1.7 Errors, results, and failure discipline
   - 1.8 Testing philosophy: fixtures, parametrization, property-based tests
   - 1.9 Concurrency: threads vs. async vs. processes — what this project needs
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 What "backend engineering" actually means in Python

Writing Python that runs is easy. Writing Python that **runs the same way in three environments, survives a restart, and can be handed to another engineer** is a different discipline. This project sharpens three axes:

1. **Determinism.** Detection results and evaluation metrics must be reproducible. That means fixed seeds, explicit clock injection, and no reliance on wall-clock time or dict iteration order in scoring paths.
2. **Boundary integrity.** The shared core (`src/lad/`) must run locally with *no AWS credentials*. If any cloud SDK leaks into it, local mode breaks. Boundaries are enforced by tests, not by good intentions.
3. **Failure discipline.** A pipeline has *rejectable* inputs (bad schema) and *retryable* failures (queue down). These require different code paths. Conflating them is how messages get silently lost — the cardinal sin in this project ("Do not lose a message silently after logging an exception").

Everything below is in service of those three axes.

#### Historical context

Python's rise in backend work tracks two waves. The first (roughly 2005–2012) was WSGI + frameworks like Django and Flask: synchronous, thread-pool-per-request. The second (2015–present) is `asyncio`, type hints (PEP 484, 2014), and data-validation libraries like pydantic. The project stack (FastAPI, pytest, JSON Schema, pydantic-style models) sits squarely in the second wave. Understanding *why* type hints arrived helps: they began as documentation ("gradual typing") and grew into runtime machinery — FastAPI reads annotations to build validation and OpenAPI, so annotations are now **executable contracts**, not comments.

> 💡 **Key mental shift:** In modern Python, a type annotation is not just for the reader. Frameworks inspect it. A wrong annotation is a runtime bug.

### 1.2 The Python execution model

#### Bytecode and the interpreter

Python source is compiled to **bytecode** for a stack-based virtual machine. You can see it with `dis`:

```python
import dis
def is_retryable(status: int) -> bool:
    return status in (408, 429) or 500 <= status < 600

dis.dis(is_retryable)
```

You'll see `LOAD_FAST`, `LOAD_CONST`, `CONTAINS_OP`, `COMPARE_OP`, `RETURN_VALUE`. This matters because *hot loops in scoring code* execute bytecode per iteration; vectorizing with numpy (module 4/5) or reducing allocations is a real optimization. This project's per-event work is small, but per-window feature computation over thousands of events is where bytecode cost accumulates.

#### CPython's GIL, 1990s through today

CPython (the reference implementation) has a **Global Interpreter Lock**: only one thread executes Python bytecode at a time. Consequences for this project:

- A collector reading journald on a background thread and flushing on another **will not parallelize CPU work**, but it *will* overlap I/O waits (journald reads, HTTP sends), which is exactly what a collector does — so threads are fine there.
- A worker computing features for many windows in parallel with threads will **not** go faster for pure-Python math. Use processes (`multiprocessing`/`concurrent.futures.ProcessPoolExecutor`) or numpy (which releases the GIL in C loops).
- Since Python 3.13 there's an experimental **free-threaded** build (PEP 703) and, separately, an experimental **JIT** (PEP 744). Treat these as *verify-before-adopt*; the project's rule is "pin what you test."

⚠️ **Pitfall preview:** the GIL is *not* protected by locking around your data structures automatically. Two threads doing `counter += 1` can lose an update. Use `itertools`/locks or a queue. We'll revisit.

#### Imports: the thing that bites cloud packaging

An `import` executes module-level code and caches the module in `sys.modules`. Three consequences:

1. **Import cost = cold-start cost** in Lambda. Importing `sklearn` at module top adds hundreds of milliseconds (or more) even when the Isolation Forest experiment is disabled. **Lazy-import inside the code path that needs it**, and keep the shared core's import graph tiny.
2. **Import side effects are real side effects.** Module-level AWS client construction (`boto3.client("dynamodb")`) happens at import time, which breaks local mode and makes tests need credentials. Construct clients inside functions, or behind factories.
3. **Circular imports** happen when modules import each other at top level. The fix is usually a boundary fix (move a shared type to a `types`/`contracts` module), not a hack.

```python
# ❌ cloud SDK at module scope → breaks local mode, bloats cold start
import boto3
_client = boto3.client("dynamodb")   # runs at import, even in local mode

# ✅ lazy, injected, and local-safe
def make_store(mode: str) -> "StorePort":
    if mode == "aws":
        import boto3                     # imported only in the AWS path
        return DynamoStore(boto3.resource("dynamodb"))
    return LocalStore(path=".lad/store")
```

### 1.3 Packaging & environments

#### The pre-`pyproject` era and why it ended

For years Python packaging had `setup.py` (executable, imperative) and `requirements.txt` (unpinned, drift-prone). PEP 517/518/621 introduced `pyproject.toml` as the single declarative source, and tools like `pip` (≥21.3), `uv`, `poetry`, `hatchling` consume it. This project uses **`pyproject.toml`** (required by the DevOps spec).

```toml
# pyproject.toml (illustrative; pins must be verified during setup)
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "lad"
version = "0.1.0"
requires-python = ">=3.11"          # verify against library support, then pin tightly
dependencies = [
    # keep the *core* dependencies minimal — this package must import fast and run locally
]

[project.optional-dependencies]
api      = ["fastapi", "uvicorn", "pydantic"]
detector = ["numpy", "scikit-learn"]
aws      = ["boto3"]
dev      = ["pytest", "pytest-cov", "jsonschema", "openapi-spec-validator", "ruff", "mypy"]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.pytest.ini_options]
addopts = "-q --strict-markers"
testpaths = ["tests"]

[tool.mypy]
strict = true
```

**Why separate extras?** The `detector` extra pulls heavy numeric libraries; `aws` pull `boto3`. A collector install should not need `scikit-learn`. Optional dependencies let each deployment surface stay lean — directly serving the cold-start and boundary goals.

#### Environment reproducibility

- **Virtual environments** isolate dependencies per project. Always create one; never install project deps into the system interpreter.
- **Lock everything.** A `pyproject.toml` expresses ranges; a lock file (e.g., `uv.lock`, `poetry.lock`, or a fully pinned `requirements.txt` generated from it) expresses *exact* versions. CI and Lambda should install from the lock, not the ranges — otherwise "works on my machine" becomes "works on my Tuesday."
- **Document the Python version** only *after* verifying the journald binding, Windows Event Log library, scikit-learn, and FastAPI all support it.

> 💡 **Tip:** `python -m venv .venv && source .venv/bin/activate` is the boring, reliable path. Tools like `uv` are much faster and this project welcomes them, but the *artifact* (a lock file + documented version) is what matters, not the tool.

### 1.4 The type system

#### Annotations are runtime-accessible objects

```python
from typing import get_type_hints
from dataclasses import dataclass
from datetime import datetime

@dataclass(frozen=True)
class Window:
    start: datetime
    seconds: int

# get_type_hints(Window) -> {'start': datetime, 'seconds': int}
```

Frameworks like FastAPI call `get_type_hints` to build validators and OpenAPI. So:

- Use precise types (`datetime`, not `str`, for timestamps).
- Prefer `datetime` with explicit timezone handling; a bare `datetime` annotation does **not** guarantee tz-awareness — that's a runtime check you must implement (see §2.3).
- Model optionality explicitly: `str | None`, never "sometimes missing."

#### Nominal vs. structural typing

`Protocol` gives **structural typing**: a class satisfies the protocol if it has the right methods, no explicit inheritance needed. This is how we keep cloud SDKs out of the core.

```python
from typing import Protocol, Sequence
from datetime import datetime

class ClockPort(Protocol):
    def now(self) -> datetime: ...

class StorePort(Protocol):
    def get_baseline(self, key: str) -> "BaselineState | None": ...
    def put_baseline(self, key: str, state: "BaselineState") -> None: ...
    def record_processed_ids(self, ids: Sequence[str]) -> None: ...
```

The core imports `ClockPort`/`StorePort` (which have **zero dependencies**). AWS and local adapters *implement* them. Because the core never imports the adapters, local mode cannot accidentally require AWS. This is Ports & Adapters (hexagonal architecture) expressed with `Protocol`.

> ⚠️ **Pitfall:** `Protocol` is checked statically by mypy, not at runtime (unless you use `@runtime_checkable`, which only checks method *names*, not signatures). Don't rely on `isinstance` for behavioral correctness.

#### Generics and `Result`

A typed `Result` makes the "rejectable vs. retryable" distinction visible in signatures:

```python
from dataclasses import dataclass
from typing import Generic, TypeVar, Union

T = TypeVar("T"); E = TypeVar("E")

@dataclass(frozen=True)
class Ok(Generic[T]):
    value: T

@dataclass(frozen=True)
class Err(Generic[E]):
    error: E

Result = Union[Ok[T], Err[E]]

def parse_ts(raw: str) -> Result[datetime, str]:
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return Err("invalid_timestamp")
    if dt.tzinfo is None:
        return Err("naive_timestamp")
    return Ok(dt)
```

`Ok`/`Err` are orthogonal to exceptions: `Err` means "this input cannot be processed" (a **rejection**, counted as a metric), while an exception means "something unexpected happened" (potentially **retryable**). Keeping them distinct prevents the classic bug where a malformed event throws and causes an entire batch to retry forever.

### 1.5 Data modeling: `dataclass` vs. `NamedTuple` vs. pydantic

| Tool | Best for | Cost | This project |
|---|---|---|---|
| `NamedTuple` | immutable record, cheap, tuple behavior | can't add methods easily; structural tuple surprises | internal tuples (e.g., `EntityKey`) |
| `@dataclass(frozen=True, slots=True)` | immutable domain objects, low overhead | no validation | core value objects (`Event`, `FeatureVector`) |
| pydantic `BaseModel` | **boundary** validation & (de)serialization | runtime cost; not in core hot path | API request/response models |
| plain `dict` | truly dynamic data | no safety | never for domain objects |

**Rule for this project:** validate at the **boundary** (API ingress) with pydantic/JSON Schema; convert to frozen dataclasses for the **core**. The core trusts its typed inputs, which keeps the hot path fast and dependency-light.

```python
from dataclasses import dataclass, field
from datetime import datetime
from typing import Mapping, Any

@dataclass(frozen=True, slots=True)
class Event:
    schema_version: str
    event_id: str
    event_ts: datetime                 # tz-aware UTC, enforced by a factory
    observed_ts: datetime
    host: str
    source: str
    category: str
    type: str
    severity: str
    message: str
    service: str | None = None
    template: str | None = None
    attributes: Mapping[str, Any] = field(default_factory=dict)
    trace_id: str | None = None
    request_id: str | None = None
    depends_on: tuple[str, ...] = ()
    evidence_ref: str | None = None
```

**`frozen=True`** prevents accidental mutation — crucial because the same event object flows through several pipeline steps; a mutation in step 5 that changes step 6's input is a nightmare to debug. **`slots=True`** reduces memory (important when buffering thousands of events) and prevents typo-attribute assignment.

⚠️ **`slots=True` + default values gotcha (pre-3.10 behavior):** with `slots=True`, a mutable default like `{}` is fine because `field(default_factory=...)` is used, but *shared* mutable defaults are a classic bug. Always use `default_factory=dict` for mappings.

### 1.6 Boundaries and dependency direction

The architecture's most load-bearing rule, restated as a **dependency rule**:

```
        contracts ◄── normalize ◄── features ◄── detection ◄── correlate
             ▲                                              │
             └──────────────── ports ◄──────────────────────┘
             ▲
   adapters/local        adapters/aws        services/*
```

Arrows mean "imports." Nothing in the left column imports anything cloud-specific. Enforce mechanically:

```python
# tests/architecture/test_boundaries.py
import ast, pathlib

def imports_in(pkg: str) -> set[str]:
    found = set()
    for path in pathlib.Path(pkg).rglob("*.py"):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                found.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                found.add(node.module.split(".")[0])
    return found

def test_core_has_no_cloud_deps():
    banned = {"boto3", "botocore", "aws_lambda_powertools"}
    leaked = imports_in("src/lad") & banned
    assert not leaked, f"cloud imports leaked into core: {leaked}"
```

This single test protects the "local mode without AWS credentials" acceptance gate far more reliably than code review.

### 1.7 Errors, results, and failure discipline

Define an error taxonomy **once** and use it everywhere:

```python
class LadError(Exception): ...
class RetryableError(LadError): ...        # queue unavailable, transient AWS error
class FatalError(LadError): ...            # poison message, invariant violated
class RejectionError(LadError): ...        # input cannot be processed (schema/size)
```

**Rules:**
- **Rejections** are values (`Err(...)`), counted as metrics, and never retried. A bad timestamp should not retry 5 times and land in the DLQ — it should be rejected once with a reason.
- **RetryableError** bubbles to the queue layer, which retries with backoff and eventually DLQs.
- **FatalError** should be rare; it means a bug or invariant violation. It goes to the DLQ immediately (no infinite loop).
- **Never** catch broad `except Exception: pass`. That is how messages vanish silently.

```python
def process_record(record, *, pipeline, queue, store, clock):
    try:
        batch = decode(record.body)
        results = pipeline.process(batch, clock=clock)     # returns Ok/Err per event
        accepted_ids = [r.value.event_id for r in results if isinstance(r, Ok)]
        store.record_processed_ids(accepted_ids)           # durable BEFORE ack
        queue.ack(record)
    except RetryableError as e:
        metrics.inc("retryable", type(e).__name__)
        queue.nack(record, retryable=True)
    except FatalError as e:
        metrics.inc("fatal", type(e).__name__)
        queue.nack(record, retryable=False)                # straight to DLQ
```

### 1.8 Testing philosophy

The project mandates eight test layers. In Python, the tools are `pytest` (fixtures, parametrize, plugins) plus property-based testing (`hypothesis`) where invariants matter.

**Fixtures as composition.** `conftest.py` provides `clock`, `store`, `pipeline`, `seed` fixtures. Local adapters make 95% of tests fast and credential-free.

```python
# tests/conftest.py
import pytest
from datetime import datetime, timezone
from lad.ports import ClockPort
from lad.adapters.local import LocalStore

class FixedClock:
    def __init__(self, t): self._t = t
    def now(self): return self._t

@pytest.fixture
def clock():
    return FixedClock(datetime(2026, 10, 17, 10, 15, tzinfo=timezone.utc))

@pytest.fixture
def store(tmp_path):
    return LocalStore(path=tmp_path / "store")
```

**Determinism:** inject `clock`; never call `datetime.now()` inside core logic. This is what makes "baseline survives restart" and "no alerts during cold start" testable without flakiness.

**Parametrization** covers the fixture matrix cheaply:

```python
@pytest.mark.parametrize("raw,expected_reason", [
    ("2026-10-17T10:15:42", "naive_timestamp"),
    ("not-a-date", "invalid_timestamp"),
    ("2026-10-17T10:15:42Z", None),
])
def test_timestamp_validation(raw, expected_reason):
    result = parse_ts(raw)
    if expected_reason is None:
        assert isinstance(result, Ok)
    else:
        assert isinstance(result, Err) and result.error == expected_reason
```

**Property-based testing** shines for redaction and normalization:

```python
from hypothesis import given, strategies as st

@given(st.text())
def test_redaction_never_raises_and_removes_known_secret(s):
    out = redact(s)
    assert "password=" not in out.lower()        # invariant, regardless of input
```

`hypothesis` generates adversarial inputs you'd never write by hand — exactly what you want for a system that treats logs as untrusted data.

### 1.9 Concurrency: threads vs. async vs. processes

| Model | Best for | This project |
|---|---|---|
| **threads** | overlapping blocking I/O (file reads, HTTP) | collector shipping loop; journald reader |
| **asyncio** | many concurrent network calls | FastAPI request handling |
| **processes** | CPU-bound pure-Python math | bulk feature computation if needed |
| **numpy/vectorized** | numeric arrays | feature math, windowing |

**Why not async everywhere?** journald and Windows Event Log APIs are **blocking** C libraries. Wrapping them in async requires a thread pool anyway (`run_in_executor`). The collector is simpler and more robust with threads + a bounded queue. FastAPI, on the other hand, is naturally async for I/O-bound request handling — but our ingestion path does little blocking work, so sync handlers are also acceptable and simpler to reason about. Choose per surface, not by fashion.

**The thread-safety footgun:**

```python
# ❌ lost update possible: counter += 1 is read-modify-write
counter = 0
def on_event(e):
    global counter
    counter += 1

# ✅ use a lock or, better, a queue + single consumer
import threading
lock = threading.Lock()
def on_event_safe(e):
    global counter
    with lock:
        counter += 1
```

For the collector, prefer a **single producer thread that drains a bounded buffer** over shared counters — a `queue.Queue` is already thread-safe and gives you backpressure when full.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Building the `Result` type and pipeline step signature

```python
# src/lad/result.py
from __future__ import annotations
from dataclasses import dataclass
from typing import Generic, TypeVar, Union, Callable

T = TypeVar("T"); E = TypeVar("E"); U = TypeVar("U")

@dataclass(frozen=True, slots=True)
class Ok(Generic[T]):
    value: T

@dataclass(frozen=True, slots=True)
class Err(Generic[E]):
    error: E

Result = Union[Ok[T], Err[E]]

def map_ok(result: Result[T, E], fn: Callable[[T], U]) -> Result[U, E]:
    """Apply fn only on success, preserving the error otherwise."""
    if isinstance(result, Ok):
        return Ok(fn(result.value))
    return result

def flat_map(result: Result[T, E], fn: Callable[[T], Result[U, E]]) -> Result[U, E]:
    if isinstance(result, Ok):
        return fn(result.value)
    return result
```

**Why this matters for the project:** every normalization/validation step returns `Result`. The pipeline collects `Ok` events and records `Err` reasons as metrics. No exceptions cross step boundaries for *expected* failures, so a single malformed event can never cause a whole batch to retry.

### 2.2 A bounded collector buffer (thread-safe, with backpressure)

```python
# collectors/common/buffer.py
from __future__ import annotations
import queue
from dataclasses import dataclass
from typing import Sequence
from lad.contracts import Event

@dataclass
class BoundedBuffer:
    """Bounded by count; drops oldest when full and records the drop.

    'Drop oldest' vs 'block' is a documented policy decision. We choose drop-oldest
    so a burst cannot wedge the host's log pipeline, and we make the loss *loud*.
    """
    max_events: int = 10_000
    def __post_init__(self):
        self._q: queue.Queue[Event] = queue.Queue(maxsize=self.max_events)
        self.dropped = 0
    def add(self, event: Event) -> None:
        try:
            self._q.put_nowait(event)
        except queue.Full:
            # evict oldest to make room, record the loss
            try:
                self._q.get_nowait()
                self.dropped += 1
            except queue.Empty:
                pass
            self._q.put_nowait(event)
    def drain(self, *, max_events: int, max_bytes: int) -> list[Event]:
        out: list[Event] = []
        size = 0
        while len(out) < max_events:
            try:
                ev = self._q.get_nowait()
            except queue.Empty:
                break
            est = len(ev.message) + 200                    # conservative size estimate
            if size + est > max_bytes and out:
                self._q.put_nowait(ev)                     # put back; stop at limit
                break
            out.append(ev); size += est
        return out
```

**Walkthrough:** `queue.Queue(maxsize=...)` gives thread-safe bounded buffering. `put_nowait` raises `queue.Full` so we choose eviction explicitly instead of blocking forever. `drain` enforces **both** the event count and the byte budget (≤100 / ≤256 KB) — the collector contract. `dropped` is exported as a metric so loss is never silent.

### 2.3 Timezone-safe timestamp parsing

```python
# src/lad/contracts/time.py
from __future__ import annotations
from datetime import datetime, timezone
from lad.result import Ok, Err, Result

def parse_utc(raw: str) -> Result[datetime, str]:
    """Parse an ISO-8601 string to a tz-aware UTC datetime."""
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return Err("invalid_timestamp")
    if dt.tzinfo is None:
        return Err("naive_timestamp")        # never guess local time
    return Ok(dt.astimezone(timezone.utc))

def to_utc(dt: datetime) -> Result[datetime, str]:
    if dt.tzinfo is None:
        return Err("naive_timestamp")
    return Ok(dt.astimezone(timezone.utc))
```

**Walkthrough:** `datetime.fromisoformat` accepts `Z` only in newer versions, so we normalize `Z` → `+00:00` for compatibility. The tz info check is the crux: a naive datetime has `tzinfo is None` and must be **rejected** ("normalize to UTC at the contract boundary"). We never call `datetime.now()` without a timezone.

### 2.4 Injecting a clock for determinism

```python
# src/lad/ports/clock.py
from datetime import datetime, timezone
from typing import Protocol

class ClockPort(Protocol):
    def now(self) -> datetime: ...

class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)

class FixedClock:
    def __init__(self, t: datetime):
        assert t.tzinfo is not None
        self._t = t
    def now(self) -> datetime:
        return self._t
```

**Walkthrough:** core logic takes a `ClockPort`. Production uses `SystemClock`; tests use `FixedClock`. This is what lets us assert "the incident's window is exactly 10:14–10:16" without sleeping.

### 2.5 A local store adapter (portable, no cloud)

```python
# src/lad/adapters/local/store.py
from __future__ import annotations
import json, sqlite3, pathlib
from datetime import datetime, timezone
from typing import Sequence
from lad.ports.store import StorePort, BaselineState

class LocalStore(StorePort):
    """SQLite-backed store. WAL mode for concurrent reads; explicit TTL sweeper
    (we do NOT pretend rows vanish instantly — that mirrors DynamoDB TTL)."""
    def __init__(self, path: pathlib.Path):
        self.path = pathlib.Path(path); self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path, isolation_level=None)
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self._migrate()
    def _migrate(self) -> None:
        self.conn.execute("""
          CREATE TABLE IF NOT EXISTS incidents(
            incident_id TEXT PRIMARY KEY, status TEXT, severity TEXT,
            payload TEXT, updated_at TEXT);""")
        self.conn.execute("""
          CREATE TABLE IF NOT EXISTS dedup(
            event_id TEXT PRIMARY KEY, created_at TEXT);""")
    def record_processed_ids(self, ids: Sequence[str]) -> None:
        now = datetime.now(timezone.utc).isoformat()
        self.conn.executemany(
            "INSERT OR IGNORE INTO dedup(event_id, created_at) VALUES (?, ?)",
            [(i, now) for i in ids])
    def get_baseline(self, key: str) -> BaselineState | None:
        row = self.conn.execute("SELECT payload FROM incidents WHERE incident_id=?", (f"BASE#{key}",)).fetchone()
        return BaselineState.from_json(row[0]) if row else None
    def put_baseline(self, key: str, state: BaselineState) -> None:
        self.conn.execute(
            "INSERT INTO incidents(incident_id,status,severity,payload,updated_at) VALUES(?,?,?,?,?) "
            "ON CONFLICT(incident_id) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at",
            (f"BASE#{key}", "n/a", "n/a", state.to_json(), datetime.now(timezone.utc).isoformat()))
```

**Walkthrough:** `INSERT OR IGNORE` gives idempotent dedup. Baseline persistence uses an upsert — durable across process restarts, which the tests will assert. The comment about TTL is deliberate: the local analogue of DynamoDB's async TTL must not be "pretend it's instant."

### 2.6 A property test for redaction

```python
# tests/unit/test_redaction.py
from hypothesis import given, strategies as st
from lad.normalize.redact import redact

SECRET_PATTERNS = ["password=", "token=", "authorization:", "session_id="]

@given(st.text(max_size=2000))
def test_redaction_removes_secret_markers(text):
    lowered = redact(text).lower()
    assert not any(p in lowered for p in SECRET_PATTERNS)

@given(st.text())
def test_redaction_is_idempotent(text):
    once = redact(text)
    assert redact(once) == once          # redacting twice changes nothing
```

**Walkthrough:** `hypothesis` feeds arbitrary text, including `"password=hunter2"`, `"AUTHORIZATION: Bearer ..."`, unicode, and control characters. Idempotence is a real invariant: redaction runs at the collector *and* again server-side; the second pass must be a no-op.

### 2.7 Enforcing boundaries with an import test (recap + variation)

```python
# tests/architecture/test_no_wall_clock_in_core.py
import ast, pathlib
FORBIDDEN = {"datetime.now", "time.time"}

def calls_in(pkg):
    for path in pathlib.Path(pkg).rglob("*.py"):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                if node.func.attr in {"now", "time", "utcnow"}:
                    yield path, node.lineno, node.func.attr

def test_core_uses_injected_clock_only():
    violations = list(calls_in("src/lad"))
    # allow time.* inside adapters; forbid in detection/features/correlate
    core_violations = [v for v in violations if "/detection/" in str(v[0]) or "/features/" in str(v[0])]
    assert not core_violations, f"wall-clock call in core: {core_violations}"
```

**Walkthrough:** this teaches two lessons at once — you *can* write architectural tests in Python with the `ast` module, and determinism is enforceable, not aspirational.

---

## 3. Common Pitfalls & Debugging

### 3.1 Mutable default arguments

```python
def add(e, bucket=[]):     # ❌ shared across calls
    bucket.append(e); return bucket

def add(e, bucket=None):   # ✅
    bucket = bucket if bucket is not None else []
    bucket.append(e); return bucket
```
**Why:** defaults are evaluated once at function definition. In a long-running collector worker, this silently accumulates state across events. **Fix:** `None` sentinel or `dataclasses.field(default_factory=...)`.

### 3.2 `datetime` naive vs. aware

`datetime.utcnow()` returns a **naive** datetime (it doesn't carry `tzinfo`), so comparisons and serialization are ambiguous. **Use `datetime.now(timezone.utc)`.** This project rejects naive timestamps at the boundary precisely because they cause windowing and latency metrics to be wrong.

### 3.3 `is` vs. `==`, interning surprises

```python
a = "abc"; b = "abc"
a is b            # True by interning — but unreliable
a == b            # True by value — what you want
```
Never use `is` for strings/numbers (except `is None`). Use `is` for sentinels only.

### 3.4 Import-order side effects + Lambda cold starts

If `import sklearn` sits at the top of a module the ingestion Lambda also imports, every ingestion cold start pays the cost. **Fix:** keep heavy imports inside the function/lazy path, and add a test that asserts `src/lad` has no heavy third-party imports at module scope.

### 3.5 Exceptions swallowed by `except Exception`

The single largest cause of "we lost events and didn't know":
```python
try:
    process(record)
except Exception:
    pass                    # 💀
```
**Fix:** catch specific errors; log with a structured reason; increment a metric; decide retry vs. reject explicitly.

### 3.6 Silent timezone bugs in tests

Tests that use `datetime.now()` are flaky across CI machines. **Fix:** inject `FixedClock`; assert exact windows.

### 3.7 SQLite threading and `check_same_thread`

`sqlite3` connections are not safe to share across threads by default. If the worker uses a connection on multiple threads, you'll see `ProgrammingError: SQLite objects created in a thread can only be used in that same thread.` **Fix:** create a connection per thread (or a small pool), enable WAL, and serialize writes through a single writer.

### 3.8 Debugging tools that actually help

```bash
# see what pytest is doing, stop at first failure
pytest -x -vv --tb=short --durations=10

# show hypothesis's failing example
pytest -q tests/unit/test_redaction.py --hypothesis-show-statistics

# profile the hot path (feature computation)
python -m cProfile -s cumulative -m lad.eval.run --scenario normal

# check for memory growth across many windows
python -m tracemalloc  # or memory_profiler
```

- **`pytest --pdb`** drops into a debugger at the failure — invaluable for pipeline bugs.
- **`faulthandler`** (`python -X faulthandler`) reveals where a process hung (hanging collector threads).
- **`ruff` + `mypy --strict`** catch a large class of bugs before runtime; run them in CI.

### 3.9 A debugging story: "events accepted, no incidents"

A classic in this project. Check in order:
1. Worker env: is `LAD_STORAGE_BACKEND` correct? Is the table name set?
2. Baseline: is `cold_start=True` for the entity-feature? (Expected — no alerts while warming up.)
3. Thresholds: is the robust z below threshold on the synthetic anomaly? (Tune on *validation*, not the demo, and document.)
4. Correlation: `min_link` too high, so candidates never form an incident?
5. Dedup: are the synthetic events already marked processed from an earlier run? (`make demo-reset`.)

Systematic elimination beats guessing.

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"Fluent Python" (2nd ed.) — Luciano Ramalho.**
  - Ch. 5 *Data Class Builders* (dataclass vs. NamedTuple vs. TypedDict — exactly §1.5).
  - Ch. 6 *Object References, Mutability, and Recycling* (the mutable-default trap, §3.1).
  - Ch. 8–9 *Type Hints* (annotations as runtime objects, generics, `Protocol`).
  - Ch. 13–14 *Interfaces, Protocols, and ABCs* (the Ports & Adapters foundation).
  - Ch. 17–19 *Concurrency models* (threads vs. asyncio vs. processes — §1.9).
- **"Effective Python" (3rd ed.) — Brett Slatkin.**
  - Items on `None`-default arguments, `try/except/else/finally`, and defining your own exception hierarchy map directly onto §1.7.
- **"Python Testing with pytest" (2nd ed.) — Brian Okken.**
  - Fixtures, parametrization, and `conftest.py` — the backbone of the test layers in §1.8.
- **"Architecture Patterns with Python" — Percival & Gregory.**
  - Ch. 2 *Repository pattern*, Ch. 4 *Service layer*, Ch. 6 *Unit of Work* — the canonical explanation of why the core must not import boto3.
- **"Robust Python" — Patrick Viafore.**
  - Ch. on *Protocols*, *Data classes*, and *Enforcing constraints at the type level*.
- **"High Performance Python" (2nd ed.) — Gorelick & Ozsvald.**
  - Ch. on *Profiling* and *numpy* — foundation for modules 4–5.

### 4.2 Videos, talks, courses

- **"Raymond Hettinger — Beyond PEP 8"** (PyCon 2015): why Pythonic code is often *simpler* code. Foundational for style choices.
- **"Raymond Hettinger — Super Considered Super"** and his *Dataclasses* talks (PyCon 2018): the mental model for `dataclass`.
- **"Anthony Sottile — pytest"** series (YouTube): the fastest path to fixtures/parametrize fluency.
- **"FastAPI" official Tutorial + "Mangum" docs** (read in module 2's context, but skim now for import-boundary intuition).
- **ArjanCodes (YouTube)** — "SOLID Principles in Python", "Protocols", "Dependency Injection" playlists: practical Ports & Adapters.
- **Talk Python To Me** podcast — episodes on packaging with `pyproject.toml` and on `uv`.
- **Real Python** — "Python Type Checking (Guide)" and "Testing in Python with pytest".

### 4.3 Exercises to internalize this module

1. Implement `Result`/`Ok`/`Err` and rewrite the timestamp parser to return `Result`. Write parametrized tests for the three cases in §2.3.
2. Write the `BoundedBuffer` and prove with a test that after `max_events+50` adds, `dropped == 50` and the buffer holds the newest `max_events`.
3. Add an `ast`-based boundary test that forbids `sklearn` and `boto3` imports anywhere under `src/lad/`.
4. Build a `FixedClock` and write a test asserting an incident window is exactly 120 seconds wide, never using `time.sleep`.
5. Convert a hand-written class into a `@dataclass(frozen=True, slots=True)` and explain (in comments) which mutability bug it prevents.

---

*Next module:* **[Module 2 — Contracts & Validation: JSON Schema, OpenAPI, FastAPI/Pydantic](learning_module_2.md)** — turning agreement into executable, testable truth.
