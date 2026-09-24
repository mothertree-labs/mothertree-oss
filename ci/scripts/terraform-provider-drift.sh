#!/usr/bin/env bash
# Fail when one Terraform provider is pinned at different version constraints
# in different .tf files.
#
# Terraform intersects a provider's constraint across a root config and every
# module that root calls. Bump one side alone (`~> 5.0` in phase1 while
# modules/lke-cluster still says `~> 4.0`) and the intersection is empty:
# `terraform init` fails with "no available releases match". PR #504 fixed
# exactly that by hand after the linode 3.9 -> 4.0 bump.
#
# The invariant this repo wants is stricter and simpler than "non-empty
# intersection": every declaration of a provider carries the SAME constraint,
# so a bump either moves all of them in one PR or turns that PR red here.
# Dependabot's terraform updater does follow each root's local module sources
# and rewrites them together (verified in its job log, 2026-09-23); this check
# is what makes that a guarantee rather than an observation.
#
# Usage: terraform-provider-drift.sh [dir]     (default: the repo root)
# Exit 0 when consistent, 1 on drift, 2 when nothing could be parsed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$HERE/../.." && pwd)}"
[ -d "$ROOT" ] || { echo "terraform-provider-drift: not a directory: $ROOT" >&2; exit 2; }
cd "$ROOT"

# Emits one line per declaration: <source> TAB <constraint> TAB <file>.
#
# Only entries inside a `required_providers` block count, comment lines are
# skipped so a documented example cannot pose as a pin, and an entry with no
# `version` is ignored because an unconstrained declaration intersects with
# anything. Handles both the multi-line and the one-line `{ ... }` block form.
# `required_version` never matches: the version regex refuses a preceding
# identifier character.
PARSER='
  /^[[:space:]]*(#|\/\/)/ { next }
  /required_providers[[:space:]]*\{/ { in_rp = 1; depth = 0 }
  in_rp {
    opens = gsub(/\{/, "{"); closes = gsub(/\}/, "}")
    if (match($0, /source[[:space:]]*=[[:space:]]*"[^"]+"/)) {
      s = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", s); sub(/"$/, "", s); src = s
    }
    if (match($0, /(^|[^_[:alnum:]])version[[:space:]]*=[[:space:]]*"[^"]+"/)) {
      v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); ver = v
    }
    depth += opens - closes
    if (closes > 0 && src != "") {
      if (ver != "") printf "%s\t%s\t%s\n", src, ver, FILENAME
      src = ""; ver = ""
    }
    if (depth <= 0) in_rp = 0
  }
'

# Submodules (config/, submodules/, synapse) are other repositories: not
# validated here, and not something this check should ever read.
declarations=""
while IFS= read -r -d '' f; do
  declarations+="$(awk "$PARSER" "$f")"$'\n'
done < <(find . \( -path './config' -o -path './submodules' -o -path './synapse' \
                   -o -name '.terraform' -o -name '.git' \) -prune \
              -o -name '*.tf' -print0 | sort -z)
declarations="$(printf '%s' "$declarations" | sed '/^$/d')"

if [ -z "$declarations" ]; then
  echo "terraform-provider-drift: no required_providers found under $ROOT" >&2
  exit 2
fi

drifted="$(printf '%s\n' "$declarations" | awk -F'\t' '
  ($1 in first) { if ($2 != first[$1]) bad[$1] = 1; next }
  { first[$1] = $2 }
  END { for (p in bad) print p }
' | sort)"

if [ -n "$drifted" ]; then
  echo "^^^ +++"
  echo "Provider constraint drift: the same provider is pinned differently in different files."
  echo "A root and a module it calls must agree or 'terraform init' resolves to the empty set."
  echo "Bump every declaration of the provider in the same PR:"
  while IFS= read -r p; do
    echo "  $p"
    printf '%s\n' "$declarations" | awk -F'\t' -v p="$p" '$1 == p { printf "    %-12s %s\n", $2, $3 }'
  done <<< "$drifted"
  exit 1
fi

providers="$(printf '%s\n' "$declarations" | cut -f1 | sort -u | wc -l | tr -d ' ')"
count="$(printf '%s\n' "$declarations" | wc -l | tr -d ' ')"
echo "Provider constraints consistent: $providers providers, $count declarations"
