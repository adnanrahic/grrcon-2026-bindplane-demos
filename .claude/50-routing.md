# Routing: wiring, misroutes, record shape

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

## Routing (gateway tier)

The edge tier forwards every source to `bdot-pool`, so the worker tier splits the
merged stream back apart and fans it out to the five backends.

`bindplane/10-connector-router.yaml` defines a `kind: Connector` of type `routing`. The
worker configuration sends logs into it, and it fans them out by source.

### Wiring, in three places

```yaml
spec:
  sources:
    - id: s-grrcon-gateway-in
      routes:
        logs:
          - id: "0"
            components: [connectors/c-grrcon-router]   # source -> connector
  connectors:
    - id: c-grrcon-router
      name: grrcon-router
      routes:
        logs:
          - id: winsec                                  # id MUST match a route
            components: [destinations/d-grrcon-google-secops]  # id in router.yaml
  destinations:
    - id: d-grrcon-google-secops
      name: grrcon-google-secops
```

Routes are **first match wins**. The connector still declares an unconditioned
`unmatched` route last, but `grrcon-gateway` no longer wires it to a
destination -- so anything not matching the five conditions is dropped.

### Detecting a misroute

**There is no catch-all.** `grrcon-router` declares five conditioned routes and
nothing else, so a record matching none of them is dropped by the connector with
nothing to observe it.

That was a two-step loss, worth knowing because the intermediate state is
misleading. When the `unmatched` route still existed but `grrcon-gateway` did not
wire it anywhere, Bindplane synthesised a terminal branch and **kept a
`throughputmeasurement` processor** on it, so the catch-all stayed measurable in
the UI even though `nop` printed no records:

```yaml
logs/c-c-grrcon-router__unmatched:
    processors: [throughputmeasurement/_p1_logs_c-c-grrcon-router__unmatched]
    exporters:  [forward/d-no_routes__c-c-grrcon-router__unmatched]
logs/d-no_routes__c-c-grrcon-router__unmatched:
    exporters:  [nop/c-c-grrcon-router]
```

Removing the route itself removed that branch too — a gateway collector's
rendered config now has zero `unmatched` and zero `nop/` references. So misroute
throughput is no longer readable anywhere; **per-exporter counts are the only
signal**. Re-add `- id: unmatched` as the last route in
`bindplane/10-connector-router.yaml` to get the measurable branch back.

Diagnosing one: per-exporter output on the gateway tier — one column drops to
zero while the others hold:

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

**Use a 3m window, not 60s.** Grepping the backend name gives the *same* counts
as the component-id parse — verified on one captured window: Elastic 244/244,
Splunk 2359/2359, Dynatrace 135/135, googlecloud 37/37. What burned an
investigation here was the window, not the method: Elastic is bursty on the
gateway tier and read 0 over 60s while healthy at 244 over 3m.

The component-id form is still preferred, for two reasons that are not about
accuracy: it enumerates every exporter including ones you forgot to list (that
is how `chronicle/grrcon-google-secops` shows up at all), and it cannot be fooled
by a backend name appearing in unrelated text.

The chronicle exporter still fails quietly — 7 lines in 3m against Splunk's
1674 — so a low `chronicle/grrcon-google-secops` count is not evidence of a
problem. Use UI throughput for the winsec branch.

To read the records, wire a temporary debug destination to `unmatched`; see
`docs/claude-generated/demo-json-parsing.md`. It is deliberately not committed.

### Every source stamps `log_type` — but not all in the same place

Routes match on `log_type`, the idiomatic Bindplane routing key. The catch is
that sources put it in different places:

| Source | Where `log_type` lands | Condition |
|---|---|---|
| `tcp` (winsec, panos, appjson) | attribute | `attributes["log_type"] == …` |
| `common_event_format` (cef) | attribute | `attributes["log_type"] == "cef"` |
| `apache_common` | **body field** | `body["log_type"] == "apache_common"` |

`apache_common` regex-parses into the body, so its `log_type` ends up a body
field and the only attribute on the record is `log.file.name`. Getting this
wrong matches nothing **silently**, and with no catch-all those records are
dropped unobserved. See [Detecting a misroute](#detecting-a-misroute), then check
which side of the record its `log_type` is on.

### Record shape: raw body, metadata in attributes

> **Historical.** No syslog source remains in the demo — every stream now uses a
> native file source or raw TCP. The `parse_to` and unwrap mechanics below are
> kept because they apply to any Bindplane syslog source you add later.

Bindplane Blueprints match the **raw log line**. Getting the record into that
shape takes two things, and neither is the default.

**1. `parse_to: attributes` on the syslog source.** The default (`body`) rewrites
the body into a map of syslog parts, which no blueprint matches.

**2. A transform processor on the edge tier.** `parse_to: attributes` alone still
leaves the body as the *whole* raw line, syslog header included:

```
<14>Sep  2 11:06:53 siem-edge-01 cef[pid42]: CEF:0|Enterprise|SIEM|...
```

The parser already extracted the clean payload into `attributes["message"]`, so
`grrcon-syslog-unwrap` promotes it and drops the duplicate:

```yaml
- set(body, attributes["message"]) where attributes["message"] != nil
- delete_key(attributes, "message")
```

It is attached to the syslog source only, so the OTLP source is untouched, and it
runs on the edge tier so every worker receives clean records.

The result:

```
Body: Str(CEF:0|Endpoint|EDR|4.0|Threat|Ransomware|10|host=WORKSTATION01 ...)
Attributes:
     -> appname:       Str(cef)
     -> hostname:      Str(siem-edge-01)
     -> facility:      Int(1)
     -> facility_text: Str(user)
     -> priority:      Int(14)
     -> proc_id:       Str(123)
```

**Two streams are still wrapped, and this pipeline cannot fix them.** The
`palo-alto` and `apache` packages ship source lines with their *own* syslog
prefix baked in, upstream in the blitz data library:

| Stream | Body | Blueprint-ready |
|---|---|---|
| `winsec` | `<Event xmlns="http://schemas.microsoft.com/...` | yes |
| `cef` | `CEF:0\|Identity\|IdP\|1.2\|...` | yes |
| `appjson` | `{"component":"cache",...` | yes |
| `paloalto` | `Sep  2 11:13:17 localhost 1,2026/09/02,...` | **no** -- embedded prefix |
| `apache` | `<86>Wed Sep 02 ... httpd: 10.0.0.1 ...` | **no** -- embedded prefix |

Unwrapping the outer syslog layer cannot reach a prefix that is part of the
source data. If the PAN or Apache blueprints need bare payloads, either add a
second transform that strips the embedded prefix per appname, or write clean
samples into `samples/` the way `winsec.xml` works.

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
