# Setup and configuration model

> Split out of the original long README. Part of the GrrCON Bindplane demo reference.

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

Compose mounts it read-only at `/opt/credentials.json` on the ten gateway
collectors, `bdot-winsec`, and `bdot-appjson` (which needs it for
`grrcon-google-gcl`). The edge tier and the unbound twins do not get it.

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

