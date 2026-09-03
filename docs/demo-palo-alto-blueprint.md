# Demo: a vendor blueprint doing the work end to end

The `paloalto` stream — the mirror image of
[the JSON parsing demo](demo-json-parsing.md), where nothing shipped and every
processor was hand-built. Here Bindplane ships a **full pipeline blueprint** that
parses, enriches and reduces PAN-OS logs. Run the two back to back.

## Why this stream

PAN-OS CSV over TCP. Three things make it a good blueprint exhibit:

- **PAN-OS is genuinely hard to parse.** Fourteen log types share one syslog
  feed, each with a different CSV column layout — a day's work by hand and a
  permanent maintenance liability.
- **A full pipeline blueprint exists**: `dynatrace-palo-alto-security-full-pipeline`.
- **The enrichment is the interesting part**, mapping events to MITRE ATT&CK
  tactics and techniques. That is analysis, not plumbing.

There is no `palo_alto` *source type*, which surprises people, and it does not
matter — the blueprint uses generic `tcp`/`udp` and works downstream. Worth
saying out loud: "there's no source for my vendor" is a common objection with a
good answer.

## Starting state

`blitz-palo-alto` → tcp `:5141` → `bdot-panos` (`grrcon-panos`) → Dynatrace; the
stream also reaches the gateway tier via `bdot-edge-*`. The source sets
`parse_format: none` deliberately — the blueprint does the parsing. On arrival:

```
Body: Str(Sep  2 12:26:49 localhost 1,2026/09/02 12:26:49,001901000123,
          AUTHENTICATION,auth,,2026/09/02 12:26:49,vsys1,203.0.113.20,
          corp\alice,alice,GlobalProtect,GP-Auth,1,,PAN-OS,default,LDAP,
          authentication succeeded,GlobalProtect,auth-success,1,...)

Attributes:
     -> log_type: Str(palo-alto)
     -> net.peer.ip, net.peer.port, net.transport
```

One string: a syslog header, then ~50 unlabelled CSV columns whose meaning
depends on field 4 (`AUTHENTICATION` here, `THREAT` or `TRAFFIC` next, each with
a different layout).

**The generator emits 13 log types** from `package:palo-alto/csv`
(`authentication`, `config`, `correlation`, `decryption`, `globalprotect`, `gtp`,
`hipmatch`, `iptag`, `sctp`, `system`, `threat`, `traffic`, `userid`). Two or
three consecutive records make the point that one regex will not do.

## What the blueprint actually does

Three processor groups, in order.

### 1. Parse Palo Alto Syslog

First processor is **Strip Syslog Header** (`parse_regex`):

```
^.+?(?P<message>\d,\d{4}\/\d{2}\/\d{2}.+)
```

It discards `Sep  2 12:26:49 localhost ` and captures the CSV payload, which
always starts `1,YYYY/MM/DD`. **The syslog header is expected, not a problem** —
hence raw TCP rather than blitz's syslog output, which would wrap it twice.

Then **13 `parse_csv` processors**, one per log type (THREAT, TRAFFIC, HIP-MATCH,
AUTHENTICATION, CONFIG, CORRELATION, DECRYPTION, GLOBALPROTECT, GTP, IPTAG, SCTP,
SYSTEM, USERID), each conditioned on the `Type` field with its own column header
list, plus a **Remove Intermediate Field** cleanup. Show it as a list — thirteen
type-specific parsers is exactly the work you are not doing.

### 2. Enrich Palo Alto Security Events

Fifteen rules, each matching a condition and attaching MITRE ATT&CK context:
valid account usage, brute force (auth and VPN), VPN access, defense evasion, C2
communication, exploit/malware/WildFire/phishing detection, drive-by compromise,
ingress tool transfer, DNS tunneling, data exfiltration, network scanning.

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

The sample set produces AUTHENTICATION and THREAT records, so several fire in a
live run. **The moment to land**: a raw CSV column became `T1078 / Valid
Accounts` with nobody writing a detection rule. Then **Delete Empty Values** and
**Batch for Dynatrace**.

### 3. Delivery

The blueprint terminates at Dynatrace, which `grrcon-panos` already targets — so
it drops in without repointing anything.

## Reduction: the ingest-cost story

The standalone **`palo-alto-full-log-parsing-and-reduction-bundle`** (23
processors) is the same parsing plus toggleable volume filters:

| Toggle | Drops |
|---|---|
| `threat_filter_informational` | informational-severity THREAT events |
| `traffic_filter_allowed` | allowed (non-blocked) traffic |
| `traffic_filter_dns` | routine DNS traffic |
| `traffic_filter_start` | session-start, keeping session-end |

Plus **Filter - Internal to Internal** and **Remove Intermediate & Control
Fields**.

Each is a `true`/`false` in a **Processing Selection** processor at the top of the
bundle, so you flip them live and watch throughput move. Firewall traffic logs
are usually the largest source in a SIEM bill and session-start plus allowed
traffic is most of that volume — the most concrete cost argument in the demo.

Narrower variants: `palo-alto-threat-log-parsing-and-reduction-bundle`,
`palo-alto-traffic-log-parsing-and-reduction-bundle`.

## The flow

1. **Show a raw record** — one string, syslog header, ~50 anonymous columns.
   Show two more of different `Type` to prove the layouts differ.
2. **Name the problem.** Fourteen log types, one feed, different columns each.
3. **Apply the blueprint** from the Bindplane UI — `processor_bundle` is a
   container type with no parameters and cannot be built from the CLI.
4. **Show the same record parsed** — named fields per log type.
5. **Show the MITRE fields**: `mitre_tactic`, `mitre_technique_id`,
   `mitre_technique_name`, `security_signal`. The payoff.
6. **Flip the reduction toggles** and watch throughput drop.
7. **Capture it back** so the demo is reproducible — a `60-` prefix applies after
   the configurations that reference it:

   ```bash
   bindplane get processors --export > bindplane/60-processors.yaml
   ```

## Suggested narrative arc

Pair this with the JSON demo and the contrast does the work:

| | `appjson` | `paloalto` |
|---|---|---|
| Blueprint | none | full pipeline |
| Parsing | hand-built, 3 processors | 13 type-specific parsers, shipped |
| Enrichment | none available | 15 MITRE rules, shipped |
| Reduction | build your own | 6 toggles, shipped |

The honest framing is not "blueprints solve everything": where one exists you get
an expert's pipeline free, where none does the same tool builds one, and the
collector, routing and destinations are identical either way. Run `appjson` first
so the audience has felt the manual work.

## Resetting between runs

The blueprint is instantiated as processors on the configuration, so reset by
removing them and re-applying:

```bash
git checkout bindplane/20-source-panos.yaml
bindplane apply -f bindplane/
bindplane rollout start grrcon-panos
```

If you exported the bundle to `bindplane/60-processors.yaml`, delete that file
first or it comes straight back. Then confirm the raw starting state:

```bash
docker logs --since 60s bdot-panos | grep -c Dynatrace     # still exporting
```

## Traps

- **Routing is independent of parsing.** `log_type: palo-alto` is stamped by the
  `tcp` source, not the blueprint, so processors never change which destination
  the stream reaches. The router keeps matching
  `attributes["log_type"] == "palo-alto"`.
- **Do not send this over syslog.** blitz's syslog output adds a *second* header
  on top of the sample data's, and the strip regex removes one. Its RFC 5424
  output is also non-compliant — nanosecond timestamps where the spec allows
  microseconds — so a syslog receiver rejects every record silently.
- **The blueprint expects the syslog header.** `Strip Syslog Header` is step one
  and needs something to strip; records without it will not match.
- **A paused progressive rollout is not a failure.** `grrcon-gateway` stages
  Canary → Prod and reports `Paused ... errors=0` between them;
  `bindplane rollout resume grrcon-gateway` advances it.

## Reference

Stream `bindplane/20-source-panos.yaml`; generator `blitz-palo-alto`; sample data
`package:palo-alto/csv` (15 lines, 13 log types). Blueprints:
`dynatrace-palo-alto-security-full-pipeline`,
`palo-alto-full-log-parsing-and-reduction-bundle`,
`enrich-palo-alto-security-events`.
