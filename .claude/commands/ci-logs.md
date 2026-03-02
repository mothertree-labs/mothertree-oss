# CI Logs — Woodpecker CI Build Logs

Retrieve and display build logs from the Woodpecker CI server.

## Configuration

- **API**: `https://ci.mother-tree.org/api`
- **Auth**: Personal access token stored in macOS keychain as `woodpecker-api-token` (account: `mothertree`)
- **Repo ID**: `1` (mothertree-labs/mothertree-oss)
- **Log encoding**: Log entry `data` fields are base64-encoded; decode before display

## How to Retrieve the Token

```bash
security find-generic-password -a "mothertree" -s "woodpecker-api-token" -w
```

All API calls use header: `Authorization: Bearer <token>`

## Your Task

When the user invokes this skill, determine what they need and use the appropriate workflow below. If no arguments are given, default to **Workflow 1** (show recent pipelines).

The user may pass arguments like:
- No args → show recent pipelines
- A pipeline number (e.g. `150`) → show that pipeline's workflows/steps and auto-fetch logs for failed steps
- `latest` → show the latest pipeline
- A branch name (e.g. `main`, `fix/something`) → filter pipelines by branch
- `failures` or `failed` → show recent failed pipelines

## Workflow 1: List Recent Pipelines

```bash
WP_TOKEN=$(security find-generic-password -a "mothertree" -s "woodpecker-api-token" -w)
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "https://ci.mother-tree.org/api/repos/1/pipelines?perPage=10"
```

Display as a table:
```
#  | Status  | Branch          | Event        | Message (truncated)         | Time
---|---------|-----------------|--------------|-----------------------------|---------
```

Useful query parameters:
- `perPage=N` — limit results
- `branch=<name>` — filter by branch
- `status=failure` — only failures
- `event=pull_request` or `event=push` — filter by trigger

## Workflow 2: Show Pipeline Detail

```bash
WP_TOKEN=$(security find-generic-password -a "mothertree" -s "woodpecker-api-token" -w)
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "https://ci.mother-tree.org/api/repos/1/pipelines/{number}"
```

Use `latest` as the number to get the most recent pipeline.

Display the pipeline info, then list all workflows and their steps with status. Highlight failed steps. If any steps failed, **automatically fetch their logs** using Workflow 3.

## Workflow 3: Fetch Step Logs

```bash
WP_TOKEN=$(security find-generic-password -a "mothertree" -s "woodpecker-api-token" -w)
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "https://ci.mother-tree.org/api/repos/1/logs/{pipeline_number}/{step_id}"
```

The response is a JSON array of log entries. Each entry has:
- `line`: line number
- `data`: base64-encoded string (or null)
- `time`: timestamp (seconds)

**Decode and display the logs.** Use this bash one-liner to decode:

```bash
curl -s -H "Authorization: Bearer $WP_TOKEN" \
  "https://ci.mother-tree.org/api/repos/1/logs/{number}/{stepID}" \
  | python3 -c "
import json, sys, base64
entries = json.load(sys.stdin)
for e in entries:
    d = e.get('data')
    if d:
        print(base64.b64decode(d).decode('utf-8', errors='replace'))
    else:
        print()
"
```

For long logs, show the **last 80 lines by default** unless the user asks for more. Always show the full output for failed steps if under 200 lines.

## Workflow 4: Smart Failure Investigation

When the user asks "why did the build fail" or similar:

1. Fetch the latest pipeline (or specified one)
2. Find all failed steps
3. Fetch logs for each failed step
4. Analyze the logs and present a summary:
   - Which steps failed
   - The error message / root cause from the logs
   - The relevant log lines (not the entire log)

## Display Guidelines

- Use readable formatting — tables for pipeline lists, indented trees for workflow/step hierarchies
- Show timestamps as relative time (e.g. "2 hours ago") when possible
- For step status, use: success/failure/skipped/running/pending
- Always include a link to the Woodpecker UI: `https://ci.mother-tree.org/repos/1/pipeline/{number}`
- When showing logs, strip ANSI color codes if present for readability
