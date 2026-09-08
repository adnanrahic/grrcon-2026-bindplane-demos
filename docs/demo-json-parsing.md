# Demo: turning an unstructured stream into structured telemetry

The `appjson` stream — the one pipeline that arrives deliberately **unparsed**,
so processors can be built live in front of an audience.

## Why this stream exists

Four of the five streams are handled by something Bindplane already ships:

| Stream | Handled by | Result |
|---|---|---|
| `apache` | `apache_common` source | CLF parsed on ingest |
| `cef` | `common_event_format` source | CEF headers + severity on ingest |
| `paloalto` | `dynatrace-palo-alto-security-full-pipeline` | parsed + MITRE enrichment |
| `winsec` | SecOps Pipeline Intelligence actions | log-type standardisation |
| **`appjson`** | **nothing** | **raw string** |

That last row is the point. `appjson` is a mixed-format application log — a JSON
envelope around a semi-structured `message` field. No source type parses it, no
blueprint covers it, no vendor integration claims it. It is what most real-world
application logs look like, and where a pipeline tool earns its keep by hand.

## Starting state

`blitz-json` → tcp `:5143` → `bdot-appjson` (`grrcon-appjson`) → Google Cloud
Logging (`grrcon-google-gcl`); the stream also reaches the gateway tier via
`bdot-edge-*`. The source sets `parse_format: none` on purpose. On arrival:

```
Body: Str({"component":"storage","duration_ms":9089,"environment":"production",
           "host":"web-prod-01.us-west1.example.com","level":"INFO",
           "location":"us-west1","message":"Application security testing, ...",
           "service":"event-bus","timestamp":"2026-09-03T11:26:51.27845118Z",
           "trace_id":"...","version":"2.0.0"})

Attributes: log_type: Str(appjson), net.transport, net.host.port

Timestamp:      1970-01-01 00:00:00      <-- not set
SeverityText:                            <-- not set
SeverityNumber: Unspecified(0)
```

**Three separate problems**, each a distinct fix and a distinct before/after:

1. **No fields.** One string — nothing queryable, filterable or routable.
2. **No timestamp.** Every record claims 1970; the JSON contains the real one.
3. **No severity.** `level: FATAL` and `level: INFO` are indistinguishable, so
   severity filtering and alerting cannot work.

2 and 3 are the interesting ones: they survive the obvious fix. Parsing the JSON
gets you fields — it does **not** fix timestamp or severity.

## Showing the starting state

A debug destination is the quickest way to put a record on screen. None is
committed any more, so define a temporary one — in a scratch file, **not** under
`bindplane/`:

```yaml
# /tmp/debug-out.yaml
apiVersion: bindplane.observiq.com/v1
kind: Destination
metadata:
  name: grrcon-debug-out
spec:
  type: custom
  parameters:
  - name: telemetry_types
    value: [Logs]
  - name: configuration
    value: |-
      debug:
        verbosity: detailed
```

```bash
bindplane apply -f /tmp/debug-out.yaml     # destination must exist FIRST
# then add `- destinations/d-grrcon-debug-out` to the logs route in
# bindplane/20-source-appjson.yaml, and d-grrcon-debug-out to its destinations
bindplane apply -f bindplane/20-source-appjson.yaml
bindplane rollout start grrcon-appjson
docker logs --since 30s bdot-appjson | grep -A20 'LogRecord #'
```

Three gotchas that waste stage time:

- **Destination before configuration.** A config pins the destination *version
  it was applied against*, so the other order leaves a dangling reference or
  stale verbosity and no records.
- **`verbosity: basic` prints a count, not a record.** Seeing only
  `"msg":"Logs" ... "log records": 9` means verbosity did not take effect.
- **Revert after:** `git checkout bindplane/20-source-appjson.yaml`, re-apply,
  roll out, `bindplane delete destination grrcon-debug-out`.

## The flow

### Step 1 — parse the JSON body

Processor: **Parse JSON** (`parse_json`) on `grrcon-appjson-in`, with
`log_source_field_type: Body` and an empty field selector to parse the whole
body. The body becomes a map, every key its own field.

A shipped **`parse-json-bundle`** blueprint does the same thing; the raw processor
shows what it is doing. **The reveal:** fields appear, timestamp is *still* 1970 and severity *still*
unset. Pause here — "parsed" is not "usable".

### Step 2 — promote the real timestamp

Processor: **Parse Timestamp** (`parse_timestamp_v2`) — `log_field_type: Body`,
`log_source_field: timestamp`, format RFC3339 (the generator emits
`2026-09-03T11:26:51.27845118Z`).

`Timestamp` becomes the event's own time. Show a time-ordered view before and
after — 1970 breaks retention, ordering and time-windowed queries.

> The `tcp` source can do this itself (`parse_timestamp: true`,
> `timestamp_field: timestamp`). Doing it as a processor separates the three fixes
> so each lands on its own.

### Step 3 — map `level` onto OTel severity

Processor: **Parse Severity Fields** (`parse_severity_v2`) — `match: Body`,
`body_severity_field: level`. `level: FATAL` becomes `SeverityNumber: Fatal`, and
severity filtering works.

**Contrast:** the CEF stream got this free — its plugin runs a `severity_parser`,
so `severity=1` arrived as `SeverityNumber: Info(9)`. The native source did in
one step what took three here — the honest argument for native sources, landing
better right after doing it by hand.

### Step 4 (optional) — now that it is structured, reduce it

With fields and severity in place, reduction becomes available:

**Filter by Severity** drops below WARN, **Deduplicate Logs** collapses bursts,
**Filter by Condition** drops by `component`/`host`. The ingest-cost story, and
possible only *after* steps 1–3 — before parsing, the pipeline cannot tell a
FATAL from a health check.

## Suggested narrative arc

1. **Show the raw record** — one string, 1970, no severity. "This is what most
   application logs look like arriving at a SIEM."
2. **Contrast with `cef` or `apache`**, which arrive fully parsed because a
   native source knew the format. Nothing knows this one.
3. **Fix it in three steps**, pausing after step 1 to show fields alone are not
   enough.
4. **Then reduce it**, only possible now.
5. **Close on the trade-off:** native source where one exists, processors where
   none does — same pipeline either way.

## Resetting between runs

Stateless — reverting the config is the reset:

```bash
git checkout bindplane/20-source-appjson.yaml bindplane/40-gateway.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-appjson
bindplane rollout start grrcon-gateway
```

Check the starting state — every gateway exporter should be non-zero, replacing
the old "catch-all must be 0" check:

```bash
for i in $(seq -w 1 10); do docker logs --since 3m bdot-$i 2>&1; done | python3 -c "
import sys, json, collections
c = collections.Counter()
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get('otelcol.component.kind') == 'exporter':
        c[d['otelcol.component.id']] += 1
for k, v in sorted(c.items()): print('%-34s %d' % (k, v))
"
```

**Do not `grep` the backend name here** — on the gateway tier all five exporters
share a collector, and a name grep under-reports Elastic and over-reports Splunk
by an order of magnitude. See `.claude/50-routing.md` for why.

## Things that will not break, and one that will

- **Routing is independent of parsing.** `log_type: appjson` is stamped by a
  separate `add` operator on the source, not the parser — break every processor
  here and the router still routes correctly. Verified: every gateway exporter
  kept receiving across the switch from `parse_format: json` to `none`.
- **Turning native parsing back on is one line.** `parse_format: json` on
  `grrcon-appjson-in` restores the `json_parser` and skips step 1.
- **The gateway rollout pauses between stages and looks like a failure.**
  Progressive rollout (Canary `env=canary` → Prod `env=prod`) reports
  `Paused STAGE=Prod completed=2 errors=0 waiting=8` mid-flight. `errors=0` is
  the tell; `bindplane rollout resume grrcon-gateway` advances it.

## Reference

Stream `bindplane/20-source-appjson.yaml`; generator `blitz-json`; field list
`.claude/60-blitz-data.md`. No debug destination is committed.
