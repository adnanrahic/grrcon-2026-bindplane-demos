# Demo: a vendor blueprint doing the work end to end

A walkthrough for the `paloalto` stream — the mirror image of
[the JSON parsing demo](demo-json-parsing.md). There, nothing shipped and every
processor was built by hand. Here, Bindplane ships a **full pipeline blueprint**
that parses, enriches and reduces PAN-OS logs, and the demo is about how much
you get for free.

Run the two back to back and the pair makes an argument neither makes alone.

## Why this stream

`paloalto` is PAN-OS CSV arriving over TCP. Three things make it a good blueprint
exhibit:

- **PAN-OS is genuinely hard to parse.** Fourteen log types share one syslog
  feed, each with a different CSV column layout. Hand-writing that is a day's
  work and a permanent maintenance liability.
- **A full pipeline blueprint exists for it** —
  `dynatrace-palo-alto-security-full-pipeline` — covering receive, parse, enrich
  and deliver.
- **The enrichment is the interesting part**, not the parsing. It maps events to
  MITRE ATT&CK tactics and techniques, which is analysis, not plumbing.

There is no `palo_alto` *source type*, which surprises people. It does not
matter: the blueprint uses generic `tcp` and `udp` sources and does the work
downstream. That is worth saying out loud, because "there's no source for my
vendor" is a common objection with a good answer.

## Starting state

`blitz-palo-alto` → tcp `:5141` → `bdot-panos` (config `grrcon-panos`) → Dynatrace.
The same stream also reaches the gateway tier via `bdot-edge-*`.

The source sets `parse_format: none` deliberately — the blueprint expects to do
the parsing. A record on arrival:

```
Body: Str(Sep  2 12:26:49 localhost 1,2026/09/02 12:26:49,001901000123,
          AUTHENTICATION,auth,,2026/09/02 12:26:49,vsys1,203.0.113.20,
          corp\alice,alice,GlobalProtect,GP-Auth,1,,PAN-OS,default,LDAP,
          authentication succeeded,GlobalProtect,auth-success,1,...)

Attributes:
     -> log_type: Str(palo-alto)
     -> net.peer.ip, net.peer.port, net.transport
```

One string. A syslog header, then ~50 unlabelled CSV columns whose meaning
depends on field 4 (`AUTHENTICATION` here, but `THREAT` or `TRAFFIC` on the next
record, each with a different layout).

**The generator emits 13 log types** from `package:palo-alto/csv`:
`authentication`, `config`, `correlation`, `decryption`, `globalprotect`, `gtp`,
`hipmatch`, `iptag`, `sctp`, `system`, `threat`, `traffic`, `userid`. Showing two
or three consecutive records makes the point that a single regex will not do.

## What the blueprint actually does

Three processor groups, in order.

### 1. Parse Palo Alto Syslog

First processor is **Strip Syslog Header** (`parse_regex`):

```
^.+?(?P<message>\d,\d{4}\/\d{2}\/\d{2}.+)
```

It discards `Sep  2 12:26:49 localhost ` and captures the CSV payload, which
always starts `1,YYYY/MM/DD`. **The syslog header is expected, not a problem** —
this is why the stream is sent as raw TCP rather than through blitz's syslog
output, which would have wrapped it a second time.

Then **13 `parse_csv` processors**, one per log type — Parse THREAT, Parse
TRAFFIC, Parse HIP-MATCH, Parse AUTHENTICATION, Parse CONFIG, Parse CORRELATION,
Parse DECRYPTION, Parse GLOBALPROTECT, Parse GTP, Parse IPTAG, Parse SCTP, Parse
SYSTEM, Parse USERID — each conditioned on the `Type` field, each with its own
column header list. A **Remove Intermediate Field** step cleans up afterwards.

This is the part worth showing as a list rather than describing. Thirteen
type-specific parsers is exactly the work you are not doing.

### 2. Enrich Palo Alto Security Events

Fifteen enrichment rules, each matching a condition and attaching MITRE ATT&CK
context:

```
Valid Account Usage      Brute Force Authentication   VPN Brute Force
VPN Access               Defense Evasion Changes      C2 Communication
Exploit Detection        Malware Detection            WildFire Detection
Phishing Detection       Drive-by Compromise          Ingress Tool Transfer
DNS Tunneling            Data Exfiltration            Network Scanning
```

A concrete one — successful administrator login:

```yaml
condition: (body["Type"] == "SYSTEM") and
           (IsMatch(body["Event ID"], "(?i)auth-success|login-success|succeeded"))
adds:
  security_signal:      paloalto.valid_account_use
  mitre_tactic:         credential-access
  mitre_technique_id:   T1078
  mitre_technique_name: Valid Accounts
  mitre_confidence:     <score>
```

The generator's sample set produces AUTHENTICATION and THREAT records, so several
of these fire in a live run. **This is the moment to land**: a raw CSV column
became `T1078 / Valid Accounts` without anyone writing a detection rule.

Then **Delete Empty Values** and **Batch for Dynatrace**.

### 3. Delivery

The blueprint terminates at Dynatrace, which matches this pipeline's existing
destination — `grrcon-panos` already sends there, so the blueprint drops in
without repointing anything.

## Reduction: the ingest-cost story

The standalone **`palo-alto-full-log-parsing-and-reduction-bundle`** (23
processors) is the same parsing plus toggleable volume filters:

| Toggle | Drops |
|---|---|
| `threat_filter_informational` | informational-severity THREAT events |
| `traffic_filter_allowed` | allowed (non-blocked) traffic |
| `traffic_filter_dns` | routine DNS traffic |
| `traffic_filter_start` | session-start records, keeping session-end |

Plus **Filter - Internal to Internal** and **Remove Intermediate & Control
Fields**.

Each is a `true`/`false` in a **Processing Selection** processor at the top of
the bundle, so you can flip them live and watch throughput move. Firewall traffic
logs are usually the single largest source in a SIEM bill, and session-start plus
allowed traffic is most of that volume — this is the most concrete cost argument
in the whole demo.

Narrower variants exist if you only want one log type:
`palo-alto-threat-log-parsing-and-reduction-bundle` and
`palo-alto-traffic-log-parsing-and-reduction-bundle`.

## The flow

1. **Show a raw record.** One string, syslog header, ~50 anonymous columns.
   Show two more of different `Type` to prove the layouts differ.
2. **Name the problem.** Fourteen log types, one feed, different columns each.
   "How long would you spend writing this?"
3. **Apply the blueprint.** It is a `full_pipeline_blueprint`, so instantiate it
   from the Bindplane UI — `processor_bundle` is a container type with no
   parameters and cannot be built from the CLI. Applying it live is a reasonable
   demo beat in itself.
4. **Show the same record parsed** — named fields per log type.
5. **Show the MITRE fields.** `mitre_tactic`, `mitre_technique_id`,
   `mitre_technique_name`, `security_signal`. This is the payoff.
6. **Flip the reduction toggles** and watch throughput drop.
7. **Capture it back into the repo** so the demo is reproducible:

   ```bash
   bindplane get processors --export > bindplane/60-processors.yaml
   ```

   Use a `60-` prefix so it applies after the configurations that reference it —
   see the numbering note in the README.

## Suggested narrative arc

Pair this with the JSON demo and the contrast does the work:

| | `appjson` | `paloalto` |
|---|---|---|
| Native source | none | none (tcp) |
| Blueprint | none | full pipeline |
| Parsing | hand-built, 3 processors | 13 type-specific parsers, shipped |
| Enrichment | none available | 15 MITRE rules, shipped |
| Reduction | build your own | 6 toggles, shipped |

The honest framing is **not** "blueprints solve everything". It is: where a
blueprint exists you get an expert's pipeline for free; where none does, the same
tool lets you build one; and the collector, routing and destinations are
identical either way. Run `appjson` first so the audience has felt the manual
work before seeing it done for them.

## Resetting between runs

The blueprint is instantiated as processors on the configuration, so a reset is
removing them and re-applying from the repo:

```bash
git checkout bindplane/20-source-panos.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-panos
```

If you exported the instantiated bundle to `bindplane/60-processors.yaml`, delete
that file too before re-applying, or it will come straight back.

Check you are back to the raw starting state:

```bash
docker logs --since 60s bdot-panos | grep -c Dynatrace     # still exporting
for i in $(seq -w 1 10); do                                # catch-all must be 0
  docker logs --since 3m bdot-$i 2>&1 \
    | grep -o '"log records":[0-9]*' | awk -F: '{s+=$2} END{print s+0}'
done | paste -sd+ - | bc
```

## Traps

**Routing is independent of parsing.** `log_type: palo-alto` is stamped by the
`tcp` source, not by the blueprint, so adding or removing processors never
affects which destination the stream reaches. The gateway router keeps matching
`attributes["log_type"] == "palo-alto"` throughout.

**Do not send this stream over syslog.** blitz's syslog output would add a
*second* header on top of the one already in the sample data, and the blueprint's
strip regex only removes one. Raw TCP is deliberate. blitz's RFC 5424 output is
also non-compliant — it emits nanosecond timestamps where the spec allows
microseconds — so a syslog receiver rejects every record and passes it through
unparsed, silently.

**The blueprint expects the syslog header to be present.** It is not an artifact
to clean up before ingestion; `Strip Syslog Header` is step one and it needs
something to strip. Records arriving without it will not match the regex.

**A paused progressive rollout is not a failure.** If you roll the gateway config
during this demo, `grrcon-gateway` stages Canary → Prod and reports
`Paused ... errors=0` in between. `bindplane rollout resume grrcon-gateway`
advances it.

## Reference

- Stream definition: `bindplane/20-source-panos.yaml`
- Generator: `blitz-palo-alto` in `docker-compose.blitz.yaml`
- Sample data: `package:palo-alto/csv` in the blitz data library (15 lines, 13 log types)
- Blueprints: `dynatrace-palo-alto-security-full-pipeline`,
  `palo-alto-full-log-parsing-and-reduction-bundle`,
  `enrich-palo-alto-security-events`
- Companion walkthrough: [`demo-json-parsing.md`](demo-json-parsing.md)
