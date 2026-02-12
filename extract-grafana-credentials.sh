#!/bin/bash

# Extract Grafana password and output to stdout for piping
# Usage: ./extract-grafana-credentials.sh | some-other-script

set -e

# Set KUBECONFIG
# export KUBECONFIG="kubeconfig.yaml"

# Extract and decode the Grafana admin password
kubectl get secret kube-prometheus-stack-grafana -n infra-monitoring -o jsonpath='{.data.admin-password}' | base64 -d
echo 
