# GrrCON demo: Bindplane-managed gateway topology

Thirty BDOT collectors in Docker, all managed from Bindplane Cloud over OpAMP.
Twenty-five run a pipeline; five are deliberately unbound (see [Unbound
twins](#unbound-twins)).

Three tiers, seven fleets -- the two multi-collector tiers get one fleet each,
and every source collector gets its own:

- **`grrcon-source-apache` / `-cef` / `-panos` / `-winsec` / `-appjson`** -- five
  collectors, one per source+destination pipeline, each with its own
  configuration, shipping straight to a backend. One fleet per collector, so any
  single source can be upgraded, restarted or rolled on its own. They all keep
  `role=source`, so `--selector role=source` still addresses the tier at once.
  Each of these fleets holds exactly one collector -- the unbound twins are
  deliberately kept out of every fleet, for a reason worth knowing before you
  add one: see [Unbound twins](#unbound-twins).
- **`grrcon-edge`** -- ten collectors (`bdot-edge-01..10`) all running the same
  configuration: the five native sources, forwarding to the gateway pool.
  Simulates a fleet of edge hosts.
- **`grrcon-gateway`** -- ten collectors behind a load-balanced alias -- which still registers and still
demonstrates fleet management, but no longer carries blitz log traffic.

```
  EDGE TIER -- one collector per pipeline, one configuration each

  blitz-winsec ──tcp:5142──▶ bdot-winsec  (grrcon-winsec)  ──▶ Google SecOps
  blitz-palo-alto ─tcp:5141▶ bdot-panos   (grrcon-panos)   ──▶ Dynatrace
  blitz-json ────tcp:5143──▶ bdot-appjson (grrcon-appjson) ──▶ Google Cloud
  blitz-cef ─────file──────▶ bdot-cef     (grrcon-cef)     ──▶ Splunk HEC
  blitz-apache-native ─file▶ bdot-apache  (grrcon-apache)  ──▶ Elastic

  EDGE + GATEWAY TIERS -- the ten edge collectors run the same five native
  sources and forward EVERYTHING to the pool; the gateway tier does the fan-out.

  apache (file) ┐
  cef (file)    │   bdot-edge-01..10
  panos  :5141  ├─▶ (alias bdot-edge-pool) ─▶ bdot-pool ─▶ router ─▶ backends
  winsec :5142  │                            (bdot-01..10)
  appjson:5143  ┘
```

Every stream therefore arrives at its backend **twice** — once via its edge
collector, once via the gateway path. That is deliberate; see "Duplicate
generators" below.

Nothing in `docker-compose.yaml` defines a pipeline. The collectors register,
report their labels, and pull their configuration from Bindplane. Pipelines
live in `bindplane/` -- one `edge-*.yaml` per pipeline.

**One configuration per source+destination pair** is the organising idea. A
collector can only hold one configuration, so each pipeline gets its own
collector. That is also the shape Bindplane's `full_pipeline_blueprint`s are
written in (`elasticsearch-apache-common-full-pipeline`,
`dynatrace-palo-alto-security-full-pipeline`), so each config here can adopt its
blueprint without disturbing the others.

## Why it is shaped this way

**`bdot-pool` is a shared Docker network alias**, declared by all ten gateway collectors.
Docker's embedded DNS returns all ten container IPs for that one name, so the
edge destination targets a single hostname with gRPC load balancing enabled.
Add or remove workers and the Bindplane config never changes.

**Each edge collector owns its ingest.** `bdot-panos`, `bdot-winsec` and
`bdot-appjson` listen on 5141/5142/5143; `bdot-apache` and `bdot-cef` tail files
instead. blitz reaches them by container name on `bdot-net`, so the published
ports exist only so you can send test traffic from the laptop.

**The gateway tier is logs-only.** The OTLP source was removed once nothing used
it, so the edge tier publishes no ports at all. Every native source is
logs-only, and the worker gateway source is now `telemetry_types: [Logs]` — which
also stops v2 auto-generating metrics/traces routes to every destination.

Re-adding OTLP means restoring three things together: the source and its route,
the 4317/4318 ports on the `bdot-edge-*` containers, and `Metrics`/`Traces` on
the worker gateway source.

**The edge tier lives in its own fleet.** A collector can belong to exactly one
fleet at a time, so `fleet=` is the one mutually exclusive label here: the ten
edge collectors are `fleet=grrcon-edge`, the ten gateways are
`fleet=grrcon-gateway`. The front door can be upgraded, restarted, or rolled
without touching the pool, and a fleet-wide action aimed at the gateway tier can
never reach it.

**The edge tier is not labeled `env=`.** `bdot-winsec` is the only source-tier collector
that needs `credentials.json` -- it is the one exporting to Google SecOps, and
the chronicle exporter reads that file at startup.

**Agent IDs are pinned ULIDs**, so the same twenty-five agents reconnect after
any restart -- even `docker compose down -v`.
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

Compose mounts it read-only at `/opt/credentials.json` on the **ten gateway collectors
only**; the edge tier has no SecOps exporter and does not get it.

### 3. Shared log directory

`blitz-apache-native` writes native CLF here and `bdot-apache` tails it:

```bash
mkdir -p logs/apache2 logs/cef && chmod 777 logs/apache2 logs/cef
```

`logs/apache2` and `logs/cef` are mounted at **`/var/log/apache2`** and
**`/var/log/cef`** inside the containers. `/var/log/apache2/access.log` is the
default path for the Apache source and for the
`elasticsearch-apache-common-full-pipeline` blueprint, so the blueprint works
without repointing it. Only that subdirectory is mounted: the collector image
has real content in `/var/log` (apt, dpkg) that a mount over the whole directory
would hide.

The mode matters — see the permissions trap under "Native formats". After the
first run, also `chmod 644 logs/*/*.log`: blitz creates files `0600` and the
collector cannot read them otherwise.

### 4. Point the CLI at your account

```bash
bindplane profile create grrcon \
  --remote-url https://app.bindplane.com \
  --api-key <YOUR_API_KEY>
bindplane profile use grrcon
```

Note this is an **API key**, a different credential from the
`BINDPLANE_SECRET_KEY` in `.env`. The secret key authenticates *collectors* over
OpAMP; the API key authenticates the *CLI* against the management API.

### 5. Apply, start, roll out -- in this order

```bash
bindplane apply -f bindplane/     # MUST come first
docker compose up -d
bindplane rollout start grrcon-gateway
bindplane rollout start grrcon-edge
```

**The order is not cosmetic.** A collector's `configuration=` label binds only
when its value *changes* while the named configuration already exists. Start the
collectors first and they register, evaluate the label against a configuration
that does not exist yet, and never re-check -- leaving all 25 pipeline
collectors sitting at
`CONFIGURATION: -` forever. Neither a container restart nor re-setting the label
to the same value fixes it. See "Recovering an unbound collector" below.

**`apply` alone is not enough.** It creates and versions the resources; the
rollout is what pushes them to collectors. A freshly applied configuration sits
at `pendingVersion` with agents still on the old pipeline until you roll it out.

Roll the gateway tier before the edge tier so the pool is listening on 4317
before the front door starts forwarding. Out of order it still converges -- the exporter
retries -- but you will see a burst of `connection refused` in the edge logs.

## Pipelines

Five independent pipelines, one Bindplane configuration each:

| Pipeline | Collector | Source type | Ingest | Destination |
|---|---|---|---|---|
| `grrcon-winsec` | `bdot-winsec` | `tcp` (`parse_format: none`) | tcp :5142 | `Google-SecOps-Linux` |
| `grrcon-panos` | `bdot-panos` | `tcp` (`parse_format: none`) | tcp :5141 | `Dynatrace` |
| `grrcon-appjson` | `bdot-appjson` | `tcp` (`parse_format: json`) | tcp :5143 | `grrcon-google-gcl` |
| `grrcon-cef` | `bdot-cef` | `common_event_format` | file | `Splunk-HEC` |
| `grrcon-apache` | `bdot-apache` | `apache_common` | file | `Elastic` |

Each source stamps its own `log_type`, so there is no routing connector and no
`appname` coupling: **the collector a stream lands on is its identity.**

### Unbound twins

Each source collector has a second instance, `bdot-<source>-unbound`, that
deliberately runs **no configuration** -- five collectors that register, connect,
and sit at `CONFIGURATION: -`. Useful for demonstrating the unbound state and
its recovery against a collector that is genuinely unbound rather than merely
broken.

| Collector | Fleet | Configuration |
|---|---|---|
| `bdot-apache` | `grrcon-source-apache` | `grrcon-apache` |
| `bdot-apache-unbound` | none | none |

...and the same shape for `cef`, `panos`, `winsec` and `appjson`.

The mechanism is the **missing `configuration=` label**. Each `grrcon-*`
configuration matches on `configuration=grrcon-<x>`, so a collector that never
reports that label matches nothing.

**They must stay out of every fleet, and that is not cosmetic.** A fleet's
`spec.configuration` binds any member that has no `configuration=` label of its
own -- so a twin placed in its own source fleet is assigned that source's
pipeline within seconds of registering and is *not* unbound. Measured, not
assumed: with `fleet=grrcon-source-<x>` set, four twins picked up their source's
configuration immediately and the fifth did this:

```
Failed applying remote config: failed to start "chronicle/Google-SecOps-Linux"
exporter: open /opt/credentials.json: no such file or directory
```

That is `bdot-winsec-unbound` being handed `grrcon-winsec` and dying on the
credentials file it does not mount -- a bound collector that cannot start, which
is the opposite of the goal. Its `CONFIGURATION: -` in the UI was a *failed*
remote config, not an unbound one. Dropping the `fleet=` label fixed all five.

Note the asymmetry: a fleet only falls back to `spec.configuration` for members
that have no `configuration=` label. Members that carry one keep it, which is
why the five bound collectors were never affected either way.

Three things the twins deliberately omit, each for a concrete reason:

| Omitted | Why |
|---|---|
| published ports | `bdot-panos`/`winsec`/`appjson` already publish 5141-5143 on the host; a twin republishing those fails on a bind collision. An unbound collector has no receiver anyway. |
| log mounts, `credentials.json` | No pipeline means no `file_log` receiver and no chronicle exporter, so the winsec twin needs no credentials file -- and cannot hit the startup failure above. |
| pool aliases | Plain `bdot-net`, so nothing can route to them. |

To relabel one after it has registered, remember that server-side labels win over
what a re-registering collector reports. An empty value deletes a label:

```bash
bindplane label agent 01K5GRRC0N0000000000BD0T21 fleet= --overwrite
```

### The edge tier mirrors all five

`grrcon-edge` references the same five Source resources and routes each one
directly to its own destination, so the same pipelines exist in two places. Only
the file-based ones actually dual-ingest:

| Source | On the edge tier |
|---|---|
| `grrcon-apache-in` (file) | **receives** — two collectors can tail one file, each keeping its own checkpoint |
| `grrcon-cef-in` (file) | **receives** — same |
| `grrcon-panos-in` (tcp) | **receives** — via `blitz-palo-alto-gw` |
| `grrcon-winsec-in` (tcp) | **receives** — via `blitz-winsec-gw` |
| `grrcon-appjson-in` (tcp) | **receives** — via `blitz-json-gw` |

### Ten edge collectors tail the same files

All ten run one configuration, and two of its sources tail files — so
`/var/log/apache2/access.log` and `/var/log/cef/events.log` are each read **ten
times over**. Measured: Elastic traffic through the gateway went from ~89 to
~779 per 90s when the tier went from one collector to ten.

That is inherent to running a file-tailing configuration on a fleet. It is
realistic in the sense that ten real edge hosts would each have their own local
log — but here they share one file, so it is pure amplification rather than ten
distinct hosts' worth of data.

If you want the volume without the duplication, give each collector its own file
(one blitz `file` output per collector) or move the file sources onto a
single-collector configuration and leave the tcp sources on the fleet.

The three tcp sources do not amplify: blitz holds one long-lived connection per
stream, so each tcp stream lands on exactly one collector, not all ten. All
three are pinned to `bdot-edge-01` (see [Duplicate generators](#duplicate-generators))
so that one agent shows all five sources at once.

### Duplicate generators

**blitz supports one output per process**, so a TCP stream cannot be sent to
both its source-tier collector and the edge tier. The `*-gw` services are second
instances of the same generators pointed at the edge tier:

| Duplicate | Target | Mirrors |
|---|---|---|
| `blitz-winsec-gw` | `bdot-edge-01:5142` | `blitz-winsec` |
| `blitz-palo-alto-gw` | `bdot-edge-01:5141` | `blitz-palo-alto` |
| `blitz-json-gw` | `bdot-edge-01:5143` | `blitz-json` |

This **doubles** those streams' volume at their backends — each event arrives
once via its source collector and once through edge → pool → worker. The two
file streams need no duplicate: both collectors tail the same file.

**Why a named collector and not the `bdot-edge-pool` alias.** blitz opens ONE
tcp connection per stream and keeps it for the life of the process. Docker's
embedded DNS resolves the alias once, at connect time, so that connection is
pinned to a single container — the alias load-balances new connections, and
there are never any new connections. Aimed at the alias, the three streams
scatter across three arbitrary collectors:

| Collector | Established inbound |
|---|---|
| `bdot-edge-01` | 5141 — panos |
| `bdot-edge-02` | 5143 — appjson |
| `bdot-edge-09` | 5142 — winsec |
| the other seven | none |

Bindplane previews a configuration from **one agent**, so on any agent you pick
at most one of the three tcp sources has data and the other two look broken —
while apache and cef always look healthy, because all ten tail the same files.
Pinning all three to `bdot-edge-01` makes that one agent show all five sources
live. Set `EDGE_TARGET=bdot-edge-pool` to get the scattered behaviour back.

To verify which collectors hold connections (the listeners are dual-stack, so
they appear in `/proc/net/tcp6`, and a `/proc/net/tcp` check looks empty):

```bash
# ports print as hex: 1415 = 5141 panos, 1416 = 5142 winsec, 1417 = 5143 appjson
for c in $(docker ps --format '{{.Names}}' | grep '^bdot-edge-' | sort); do
  printf '%-14s %s\n' "$c" "$(docker exec $c cat /proc/net/tcp6 \
    | awk 'NR>1 && $4=="01" {split($2,a,":"); print a[2]}' \
    | grep -E '^(1415|1416|1417)$' | sort | uniq -c | tr '\n' ' ')"
done
```

The edge tier's TCP ports are deliberately **not published**: `bdot-panos`,
`bdot-winsec` and `bdot-appjson` already publish 5141/5142/5143, and a second
publisher would collide on the host. The `*-gw` generators do not need them
published — they reach `bdot-edge-01` over `bdot-net` by container name.

Because the edge tier now exports to Google SecOps, it mounts `credentials.json`
— the chronicle exporter reads it at startup and the collector will not start
without it.

`grrcon-google-gcl` is the exception to the rule below: it is defined in
`bindplane/15-destination-google-gcl.yaml` rather than referenced, because the
account's shared `Google-GCL` cannot work here -- see [Why not the shared
Google-GCL](#why-not-the-shared-google-gcl).

`Google-SecOps-Linux`, `Elastic` and `Dynatrace` are pre-existing resources in
the Bindplane account, referenced by name rather than redefined so they keep
their real credentials. `bindplane apply` against a **fresh** account needs those
three created first. `Splunk-HEC` is defined in `bindplane/40-gateway.yaml`.

### Why not the shared Google-GCL

The account has a `Google-GCL` destination, but the appjson stream does **not**
use it. It is set to `auth_type: auto`, which makes the googlecloud exporter
resolve Application Default Credentials from the environment -- credentials these
containers do not have. That is not a soft export failure like Dynatrace's 404;
the exporter fails to **start**, so the collector never runs the pipeline:

```
cannot start pipelines: failed to start "googlecloud/Google-GCL" exporter:
failed to start logs exporter: credentials: could not find default credentials
```

Its `credentials` parameter displays as `(sensitive)`, which looks like it should
help, but `auth_type: auto` ignores both `credentials` and `credentials_file` --
that parameter is only read under `auth_type: json`. It is also terraform-managed
(`id: tf-...`), so editing it would drift from terraform and affect anything else
that uses it.

So `bindplane/15-destination-google-gcl.yaml` defines a separate
`grrcon-google-gcl` with `auth_type: file`, reading the same mocked
service-account key the chronicle exporter already uses. `auth_type: json` would
also work, but its `credentials` parameter is an inline string -- that means
pasting a private key into a tracked YAML file, and `credentials.json` is
gitignored precisely so that never happens.

The key is a mock, so export fails at request time with
`rpc error: code = Unauthenticated`. That is the point: the pipeline **runs**, and
Bindplane measures throughput through it, exactly like every other backend here.

**Any collector running a configuration that uses it needs `credentials.json`
mounted at `/opt/credentials.json`** -- that is `bdot-appjson` plus the ten
gateway collectors. The mount was already present on `bdot-01..10`; it had to be
added to `bdot-appjson`.

### Known state of each backend

None of the four currently ingest successfully. That is fine for a pipeline
demo -- Bindplane measures throughput at the pipeline, not the backend -- but do
not promise the room that data lands anywhere.

- **Google SecOps** -- dummy credentials by design. Loads, fails at the network,
  logs nothing noisy.
- **Splunk HEC** -- placeholder token and `REPLACE_ME.splunkcloud.com` hostname.
  Replace both in `bindplane/40-gateway.yaml` to make it real.
- **Elastic** -- real endpoint, returns **HTTP 404**. Tenant is stale or the
  OTLP path has changed.
- **Dynatrace** -- real endpoint, returns **HTTP 404**. Same. Still carries the
  Palo Alto stream; the appjson stream moved to Google Cloud.
- **Google Cloud Logging** (`grrcon-google-gcl`) -- real endpoint, returns
  **`rpc error: code = Unauthenticated`**, because `credentials.json` is a mock.
  The pipeline still runs.

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
bindplane copy configuration grrcon-edge grrcon-v2-probe
# ...upgrade and inspect the probe...
bindplane delete configuration grrcon-v2-probe --force
```

## Verify

```bash
docker compose ps                                     # 30 up
bindplane get fleets | grep grrcon                    # 7 grrcon fleets
bindplane get agents --selector fleet=grrcon-gateway  # 10 gateways
bindplane get agents --selector fleet=grrcon-edge     # 10 edge
bindplane get agents --selector role=source           # 5 source collectors
bindplane get agents --selector role=source-unbound   # 5 unbound, no fleet
bindplane get agents --selector fleet=grrcon-source-apache   # 1
```

There is no single selector covering all 30 -- the fleet split is what makes
that true. Use `role=edge` / `role=gateway` / `role=source` to slice by tier:
`role=` is the non-exclusive label, which is why the source tier is still
addressable as a unit after being split into five fleets.
No collector publishes 13133, so there is no host-side health curl.

Confirm every collector actually bound to a configuration; a `-` in the
`CONFIGURATION` column means it did not:

```bash
bindplane get agents --selector fleet=grrcon-gateway | awk '{print $2, $6}'
```

Push real telemetry through the front door:

```bash
docker compose -f docker-compose.blitz.yaml up -d
```

### Are all five pipelines carrying data?

Every destination currently fails to export, and those errors are the evidence —
each names its exporter, so a non-zero count per collector proves records reached
it:

```bash
for row in bdot-apache:Elastic bdot-cef:Splunk bdot-panos:Dynatrace \
           bdot-appjson:googlecloud bdot-winsec:SecOps; do
  n=${row%%:*}; d=${row##*:}
  printf "%-14s -> %-10s %s\n" "$n" "$d" \
    "$(docker logs --since 60s $n 2>&1 | grep -c "$d")"
done
```

All five should be non-zero. A zero on `bdot-apache` or `bdot-cef` almost always
means file permissions — check `docker exec <collector> stat -c '%U %a' <path>`;
it must be readable by `otel`.

Confirm each collector is on its own configuration:

```bash
bindplane get agents --selector fleet=grrcon-edge
```

### Is the gateway tier still healthy?

It carries no blitz logs any more, so the gateway tier should be quiet — that is
expected, not a fault:

```bash
bindplane get agents --selector fleet=grrcon-gateway    # 10, all Connected
```

### Is the pool balanced?### Is the pool balanced? Expect a spread rather than an even split:
`round_robin` balances per gRPC *connection*, not per record, so at low
connection counts some workers run 2-3x others. That is not a fault.

If one collector has everything and the rest are at zero, gRPC load balancing did
not take effect -- check for `balancer_name: round_robin` and
`endpoint: dns:///bdot-pool:4317` in an edge collector's effective config:

```bash
docker exec bdot-edge-01 sh -c 'cat ./config.yaml' | grep -A4 otlp_grpc
```

**Grep gotcha:** the debug exporter logs `"msg":"Logs"` with component id
`debug/grrcon-debug-out`. Older collector builds wrote `LogsExporter`; grepping
for that against v1.106 silently returns zero and looks exactly like an outage.

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
            components: [destinations/d-Google-SecOps-Linux]  # id in router.yaml
  destinations:
    - id: d-Google-SecOps-Linux
      name: Google-SecOps-Linux
```

Routes are **first match wins**, so the unconditioned catch-all must stay last.

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
wrong matches nothing **silently** and dumps the stream into the catch-all — so
if a stream disappears, check the debug destination first, then check which side
of the record its `log_type` is on.

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

### `ottl` executes, `ui` draws

Each route condition carries both:

```yaml
- condition:
    ottl: attributes["log_type"] == "cef"     # what the collector evaluates
    ui:                                       # what the Bindplane UI renders
      operator: ""
      statements:
        - key: log_type
          match: attributes
          operator: Equals
          value: cef
  id: winsec
```

Leave `ui.statements` empty and the routing node shows **no conditions in the
UI** even though it routes correctly -- and anyone editing it in the UI can
silently overwrite the working `ottl`. Keep the two in sync.

### Why not OTLP

Relevant if you ever collapse these streams back onto one collector: blitz
hardcodes `service.name = "blitz"` on OTLP output
(`output/otlp_grpc/otlp_grpc.go:699`) with no config override, and the logs path
builds a Resource containing only that one attribute. Over OTLP every stream is
indistinguishable, leaving nothing to route on but body regex. Raw TCP and files
carry the generator's line verbatim, which is why the per-pipeline split uses
them instead.

### RFC 3164, not 5424 -- if you ever go back to syslog

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
- `bindplane/30-edge.yaml`: `protocol: rfc3164`

Cost: no sub-second precision in the syslog *header*. Message bodies keep their
own timestamps, so PAN-OS and the JSON stream are unaffected.

### Connector apply ordering

`bindplane apply -f bindplane/` processes files in **filename order**, and a
resource must exist before anything references it. Two dependencies bite:

- a **Connector** cannot share a file with the Configuration that uses it --
  apply renders the config before committing the connector and fails with
  `unknown Connector`. Separate files, connector first.
- the five **Sources** must exist before `30-edge.yaml`, which references them,
  or apply fails with `unknown Source`.

Hence the numeric prefixes:

```
10-connector-router  ->  20-source-*  ->  30-edge  ->  40-gateway  ->  50-fleets
```

**Both failures only surface against a fresh account.** With the resources
already present a wrong order silently works, so this stayed hidden until the
account was wiped and everything was recreated from scratch.

## What blitz generates

`docker-compose.blitz.yaml` runs five generators, each pointed at **its own edge
collector**. No syslog and no `APPNAME` any more: the collector a stream reaches
is its identity. Raw TCP carries the generator's line verbatim; the two streams
with a native file-based source write files instead. See "Native formats" for why.

| Service | Transport | Target | Generator | Source | Rate | Workers |
|---|---|---|---|---|---|---|
| `blitz-winsec` | tcp | `bdot-winsec:5142` | `filegen` | `./samples/winsec.xml` | 500ms | 2 |
| `blitz-palo-alto` | tcp | `bdot-panos:5141` | `filegen` | `package:palo-alto/csv` | 500ms | 2 |
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
EDGE_TARGET=bdot-edge-01                  COLLECTOR_NETWORK=bdot-net
```

`EDGE_TARGET` picks which edge collector the three `*-gw` generators feed; set it
to `bdot-edge-pool` to scatter them across the tier instead. The TCP ports are
hardcoded in compose, not tunable.

## Native formats: files, not the wire

Bindplane's format-specific log sources — `apache_common`, `apache_combined`,
`apache_http`, `nginx`, `common_event_format`, `csv`, `w3c`, `iis` — all render
to a `plugin/...` receiver that resolves to `file_log`. **They tail files and
have no listener mode.** Only generic sources (`syslog`, `tcp`, `udp`, `otlp`,
`http`, `splunk_tcp`, `splunkhec`, `fluentforward`) accept pushed data.

So a native format reaches a native receiver only by way of a file on disk.

### The Apache path

`blitz-apache-native` uses blitz's native **`apache-common` generator** — not
`filegen`. That distinction matters: the `data_library/apache` samples carry a
`<86>… httpd:` syslog prefix *and* two leading IPs, so the CLF regex will never
match them. The native generator constructs a real CLF line, and blitz's `file`
output writes it byte-for-byte with no wrapper:

```
124.159.111.209 - - [02/Sep/2026:12:16:27 +0000] "DELETE /api/v1/products HTTP/1.1" 200 9482648
```

`bdot-apache` (fleet `grrcon-source-apache`) tails `/var/log/apache2/access.log` with
the `apache_common` source and ships **straight
to Elastic**, bypassing the worker pool — which is what makes this path additive:
the edge, worker and router tiers are untouched by it.

Verified parse output:

```
Body: Map({"remote_addr":"77.62.106.165","method":"DELETE","path":"/api/v1/transfers",
           "status":"204","body_bytes_sent":"7585681","protocol":"HTTP",
           "protocol_version":"1.1","log_type":"apache_common",
           "time":"02/Sep/2026:12:20:06 +0000"})
```

**The permissions trap.** blitz's file output uses lumberjack, which creates
files `0600` — including after rotation. The collector runs as `uid=10005(otel)`
and the blitz image is `FROM scratch` running as root. A root-owned `0600` file
is unreadable and **the source tails nothing without reporting an error.**
`user: "10005:10005"` on the blitz service fixes it; the host directory must be
writable by that uid:

```bash
mkdir -p logs/apache && chmod 777 logs/apache
```

Use the **exact file path, not a glob** — lumberjack rotates to siblings like
`access-2026-09-02T….log`, and a glob would tail those too.

### The Palo Alto path

There is no `palo_alto` source type, and that turns out not to matter. The
blueprint **`dynatrace-palo-alto-security-full-pipeline`** defines exactly two
sources — `type: tcp` and `type: udp` — and its first processor is "Strip Syslog
Header":

```yaml
type: parse_regex
log_regex_pattern: ^.+?(?P<message>\d,\d{4}\/\d{2}\/\d{2}.+)
```

The `package:palo-alto/csv` samples already carry a `%b %e %T localhost ` header,
which is exactly what that regex expects. Sending them over blitz's syslog
output wrapped them a *second* time. `blitz-palo-alto` now uses raw **TCP** to
port 5141, so the body arrives as the blueprint was written for:

```
Sep  2 12:26:49 localhost 1,2026/09/02 12:26:49,001901000123,AUTHENTICATION,auth,,...
```

TCP rather than UDP because blitz's tcp output appends `\n`, which `tcplog`
framing needs, and there is no datagram loss.

The `tcp` source stamps **`log_type: palo-alto`**, so this stream routes on
`attributes["log_type"]` — the idiomatic Bindplane routing key, which every
source exposes and which the account's own `gateway-router` already uses. All
five streams now route on `log_type`; see "Routing" for the per-source table.

### Still not possible

**Windows Events.** `windowsevents_v3` uses the `windowseventlog` receiver
(Windows Event Log API). It cannot read a file and cannot run in a Linux
container. The `winsec` stream stays on syslog.

### Not yet applied

The parsing bundles are available but not wired up:
`palo-alto-full-log-parsing-and-reduction-bundle` (23 processors — parses all
PAN-OS types, with toggleable volume-reduction filters),
`enrich-palo-alto-security-events` (MITRE ATT&CK), and
`elasticsearch-apache-common-full-pipeline`. `processor_bundle` is a container
type with no parameters, so a bundle is instantiated through the Bindplane UI
and then captured back with `bindplane get processors --export`.

## Progressive rollout demo

`grrcon-gateway` carries progressive rollout options on the **configuration
resource**, so every rollout of it stages by label however it is triggered:

```yaml
spec:
  rollout:
    type: progressive
    parameters:
      - name: stages
        value:
          - {name: Canary, labels: {env: canary}}   # bdot-01, bdot-02
          - {name: Prod,   labels: {env: prod}}     # bdot-03..10
      - name: maxErrors
        value: 0
      - name: phaseAgentCount
        value: {type: adaptive, initial: 0, multiplier: 0, maximum: 0}
```

**This is label-based staging, which `bindplane rollout start` cannot express** —
its flags (`--initial`/`--multiplier`/`--max`) only phase by *count*. Earlier
versions of this README claimed label staging was impossible; that was wrong. It
lives on the configuration, not on the command.

`phaseAgentCount: adaptive` lets the server size each phase from the collector
count; `initial`/`multiplier`/`maximum` are ignored in that mode.

Running it:

```bash
bindplane rollout start  grrcon-gateway    # stage 1: env=canary only
bindplane rollout status grrcon-gateway    # STAGE column shows "Canary"
bindplane get agents --selector env=canary # confirm only these two moved
bindplane rollout resume grrcon-gateway    # advance to stage 2: env=prod
```

**It pauses between stages** — after Canary completes, status goes `Pending` and
waits for `resume`. Observed mid-rollout, which is the moment worth showing:

```
bdot-01  canary  grrcon-gateway:31     <- new version
bdot-02  canary  grrcon-gateway:31
bdot-03  prod    grrcon-gateway:30     <- held back
...
bdot-10  prod    grrcon-gateway:29
```

`maxErrors: 0` halts the rollout on the first collector that fails to start —
observed for real earlier in this project, when a bad SecOps credentials path
stopped a rollout at one collector while the other nine stayed up.

## Recovering an unbound collector

If `bindplane get agents` shows `CONFIGURATION: -` on a collector whose labels
clearly include `configuration=<name>`, the binding never fired. Force it by
toggling the label to a throwaway value and back:

```bash
bindplane label agent --selector fleet=grrcon-gateway configuration=none --overwrite
sleep 5
bindplane label agent --selector fleet=grrcon-gateway configuration=grrcon-gateway --overwrite
```

Applying the configurations before `docker compose up -d` avoids this entirely.

## Demo walkthroughs

- [`docs/demo-json-parsing.md`](docs/demo-json-parsing.md) — building JSON
  parsing, timestamp promotion and severity mapping by hand on the `appjson`
  stream, the one pipeline no native source or blueprint covers.
- [`docs/demo-palo-alto-blueprint.md`](docs/demo-palo-alto-blueprint.md) — the
  mirror image: a shipped full-pipeline blueprint that parses 13 PAN-OS log
  types, adds MITRE ATT&CK context and exposes volume-reduction toggles.

- [`docs/demo-native-sources.md`](docs/demo-native-sources.md) — the `apache`
  and `cef` streams, where the source type parses on ingest and you write no
  processors at all, plus the silent failure mode when the data does not match
  what the parser expects.
- [`docs/demo-winsec-secops.md`](docs/demo-winsec-secops.md) — Windows Events to
  Google SecOps, where a native source exists but the `windowseventlog` receiver
  needs a Windows host, so the XML is parsed and standardized downstream instead.

Run them in that order — hand-built, then shipped blueprint, then native source.
Each ran on the same collectors, routing and destinations; only the amount of
work differed, which is the argument none of them makes alone.

## Collector Type

Each configuration carries `agent-type: observiq-otel-collector` in
`metadata.labels` — that is what the UI shows as **Collector Type**. Without it
the field renders as `-`. `platform: linux` sits alongside it:

```yaml
metadata:
  name: grrcon-edge
  labels:
    agent-type: observiq-otel-collector
    platform: linux
```

## Rebuilding after the account loses the resources

If the `grrcon-*` configurations are deleted from Bindplane, the collectors keep
running but lose their pipelines -- the edge collectors stop listening on
5141-5143 and the generators fail with `connection refused`. Symptoms look like a
broken generator; the cause is an empty configuration.

Rebuild from source and roll out:

```bash
bindplane apply -f bindplane/
bindplane rollout start grrcon-gateway
bindplane rollout start grrcon-edge
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
docker compose rm -sf bdot-edge-01
docker volume rm grrcon-demos_bdot-edge-01-storage
docker compose up -d bdot-edge-01
```

Because the agent ID is pinned in compose, the *same* agent reconnects under the
new labels -- no orphaned collector left in the UI. Alternatively, relabel
server-side without touching the container:

```bash
bindplane label agent 01K5GRRC0N0000000000BD0T00 fleet=grrcon-edge --overwrite
```

## Reset

```bash
docker compose -f docker-compose.blitz.yaml down   # stop the traffic
docker compose down -v                             # agents reconnect with same IDs
```

## Files

| File | Purpose |
|---|---|
| `docker-compose.yaml` | 30 collectors (25 with a pipeline, 5 unbound), network aliases, per-collector volumes, credentials mount |
| `docker-compose.blitz.yaml` | telemetry generators feeding tcp 5141-5143 and the tailed log files |
| `.env` | secret key and endpoint -- gitignored, never commit |
| `.env.example` | template |
| `credentials.json` | dummy SecOps service account -- gitignored, generate per step 2 |
| `logs/apache2/`, `logs/cef/` | native-format files written by blitz, tailed by the collectors -- gitignored |
| `bindplane/20-source-apache.yaml` | `apache_common` (file) -> Elastic |
| `bindplane/20-source-cef.yaml` | `common_event_format` (file) -> Splunk HEC |
| `bindplane/20-source-panos.yaml` | `tcp` :5141 -> Dynatrace |
| `bindplane/20-source-winsec.yaml` | `tcp` :5142 -> Google SecOps |
| `bindplane/15-destination-google-gcl.yaml` | `grrcon-google-gcl` -- Google Cloud Logging, `auth_type: file` |
| `bindplane/20-source-appjson.yaml` | `tcp` :5143 (JSON parsed) -> Google Cloud |
| `bindplane/50-fleets.yaml` | `grrcon-gateway`, `grrcon-edge`, and one `grrcon-source-*` fleet per source collector |
| `bindplane/30-edge.yaml` | `grrcon-edge` -- the five native sources -> gateway pool |
| `bindplane/10-connector-router.yaml` | routing connector -- splits the pooled stream by `log_type`. numbered `10-` so it applies first: a connector must exist before the config referencing it |
| `bindplane/40-gateway.yaml` | `grrcon-gateway` -- gateway source -> router -> five destinations, progressive rollout |
