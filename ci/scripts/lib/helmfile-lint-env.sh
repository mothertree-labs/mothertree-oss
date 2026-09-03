#!/usr/bin/env bash
# Dummy values for every `requiredEnv` referenced by apps/helmfile.yaml.gotmpl.
#
# Sourced by CI steps that only *render* the helmfile (lint, template,
# config validation) and never talk to a cluster. Keep this list in sync with
# the requiredEnv calls in the helmfile; a missing entry makes helmfile abort
# before rendering anything.
#
# Usage:  source "$(dirname "$0")/lib/helmfile-lint-env.sh"

export NS_INGRESS="infra-ingress"
export NS_CERTMANAGER="infra-cert-manager"
export NS_MONITORING="infra-monitoring"
export NS_INGRESS_INTERNAL="infra-ingress-internal"
export NS_AUTH="infra-auth"
export NS_OFFICE="tn-lint-docs"
export NS_MATRIX="tn-lint-matrix"
export NS_FILES="tn-lint-files"
export NS_JITSI="tn-lint-jitsi"
export NEXTCLOUD_DB_NAME="lint_nextcloud"
export TENANT_DB_USER="lint_user"
export ALERTMANAGER_EMAIL_TO="lint@example.com"
export SMTP_DOMAIN="example.com"
