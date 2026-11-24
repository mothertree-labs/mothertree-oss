#!/usr/bin/env python3
# migrate_v016.py (v0.16.27) leaves secrets as literal "%{env:X}%" strings,
# which v0.16/v1 do not expand: rewrite them to EnvironmentVariable refs
# (#715 rehearsal). Usage: patch_v016_secrets.py <src> <dst> json|ndjson
import json, re, sys
PAT = re.compile(r"^%\{env:([A-Za-z0-9_]+)\}%$")
n = 0
def fix(o):
    global n
    if isinstance(o, dict):
        if o.get("@type") in ("Value", "Text"):
            for k in ("secret", "value"):
                v = o.get(k)
                if isinstance(v, str) and PAT.match(v):
                    n += 1
                    return {"@type": "EnvironmentVariable", "variableName": PAT.match(v).group(1)}
        return {k: fix(v) for k, v in o.items()}
    if isinstance(o, list):
        return [fix(x) for x in o]
    return o
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
if mode == "json":
    out = json.dumps(fix(json.load(open(src))))
else:
    out = "\n".join(json.dumps(fix(json.loads(l))) for l in open(src) if l.strip()) + "\n"
open(dst, "w").write(out)
print(f"{src}: patched {n} secret(s)", file=sys.stderr)
