# GrrCON demo: Bindplane-managed gateway topology

Eleven BDOT collectors in Docker, all managed from Bindplane Cloud over OpAMP:
one ingress collector holding the only open ports, fanning telemetry out across
a pool of ten workers, which split it back apart by source and send each stream
to its own backend.

```
  5 blitz streams (winsec · paloalto · appjson · apache · cef)
          |  RFC 3164 syslog, one APPNAME per stream
          v  localhost:5140/udp   (also 4317/4318 OTLP)
  +-----------------+
  |  bdot-ingress   |   fleet=grrcon-ingress
  +-----------------+
          |  bdot-pool:4317, gRPC round-robin
          v
  +---------------------------------------------------------------+
  | bdot-01  bdot-02 | bdot-03 bdot-04 ... bdot-10                 |
  |   env=canary     |            env=prod                         |
  +---------------------------------------------------------------+
              fleet=grrcon, role=worker, alias bdot-pool
          |
          v  routing connector, matching attributes["appname"]
  +--------------+------------+---------+-------------+-----------+
  | winsec       | paloalto   | appjson | apache      | cef       |
  | Google SecOps| Dynatrace  |Dynatrace| Elastic     | Splunk HEC|
  +--------------+------------+---------+-------------+-----------+
                     unmatched -> debug (should always be empty)
```

Nothing in `docker-compose.yaml` defines a pipeline. The collectors register,
report their labels, and pull their configuration from Bindplane. Pipelines
live in `bindplane/`.

## Why it is shaped this way

**`bdot-pool` is a shared Docker network alias**, declared by all ten workers.
Docker's embedded DNS returns all ten container IPs for that one name, so the
ingress destination targets a single hostname with gRPC load balancing enabled.
Add or remove workers and the Bindplane config never changes.

**Only the ingress publishes ports.** The workers listen on 4317 inside
`bdot-net` only. One door in, ten collectors behind it -- and no ten-way fight
over port 4317 on your laptop.

**The ingress lives in its own fleet.** A collector can belong to exactly one
fleet at a time, so `fleet=` is the one mutually exclusive label here: the
ingress is `fleet=grrcon-ingress`, the ten workers are `fleet=grrcon`. The front
door can be upgraded, restarted, or rolled without touching the pool, and a
fleet-wide action aimed at the workers can never reach it.

**The ingress is not labeled `env=`.** It is also the only collector without a
SecOps exporter, so it needs no credentials file.

**Agent IDs are pinned ULIDs** (`...BD0T00` through `...BD0T10`), so the same
eleven agents reconnect after any restart -- even `docker compose down -v`.
Without pinning, every teardown mints new agents and orphans the old ones.

**Both configurations use `apiVersion: bindplane.observiq.com/v2`**, which adds
advanced routing: explicit source-to-destination connections instead of an
implicit fan-out. See "Configuration v2" below.

## Setup

### 1. Environment

```bash
cp .env.example .env      # fill in BINDPLANE_SECRET_KEY
```

### 2. Dummy SecOps credentials

The Google SecOps exporter reads a service-account JSON **at startup**. If the
file is missing or unparseable the collector fails to start and the whole
rollout halts -- so this file is required even when you have no intention of
shipping to SecOps.

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/k.pem
python3 - <<'PY'
import json, secrets
open('credentials.json','w').write(json.dumps({
  "type": "service_account",
  "project_id": "grrcon-demo",
  "private_key_id": secrets.token_hex(20),
  "private_key": open('/tmp/k.pem').read(),
  "client_email": "grrcon-demo@grrcon-demo.iam.gserviceaccount.com",
  "client_id": "".join(secrets.choice("0123456789") for _ in range(21)),
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/grrcon-demo",
  "universe_domain": "googleapis.com",
}, indent=2) + "\n")
PY
rm /tmp/k.pem
```

The key is real (2048-bit RSA) but the identity is fake. That combination is
deliberate: the exporter *parses* the key, so a placeholder string like
`REPLACE_ME` crashes it exactly the way a missing file does. A real key with a
fake identity loads cleanly and then fails at the network -- which looks like a
working exporter that cannot reach its backend.

`credentials.json` is gitignored. Never commit it, dummy or not.

Compose mounts it read-only at `/opt/credentials.json` on the **ten workers
only**; the ingress has no SecOps exporter and does not get it.

### 3. Point the CLI at your account

```bash
bindplane profile create grrcon \
  --remote-url https://app.bindplane.com \
  --api-key <YOUR_API_KEY>
bindplane profile use grrcon
```

Note this is an **API key**, a different credential from the
`BINDPLANE_SECRET_KEY` in `.env`. The secret key authenticates *collectors* over
OpAMP; the API key authenticates the *CLI* against the management API.

### 4. Apply, start, roll out -- in this order

```bash
bindplane apply -f bindplane/     # MUST come first
docker compose up -d
bindplane rollout start grrcon-workers
bindplane rollout start grrcon-ingress
```

**The order is not cosmetic.** A collector's `configuration=` label binds only
when its value *changes* while the named configuration already exists. Start the
collectors first and they register, evaluate the label against a configuration
that does not exist yet, and never re-check -- leaving all 11 sitting at
`CONFIGURATION: -` forever. Neither a container restart nor re-setting the label
to the same value fixes it. See "Recovering an unbound collector" below.

**`apply` alone is not enough.** It creates and versions the resources; the
rollout is what pushes them to collectors. A freshly applied configuration sits
at `pendingVersion` with agents still on the old pipeline until you roll it out.

Roll the workers before the ingress so the pool is listening on 4317 before the
front door starts forwarding. Out of order it still converges -- the exporter
retries -- but you will see a burst of `connection refused` in the ingress log.

## Destinations

Logs no longer fan out to every destination. A routing connector splits them by
source -- see "Routing" below.

| Stream (`appname`) | Destination | Type | Why |
|---|---|---|---|
| `winsec` | `Google-SecOps-Linux` | `chronicle` | SecOps-specific Pipeline Intelligence actions ("Standardize Log Type for SecOps", "Validate SecOps Parser") |
| `paloalto` | `Dynatrace` | `dynatrace_otlp` | Palo Alto enrichment blueprint |
| `appjson` | `Dynatrace` | `dynatrace_otlp` | app telemetry alongside the PAN stream |
| `apache` | `Elastic` | `elasticsearch_otlp` | Apache/NGINX Full-Pipeline Blueprint |
| `cef` | `Splunk-HEC` | `splunkhec_v2` | SIEM ingest -- where the cost-reduction story lands |
| *(unmatched)* | `grrcon-debug-out` | `custom` (debug) | catch-all; traffic here means a route stopped matching |

Metrics and traces skip the router entirely and go straight to debug -- blitz
sends logs only, so those are collector self-telemetry.

Three of these -- SecOps, Elastic, Dynatrace -- are pre-existing resources in the
Bindplane account, referenced by name rather than redefined, so they keep their
real credentials. `bindplane apply` against a **fresh** account will fail until
those three exist.

### Known state of each backend

None of the four currently ingest successfully. That is fine for a pipeline
demo -- Bindplane measures throughput at the pipeline, not the backend -- but do
not promise the room that data lands anywhere.

- **Google SecOps** -- dummy credentials by design. Loads, fails at the network,
  logs nothing noisy.
- **Splunk HEC** -- placeholder token and `REPLACE_ME.splunkcloud.com` hostname.
  Replace both in `bindplane/workers.yaml` to make it real.
- **Elastic** -- real endpoint, returns **HTTP 404**. Tenant is stale or the
  OTLP path has changed.
- **Dynatrace** -- real endpoint, returns **HTTP 404**. Same.

`grrcon-debug-out` is no longer a proof-of-flow sink -- it only receives
*unmatched* logs. An empty debug output now means routing is working. See
"Verify" for how to confirm flow instead.

### Why `Google-SecOps-Linux`, not `Google-SecOps`

The account holds both. `Google-SecOps` points at `C:/credentials.json`, a
Windows path -- inside a Linux container the exporter dies at startup with
`load Google credentials: read credentials file`, and the rollout halts on the
first collector. `Google-SecOps-Linux` expects `/opt/credentials.json`, which is
where compose mounts the dummy file.

## Configuration v2

Both configurations declare `apiVersion: bindplane.observiq.com/v2`. v2 adds
advanced routing -- explicit connections between sources and destinations rather
than an implicit fan-out, so you can send different telemetry to different
backends without duplicating data.

**Flipping the `apiVersion` line is the entire upgrade.** The server generates
the `routes` block itself; there is no route syntax to hand-write:

```yaml
sources:
  - id: s-grrcon-gateway-in
    name: grrcon-gateway-in:1
    routes:
      logs:
        - id: "0"
          components:
            - destinations/d-Google-SecOps-Linux
            - destinations/d-Splunk-HEC
            - ...
```

Routing respects each destination's `telemetry_types`: `Splunk-HEC` is declared
logs-only, so it appears under `logs` and not under `metrics` or `traces`.

Only the `Configuration` documents are v2. `Source` and `Destination` resources
stay on `apiVersion: bindplane.observiq.com/v1`.

The docs recommend duplicating a configuration before upgrading it. With the
config defined in `bindplane/*.yaml` you have a stronger safety net: delete and
re-apply rebuilds it from source. Test on a copy first if you prefer:

```bash
bindplane copy configuration grrcon-ingress grrcon-v2-probe
# ...upgrade and inspect the probe...
bindplane delete configuration grrcon-v2-probe --force
```

## Verify

```bash
docker compose ps                                     # 11 up
bindplane get fleets                                  # grrcon + grrcon-ingress
bindplane get agents --selector fleet=grrcon          # 10 workers
bindplane get agents --selector fleet=grrcon-ingress  # 1 ingress
curl -s localhost:13133                               # ingress health
```

There is no single selector covering all 11 -- the fleet split is what makes
that true. Use `role=worker` / `role=ingress` to slice by tier.

Confirm every collector actually bound to a configuration; a `-` in the
`CONFIGURATION` column means it did not:

```bash
bindplane get agents --selector fleet=grrcon | awk '{print $2, $6}'
```

Push real telemetry through the front door:

```bash
docker compose -f docker-compose.blitz.yaml up -d
```

### Is routing working?

The catch-all feeds debug, so **debug should be silent**. Any output here means a
stream stopped matching its route:

```bash
for i in $(seq -w 1 10); do
  docker logs --since 3m bdot-$i 2>&1 \
    | grep -o '"log records":[0-9]*' | awk -F: '{s+=$2} END{print s+0}'
done | paste -sd+ - | bc      # expect 0
```

Non-zero means look at the appname: either an `APPNAME` changed in
`docker-compose.blitz.yaml` without its route being updated, or syslog parsing
broke and every record is unparsed (see "RFC 3164" above).

### Is data reaching the destinations?

Since debug no longer sees the traffic, use the destinations themselves. All four
currently fail to export, and the *errors* are the evidence -- each names its
exporter, so the mix shows the split:

```bash
docker logs --since 2m bdot-01 2>&1 | grep '"level":"error"' \
  | grep -oE 'otlp_http/[A-Za-z]+|splunk_hec/[A-Za-z_-]+|chronicle/[A-Za-z-]+' \
  | sort | uniq -c
```

Healthy output looks roughly like this -- Dynatrace highest because it takes two
streams, SecOps near-silent because it fails quietly with dummy credentials:

```
 121 otlp_http/Dynatrace
  30 otlp_http/Elastic
  30 splunk_hec/Splunk-HEC__logs
   3 chronicle/Google-SecOps-Linux
```

Once a backend actually accepts data this trick stops working -- use Bindplane's
per-destination throughput in the UI instead.

### Is the pool balanced? Expect a spread rather than an even split:
`round_robin` balances per gRPC *connection*, not per record, so at low
connection counts some workers run 2-3x others. That is not a fault.

If one collector has everything and the rest are at zero, gRPC load balancing did
not take effect -- check for `balancer_name: round_robin` and
`endpoint: dns:///bdot-pool:4317` in the ingress's effective config:

```bash
docker exec bdot-ingress sh -c 'cat ./config.yaml' | grep -A3 otlp_grpc
```

**Grep gotcha:** the debug exporter logs `"msg":"Logs"` with component id
`debug/grrcon-debug-out`. Older collector builds wrote `LogsExporter`; grepping
for that against v1.106 silently returns zero and looks exactly like an outage.

## Routing

`bindplane/router.yaml` defines a `kind: Connector` of type `routing`. The
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
            components: [destinations/d-Google-SecOps-Linux]  # id in router.yaml
  destinations:
    - id: d-Google-SecOps-Linux
      name: Google-SecOps-Linux
```

Routes are **first match wins**, so the unconditioned catch-all must stay last.

### `attributes["appname"]` -- and why it depends on `parse_to`

Routes match `attributes["appname"]`. That is only correct because the ingress
syslog source sets `parse_to: attributes` (see "Record shape" below).

**The source default is `parse_to: body`**, which moves the parsed RFC fields
into the body instead:

```yaml
- from: attributes.appname
  to:   body.appname
  type: move
```

Under that default the condition must be `body["appname"]`. The two settings are
coupled: change one without the other and every condition compiles fine, matches
nothing, and dumps all traffic into the catch-all. If routing suddenly sends
everything to debug, check `parse_to` before anything else.

### Record shape: raw body, metadata in attributes

Bindplane Blueprints match the **raw log line**. Getting the record into that
shape takes two things, and neither is the default.

**1. `parse_to: attributes` on the syslog source.** The default (`body`) rewrites
the body into a map of syslog parts, which no blueprint matches.

**2. A transform processor on the ingress.** `parse_to: attributes` alone still
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
runs on the ingress so every worker receives clean records.

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

### `ottl` executes, `ui` draws

Each route condition carries both:

```yaml
- condition:
    ottl: attributes["appname"] == "winsec"   # what the collector evaluates
    ui:                                       # what the Bindplane UI renders
      operator: ""
      statements:
        - key: appname
          match: attributes
          operator: Equals
          value: winsec
  id: winsec
```

Leave `ui.statements` empty and the routing node shows **no conditions in the
UI** even though it routes correctly -- and anyone editing it in the UI can
silently overwrite the working `ottl`. Keep the two in sync.

### Why syslog and not OTLP

blitz hardcodes `service.name = "blitz"` on OTLP output
(`output/otlp_grpc/otlp_grpc.go:699`) with no config override, and the logs path
builds a Resource containing only that one attribute. Over OTLP all five streams
are indistinguishable, and there is nothing to route on but body regex.

Syslog carries a per-stream `APPNAME`, set in `docker-compose.blitz.yaml`. That
is the whole reason the transport changed.

### RFC 3164, not 5424 -- this one will bite you

blitz formats RFC 5424 timestamps with `time.RFC3339Nano`
(`output/syslog/syslog.go:209`) -- nine fractional digits. RFC 5424 permits at
most six, so the collector's parser rejects every record:

```
expecting a RFC3339MICRO timestamp or a nil value [col 32]
```

**The failure mode is silent.** The parser does not drop the record, it passes
the raw line through *unparsed*. Throughput looks perfectly healthy, collectors
stay green, and every single log lands in the catch-all because `appname` never
got created. It looks exactly like a broken routing condition.

RFC 3164 uses `Jan _2 15:04:05` with no fractional seconds, so it parses
cleanly. Both sides must agree:

- `docker-compose.blitz.yaml`: `BLITZ_OUTPUT_SYSLOG_RFC: "3164"`
- `bindplane/ingress.yaml`: `protocol: rfc3164`

Cost: no sub-second precision in the syslog *header*. Message bodies keep their
own timestamps, so PAN-OS and the JSON stream are unaffected.

### Connector apply ordering

A Connector and a Configuration that references it **cannot live in the same
file** -- apply renders the config before committing the connector and fails
with `unknown Connector: grrcon-router:1`. Separate files are fine, as long as
the connector's filename sorts first. `router.yaml` before `workers.yaml` works;
renaming either could break `bindplane apply -f bindplane/`.

## What blitz generates

`docker-compose.blitz.yaml` runs five generators, all sending **RFC 3164 syslog**
to `bdot-ingress:5140/udp` over `bdot-net`. Each carries a distinct `APPNAME`,
which is what the routing connector splits on.

| Service | `APPNAME` | Syslog hostname | Generator | Source | Rate | Workers |
|---|---|---|---|---|---|---|
| `blitz-winsec` | `winsec` | `dc01.contoso.local` | `filegen` | `./samples/winsec.xml` | 500ms | 2 |
| `blitz-palo-alto` | `paloalto` | `pan-fw-01` | `filegen` | `package:palo-alto/csv` | 500ms | 2 |
| `blitz-json` | `appjson` | `app-worker-01` | `json` | `default`, synthesized | 1s | 1 |
| `blitz-cef` | `cef` | `siem-edge-01` | `filegen` | `package:universal-cef` | 1s | 1 |
| `blitz-apache` | `apache` | `apache.httpserver.test` | `filegen` | `package:apache` | 1s | 1 |

Changing an `APPNAME` without changing the matching route in
`bindplane/router.yaml` sends that stream to the catch-all.

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
`palo-alto/csv` package holds 15 lines across 13 log types:

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

No blueprint covers this shape, which is what gives Pipeline Intelligence a real
job. The generator also supports a `pii` type
(`BLITZ_GENERATOR_JSON_TYPE: pii`) if you want a redaction story instead.

### 4. Universal CEF -- `blitz-cef`

Bare `CEF:0` records with no syslog wrapper -- what a CEF parser wants to chew
on. Eight static lines spanning eight vendor/product pairs:

`Network|IDS`, `Cloud|WAF`, `Endpoint|EDR`, `Identity|IdP`,
`Secure|DataLoss`, `Container|Runtime`, `Acme|WebApp`, `Enterprise|SIEM`

Eight lines with no timestamp directives, so the collector stamps observed time.
Fine for exercising a parser, repetitive as a volume source.

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

### Data library dependency

`package:` sources are not in the blitz image -- it is `FROM scratch` and ships
only the binary. Compose bind-mounts them from a blitz clone:

```
${BLITZ_REPO:-../blitz}/generator/filegen/embeddedlibrary/data_library
```

Set `BLITZ_REPO` in `.env` if your clone is not a sibling of this directory.
`blitz-winsec` is the exception -- it reads `./samples`, so it works without the
clone.

### Tunables

All optional, override in `.env`:

```
BLITZ_REPO=../blitz    BLITZ_VERSION=latest    BLITZ_LOG_LEVEL=info
WINSEC_RATE=500ms      WINSEC_WORKERS=2
PAN_RATE=500ms         PAN_WORKERS=2
JSON_RATE=1s           JSON_WORKERS=1
CEF_RATE=1s            CEF_WORKERS=1
APACHE_RATE=1s         APACHE_WORKERS=1
COLLECTOR_HOST=bdot-ingress               COLLECTOR_NETWORK=bdot-net
SYSLOG_PORT=5140       SYSLOG_TRANSPORT=udp
```

## Progressive rollout demo

```bash
bindplane rollout start grrcon-workers --initial 2 --multiplier 2 --max-errors 0
bindplane rollout status grrcon-workers
bindplane rollout pause grrcon-workers     # show the brakes mid-flight
```

**Rollout batching is count-based, not label-based.** `--initial`,
`--multiplier`, and `--max` control how many collectors move per phase; there is
no CLI flag that targets `env=canary` first. The `env=` labels are for
*selecting and verifying* subsets, and for the UI's rollout options:

```bash
bindplane get agents --selector env=canary   # did the first phase land here?
```

`--max-errors 0` is the part worth demoing. A configuration that fails to start
halts the rollout on the first collector instead of taking the fleet down --
observed behavior, not theory: a bad SecOps credentials path stopped a rollout at
one collector while the other nine stayed up on the previous version.

## Recovering an unbound collector

If `bindplane get agents` shows `CONFIGURATION: -` on a collector whose labels
clearly include `configuration=<name>`, the binding never fired. Force it by
toggling the label to a throwaway value and back:

```bash
bindplane label agent --selector fleet=grrcon configuration=none --overwrite
sleep 5
bindplane label agent --selector fleet=grrcon configuration=grrcon-workers --overwrite
```

Applying the configurations before `docker compose up -d` avoids this entirely.

## Rebuilding after the account loses the resources

If the `grrcon-*` configurations are deleted from Bindplane, the collectors keep
running but lose their pipelines -- the ingress stops listening on 4317 and
generators fail with `connection refused`. Symptoms look like a broken generator;
the cause is an empty configuration.

Rebuild from source and roll out:

```bash
bindplane apply -f bindplane/
bindplane rollout start grrcon-workers
bindplane rollout start grrcon-ingress
```

Content comes back identical because `bindplane/*.yaml` is the source of truth.
Version history does not -- configurations restart at `:1`.

## Relabeling a collector that has already registered

Two layers cache labels, and both outrank the env var.

**Server-side wins over everything.** Because the agent ID is pinned, Bindplane
already knows this agent and keeps the labels it holds, ignoring what a
re-registering collector reports. A label edit in `docker-compose.yaml` can look
correct inside the container and still be wrong in the UI -- always confirm with
`bindplane get agents`, not with `cat manager.yaml`.

**`OPAMP_LABELS` only seeds `manager.yaml` on first boot.** Once a collector has
registered, the file wins and editing the env var in `docker-compose.yaml` does
nothing -- `docker compose up -d` will recreate the container and it will
reconnect with its old labels.

To make a label edit stick, drop that collector's volume so the file is
re-seeded:

```bash
docker compose rm -sf bdot-ingress
docker volume rm grrcon-demos_bdot-ingress-storage
docker compose up -d bdot-ingress
```

Because the agent ID is pinned in compose, the *same* agent reconnects under the
new labels -- no orphaned collector left in the UI. Alternatively, relabel
server-side without touching the container:

```bash
bindplane label agent 01K5GRRC0N0000000000BD0T00 fleet=grrcon-ingress --overwrite
```

## Reset

```bash
docker compose -f docker-compose.blitz.yaml down   # stop the traffic
docker compose down -v                             # agents reconnect with same IDs
```

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | 11 collectors, network alias, per-collector volumes, credentials mount |
| `docker-compose.blitz.yaml` | telemetry generators feeding `bdot-ingress:4317` |
| `.env` | secret key and endpoint -- gitignored, never commit |
| `.env.example` | template |
| `credentials.json` | dummy SecOps service account -- gitignored, generate per step 2 |
| `bindplane/fleets.yaml` | the `grrcon` and `grrcon-ingress` fleets |
| `bindplane/ingress.yaml` | OTLP + syslog sources, unwrap processor -> Bindplane Gateway destination |
| `bindplane/router.yaml` | routing connector -- splits logs by `attributes["appname"]` |
| `bindplane/workers.yaml` | Bindplane Gateway source -> router -> five destinations |
