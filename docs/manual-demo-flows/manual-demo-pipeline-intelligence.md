# Pipeline Intelligence - Demo Flow

- Open `grrcon-appjson` config
- Show raw JSON logs
- Create JSON parser with natural language OR use `Recommendations`
- Continue using natural language or `Recommendations` to:
    - Add `Parse Timestamp` processor
    - Add `Parse Severity` processor
    - Add `Delete Parsed Fields` processor
    - Add `Filter Debug Logs` processor
- After fully parsing the JSON logs you can add whichever filter you want eg:
    - Filter by condition: `service`, `host`, etc.
