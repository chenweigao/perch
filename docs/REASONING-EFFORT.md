# Reasoning capability and selectable effort

A model can support reasoning without declaring selectable effort levels. Perch
keeps these facts separate: missing `support_efforts` hides the effort selector,
while a reasoning-capable model's details explain that its levels are undeclared.
Opening the Kimi model picker refreshes its catalog, so a configuration correction
does not require disconnecting an active task. `none` is preserved as its own
wire value, distinct from `off`.

Kimi supports explicit model overrides in its
[configuration](https://moonshotai.github.io/kimi-code/en/configuration/config-files.html#thinking).
Perch never infers levels from provider or model names. For existing custom aliases,
review upstream documentation or API responses, then prepare a JSON file such as:

```json
{"configured-alias": {"support_efforts": ["low", "medium", "high"]}}
```

The sample is a format example, not a recommendation for any model. Run
`python3 scripts/configure-verified-efforts.py metadata.json --config PATH` to
validate without writing, then add `--apply` to save. The utility only appends
reviewed effort overrides to existing aliases; it refuses conflicting metadata,
keeps the original configuration text, writes a private backup beside it and
replaces the file atomically. It does not change defaults or credentials.

## aone observations on 2026-09-24

Minimal authenticated probes used the already configured endpoints. Low succeeded;
an intentionally invalid effort produced an explicit allowed-value list:

| Configured alias | Declared values from API rejection | Low probe |
| --- | --- | --- |
| aone/glm-5.2 | none, minimal, low, medium, high, xhigh, max | HTTP 200 |
| aone/deepseek-v4-pro | low, medium, high, xhigh, max | HTTP 200 |
| aone/gpt-5.6-sol | none, minimal, low, medium, high, xhigh, max | HTTP 200 |
| aone/qwen3.8-max | Unverified | HTTP 429, workspace quota exceeded |

The three verified lists were applied to the local and dev-env Kimi configurations,
with private backups. Catalog readback reflected the new values without restarting
Kimi or changing the default effort. The Qwen configuration was left unchanged.
These probes establish accepted parameters, not comparative reasoning quality or
that every advertised level has been independently exercised.
