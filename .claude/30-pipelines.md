# Pipelines, fleets, unbound twins, generators

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

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

Each source collector has a twin, `bdot-<source>-unbound`, running **no
configuration** — it registers, connects, and sits at `CONFIGURATION: -`. For
demoing the unbound state against a genuinely unbound agent.

The mechanism is the **missing `configuration=` label**: configurations match on
`configuration=grrcon-<x>`, so a collector never reporting it matches nothing.

**They must stay out of every fleet.** A fleet's `spec.configuration` binds any
member lacking its own `configuration=` label, so a twin inside its source fleet
gets that pipeline within seconds. Measured: four twins picked one up
immediately, and `bdot-winsec-unbound` was handed `grrcon-winsec` and died on
`open /opt/credentials.json: no such file or directory` — a bound collector that
can't start. Its `CONFIGURATION: -` was a *failed* remote config, not an unbound
one. Note the asymmetry: members that *do* carry a `configuration=` label keep
it, which is why the bound five were never affected.

The twins omit published ports (5141-5143 are already bound on the host), log
mounts and `credentials.json` (no pipeline, so no `file_log` receiver and no
chronicle exporter), and the pool aliases.

Server-side labels beat what a re-registering collector reports. An empty value
deletes a label:

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

**Why a named collector, not the `bdot-edge-pool` alias.** blitz holds ONE tcp
connection per stream for the life of the process, and Docker DNS resolves the
alias once at connect time — so the alias load-balances new connections and
there are never any. Aimed at it, the three streams scatter:

| Collector | Established inbound |
|---|---|
| `bdot-edge-01` | 5141 — panos |
| `bdot-edge-02` | 5143 — appjson |
| `bdot-edge-09` | 5142 — winsec |
| the other seven | none |

Bindplane previews a configuration from **one agent**, so at most one tcp source
has data on any agent you pick and the other two look broken — while apache and
cef always look healthy, since all ten tail the same files. Pinning all three to
`bdot-edge-01` makes one agent show all five. Set `EDGE_TARGET=bdot-edge-pool`
to scatter them again.

Which collectors hold connections (dual-stack listeners, so `/proc/net/tcp` looks
empty):

```bash
# ports are hex: 1415 = 5141 panos, 1416 = 5142 winsec, 1417 = 5143 appjson
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

