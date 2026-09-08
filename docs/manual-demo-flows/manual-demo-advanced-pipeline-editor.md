# Advanced Pipeline Editor - Demo Flow

- Open `grrcon-edge` config
- Explain OTel collector agent pattern of collecting telemetry on the edge
    - Limited to no processing on the edge
    - Send telemetry from all edge devices and apps to a gateway
- Open `grrcon-gateway` config
    - Explain OTel collector gateway pattern
- Open Advanced Pipeline Editor
- Open source processor node, show all different log types with Pipeline Intelligence Get Log Types
- Explain Routing with the routing connector + show the routing rules with the OTTL Expressions
- Use left side filters sidebar to isolate SecOps destination - explain router is sending only Windows Security events to SecOps
- Add the `Standardize & Route Windows Events for Google SecOps` full-pipeline blueprint on the SecOps processor node
- Show before/after logs structure
