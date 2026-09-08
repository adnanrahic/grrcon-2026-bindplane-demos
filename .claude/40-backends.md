# Backends and native formats

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

### Why not the shared Google-GCL

The account's `Google-GCL` is set to `auth_type: auto`, which resolves
Application Default Credentials from the environment — which these containers
lack. Unlike Dynatrace's 404, the exporter fails to **start**:

```
cannot start pipelines: failed to start "googlecloud/Google-GCL" exporter:
failed to start logs exporter: credentials: could not find default credentials
```

Its `credentials` param displays as `(sensitive)`, but `auth_type: auto` ignores
both `credentials` and `credentials_file` — that param is only read under
`auth_type: json`. It is also terraform-managed (`id: tf-...`), so editing it
would drift from terraform.

So `bindplane/15-destination-google-gcl.yaml` defines `grrcon-google-gcl` with
`auth_type: file`, reading the same mocked key the chronicle exporter uses.
`auth_type: json` takes credentials as an inline string, which would mean a
private key in tracked YAML — `credentials.json` is gitignored to prevent that.

The key is a mock, so export fails at request time with
`rpc error: code = Unauthenticated`. That is the point: the pipeline **runs**.

**Every collector running a config that uses it needs `credentials.json` at
`/opt/credentials.json`** — `bdot-appjson` plus `bdot-01..10`.

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

`grrcon-debug-out` has been **removed** from `grrcon-gateway`, and with it the
`unmatched` catch-all wiring. The router's five conditioned routes remain; the
`unmatched` route id is still declared in `10-connector-router.yaml` but nothing
is wired to it, so unmatched logs are discarded via a synthesised `nop`
pipeline -- still throughput-measured, just no longer readable. See `.claude/70-operations.md` for
how to confirm flow, and [Detecting a misroute without the catch-all
sink](#detecting-a-misroute-without-the-catch-all-sink) for the detail.

### Why `Google-SecOps-Linux`, not `Google-SecOps`

The account holds both. `Google-SecOps` points at `C:/credentials.json`, a
Windows path -- inside a Linux container the exporter dies at startup with
`load Google credentials: read credentials file`, and the rollout halts on the
first collector. `Google-SecOps-Linux` expects `/opt/credentials.json`, which is
where compose mounts the dummy file.

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

---

Working rules, verification discipline and the silent failure modes:
[`../CLAUDE.md`](../CLAUDE.md).
