# Demo: turning an unstructured stream into structured telemetry

A walkthrough for the `appjson` stream — the one pipeline in this demo that
arrives deliberately **unparsed**, so processors can be built live in front of an
audience.

## Why this stream exists

Four of the five streams are handled by something Bindplane already ships:

| Stream | Handled by | Result |
|---|---|---|
| `apache` | `apache_common` source (native) | CLF parsed into fields on ingest |
| `cef` | `common_event_format` source (native) | CEF headers + severity parsed on ingest |
| `paloalto` | `dynatrace-palo-alto-security-full-pipeline` blueprint | header stripped, PAN-OS CSV parsed, MITRE enrichment |
| `winsec` | Google SecOps Pipeline Intelligence actions | SecOps log-type standardisation |
| **`appjson`** | **nothing** | **raw string** |

That last row is the point. `appjson` is a mixed-format application log — a JSON
envelope wrapping a semi-structured `message` field. No source type parses it, no
blueprint covers it, and no vendor integration claims it. It is what most
real-world application logs actually look like, and it is where a pipeline tool
has to earn its keep by hand.

## Starting state

`blitz-json` → tcp `:5143` → `bdot-appjson` (config `grrcon-appjson`) → Google
Cloud Logging (`grrcon-google-gcl`).
The same stream also reaches the gateway tier via `bdot-edge-*`.

The source sets `parse_format: none` on purpose. A record on arrival:

```
Body: Str({"component":"storage","correlation_id":"21164fa7-7167-74fd-7d65-41c0aae7ebdd",
           "duration_ms":9089,"environment":"production",
           "host":"web-prod-01.us-west1.example.com","level":"INFO",
           "location":"us-west1","message":"Application security testing, ...",
           "region":"ca-central-1","request_id":"...","service":"event-bus",
           "span_id":"...","timestamp":"2026-09-03T11:26:51.27845118Z",
           "trace_id":"...","version":"2.0.0"})

Attributes:
     -> log_type: Str(appjson)
     -> net.transport: Str(IP.TCP)
     -> net.host.port: Str(5143)

Timestamp:      1970-01-01 00:00:00      <-- not set
SeverityText:                            <-- not set
SeverityNumber: Unspecified(0)
```

**Three separate problems, and they are worth naming separately** — each is a
distinct fix and a distinct "before/after" on screen:

1. **No fields.** The whole record is one string. Nothing is queryable,
   filterable, or routable by content.
2. **No timestamp.** Every record claims 1970. The JSON *contains* the real
   timestamp; nothing has promoted it.
3. **No severity.** `level: FATAL` and `level: INFO` are indistinguishable to
   the collector. Severity-based filtering and alerting cannot work.

Problems 2 and 3 are the interesting ones for a demo, because they survive the
obvious fix. Parsing the JSON gets you fields — it does **not** fix the timestamp
or the severity.

## Showing the starting state

The debug destination is the quickest way to put a record on screen. Temporarily
add it to `grrcon-appjson` and raise verbosity:

```bash
# bindplane/20-source-appjson.yaml -> add to the logs route:
#     - destinations/d-grrcon-debug-out
# bindplane/40-gateway.yaml -> verbosity: detailed
bindplane apply -f bindplane/
bindplane rollout start grrcon-gateway     # the destination lives here
bindplane rollout start grrcon-appjson     # then the config that uses it

docker logs --since 30s bdot-appjson | grep -A20 'LogRecord #'
```

Two gotchas, both of which will waste stage time if you hit them cold:

- **Roll out the gateway config first.** `grrcon-debug-out` is defined in
  `40-gateway.yaml`; a config referencing it picks up the *version it was
  applied against*, so rolling `grrcon-appjson` before the destination's new
  version exists leaves you on `verbosity: basic` and no visible records.
- **`verbosity: basic` prints a count, not a record.** If you only see
  `"msg":"Logs" ... "log records": 9`, verbosity did not take effect.

## The flow

### Step 1 — parse the JSON body

Processor: **Parse JSON** (`parse_json`), on the `grrcon-appjson-in` source.

- `log_source_field_type`: `Body`
- Leave the field selector empty to parse the whole body

Result: the body becomes a map, and every key is its own field —
`component`, `service`, `host`, `level`, `duration_ms`, `trace_id`, and the rest.

There is also a shipped **`parse-json-bundle`** blueprint ("Parses a JSON object
from the log body and creates new fields for each key"). Using the blueprint is
the faster path; using the raw processor shows what the blueprint is doing. Pick
based on which story you are telling.

**The reveal:** fields appear, and the timestamp is *still* 1970 and severity is
*still* unset. This is the moment worth pausing on — "parsed" is not the same as
"usable".

### Step 2 — promote the real timestamp

Processor: **Parse Timestamp** (`parse_timestamp_v2`).

- `log_field_type`: `Body`
- `log_source_field`: `timestamp`
- Format: RFC3339 (the generator emits `2026-09-03T11:26:51.27845118Z`)

Result: `Timestamp` becomes the event's own time instead of 1970. Worth showing
a time-ordered view before and after — 1970 timestamps do not merely look wrong,
they break retention, ordering, and any time-windowed query downstream.

> The `tcp` source can do this itself (`parse_timestamp: true`,
> `timestamp_field: timestamp`), and so can most sources. Doing it as a processor
> here is a deliberate teaching choice — it separates the three fixes so each
> lands on its own.

### Step 3 — map `level` onto OTel severity

Processor: **Parse Severity Fields** (`parse_severity_v2`).

- `match`: `Body`
- `body_severity_field`: `level`

Result: `level: FATAL` becomes `SeverityNumber: Fatal`, `INFO` becomes `Info`,
and so on. Now severity-based filtering works.

**Contrast worth drawing:** the CEF stream got this for free — its
`common_event_format` plugin runs a `severity_parser`, so `severity=1` was
already `SeverityNumber: Info(9)` on arrival. The native source did in one step
what took three here. That is the honest argument for native sources, and it
lands better if you have just done the work by hand.

### Step 4 (optional) — now that it is structured, reduce it

With fields and severity in place, the usual reduction tools become available:

- **Filter by Severity** (`filter_severity`) — drop everything below WARN
- **Deduplicate Logs** (`log_dedup_v2`) — collapse repeated bursts
- **Filter by Condition** (`filter-by-condition`) — drop by `component` or `host`

This is the ingest-cost story, and it only becomes possible *after* steps 1–3.
Before parsing, the pipeline cannot tell a FATAL from a health check.

## Suggested narrative arc

1. **Show the raw record.** One string, 1970, no severity. "This is what most
   application logs actually look like arriving at a SIEM."
2. **Contrast with `cef` or `apache`.** Same demo, same collector — those
   arrive fully parsed because a native source knew the format. Nothing knows
   this one.
3. **Fix it in three steps**, pausing after step 1 to show that fields alone are
   not enough.
4. **Then reduce it**, which is only possible now.
5. **Close on the trade-off:** native source where one exists, processors where
   none does — and the same pipeline handles both.

## Resetting between runs

The stream is stateless, so a reset is just reverting the config:

```bash
git checkout bindplane/20-source-appjson.yaml bindplane/40-gateway.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-appjson
bindplane rollout start grrcon-gateway
```

Check you are back to the starting state:

```bash
# catch-all must be 0 -- log_type routing is independent of parsing
for i in $(seq -w 1 10); do
  docker logs --since 3m bdot-$i 2>&1 \
    | grep -o '"log records":[0-9]*' | awk -F: '{s+=$2} END{print s+0}'
done | paste -sd+ - | bc
```

## Things that will not break, and one that will

**Routing is independent of parsing.** `log_type: appjson` is stamped by a
separate `add` operator on the source, not by the parser. You can add, remove, or
break every processor in this flow and the gateway router will still route the
stream correctly. Verified: catch-all stayed 0 across the switch from
`parse_format: json` to `none`.

**Turning native parsing back on is one line.** `parse_format: json` on
`grrcon-appjson-in` restores the built-in `json_parser` and skips step 1
entirely. Useful if the demo runs long and you want to jump to steps 2–3.

**The gateway rollout pauses between stages, and it looks like a failure.**
`grrcon-gateway` uses a progressive rollout (Canary `env=canary` → Prod
`env=prod`), so mid-rollout it reports:

```
grrcon-gateway:5  Paused  STAGE=Prod  completed=2  errors=0  waiting=8
```

That is stage 1 finished and stage 2 awaiting approval — `errors=0` is the tell.
`bindplane rollout resume grrcon-gateway` advances it. Do not debug it as an
outage on stage.

## Reference

- Stream definition: `bindplane/20-source-appjson.yaml`
- Generator: `blitz-json` in `docker-compose.blitz.yaml`
- Debug destination: `grrcon-debug-out` in `bindplane/40-gateway.yaml`
- Field list and generator internals: README, "What blitz generates" → section 3
