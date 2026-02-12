To provision users:

```sh
./perf/tools/users/provision_users.py \
  --env dev \
  --csv perf/users/users.csv \
  --kc-base-url https://auth.dev.example.com \
  --realm master \
  --kc-admin-username admin \
  --kc-admin-password 'keycloak-admin-password-change-me'
```


Create namespace and secrets (after creating the env):

```
KUBECONFIG=./kubeconfig.dev.yaml kubectl create namespace perf

KUBECONFIG=./kubeconfig.dev.yaml kubectl -n perf create secret generic perf-users \
  --from-file=users.csv=perf/users/users.csv \
  --dry-run=client -o yaml | kubectl apply -f -

KUBECONFIG=./kubeconfig.dev.yaml kubectl -n perf apply -f apps/manifests/perf/prod/k6-matrix-load.yaml
KUBECONFIG=./kubeconfig.dev.yaml kubectl -n perf apply -f apps/manifests/perf/prod/k6-docs-smoke.yaml
```

Create secretes in kube:

```
kubectl -n perf create secret generic perf-users \
  --from-file=users.csv=perf/users/users.csv \
  --dry-run=client -o yaml | kubectl apply -f -
```


Run
```
kubectl -n perf apply -f apps/manifests/perf/prod/k6-matrix-load.yaml
kubectl -n perf apply -f apps/manifests/perf/prod/k6-docs-smoke.yaml
```

logs:
```
kubectl -n perf logs job/k6-matrix-load -f
kubectl -n perf logs job/k6-docs-smoke -f
```



```
# Or delete all perf jobs at once
KUBECONFIG=./kubeconfig.dev.yaml kubectl -n perf delete job --all
```


to run, use script
```
./scripts/run_perf dev matrix load   
```