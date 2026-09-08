# Full Pipeline Blueprints - Demo Flow

- Create a new config
- Select `Build from a Blueprint`
- Select either of these two (note the sources are pre-configured in the demo to work OOTB, only configure the destinations with dummy data):
    - `Enrich Palo Alto Security Events for Dynatrace`
    - `Ingest and Process Apache Common Logs for Elasticsearch`
- Show the new pipeline with the pre-created processor nodes and processors
- Show that the sample logs are being transformed OOTB
- Show you can also drop a full-pipeline blueprint into an existing config
- Open `grrcon-winsec`, click `Add Blueprint`, select `Standardize & Route Windows Events for Google SecOps`, click `Add to pipeline`, click a processor node, click `Start Rollout`
- Show the processor node that added the processors, explain the standardization processor bundle
- Show the routing connector, explain the OTTL expression routing
