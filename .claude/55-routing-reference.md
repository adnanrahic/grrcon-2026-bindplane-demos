# Routing reference: ottl, OTLP, syslog, ordering

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

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
got created. With the catch-all unwired those records are discarded rather than
printed, so no exporter errors appear anywhere -- but the unmatched branch's
throughput still climbs, which is the tell. It looks exactly like a broken
routing condition.

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

