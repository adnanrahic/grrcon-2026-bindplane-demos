# What blitz generates

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

## What blitz generates

`docker-compose.blitz.yaml` runs five generators, each pointed at **its own edge
collector**. No syslog and no `APPNAME` any more: the collector a stream reaches
is its identity. Raw TCP carries the generator's line verbatim; the two streams
with a native file-based source write files instead. See "Native formats" for why.

| Service | Transport | Target | Generator | Source | Rate | Workers |
|---|---|---|---|---|---|---|
| `blitz-winsec` | tcp | `bdot-winsec:5142` | `filegen` | `./samples/winsec.xml` | 500ms | 2 |
| `blitz-palo-alto` | tcp | `bdot-panos:5141` | `filegen` | `./samples/palo-alto.log` | 500ms | 2 |
| `blitz-json` | tcp | `bdot-appjson:5143` | `json` | `default`, synthesized | 1s | 1 |
| `blitz-cef` | file | `/var/log/cef/events.log` | `filegen` | `./samples/cef.log` | 1s | 1 |
| `blitz-apache-native` | file | `/var/log/apache2/access.log` | `apache-common` | generated | 1s | 1 |


`blitz-apache` (the old `filegen` + `package:apache` service) has been removed:
its lines carry an embedded syslog prefix and two leading IPs, so no Apache
parser can match them. `blitz-apache-native` supersedes it.

`filegen` picks **one random line per cycle**, so a file's line mix is the mix on
the wire.

### 1. Windows Security events -- `blitz-winsec`

Windows Event Log XML, replayed from `samples/winsec.xml` (67 lines):

| EventID | Count | Meaning |
|---|---|---|
| 4624 | 52 | successful logon |
| 4688 | 6 | process creation |
| 4625 | 6 | failed logon |
| 4740 | 3 | account lockout |

That is ~78% benign successful logons burying the events that matter -- the
point being that filtering them is obviously worthwhile. Retune the ratio with
`samples/generate-winsec.sh`.

Rate note: the compose file defaults to `150ms`, but `.env` sets
`WINSEC_RATE=500ms`, which wins. Check `.env` before quoting a throughput number.

### 2. Palo Alto -- `blitz-palo-alto`

Native PAN-OS CSV, the format the Palo Alto blueprint parses. The
`samples/palo-alto.log` holds 15 lines across 13 log types, copied verbatim
from the upstream `palo-alto/csv` package:

`authentication`, `config`, `correlation`, `decryption`, `globalprotect` (2),
`gtp`, `hipmatch`, `iptag`, `sctp`, `system` (2), `threat`, `traffic`, `userid`

Because the pool is only 15 lines, this is a parser and enrichment exercise
rather than a volume source.

### 3. Mixed-format JSON app log -- `blitz-json`

Synthesized, not replayed. The `default` type emits a flat JSON object with
these fields:

```
timestamp  level  environment  location  message  service  host
request_id trace_id span_id duration_ms component version
correlation_id region
```

**Deliberately left unparsed.** The `tcp` source *can* parse it natively --
`parse_format: json` renders a `json_parser` with `parse_to: body` -- but
`grrcon-appjson-in` sets `parse_format: none`, so the body arrives as a raw JSON
string:

```
Body: Str({"component":"storage","correlation_id":"21164fa7-...","level":"INFO",...})
```

That is the point of this stream: no blueprint covers this shape, so it is the
one worth demonstrating hand-built parsing processors on. Turning native parsing
back on is a one-line change to `parse_format`.

`log_type` is stamped by a separate `add` operator, independent of
`parse_format`, so routing keeps working either way.

Two things the tcp source does **not** do even with parsing enabled: it leaves
the record `Timestamp` at 1970 unless `parse_timestamp: true` /
`timestamp_field: timestamp` are set, and it has no severity option at all, so
`level: FATAL` never becomes an OTel severity. CEF gets both for free from its
plugin's `severity_parser`.

The generator also supports a `pii` type (`BLITZ_GENERATOR_JSON_TYPE: pii`) if
you want a redaction story instead.

### 4. CEF -- `blitz-cef`

Vendor-neutral `CEF:0` records replayed from `samples/cef.log`, written to
`/var/log/cef/events.log` and tailed by the native `common_event_format` source.

**Not `package:universal-cef`.** Those samples are bare `CEF:0|...` lines, and
the Bindplane CEF source parses with a regex that requires a syslog prefix:

```
^(?P<timestamp>\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+((?P<hostname>[^\s]+)\s+)?(?P<cef_headers>[\d\D]+)
```

Against bare lines that never matches, the operator chain aborts, and records
arrive **completely unparsed -- silently**. No error is logged and throughput
looks healthy; the only symptoms are a string body and a 1970 timestamp.

`samples/cef.log` carries the prefix, so the native parser produces:

```
Timestamp: 2026-09-02 13:49:15          (parsed, not 1970)
SeverityText: 1   SeverityNumber: Info(9)
Attributes: device_vendor=Identity  device_product=IdP  device_version=1.2
            signature_id=2001  name=Auth_Success  severity=1
            hostname=siem-edge-01  extensions="src=... suser=... cat=..."
```

Use `%d` (zero-padded day), not `%e` (space-padded): the plugin's layout is
gotime `Jan 02 15:04:05`, and `Sep  2` will not match a `02` layout.

54 lines, ~74% severity 1-3 noise, so filtering and volume reduction have
something to bite on. Retune with `samples/generate-cef.sh`.

**No CEF blueprint exists** -- none of the 33 targets CEF. `extensions` also
arrives as one unsplit key=value string; splitting it needs a downstream parser
(`parse-regex-bundle` is the closest shipped option).


### 5. Apache web-server logs -- `blitz-apache`

Feeds the Apache/NGINX Full-Pipeline Blueprint, which otherwise has no data to
work on. Five lines from `package:apache`, with two caveats worth knowing before
you put this on a projector.

**These are not Common Log Format.** They are syslog-wrapped and carry two
leading IPs plus trailing referer and user-agent -- Combined, not Common:

```
<86>%c apache.httpserver.test httpd: 10.0.0.1 10.0.0.2 - - [%d/%b/%Y:%H:%M:%S +0000] "POST /login HTTP/1.1" 401 512 "-" "curl/7.64.1"
```

Reading left to right: syslog priority, timestamp, host, `httpd:` tag, then
*two* IPs where CLF has a single host field, then the usual
`ident authuser [date] "request" status bytes`, then Combined's
`"referer" "user-agent"`.

**One of the five lines is not a web log at all.** It is an sshd `pam_vas`
authentication record. Since `filegen` picks one random line per cycle, roughly
20% of this stream is an SSH auth event rather than an HTTP request. Useful if
you want to show mixed-source noise; misleading if you are demoing pure web
traffic.

The `%c` and `%d/%b/%Y` directives are strftime placeholders, so timestamps are
live rather than collector-stamped.

Swap `BLITZ_GENERATOR_FILEGEN_SOURCE` to `package:nginx` for the same shape from
NGINX (`access.log`, 5 lines, plus `upstream_error.log` and `leef_status.log`),
or point it at a file under `./samples` for a hand-tuned Common Log Format mix
with no sshd contamination.

### No data library dependency

`package:` sources are not in the blitz image -- it is `FROM scratch` and ships
only the binary, so they used to be bind-mounted from a blitz clone at
`${BLITZ_REPO:-../blitz}/generator/filegen/embeddedlibrary/data_library`.

**Nothing uses `package:` any more.** Every replayed sample is vendored into
`./samples`, so the stack runs with no blitz checkout present -- verified by
renaming the clone away and restarting the generators.

The Palo Alto lines were the last holdout; `samples/vendor-palo-alto.sh`
refreshes them from upstream and is the only thing that still wants a clone
(honours `BLITZ_REPO`).

### Tunables

All optional, override in `.env`:

```
BLITZ_VERSION=latest   BLITZ_LOG_LEVEL=info
WINSEC_RATE=500ms      WINSEC_WORKERS=2
PAN_RATE=500ms         PAN_WORKERS=2
JSON_RATE=1s           JSON_WORKERS=1
CEF_RATE=1s            CEF_WORKERS=1
APACHE_RATE=1s         APACHE_WORKERS=1
EDGE_TARGET=bdot-edge-01                  COLLECTOR_NETWORK=bdot-net
```

`EDGE_TARGET` picks which edge collector the three `*-gw` generators feed; set it
to `bdot-edge-pool` to scatter them across the tier instead. The TCP ports are
hardcoded in compose, not tunable.

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
