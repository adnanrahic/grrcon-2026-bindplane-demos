# Demo: Windows Events to Google SecOps — when the native source can't run

A walkthrough for the `winsec` stream. It completes the set with a fourth
pattern: a native source **exists** for this format and is **unusable here**.

| Walkthrough | Pattern | Processors you write |
|---|---|---|
| [`demo-json-parsing.md`](demo-json-parsing.md) | nothing ships | 3, by hand |
| [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md) | full pipeline blueprint | 0 — 32 shipped |
| [`demo-native-sources.md`](demo-native-sources.md) | native source parses on ingest | 0 |
| **this one** | **native source exists, platform rules it out** | **build from XML, then standardize** |

## Why the native source is off the table

Bindplane has `windowsevents_v3`, `windowsevents_v2`,
`windowseventforwarding`, `windowsremotecollection` and `windowseventtrace`.
All render to the **`windowseventlog` receiver**, which reads the Windows Event
Log API — channels and XPath queries against a live Windows host.

It cannot read a file, and it cannot run in a Linux container. Every collector in
this demo is Linux. So the format-specific source is out, and the stream arrives
over **raw TCP** with `parse_format: none`.

This is a more common situation than it sounds. Agentless collection, forwarded
events, syslog relays from Windows infrastructure, and anything running in a
container all land in the same place: you have Windows Event XML on a socket and
no Windows-specific receiver to hand it to.

**Worth stating plainly on stage:** this is not Bindplane failing to ship
something. The native source exists and is the right answer on a Windows host.
It is the wrong answer here, and the demo shows what you do instead.

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

One XML string. Same three problems as the JSON stream — no fields, no
timestamp, no severity — but with a harder shape: nested elements, attributes
carrying the meaning (`<Data Name="TargetUserName">`), and empty elements that
naive parsers drop.

**Raw TCP is deliberate.** `parse_format: none` means the body is the XML exactly
as generated, with no syslog header to strip. Contrast the Palo Alto stream,
where the blueprint *expects* a header and removes it itself.

## The event mix, and why it matters

`samples/winsec.xml` is 67 lines, deliberately skewed:

| EventID | Count | Meaning |
|---|---|---|
| 4624 | 52 | successful logon |
| 4688 | 6 | process creation |
| 4625 | 6 | failed logon |
| 4740 | 3 | account lockout |

`filegen` picks one random line per cycle, so **~78% of this stream is benign
successful logons**. That ratio is the demo: 4625 (failed logon) and 4740
(lockout) are what a SOC cares about, and they are buried. Retune with
`samples/generate-winsec.sh`.

## What ships for this stream

Nothing parses Windows Event XML on ingest, but four bundles do the work
downstream:

**`parse-windows-event-xml`** — the parser. Four processors, and the three
before the last are the interesting part:

```
Convert XML Attributes To Elements   xml_attributes_to_elements
Insert XML Placeholder For Empty     xml_insert_elements
Convert XML Text To Elements         xml_text_to_elements
Parse Simplified XML                 parse_simple_xml
```

Three normalization passes before a single parse. That is not overengineering:
Windows Event XML puts meaning in *attributes* (`<Data Name="TargetUserName">`),
and a simplified XML parser keyed on element names would throw those away. Empty
`<Data>` elements vanish entirely without the placeholder step. **This is a good
slide** — it is a concrete answer to "why can't I just parse the XML?"

**`google-secops-windows-routing-bundle`** — a full pipeline blueprint:

```
Google SecOps Standardization    google_secops_standardization
Copy Field                       copy_field_v2
Batch (WINEVTLOG)  Batch (SYSMON)  Batch (POWERSHELL)
Batch (DNS)        Batch (MSSQL)
```

The standardization step assigns the SecOps log type; the five batch processors
then keep each log type in its own batch. **SecOps ingests per log type**, so a
mixed batch is a problem — the routing is not cosmetic.

**`google-secops-bundle`** — general SecOps standardization.

**`deduplicate-windows-events-rendering-info`** and **`remove-winevt-messages`** —
volume reduction. Windows events carry large rendered-message blocks that
duplicate the structured data; dropping them is a substantial saving on a stream
that is mostly 4624s.

There is also a `secops_filter` processor type, and
`crowdstrike-falcon-google-secops-volume-reduction` as a worked example of the
30–50% reduction pattern applied to a different EDR source.

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

Run it **after** the JSON walkthrough and **before or after** Palo Alto. It is
the natural sequel to JSON — same "nothing parses this" starting point, but with
a harder format and a vendor destination with real requirements. The four
together make a complete argument:

- `appjson` — nothing ships, build it
- `winsec` — the native source exists but not on this platform, build it anyway
- `paloalto` — a full pipeline ships, take it
- `apache` / `cef` — the source itself parses, just pick it

## The credentials trap

`grrcon-winsec` is the only source-tier configuration exporting to Google SecOps,
and the chronicle exporter **reads its credentials file at startup**. Without it
the collector fails to start — not the pipeline, the whole collector.

That is why `bdot-winsec` mounts `credentials.json` and the other source
collectors do not. It bit this project for real: a rollout halted on the first
collector with

```
failed to start "chronicle/Google-SecOps" exporter:
load Google credentials: read credentials file: open C:/credentials.json: no such file or directory
```

— a Windows path on a Linux container, from the account's `Google-SecOps`
destination. `Google-SecOps-Linux` uses `/opt/credentials.json`, which is what
this pipeline uses.

**The credentials are a dummy** — a real 2048-bit RSA key with a fake identity,
so the exporter loads cleanly and then fails at the network. See the README's
"Dummy SecOps credentials".

**So SecOps failing is not observable the way the others are.** Elastic,
Dynatrace and Splunk log export errors you can count; SecOps fails quietly. Do
not read a low error count on this stream as success. Verify with the debug
destination or Bindplane throughput instead.

## Resetting between runs

```bash
git checkout bindplane/20-source-winsec.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-winsec
```

If you exported instantiated bundles to `bindplane/60-processors.yaml`, delete
that file before re-applying or they will come straight back.

## Traps

**`log_type` is an attribute here**, set by the tcp source, so the gateway router
matches `attributes["log_type"] == "windows_event.security"`. Apache is the odd
one out with `body["log_type"]`. Adding processors never affects routing.

**Do not switch this stream to syslog to "fix" the timestamp.** The XML carries
its own `TimeCreated SystemTime`, which a parser can promote. Wrapping it in
syslog adds a header to strip and, with blitz's RFC 5424 output, a
non-compliant nanosecond timestamp that the collector's syslog parser rejects
outright — silently.

**A paused progressive rollout is not a failure.** If you roll the gateway
config during this demo, `grrcon-gateway` stages Canary → Prod and reports
`Paused ... errors=0` in between. `bindplane rollout resume grrcon-gateway`
advances it.

## Reference

- Stream definition: `bindplane/20-source-winsec.yaml`
- Generator: `blitz-winsec` in `docker-compose.blitz.yaml`; edge duplicate
  `blitz-winsec-gw`
- Sample regeneration: `samples/generate-winsec.sh`
- Bundles: `parse-windows-event-xml`, `google-secops-windows-routing-bundle`,
  `google-secops-bundle`, `deduplicate-windows-events-rendering-info`,
  `remove-winevt-messages`
- Companion walkthroughs: [`demo-json-parsing.md`](demo-json-parsing.md),
  [`demo-palo-alto-blueprint.md`](demo-palo-alto-blueprint.md),
  [`demo-native-sources.md`](demo-native-sources.md)
