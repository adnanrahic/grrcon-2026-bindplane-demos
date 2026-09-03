# GrrCON demo reference (index)

The original long README, split into topic files. Every markdown file in this
repo is capped at 200 lines.

| File | Covers |
|---|---|
| `10-architecture.md` | Topology, tiers, fleets, why it is shaped this way |
| `20-setup.md` | Env, dummy credentials, log dirs, CLI profile, apply order, v2 |
| `30-pipelines.md` | The five pipelines, unbound twins, edge mirroring, generators |
| `40-backends.md` | Backend state, Google-GCL vs grrcon-google-gcl, native formats |
| `50-routing.md` | Router wiring, misroute detection, `log_type`, record shape |
| `55-routing-reference.md` | `ottl` vs `ui`, why not OTLP, RFC 3164, apply ordering |
| `60-blitz-data.md` | What each blitz generator emits |
| `70-operations.md` | Verify commands, progressive rollout, unbound recovery |
| `80-maintenance.md` | Collector type, rebuild, relabel, reset, file map |

Demo walkthroughs live in `docs/`.
