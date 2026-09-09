# Demo: Windows Events to Google SecOps — when the native source can't run

The `winsec` stream: a native source **exists** for this format and is
**unusable here**.

| Walkthrough | Pattern | Processors you write |
|---|---|---|
| [`demo-json-parsing.md`](demo-json-parsing.md) | nothing ships | 3, by hand |
| [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md) | blueprint | 0 — 32 shipped |
| [`demo-native-sources.md`](demo-native-sources.md) | native source | 0 |
| **this one** | **platform rules the source out** | **build from XML** |

## Why the native source is off the table

`windowsevents_v3`, `windowsevents_v2`, `windowseventforwarding`,
`windowsremotecollection` and `windowseventtrace` all render to the
**`windowseventlog` receiver**, which reads the Windows Event Log API against a
live Windows host. It cannot read a file and cannot run in a Linux container —
and every collector here is Linux. So the stream arrives over **raw TCP** with
`parse_format: none`.

More common than it sounds: agentless collection, forwarded events, syslog relays
and anything containerised all land here — Windows Event XML on a socket with no
Windows-specific receiver to hand it to.

**Worth stating on stage:** the native source exists and is the right answer on a
Windows host. It is the wrong answer here.

## Starting state

`blitz-winsec` → tcp `:5142` → `bdot-winsec` (config `grrcon-winsec`) → Google SecOps.
The same stream also reaches the edge tier via `blitz-winsec-gw`.

A record on arrival, verified live:

```
Body: Str(<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
          <System><Provider Name="Microsoft-Windows-Security-Auditing"
          Guid="{54849625-5478-4994-A5BA-3E3B0328C30D}"/><EventID>4624</EventID>
          ...<EventData><Data Name="TargetUserName">jsmith</Data>...)

Attributes:
     -> log_type: Str(windows_event.security)
     -> net.transport, net.peer.ip, net.peer.port, net.host.name

Timestamp:      1970-01-01 00:00:00      <-- not set
SeverityText:                            <-- not set
SeverityNumber: Unspecified(0)
```

One XML string. Same three problems as the JSON stream — no fields, timestamp or
severity — with a harder shape: nested elements, meaning in *attributes*, and
empty elements naive parsers drop.

**Raw TCP is deliberate.** `parse_format: none` keeps the body as generated, with
no syslog header to strip. Contrast Palo Alto, where the blueprint *expects* a
header and removes it.

## The event mix, and why it matters

`samples/winsec.xml` is 67 lines, deliberately skewed: 52× 4624 (successful
logon), 6× 4688 (process creation), 6× 4625 (failed logon), 3× 4740 (lockout).

`filegen` picks one random line per cycle, so **~78% of this stream is benign
successful logons** — and 4625/4740, what a SOC actually cares about, are buried.
That ratio is the demo. Retune with `samples/generate-winsec.sh`.

## What ships for this stream

Nothing parses Windows Event XML on ingest; four bundles do it downstream.

**`parse-windows-event-xml`** — the parser. Four processors, the first three
being the interesting part:

```
Convert XML Attributes To Elements   xml_attributes_to_elements
Insert XML Placeholder For Empty     xml_insert_elements
Convert XML Text To Elements         xml_text_to_elements
Parse Simplified XML                 parse_simple_xml
```

Three normalization passes before one parse, and not overengineering: meaning
lives in *attributes*, which an element-keyed parser would discard, and empty
`<Data>` elements vanish without the placeholder step. **Good slide** — a
concrete answer to "why can't I just parse the XML?"

**`google-secops-windows-routing-bundle`** — a full pipeline blueprint:

```
Google SecOps Standardization    google_secops_standardization
Copy Field                       copy_field_v2
Batch (WINEVTLOG)  Batch (SYSMON)  Batch (POWERSHELL)
Batch (DNS)        Batch (MSSQL)
```

Standardization assigns the SecOps log type; the five batch processors keep each
type in its own batch. **SecOps ingests per log type**, so a mixed batch is a
problem — the routing is not cosmetic.

**`google-secops-bundle`** — general standardization.
**`deduplicate-windows-events-rendering-info`** and **`remove-winevt-messages`** —
volume reduction; Windows events carry large rendered-message blocks duplicating
the structured data, a substantial saving on a mostly-4624 stream.

Also a `secops_filter` processor type, and
`crowdstrike-falcon-google-secops-volume-reduction` as a worked 30–50% reduction
example on a different EDR source.

## The flow

1. **Show the raw record.** XML string, 1970, no severity. Point out the
   attribute-carried fields — that is what makes it harder than the JSON stream.
2. **Explain why the native source is out.** `windowseventlog` needs the Windows
   Event Log API. This is a Linux container. Show `parse_format: none`.
3. **Apply `parse-windows-event-xml`.** Walk the three normalization steps before
   the parse and say why each exists. Show the structured, name-keyed map.
4. **Apply the SecOps standardization** and show the assigned log type, then the
   per-log-type batching.
5. **Reduce.** `remove-winevt-messages` and
   `deduplicate-windows-events-rendering-info`, then filter the 4624 noise —
   ~78% of the stream by construction.
6. **Capture it back into the repo:**

   ```bash
   bindplane get processors --export > bindplane/60-processors.yaml
   ```

   Use a `60-` prefix so it applies after the configurations that reference it.

## Suggested placement in the set

Run it **after** JSON — the natural sequel, same "nothing parses this" start but
a harder format and a vendor destination with real requirements. The four
together:

- `appjson` — nothing ships, build it
- `winsec` — the native source exists but not on this platform, build it anyway
- `paloalto` — a full pipeline ships, take it
- `apache` / `cef` — the source itself parses, just pick it

## The credentials trap

The chronicle exporter **reads its credentials file at startup**. Without it the
collector fails to start — not the pipeline, the whole collector. That is why
`bdot-winsec` mounts `credentials.json`. It bit this project for real: a rollout
halted on the first collector with

```
failed to start "chronicle/Google-SecOps" exporter:
load Google credentials: read credentials file: open C:/credentials.json: no such file or directory
```

— a Windows path on a Linux container, from the account's `Google-SecOps`
destination. `grrcon-google-secops`, which this pipeline uses, points at
`/opt/credentials.json`.

**The credentials are a dummy** — a real 2048-bit RSA key with a fake identity,
so the exporter loads cleanly then fails at the network.

**SecOps failing is not observable the way the others are.** Elastic, Dynatrace
and Splunk log countable export errors; SecOps fails quietly — measured at 4 log
lines in 5 minutes against Splunk's 423 in 60 seconds. Never read a low error
count here as success; use Bindplane throughput instead. (There is no committed
debug destination any more — see `.claude/50-routing.md`.)

## Resetting between runs

```bash
git checkout bindplane/20-source-winsec.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-winsec
```

If you exported instantiated bundles to `bindplane/60-processors.yaml`, delete
that file before re-applying or they will come straight back.

## Traps

- **`log_type` is an attribute here**, set by the tcp source, so the router
  matches `attributes["log_type"] == "windows_event.security"`. Apache is the odd
  one out with `body["log_type"]`. Processors never affect routing.
- **Do not switch to syslog to "fix" the timestamp.** The XML carries its own
  `TimeCreated SystemTime` for a parser to promote. Syslog adds a header to strip
  and, with blitz's RFC 5424 output, a non-compliant nanosecond timestamp the
  collector's syslog parser rejects silently.
- **A paused progressive rollout is not a failure.** `grrcon-gateway` stages
  Canary → Prod and reports `Paused ... errors=0` between them;
  `bindplane rollout resume grrcon-gateway` advances it.

## Reference

Stream `bindplane/20-source-winsec.yaml`; generators `blitz-winsec` and
`blitz-winsec-gw`; samples via `samples/generate-winsec.sh`. Bundles:
`parse-windows-event-xml`, `google-secops-windows-routing-bundle`,
`google-secops-bundle`, `deduplicate-windows-events-rendering-info`,
`remove-winevt-messages`.
