# Demo: native sources — when the format does the work

A walkthrough for the `apache` and `cef` streams. This is the third pattern in
the set, and the one with the least to show on screen — which is the point.

| Walkthrough | Pattern | Processors you write |
|---|---|---|
| [`demo-json-parsing.md`](demo-json-parsing.md) | nothing ships | 3, by hand |
| [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md) | full pipeline blueprint | 0 — 32 shipped |
| **this one** | **native source** | **0 — the source parses on ingest** |

No blueprint, no processors, no OTTL. You pick the right source type and records
arrive structured. The demo value is the setup constraint and the failure mode,
not the pipeline.

## The constraint that shapes everything: these sources read files

Every format-specific log source in Bindplane — `apache_common`,
`apache_combined`, `apache_http`, `nginx`, `common_event_format`, `csv`, `w3c`,
`iis` — renders to a `plugin/...` receiver that resolves to `file_log`.
**None has a listener mode.** Nothing can push to them over a network.

Only generic sources accept pushed data: `syslog`, `tcp`, `udp`, `otlp`, `http`,
`splunk_tcp`, `splunkhec`, `fluentforward`.

So a native source needs something to write a file. In this demo blitz does it:

```
blitz-apache-native  --file-->  /var/log/apache2/access.log  <--tail--  bdot-apache
blitz-cef            --file-->  /var/log/cef/events.log      <--tail--  bdot-cef
```

That is also why these two streams are the only ones where `bdot-edge-*` tailing
multiplies volume — ten collectors reading one file read every line ten times.
See the README's "Ten edge collectors tail the same files".

## Apache

`blitz-apache-native` → `/var/log/apache2/access.log` → `bdot-apache`
(config `grrcon-apache`, source type `apache_common`) → Elastic.

**The path is the blueprint's default.** `/var/log/apache2/access.log` is what
both `apache_common` and `elasticsearch-apache-common-full-pipeline` expect, so
nothing needs repointing later.

blitz uses its **native `apache-common` generator**, not `filegen`, which
constructs real Common Log Format:

```
124.159.111.209 - - [02/Sep/2026:12:16:27 +0000] "DELETE /api/v1/products HTTP/1.1" 200 9482648
```

Arriving parsed, with no processors involved:

```
Body: Map({"remote_addr":"77.62.106.165","remote_host":"-","remote_user":"-",
           "method":"DELETE","path":"/api/v1/transfers","protocol":"HTTP",
           "protocol_version":"1.1","status":"204","body_bytes_sent":"7585681",
           "time":"02/Sep/2026:12:20:06 +0000","log_type":"apache_common"})
Attributes: log.file.name: Str(access.log)
```

Note `log_type` lands in the **body**, not attributes — `apache_common` parses
into the body. That is why the gateway router matches
`body["log_type"] == "apache_common"` for this stream while every other stream
matches `attributes["log_type"]`. See the README's Routing section.

### Pairing with the Elasticsearch blueprint

`elasticsearch-apache-common-full-pipeline` exists and terminates at Elastic,
matching this pipeline's destination. Twelve processors:

```
Parse Apache Common Log Format   Parse Apache Timestamp
Filter Health Checks             Filter Static Asset Requests
Map HTTP Status to Severity      Mask Sensitive Data
Remove High-Cardinality Fields   Add ECS-Compatible Fields
Sample Success Responses         Deduplicate Error Responses
Delete Empty Fields              Batch for Elasticsearch
```

**One detail worth knowing before you adopt it:** the blueprint sets
`parse: false` on its `apache_common` source and does its own `parse_regex`. It
expects a **raw** body. Our config has `parse: true`, so applying the blueprint
without flipping that leaves the blueprint's regex running against an
already-parsed map.

That is a good demo beat rather than a gotcha to hide: two valid designs — let
the source parse, or let the pipeline parse — and the blueprint chose the second
so it could also handle timestamp, severity, ECS fields and sampling in one
place.

## CEF

`blitz-cef` → `/var/log/cef/events.log` → `bdot-cef`
(config `grrcon-cef`, source type `common_event_format`) → Splunk HEC.

Arriving parsed:

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

**CEF gets more for free than Apache does.** Its plugin chain is
`regex_parser` → `csv_parser` → `severity_parser`, so the timestamp resolves and
`severity=1` becomes `SeverityNumber: Info(9)` on ingest. Compare the JSON
walkthrough, where mapping `level` onto severity was its own processor and its
own step.

**There is no CEF blueprint.** None of the 33 targets CEF. If you want the
Splunk ingest-cost story on this stream you build the reduction yourself —
`palo-alto-full-log-parsing-and-reduction-bundle` has the toggleable-filter shape
worth copying, and `samples/cef.log` is ~74% severity 1–3 noise specifically so
`filter_severity` has something to remove.

`extensions` also arrives as one unsplit `key=value` string. Splitting it needs a
downstream parser (`parse_key_value` is the natural fit).

## The failure mode worth demonstrating

Both of these broke on first attempt, in the same way, and it is the most
useful thing in this walkthrough.

**A format-specific source parses only if the data matches what its parser
expects. When it does not match, it fails silently.** No error is logged, the
records still flow, throughput looks healthy. The only symptoms are a **string
body** and a **1970 timestamp**.

### CEF: the library samples were bare

`package:universal-cef` ships bare `CEF:0|...` lines. The plugin's first operator
requires a syslog prefix:

```
^(?P<timestamp>\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+((?P<hostname>[^\s]+)\s+)?(?P<cef_headers>[\d\D]+)
```

No match, chain aborts, records pass through untouched. Fixed by writing
`samples/cef.log` **with** the prefix (`%b %d %T siem-edge-01 CEF:0|...`).

Use `%d` (zero-padded day), not `%e` (space-padded): the plugin's layout is
gotime `Jan 02 15:04:05`, and `Sep  2` will not match a `02` layout. That one
gets you past the regex and fails only at timestamp parsing — a subtler version
of the same silent failure.

### Apache: the library samples were prefixed

`package:apache` ships the opposite problem — lines with a `<86>… httpd:` syslog
prefix *and* two leading IPs, where CLF has one host field. The regex expects the
record to start at `remote_addr`. Fixed by using blitz's native `apache-common`
generator instead of replaying the library.

One of those five library lines is also an sshd `pam_vas` record, not a web
request at all.

### Showing it live

Point `blitz-cef` back at `package:universal-cef`, re-apply, and show the record:
string body, 1970 timestamp, zero errors anywhere. Then switch back. It is a
thirty-second demonstration of why "data is flowing" is not the same as "data is
parsed", and it justifies every verification step in this repo.

## The permissions trap

Both streams depend on a file the collector can read, and blitz's file output
(lumberjack) creates files **`0600`** — including after rotation. Collectors run
as `uid=10005(otel)`; the blitz image is `FROM scratch` running as root.

A root-owned `0600` file is unreadable, and **the source tails nothing without
reporting an error** — the same silent class as a format mismatch.

Mitigated by `user: "10005:10005"` on the blitz services plus a writable host
directory. After a first run on a fresh clone:

```bash
mkdir -p logs/apache2 logs/cef && chmod 777 logs/apache2 logs/cef
chmod 644 logs/*/*.log
```

Check from inside the collector, which is the only view that matters:

```bash
docker exec bdot-apache stat -c '%U %a %n' /var/log/apache2/access.log   # otel 644
docker exec bdot-cef    stat -c '%U %a %n' /var/log/cef/events.log       # otel 644
```

## The flow

1. **Show a parsed record** for each stream. No processors on either
   configuration — open them and show the pipeline is source → destination.
2. **Contrast with the JSON stream.** Same collector, same routing, same
   destinations; that one arrives as a string because nothing knows its format.
3. **Break it deliberately** — point CEF at `package:universal-cef`, show the
   string body and 1970 timestamp with no errors, switch back.
4. **Note what CEF gets that Apache does not** — timestamp and severity parsed
   on ingest, because the CEF plugin runs a `severity_parser`.
5. **Optionally add the Elasticsearch blueprint** to Apache, remembering to set
   `parse: false` first.

## Suggested placement in the set

Run this one **last**. The audience has built a pipeline by hand (JSON), seen an
expert's pipeline arrive complete (Palo Alto), and now sees the case where the
answer was picking the right source type — provided the data is in the shape the
parser expects. The closing point is that all three ran on the same collectors,
the same routing and the same destinations; only the amount of work differed.

## Resetting between runs

Both streams are file-based and stateless — reverting the config is enough:

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

**Use the exact file path, not a glob.** lumberjack rotates to siblings like
`access-2026-09-02T….log`; a glob would tail those too and re-read history.

**Do not mount over `/var/log`.** The collector image has real content there
(`apt`, `dpkg.log`). Mount only `/var/log/apache2` and `/var/log/cef`.

**Ten edge collectors tail these same files**, so both streams are ingested ten
times over on the gateway path. Measured: Elastic went from ~89 to ~779 per 90s
when the edge tier grew from one collector to ten. The tcp streams do not
amplify.

**`log_type` is in the body for Apache**, in attributes for CEF. Routing
conditions differ accordingly, and getting it wrong matches nothing silently.

## Reference

- Stream definitions: `bindplane/20-source-apache.yaml`, `bindplane/20-source-cef.yaml`
- Generators: `blitz-apache-native`, `blitz-cef` in `docker-compose.blitz.yaml`
- Sample regeneration: `samples/generate-cef.sh`
- Blueprints: `elasticsearch-apache-common-full-pipeline`,
  `elasticsearch-apache-common-logs` (Apache); **none for CEF**
- Companion walkthroughs: [`demo-json-parsing.md`](demo-json-parsing.md),
  [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md)
