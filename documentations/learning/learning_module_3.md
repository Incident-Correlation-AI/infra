# 📚 Learning Module 3 — Log Collection & Parsing: journald, Windows Event Log, Templates, Redaction

> **Module goal:** Get real bytes off real hosts — Linux and Windows — into the shared event envelope, safely, with least privilege, without losing events, and with secrets stripped *before* they leave the machine.
> **Project tie-in:** You will build `collectors/linux/`, `collectors/windows/`, and `collectors/app_adapters/`, plus `src/lad/normalize/` (template extraction + redaction).

**Estimated study time:** 30–40 hours (this module is unusually wide: two OS ecosystems, a parsing theory section, and a security section). **Prereq:** Modules 1–2.

---

## Table of Contents

1. [Core Theory & In-Depth Explanation](#1-core-theory--in-depth-explanation)
   - 1.1 What a log *is*, and the layers between you and it
   - 1.2 The Linux logging stack: syslog → rsyslog → journald
   - 1.3 The Windows Event Log architecture: channels, providers, EVTX
   - 1.4 Structured vs. unstructured logs, and why it matters
   - 1.5 Log parsing theory: from regex to log templates (Drain and friends)
   - 1.6 Redaction: threat model, techniques, and failure modes
   - 1.7 Collector reliability: offsets, cursors, buffering, backpressure
   - 1.8 Least privilege: journal groups and Event Log readers
2. [Practical Examples & Code Walkthroughs](#2-practical-examples--code-walkthroughs)
3. [Common Pitfalls & Debugging](#3-common-pitfalls--debugging)
4. [Curated Resources](#4-curated-resources)

---

## 1. Core Theory & In-Depth Explanation

### 1.1 What a log *is*, and the layers between you and it

A "log line" is a **serialization of an event by a program that was busy doing something else**. It is optimized for humans-under-stress, not for parsers. Between the event and your collector sit several layers:

```
application code ──► logging library ──► OS log service ──► storage (file/journal/EVTX)
                                                │
                                    you read here ▲
```

Each layer can:
- **drop** events (rate limiting, ring buffers, rotation),
- **reformat** them (syslog prefixes, journald field wrapping),
- **truncate** them (max message size),
- **delay** them (buffers, async flush),
- and **reorder** them (multi-threaded writers).

The single most important consequence: **`observed_ts` (when you saw it) and `event_ts` (when it happened) are different, and both matter.** The project's envelope stores both. Ingestion delay is itself a signal ("missing telemetry or ingestion delay as separate operational signals").

> 💡 **Design implication:** never assume the log stream is complete, ordered, or lossless. Build for gaps: record offsets/cursors, count dropped events, and surface ingest delay as a first-class metric.

### 1.2 The Linux logging stack: syslog → rsyslog → journald

#### History in one paragraph

- **syslog** (1980s, BSD) defined a wire format: `<priority>timestamp host tag: message`, with *facilities* (auth, kern, mail, …) and *severities* (emerg, alert, crit, err, warning, notice, info, debug). It was simple text, easy to write, impossible to structure.
- **syslog-ng / rsyslog** (2000s) added rules, filtering, and multiple outputs — the "log router" era. `/var/log/syslog`, `/var/log/auth.log`, and friends live here.
- **systemd-journald** (2011+) replaced/augmented this on most modern distros with a **binary, indexed, structured** journal. Every message gets automatic **trusted fields** plus arbitrary **user fields**.

#### The journal's structure (this is the part that matters)

journald stores entries as sets of key/value fields. You can see them:

```bash
journalctl -o json-pretty -n 1
```

```jsonc
{
  "__CURSOR": "s=...;i=...;b=...;m=...;t=...;x=...",
  "__REALTIME_TIMESTAMP": "1760705742123456",     // microseconds since epoch
  "_BOOT_ID": "…",
  "_MACHINE_ID": "…",
  "_HOSTNAME": "host-alpha",
  "_PID": "34521",
  "_COMM": "nginx",
  "_SYSTEMD_UNIT": "nginx.service",
  "_SYSTEMD_CGROUP": "/system.slice/nginx.service",
  "PRIORITY": "3",                                 // syslog severity 0–7
  "SYSLOG_FACILITY": "1",
  "MESSAGE": "GET /pay/checkout returned 502",
  "SYSLOG_IDENTIFIER": "nginx"
}
```

**Trusted fields** (prefixed `_`) are set by journald from the kernel/process metadata — a process cannot forge `_PID` or `_SYSTEMD_CGROUP`. **Untrusted fields** come from the application. This distinction is a *security* feature: `_SYSTEMD_UNIT` is reliable provenance; `SYSLOG_IDENTIFIER` is not.

**Cursor:** `__CURSOR` is an opaque position marker. Persist it to resume exactly where you left off — the journald equivalent of a file offset. Prefer cursors over timestamps: two entries can share a timestamp, but a cursor is exact.

#### Reading the journal in Python — three approaches

| Approach | How | Pros | Cons |
|---|---|---|---|
| **Shell out to `journalctl`** | `journalctl -o json -f` | Zero dependencies, works everywhere | Process management, parsing, quoting, permission via `sudo` |
| **`systemd.journal` (python-systemd)** | native binding | Cursor-based, structured fields, efficient | Needs the binding installed; Linux-only |
| **`libsystemd` via ctypes / `systemd-python` forks** | lower-level | Flexible | Fragile across versions |

For this project: **`systemd.journal` when available, `journalctl -o json` as a portable fallback.** Both must produce the same envelope — that's an adapter decision.

#### Permissions and least privilege

Reading the journal requires either root or membership in the `systemd-journal` group (and `systemd-journal-remote` for remote). **Prefer the group.** The collector runs as a dedicated unprivileged user in that group. Document it; don't `sudo` a long-running agent if avoidable.

```bash
# create a dedicated collector user and grant journal read access (illustrative)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin lad-collector
sudo usermod -aG systemd-journal lad-collector
```

> ⚠️ Membership in `systemd-journal` lets a process read *all* journal content, including entries from other services. That is a broad privilege. Scope it as tightly as the distro allows (some distros/versions support more granular ACLs), and treat the collector host's trust boundary accordingly. Document this residual risk (the security spec explicitly calls out "collection permissions" as a residual risk).

### 1.3 The Windows Event Log architecture: channels, providers, EVTX

#### History

Windows had a flat "Event Log" (System/Application/Security) since NT. **Vista/2008** introduced the modern architecture: **channels**, **event providers (manifests)**, the `Evt*` Win32 API, and the **EVTX** binary file format (also XML on the wire).

```
Provider (e.g., "Microsoft-Windows-Security-Auditing")
      │  emits an event with an Event ID + template + parameters
      ▼
Channel (e.g., "Security", "System", "Application", "Microsoft-Windows-.../Operational")
      │  stored in  %SystemRoot%\System32\winevt\Logs\*.evtx
      ▼
Subscription / Reader  ◄── your collector reads here
```

**Key concepts:**
- **Provider** — who logged. Maps a numeric Event ID to a *template* via a manifest.
- **Channel** — the stream (Security, System, Application, plus hundreds of provider-specific operational channels).
- **Event ID** — numeric, **only meaningful within a provider** (Event ID 4624 is "successful logon" for Security-Auditing; the same number means something else elsewhere).
- **Level** — Critical/Error/Warning/Information/Verbose.
- **Task/Opcode/Keywords** — finer classification.
- **EventRecordID** — monotonic per channel; the *cursor* analogue for resuming.

#### Reading via the modern API

`wevtutil` (CLI), PowerShell (`Get-WinEvent`), and Win32 `EvtQuery`/`EvtNext` all read channels. From Python, two viable paths:

| Path | Library | Notes |
|---|---|---|
| **`pywin32` → `win32evtlog`** | mature, widely used | Classic `ReadEventLog` API; supports channels, `EventRecordID` bookmarks |
| **`wevtutil`/PowerShell subprocess** | zero extra deps | XML output; parse per event; slower but portable |
| **`win32evtlog.EvtQuery`** (newer `Evt*` API via pywin32) | modern API | XML rendering, better channel filtering |

**Collect specific channels.** Never collect everything: the Security channel alone can be enormous and sensitive. Data minimization is a control ("Avoid collecting broad sensitive channels without a defined need").

#### Permissions

Reading Event Log channels requires membership in **Event Log Readers** (or admin for Security). Create a dedicated service account in that group.

```powershell
# illustrative: grant a service account read access to a channel via SDDL
$channel = "System"
wevtutil set-log $channel /ca:"O:BAG:SYD:(A;;0x1;;;S-1-5-21-...-1234)"   # replace with the real SID
```

**Installation/startup:** the collector should run as a **Windows service** (or a scheduled task at boot) under that account. Document install, start, stop, uninstall, and how to emit a **test event** to prove the pipeline.

### 1.4 Structured vs. unstructured logs

- **Structured** logs carry explicit fields (journald fields, Windows event XML, JSON logs from apps). You can map fields *without guessing*.
- **Unstructured** logs are free text (`"user alice failed to login from 10.0.0.5"`). Extracting fields requires *parsing*, which requires *heuristics*, which is where the ML/parsing theory comes in.
- **Semi-structured** (`nginx` combined log format, `key=value` pairs) is the common middle ground.

**Rule for this project:** preserve structure when it exists. journald's `_SYSTEMD_UNIT`, Windows' provider/channel/EventID, and an app's `status`/`duration_ms` should land in **`attributes`** as fields, not be flattened into `message`. Only *then* consider template extraction for the free-text remainder.

### 1.5 Log parsing theory: from regex to log templates

#### Why parse at all?

Two features depend on it:
- **`log_template_freq_change`** — "the *shape* of this log line started appearing, or stopped appearing, at a new rate." This catches novel error types that no fixed rule anticipated.
- **`event_count` by category/type** — grouping raw messages into meaningful categories.

#### The parsing spectrum

1. **Hand-written regex / Grok.** Precise, fast, but brittle and laborious.
   ```
   ^(?P<ip>\S+) - - \[(?P<ts>[^\]]+)\] "(?P<method>\w+) (?P<path>\S+) [^"]*" (?P<status>\d{3}) (?P<bytes>\d+)
   ```
   Grok composes named patterns on top of regex, popular in the ELK world. Good for a handful of known formats; poor at "unknown future formats."

2. **Rule/token-based mining (the research line).** These infer templates automatically:
   - **Drain** (He et al., 2017): a **fixed-depth parse tree** keyed by token count; messages with the same token count go to the same branch; similarity measured by matching leading tokens; a wildcard `<*>` replaces variable tokens. **Very fast, online, single-pass** — the standard baseline.
   - **Spell** (2016): longest-common-subsequence over token streams.
   - **IPLoM** (2013): iterative partitioning by token count → token position → bijection.
   - **LogMine, MoLFI, etc.** — evolutionary/greedy variants.
   - **Loghub / LogPAI** (Jieming Zhu et al.) provides datasets, tools, and benchmarks — the standard evaluation ecosystem.

3. **Delimiter/key-value parsing.** For `key=value` and JSON logs, parse structurally — don't template-mine what's already structured.

#### Drain, in detail (because we'll implement a tiny version)

Drain builds a tree:
- **Root** → children keyed by **token count** (e.g., "this message has 7 tokens").
- **Depth-2** → children keyed by the **first token** (often the most distinctive, e.g., a level or component).
- **Leaf nodes** → clusters of templates; each cluster keeps a representative template with `<*>` wildcards.

When a new message arrives:
1. Tokenize (usually by whitespace, after stripping obvious variable prefixes).
2. Walk to the `token_count` branch, then the `first_token` branch.
3. Compare against existing template clusters in that leaf using a **similarity threshold** (fraction of equal tokens; often `sim_threshold=0.4`).
4. If similar enough → assign to the cluster and **update** the template (positions that disagree become `<*>`).
5. Else → create a new template cluster.

**Complexity:** effectively O(1) per message for a bounded tree. This is why Drain is everywhere.

**Wildcards and variable detection:** truly variable tokens (numbers, UUIDs, IPs, hex) can be pre-detected and masked (`<NUM>`, `<IP>`) *before* clustering to improve template stability. This is a hyperparameter with real effects:

```python
# pre-normalization improves template stability dramatically
RULES = [
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<UUID>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<IP>"),
    (re.compile(r"\b[0-9a-f]{16,}\b", re.I), "<HEX>"),
    (re.compile(r"\b\d+\b"), "<NUM>"),
]
def mask_variables(msg: str) -> str:
    for pat, tag in RULES:
        msg = pat.sub(tag, msg)
    return msg
```

⚠️ **Order matters:** mask the *specific* patterns (UUID, IP, long-hex) before the generic `<NUM>`, or the generic rule eats the digits inside them.

#### Choosing a strategy for this project

- **Default:** template extraction is **best effort**. When it fails or is ambiguous, `template` stays `None` and the feature layer treats `log_template_freq_change` as **absent** (never zero).
- **Start** by supporting a small set of known formats explicitly (journald `MESSAGE`, nginx combined, Windows rendered message) plus a Drain-lite for unknown text.
- **Validate** template quality on a labeled sample; report template accuracy if you claim it (LogPAI's parsing-accuracy metric is standard).

### 1.6 Redaction: threat model, techniques, failure modes

#### Threat model

Secrets leak into logs constantly: bearer tokens in `Authorization` headers, passwords in connection strings, session IDs, API keys, PII (emails, IPs, national IDs), and credentials embedded in URLs. The security spec lists "secret leakage in logs" as a top threat and requires redaction of "tokens, passwords, session IDs, and sensitive values." **Redaction happens at the collector (before transmission) and again server-side (defense in depth).**

#### Techniques

1. **Pattern-based masking** — regexes for known secrets.
   ```python
   PATTERNS = [
     (re.compile(r"(?i)\b(password|passwd|pwd)\s*[=:]\s*\S+"), r"\1=<REDACTED>"),
     (re.compile(r"(?i)\bauthorization:\s*bearer\s+\S+"), "authorization: Bearer <REDACTED>"),
     (re.compile(r"(?i)\b(api[_-]?key|token|secret)\s*[=:]\s*[\w\-\.]{8,}"), r"\1=<REDACTED>"),
     (re.compile(r"(?i)\b(session[_-]?id|sid)\s*[=:]\s*[\w\-\.]{6,}"), r"\1=<REDACTED>"),
     (re.compile(r"(?i)([a-z]+://[^:@/]+):[^@/]+@"), r"\1:<REDACTED>@"),   # creds in URLs
   ]
   ```
2. **Field-aware redaction** — when structure exists, redact by key: drop or hash `attributes["authorization"]`, `attributes["password"]`. **Far more reliable than text regex.**
3. **Entropy-based detection** — flag high-entropy tokens (base64/hex-ish) as likely secrets. Useful as a backstop, but **prone to false positives** (request IDs, hashes). Use with a threshold and allowlist.
4. **Tokenizer/NER for PII** — overkill for the MVP; mention as future work. External LLMs are **deferred** and must never receive raw logs by default.
5. **Allowlist/ephemeral** — the strongest stance is "don't log the secret in the first place," but you don't control all producers.

#### Failure modes (memorize these)

- **Over-redaction** destroys evidence (redacting all hex kills request IDs used for correlation). Over-redaction is *safer* than under-redaction but hurts detection.
- **Under-redaction via encoding** — the secret appears URL-encoded, base64'd, or split across lines. Regex on the literal won't catch it. This is why field-aware redaction (structured) plus a conservative entropy backstop matters.
- **Order-dependent regex** — `password=` must be masked before a generic `\S+` rule; otherwise the generic rule can consume the marker and defeat the mask.
- **Redacting the key but not the value** (or vice-versa) — match the whole `key=value` construct.
- **Re-introducing secrets** — if you keep a "debug" copy of the original for troubleshooting and it reaches the same pipeline, you've defeated the purpose. Never persist the un-redacted original locally.

```python
def redact_text(msg: str) -> str:
    for pat, repl in PATTERNS:
        msg = pat.sub(repl, msg)
    return msg

def redact_event(ev: Event) -> Event:
    # structured first (most reliable), then textual fallback
    attrs = {k: ("<REDACTED>" if k.lower() in SENSITIVE_KEYS else v)
             for k, v in ev.attributes.items()}
    return replace(ev, message=redact_text(ev.message), attributes=attrs)
```

**Tests are mandatory:** representative sensitive values must be caught (security test list includes "redaction catches representative sensitive values"), and redaction must be **idempotent** (runs twice safely). Property-based tests (Module 1 §2.6) are ideal here.

### 1.7 Collector reliability: offsets, cursors, buffering, backpressure

**Resume state is the difference between "collector" and "toy."** On restart, a collector must resume from where it stopped without gaps (or duplication that the server dedupes) — never lose the middle.

- **journald:** persist `__CURSOR` (or `_BOOT_ID` + timestamp as a fallback). Cursors are exact; timestamps can duplicate.
- **files:** persist `(inode, byte offset)`; handle rotation (inode change) and truncation (offset > size).
- **Windows:** persist `(channel, EventRecordID)`; query events with `EventRecordID > last`.

**Bounded buffer + backpressure** (from Module 1 §2.2): the buffer is bounded; when full you **drop oldest or block**, chosen deliberately, with a `dropped` metric. Never let an unbounded buffer OOM the host.

**Flush & batch:** flush on `max(interval, size)`; batch ≤100 events / ≤256 KB. A short flush interval keeps latency low but increases request count; document the trade-off.

**Retry with backoff + jitter:** exponential, bounded, with jitter (avoid thundering herd when many collectors reconnect after an outage). Distinguish retryable (network/5xx/429) from non-retryable (4xx except 408/429) — non-retryable goes to a local dead-letter, not an infinite loop.

**At-least-once means duplicates are normal.** Stable `event_id` makes duplicates harmless server-side. Assign the ID **once** (at the source) and reuse across retries.

### 1.8 Least privilege: journal groups and Event Log readers

| Platform | Minimum privilege | Broader risk |
|---|---|---|
| Linux | `systemd-journal` group (or journal ACLs) | can read all journals |
| Windows | `Event Log Readers`, per-channel SDDL | Security channel is highly sensitive |
| App logs | filesystem ACL on the specific log dir | overly broad read on `/var/log` |

**Principles:**
- Dedicated unprivileged user per host.
- Read only needed channels/dirs.
- Collector credential is **submission-only** (Module 2/6): even a fully compromised collector cannot read incidents.
- Document residual risk (permissions remain broad) rather than pretending it's solved.

---

## 2. Practical Examples & Code Walkthroughs

### 2.1 Linux collector — journald via `systemd.journal`

```python
# collectors/linux/journal_reader.py
from __future__ import annotations
import json, pathlib, time
from datetime import datetime, timezone
import systemd.journal as journal          # verify binding availability during setup
from lad.contracts import Event
from lad.normalize.redact import redact_event

CURSOR_FILE = pathlib.Path("/var/lib/lad-collector/cursor")

PRIORITY_TO_SEVERITY = {"0":"critical","1":"critical","2":"critical","3":"error",
                        "4":"warning","5":"notice","6":"info","7":"info"}

def load_cursor() -> str | None:
    try: return CURSOR_FILE.read_text().strip() or None
    except FileNotFoundError: return None

def save_cursor(cur: str) -> None:
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(cur)            # atomic-ish; consider write+rename for safety

def to_event(entry) -> Event:
    ts = datetime.fromtimestamp(entry["__REALTIME_TIMESTAMP"] / 1_000_000, tz=timezone.utc)
    attrs = {k: v for k, v in entry.items()
             if k in ("_PID","_COMM","SYSLOG_IDENTIFIER","SYSLOG_FACILITY","_SYSTEMD_UNIT","CODE_FILE")}
    msg = entry.get("MESSAGE", "")
    if isinstance(msg, bytes): msg = msg.decode("utf-8", "replace")
    ev = Event(
        schema_version="1.0",
        event_id=make_stable_id(entry),                 # derive deterministically
        event_ts=ts, observed_ts=datetime.now(timezone.utc),
        host=entry.get("_HOSTNAME", "unknown"),
        source="journald",
        service=entry.get("_SYSTEMD_UNIT"),
        category=guess_category(entry),
        type="journal_message",
        severity=PRIORITY_TO_SEVERITY.get(entry.get("PRIORITY","6"), "info"),
        message=msg,
        template=None,                                  # extraction is a later stage
        attributes=attrs,
    )
    return redact_event(ev)

def stream(reader: journal.Reader | None = None):
    reader = reader or journal.Reader()
    reader.this_boot()
    cur = load_cursor()
    if cur:
        reader.seek_cursor(cur); reader.get_next()      # position just after the saved cursor
    else:
        reader.seek_tail()                              # start at "now" by default (ADR)
        reader.get_previous()
    reader.log_level("info")                            # configurable; document default
    while True:
        for entry in reader:
            yield to_event(entry)
            if "__CURSOR" in entry:
                save_cursor(entry["__CURSOR"])
        reader.wait(1.0)                                # block up to 1s for new entries
```

**Walkthrough:**
- **Cursor persistence** is the resume mechanism. `seek_cursor` + `get_next` positions just after the saved cursor to avoid reprocessing the last entry.
- `journal.Reader.wait(timeout)` blocks efficiently instead of busy-looping.
- `make_stable_id` must be deterministic from journal content that uniquely identifies the entry (cursor is ideal) so retries reuse the same ID.
- `observed_ts` uses real time; `event_ts` comes from the journal. Both are stored (per the envelope).

### 2.2 Linux collector — portable `journalctl -o json` fallback

```python
# collectors/linux/journalctl_reader.py
import json, subprocess

def stream_journalctl(since: str | None = None):
    args = ["journalctl", "-o", "json", "-f", "--no-pager"]
    if since:
        args += ["--since", since]
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, text=True, bufsize=1)
    for line in proc.stdout:                    # one JSON object per line
        entry = json.loads(line)
        yield to_event_from_json(entry)
```

**Walkthrough:** `Popen` with line buffering gives a generator over journal lines. This needs the subprocess to have journal access, so it runs as the collector user (same group). It's slower than the binding and adds a process, but zero native deps — good for environments where the binding can't be installed. **Both readers must produce identical envelopes** — test that.

### 2.3 Windows collector — `win32evtlog` channel reader

```python
# collectors/windows/eventlog_reader.py
from __future__ import annotations
import win32evtlog, win32evtlogutil, pywintypes
from datetime import datetime, timezone
from lad.contracts import Event
from lad.normalize.redact import redact_event

CHANNELS = ["System", "Application"]                # configured; start narrow
LEVEL_TO_SEVERITY = {1:"critical",2:"error",3:"warning",4:"info",5:"info"}

def read_channel(channel: str, last_record_id: int):
    hand = win32evtlog.OpenEventLog(None, channel)
    flags = win32evtlog.EVENTLOG_BACKWARDS_READ | win32evtlog.EVENTLOG_SEQUENTIAL_READ
    # In production prefer the EvtQuery API with an XPath filter:
    #   EvtQuery(channel, "Event/System/EventRecordID > N")
    events = []
    while True:
        batch = win32evtlog.ReadEventLog(hand, flags, 0)
        if not batch: break
        for rec in batch:
            if rec.RecordNumber <= last_record_id:
                continue
            events.append(to_event(channel, rec))
    win32evtlog.CloseEventLog(hand)
    return list(reversed(events))                    # restore chronological order

def to_event(channel: str, rec) -> Event:
    ts = rec.TimeGenerated.replace(tzinfo=timezone.utc)   # pywintypes time is UTC-naive
    # rendered message needs the provider; may fail if the provider isn't registered
    try:
        msg = win32evtlogutil.SafeFormatMessage(rec, channel)
    except Exception:
        msg = "<message unavailable: provider not registered>"
    ev = Event(
        schema_version="1.0",
        event_id=f"wevt-{channel}-{rec.RecordNumber}",     # stable across retries
        event_ts=ts, observed_ts=datetime.now(timezone.utc),
        host=rec.ComputerName,
        source="windows-eventlog",
        service=rec.SourceName,                            # provider
        category="windows",
        type=f"wevt_{rec.EventID}",                        # ID meaningful within provider
        severity=LEVEL_TO_SEVERITY.get(rec.EventType, "info"),
        message=msg,
        attributes={"provider": rec.SourceName, "channel": channel,
                    "event_id": rec.EventID, "record_id": rec.RecordNumber,
                    "strings": list(rec.StringInserts or [])},
    )
    return redact_event(ev)
```

**Walkthrough:**
- **Resume via `EventRecordID`/`RecordNumber`.** Read backwards for efficiency, filter by the last seen record ID, then reverse to chronological.
- **`SafeFormatMessage`** can fail if the provider manifest isn't installed; fall back gracefully rather than dropping the event.
- **`EventID` is provider-scoped** — we store both `provider` and `event_id` so the pair is meaningful, and `channel` for provenance.
- `StringInserts` holds the event's structured parameters — the raw material for real structure rather than prose.
- Prefer **`EvtQuery` XPath** (`Event/System/EventRecordID > N`) in production; it filters server-side and is far faster than scanning backwards.

### 2.4 A tiny Drain implementation

```python
# src/lad/normalize/drain.py
from __future__ import annotations
import re
from collections import defaultdict
from dataclasses import dataclass, field

WILDCARD = "<*>"

MASK = [
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<UUID>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<IP>"),
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "<HEX>"),
    (re.compile(r"\b\d+\b"), "<NUM>"),
]

def mask_vars(s: str) -> str:
    for pat, tag in MASK:
        s = pat.sub(tag, s)
    return s

@dataclass
class Cluster:
    template: list[str]
    count: int = 0

@dataclass
class DrainLite:
    sim_threshold: float = 0.4
    max_children: int = 100
    # tree: token_count -> first_token -> list[Cluster]
    tree: dict[int, dict[str, list[Cluster]]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(list)))

    def add(self, message: str) -> str:
        msg = mask_vars(message)
        tokens = msg.split()
        n = len(tokens)
        first = tokens[0] if tokens else ""
        clusters = self.tree[n][first]
        best, best_sim = None, 0.0
        for c in clusters:
            sim = self._similarity(c.template, tokens)
            if sim > best_sim:
                best, best_sim = c, sim
        if best is not None and best_sim >= self.sim_threshold:
            best.template = self._merge(best.template, tokens)
            best.count += 1
            return " ".join(best.template)
        new = Cluster(template=list(tokens), count=1)
        clusters.append(new)
        return " ".join(new.template)

    @staticmethod
    def _similarity(a: list[str], b: list[str]) -> float:
        if len(a) != len(b): return 0.0
        same = sum(1 for x, y in zip(a, b) if x == y or x == WILDCARD or y == WILDCARD)
        return same / len(a)

    @staticmethod
    def _merge(a: list[str], b: list[str]) -> list[str]:
        return [x if x == y else WILDCARD for x, y in zip(a, b)]
```

**Walkthrough:**
- **Masking first** collapses variable tokens so templates stabilize (`<NUM>` instead of thousands of distinct numbers).
- The tree is keyed by `(token_count, first_token)` — Drain's cheap branching that avoids comparing every message to every template.
- `_similarity` respects existing wildcards (a wildcard already matches anything) so templates keep generalizing.
- `_merge` turns disagreeing positions into `<*>`.
- This is a *tiny* Drain. Real Drain handles depth limits, max-children (these empty on overload), and better token keys. For production quality, consider adapting the reference implementation (see resources) — but the concepts here are the ones the feature `log_template_freq_change` relies on.

**Test:**
```python
def test_drain_learns_template_and_generalizes():
    d = DrainLite()
    t1 = d.add("GET /a returned 200")
    t2 = d.add("GET /b returned 200")
    t3 = d.add("GET /c returned 500")
    assert t1 == t2 == t3                                   # same template after masking
    assert "/a" not in t1 and "<NUM>" in t1                 # variables masked
```

### 2.5 Redaction with structured + textual passes and tests

```python
# src/lad/normalize/redact.py
from __future__ import annotations
import re
from dataclasses import replace
from lad.contracts import Event

SENSITIVE_KEYS = {"authorization","password","passwd","token","api_key","apikey",
                  "secret","session_id","sid","cookie","set-cookie","private_key"}

PATTERNS = [
    (re.compile(r"(?i)\b(password|passwd|pwd)\s*[=:]\s*\S+"), r"\1=<REDACTED>"),
    (re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+\S+"), "authorization: Bearer <REDACTED>"),
    (re.compile(r"(?i)\b(api[_-]?key|token|secret)\s*[=:]\s*[\w\-\.]{8,}"), r"\1=<REDACTED>"),
    (re.compile(r"(?i)\b(session[_-]?id|sid)\s*[=:]\s*[\w\-\.]{6,}"), r"\1=<REDACTED>"),
    (re.compile(r"(?i)([a-z][a-z0-9+.-]*://[^:@/]+):[^@/]+@"), r"\1:<REDACTED>@"),
]

def redact_text(message: str) -> str:
    for pat, repl in PATTERNS:
        message = pat.sub(repl, message)
    return message

def redact_event(ev: Event) -> Event:
    attrs = {k: ("<REDACTED>" if k.lower() in SENSITIVE_KEYS else v)
             for k, v in ev.attributes.items()}
    return replace(ev, message=redact_text(ev.message), attributes=attrs)
```

```python
# tests/unit/test_redact.py
import pytest
from lad.normalize.redact import redact_text

@pytest.mark.parametrize("raw,forbidden", [
    ("password=hunter2", "hunter2"),
    ("Authorization: Bearer abc.def.ghi", "abc.def.ghi"),
    ("api_key=sk_live_1234567890", "sk_live_1234567890"),
    ("session_id=abc123xyz", "abc123xyz"),
    ("postgres://admin:s3cret@db:5432/app", "s3cret"),
])
def test_redacts_representative_secrets(raw, forbidden):
    assert forbidden not in redact_text(raw)

def test_redaction_idempotent():
    once = redact_text("password=hunter2 token=abcdef123456")
    assert redact_text(once) == once
```

### 2.6 Collector batching + backoff (end-to-end shape)

```python
# collectors/common/shipper.py
from __future__ import annotations
import time, random, itertools
from lad.contracts.serialize import events_to_batch_json

def shipper_loop(cfg, buffer, post):
    while True:
        time.sleep(cfg.flush_interval_s)
        batch = buffer.drain(max_events=100, max_bytes=262144)
        if not batch: continue
        body = events_to_batch_json(batch)
        for attempt in itertools.count():
            try:
                post(cfg.endpoint, body, token=cfg.token, timeout=cfg.request_timeout_s)
                metrics.inc("sent", len(batch)); break
            except RetryableHttpError:
                delay = min(cfg.backoff_base_s * 2**attempt, cfg.backoff_max_s)
                metrics.inc("retry")
                time.sleep(delay + random.uniform(0, delay*0.3))   # jitter
            except FatalHttpError:
                buffer.dead_letter(batch); metrics.inc("dead_letter", len(batch)); break
```

**Walkthrough:** bounded batch, exponential backoff with jitter, and a clear split between retryable (network/5xx/429) and fatal (4xx) that routes to a local dead-letter instead of looping. This is the exact behavior the collector contract specifies.

---

## 3. Common Pitfalls & Debugging

### 3.1 Timezone and timestamp pitfalls

- `rec.TimeGenerated` on Windows is **UTC but naive**; assigning `tzinfo=timezone.utc` is required, not optional.
- journald's `__REALTIME_TIMESTAMP` is **microseconds** since epoch (integer), `_SOURCE_REALTIME_TIMESTAMP` may differ. Use the right one and convert carefully.
- Naive datetimes anywhere → rejected at the contract boundary. Test it.

### 3.2 Cursor/offset bugs

- Saving the cursor **after** yielding may reprocess the last entry on restart. Position **just after** the saved cursor.
- On log rotation, the inode changes; an offset into the old file is meaningless. Track `(inode, offset)`.
- On truncation, offset > file size; reset to 0.
- Windows: `RecordNumber` is per-channel; never compare across channels.

### 3.3 journald cursor invalidation

If the journal is rotated or vacuumed, an old cursor may no longer resolve, raising an error. Handle it: fall back to time-based (`--since`) or tail, and log the fallback. **Do not crash the collector.**

### 3.4 Windows provider-not-registered

`SafeFormatMessage` fails when the provider manifest is absent (common for forwarded events). Fall back to a structured rendering from `StringInserts` rather than dropping the event, and mark the message as unavailable.

### 3.5 Masking order and over-masking

Reversing mask rules (`<NUM>` before `<IP>`) destroys IPs. Over-masking hex kills request IDs used for correlation. **Tune masks on real data and keep a correlation-friendly subset.** Correlation depends on `trace_id`/`request_id`; don't mask those into oblivion.

### 3.6 Redaction false sense of security

Regex redaction misses encoded/split secrets and unknown formats. It is **defense in depth**, not a guarantee. The stronger controls are: don't collect broad sensitive channels, don't transmit raw payloads by default, and use field-aware redaction when structure exists.

### 3.7 Silent drops

An unbounded buffer "works" until the host OOMs. A blocking buffer "works" until the log pipeline wedges. **Always bound and always count drops.** Emit `dropped_total` and alert on it.

### 3.8 Duplicate events after restart

If stable IDs are regenerated on restart, dedup fails server-side and you get duplicate incidents. Derive IDs **deterministically** from durable source identity (cursor, `RecordNumber`, inode+offset).

### 3.9 Debugging toolkit

```bash
# inspect journald as JSON
journalctl -o json -n 3 | jq .

# follow the journal like a log file
journalctl -f -o json | jq -r '.MESSAGE'

# check collector permissions
journalctl -n 1 >/dev/null && echo "can read" || echo "permission denied"
id lad-collector    # confirm systemd-journal membership

# Windows: emit a test event and verify it appears
powershell -c "Write-EventLog -LogName Application -Source LADTest -EventId 1001 -EntryType Information -Message 'test'"
powershell -c "Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1001} -MaxEvents 1 | Format-List *"

# see whether the collector is shipping (structured, no secrets)
journalctl -u lad-collector -f
```

- **`journalctl --verify`** checks journal integrity if entries look corrupt.
- **`wevtutil gl <channel>`** shows channel config and access.
- **pytest with recorded sample logs** lets you develop parsers without a live host (commit a small, sanitized sample under `collectors/*/testdata/`).

---

## 4. Curated Resources

### 4.1 Books (with chapter guidance)

- **"Linux System Programming" (2nd ed.) — Robert Love.** Ch. on files, inodes, and rotation mechanics behind file offsets; foundational for resume logic.
- **"Systems Performance" (2nd ed.) — Brendan Gregg.** The *logical* (not just physical) reasoning about observability data: resolution, sampling, and completeness. Directly informs §1.1.
- **"The Practice of System and Network Administration" — Limoncelli, Hogan, Chalup.** The operational discipline of collecting exactly what you need, with least privilege.
- **"Windows Internals, Part 1 & 2" — Russinovich, Solomon, Ionescu.** The Event Log architecture, providers, and channels in depth (§1.3).
- **"Logging and Log Management" — Chuvakin, Schmidt, Phillips.** Vendor-neutral theory of collection, parsing, and retention.
- **"Site Reliability Engineering" (Google) — Ch. on *Monitoring Distributed Systems*.** Why logs are signals, not truth.

### 4.2 Papers (the parsing canon)

- **Drain: "Drain: An Online Log Parsing Approach with Fixed Depth Tree" (He et al., ICWS 2017).** Read the algorithm section; it's short and it's the one you'll implement.
- **"Spell: Streaming Parsing of System Event Logs" (Du & Li, ICDM 2016).**
- **"A Directed Acyclic Graph Approach to Online Log Parsing" / IPLoM (Makanju et al., 2013).**
- **"LogPAI / Loghub: A Large Collection of System Log Datasets" (Zhu et al.).** Datasets (HDFS, BGL, …, see Module 5 for evaluation caution), tools, and parsing-accuracy benchmarks.
- **"Towards Automated Log Parsing for Large-Scale Log Data Analysis" (Zhu et al.).**

### 4.3 Videos, talks, courses

- **"journald Deep Dive"** and **systemd.conf talks** (YouTube) — cursors, fields, structured logging.
- **"Windows Event Logs for Blue Teams" and SANS "Hunt Evil"/logging talks** — practical channel/provider/EventID knowledge (security framing is useful even though we're not a SIEM).
- **Elastic "Getting Started with Grok" and Logstash parsing videos** — pattern composition.
- **Brendan Gregg — "The Method"** talk — the systematic approach to observability data.
- **CNCF / OpenTelemetry "Logs" spec talks** — where structured logging is heading (useful for future-proofing the envelope).

### 4.4 Exercises to internalize this module

1. Run the journald reader against your own machine; emit a known `logger` message and confirm it appears with correct fields.
2. Implement `journalctl -o json` fallback and a test asserting both readers produce identical envelopes for the same entry.
3. On Windows 11 (VM is fine), read the Application channel, resume from `RecordNumber`, and prove no gaps after a restart.
4. Implement `DrainLite` and measure template stability on nginx logs with and without variable masking.
5. Write redaction tests for the five representative secrets and an idempotence property test.
6. Simulate an API outage (return 503) and prove the shipper retries with jitter, then dead-letters on 400 — and that `dropped`/`dead_letter` metrics increment.

---

*Next module:* **[Module 4 — Statistical Anomaly Detection: Windows, Baselines, Robust Statistics, Correlation](learning_module_4.md)** — turning windows of events into trustworthy, explainable alerts.
