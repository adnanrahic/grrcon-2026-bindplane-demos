# Demo: native sources — when the format does the work

The `apache` and `cef` streams: the pattern with the least to show on screen.

| Walkthrough | Pattern | Processors you write |
|---|---|---|
| [`demo-json-parsing.md`](demo-json-parsing.md) | nothing ships | 3, by hand |
| [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md) | blueprint | 0 — 32 shipped |
| **this one** | **native source** | **0 — parses on ingest** |

Pick the right source type and records arrive structured. The demo value is the
setup constraint and the failure mode.

## These sources read files

Every format-specific source — `apache_common`, `apache_combined`,
`apache_http`, `nginx`, `common_event_format`, `csv`, `w3c`, `iis` — renders to a
`plugin/...` receiver resolving to `file_log`. **None has a listener mode.** Only
generic sources accept pushed data (`syslog`, `tcp`, `udp`, `otlp`, `http`,
`splunk_tcp`, `splunkhec`, `fluentforward`), so something must write a file.
Here, blitz:

```
blitz-apache-native  --file-->  /var/log/apache2/access.log  <--tail--  bdot-apache
blitz-cef            --file-->  /var/log/cef/events.log      <--tail--  bdot-cef
```

These are also the only streams where edge-tier tailing multiplies volume — ten
collectors reading one file read every line ten times.

## Apache

`blitz-apache-native` → `/var/log/apache2/access.log` → `bdot-apache`
(`grrcon-apache`, type `apache_common`) → Elastic.

`/var/log/apache2/access.log` is the default for both `apache_common` and
`elasticsearch-apache-common-full-pipeline`, so nothing needs repointing. blitz
uses its native `apache-common` generator, not `filegen`:

```
124.159.111.209 - - [02/Sep/2026:12:16:27 +0000] "DELETE /api/v1/products HTTP/1.1" 200 9482648
```

Arriving parsed, no processors involved:

```
Body: Map({"remote_addr":"77.62.106.165","remote_host":"-","remote_user":"-",
           "method":"DELETE","path":"/api/v1/transfers","protocol":"HTTP",
           "protocol_version":"1.1","status":"204","body_bytes_sent":"7585681",
           "time":"02/Sep/2026:12:20:06 +0000","log_type":"apache_common"})
Attributes: log.file.name: Str(access.log)
```

`log_type` lands in the **body**, not attributes — `apache_common` parses into
the body. Hence the router matches `body["log_type"] == "apache_common"` for this
stream and `attributes["log_type"]` for every other.

### Pairing with the Elasticsearch blueprint

`elasticsearch-apache-common-full-pipeline` terminates at Elastic, matching this
pipeline. Twelve processors: CLF and timestamp parsing, health-check and
static-asset filters, status→severity mapping, masking, high-cardinality field
removal, ECS fields, success sampling, error dedup, empty-field deletion, and
batching.

**Before adopting it:** the blueprint sets `parse: false` and runs its own
`parse_regex`, expecting a **raw** body. Our config has `parse: true`, so
applying it unchanged runs the blueprint's regex against an already-parsed map.
Two valid designs — parse at the source, or parse in the pipeline — and the
blueprint chose the second so it could also do timestamp, severity, ECS and
sampling in one place.

## CEF

`blitz-cef` → `/var/log/cef/events.log` → `bdot-cef` (`grrcon-cef`, type
`common_event_format`) → Splunk HEC. Arriving parsed:

```
Timestamp: 2026-09-02 13:49:15
SeverityText: 1   SeverityNumber: Info(9)
Body: Str(Sep 02 13:49:15 siem-edge-01 CEF:0|Identity|IdP|1.2|2001|Auth_Success|1|src=...)
Attributes:
     -> device_vendor: Str(Identity)      -> device_product: Str(IdP)
     -> device_version: Str(1.2)          -> signature_id: Str(2001)
     -> name: Str(Auth_Success)           -> severity: Str(1)
     -> hostname: Str(siem-edge-01)       -> log_type: Str(cef)
     -> extensions: Str(src=... suser=... cat=...)
```

**CEF gets more for free than Apache.** Its chain is `regex_parser` →
`csv_parser` → `severity_parser`, so timestamp and severity resolve on ingest —
both separate hand-built steps in the JSON walkthrough.

**There is no CEF blueprint** among the 33. For a Splunk ingest-cost story here,
copy the toggleable-filter shape from
`palo-alto-full-log-parsing-and-reduction-bundle`; `samples/cef.log` is ~74%
severity 1–3 noise so `filter_severity` has something to remove.

`extensions` arrives as one unsplit `key=value` string — `parse_key_value` is the
natural downstream fit.

## The failure mode worth demonstrating

**A format-specific source parses only if the data matches its parser, and fails
silently otherwise.** No error, records still flow, throughput healthy. The only
symptoms are a **string body** and a **1970 timestamp**.

**CEF: library samples were bare.** `package:universal-cef` ships bare
`CEF:0|...`; the plugin's first operator requires a syslog prefix:

```
^(?P<timestamp>\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+((?P<hostname>[^\s]+)\s+)?(?P<cef_headers>[\d\D]+)
```

No match, chain aborts, records pass untouched. Fixed by writing
`samples/cef.log` **with** the prefix. Use `%d` (zero-padded), not `%e`: the
layout is gotime `Jan 02 15:04:05`, and `Sep  2` will not match `02` — that one
passes the regex and fails only at timestamp parsing.

**Apache: library samples were prefixed.** `package:apache` ships lines with a
`<86>… httpd:` syslog prefix *and* two leading IPs where CLF has one host field.
Fixed by using blitz's native `apache-common` generator. One of those five
library lines is also an sshd `pam_vas` record, not a web request.

**Showing it live:** point `blitz-cef` at `package:universal-cef`, re-apply, show
the string body and 1970 timestamp with zero errors, switch back. Thirty seconds,
and it justifies every verification step here.

## The permissions trap

blitz's file output (lumberjack) creates files **`0600`**, including after
rotation. Collectors run as `uid=10005(otel)`; blitz runs as root. A root-owned
`0600` file is unreadable and **the source tails nothing without reporting an
error** — same silent class as a format mismatch.

Mitigated by `user: "10005:10005"` on the blitz services plus a writable host
directory. After a first run:

```bash
mkdir -p logs/apache2 logs/cef && chmod 777 logs/apache2 logs/cef
chmod 644 logs/*/*.log
```

Check from inside the collector, the only view that matters:

```bash
docker exec bdot-apache stat -c '%U %a %n' /var/log/apache2/access.log   # otel 644
docker exec bdot-cef    stat -c '%U %a %n' /var/log/cef/events.log       # otel 644
```

## The flow

1. **Show a parsed record** for each — both configs are source → destination.
2. **Contrast with the JSON stream.** Same collectors, routing and destinations;
   that one arrives as a string because nothing knows its format.
3. **Break it deliberately** — point CEF at `package:universal-cef`, show the
   string body and 1970 timestamp with no errors, switch back.
4. **Note what CEF gets that Apache does not** — timestamp and severity on
   ingest, via `severity_parser`.
5. **Optionally add the Elasticsearch blueprint**, setting `parse: false` first.

Run this **last**: the audience has built a pipeline by hand (JSON) and seen one
arrive complete (Palo Alto). All three ran on the same collectors, routing and
destinations — only the amount of work differed.

## Resetting between runs

Both streams are file-based and stateless, so reverting the config is enough:

```bash
git checkout bindplane/20-source-apache.yaml bindplane/20-source-cef.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-apache
bindplane rollout start grrcon-cef
```

If you broke CEF deliberately, also revert the generator:

```bash
git checkout docker-compose.blitz.yaml
docker compose -f docker-compose.blitz.yaml up -d --force-recreate blitz-cef
```

## Traps

- **Exact file path, not a glob.** lumberjack rotates to siblings like
  `access-2026-09-02T….log`; a glob re-reads history.
- **Do not mount over `/var/log`.** The image has real `apt`/`dpkg.log` there.
- **Ten edge collectors tail these files**, so both are ingested ten times on the
  gateway path. Measured: Elastic ~89 → ~779 per 90s going from one edge
  collector to ten. The tcp streams do not amplify.
- **`log_type` is in the body for Apache**, attributes for CEF. A wrong routing
  condition matches nothing silently.

## Reference

Streams `bindplane/20-source-{apache,cef}.yaml`; generators
`blitz-apache-native` and `blitz-cef`; samples via `samples/generate-cef.sh`.
Apache blueprints: `elasticsearch-apache-common-full-pipeline`,
`elasticsearch-apache-common-logs`. **None for CEF.**
