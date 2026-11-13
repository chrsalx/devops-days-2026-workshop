# Lab: File descriptors

Each `GET /work` opens up to eight real `/dev/null` descriptors and closes them when the request completes or is canceled. A 64-slot semaphore bounds all open descriptors per pod. Gin middleware and the Prometheus Go client's process collector expose request, runtime, and process telemetry, including the container's open descriptors and baseline handles.

This lab is an independent Go module. From the repository root, run its tests and build locally with:

```sh
(cd labs/file-descriptors && go test ./... && go build ./...)
```

Initialize this lab's isolated kind cluster and install `kube-prometheus-stack`, KEDA (including its CRDs), and cAdvisor:

```sh
./labs/file-descriptors/scripts/setup.sh
```

The setup script is safe to rerun and does not install this lab's application. It creates or reuses `metrics-file-descriptors`, using the `kind-metrics-file-descriptors` context. The app, ScaledObject, k6 Job, and k6 ConfigMap use the dedicated `file-descriptors` namespace; monitoring and KEDA use their own namespaces. Setup also installs the shared cAdvisor DaemonSet from `monitoring/cadvisor` and waits for its rollout. Run `./labs/file-descriptors/scripts/cleanup.sh` when finished with this lab; it deletes only that cluster.

Prometheus automatically scrapes cAdvisor's annotated pod at `/metrics` on port 8080, making container CPU and memory series available in Grafana Explore. The DaemonSet is bounded to 300m CPU and 256Mi memory and requires read-only access to node filesystem, cgroups, and containerd state/socket; keep it to these disposable kind clusters.

If this cluster still has the old standalone Helm releases `prometheus` or `grafana`, setup stops without removing them. The simplest migration is to run `./labs/file-descriptors/scripts/cleanup.sh` and then setup again; to preserve the cluster, manually uninstall each existing release from context `kind-metrics-file-descriptors` before retrying.

Setup provisions **Workshop: application resources and k6 requests** in Grafana. After starting the app and load Job, run `./labs/file-descriptors/scripts/grafana-port-forward.sh` in a separate terminal; it forwards the service to `localhost:3000` by default and stays active until Ctrl-C. Open <http://localhost:3000> and sign in as `admin`. Retrieve the chart-generated password with:

```sh
kubectl --context kind-metrics-file-descriptors get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

This is the same command as `k get secret -n monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo` when `k` is your `kubectl` alias. On macOS, use `base64 -D` instead of `base64 --decode`. Setup also prints the generated password at completion; avoid sharing or saving terminal logs that contain it. Select this lab in the dashboard. It compares per-pod application-process CPU and resident memory with k6 HTTP requests per second by response status, summing concurrent runs. The request panel needs at least two k6 samples to calculate a rate. Grafana's local state is ephemeral and is removed when the lab cluster is cleaned up.

To update the dashboard in an existing cluster, run `kubectl --context kind-metrics-file-descriptors apply -k monitoring/grafana` from the repository root, then refresh Grafana.

If upgrading a cluster that has workloads left in the legacy Kubernetes namespace `labs`, setup does not move or delete them; they may continue running. Review and remove the old resources yourself, or run this lab's `scripts/cleanup.sh` followed by `scripts/setup.sh` to recreate the cluster.

```sh
./labs/file-descriptors/scripts/build-images.sh
kubectl --context kind-metrics-file-descriptors apply -f labs/file-descriptors/kubernetes.yaml
kubectl --context kind-metrics-file-descriptors rollout status deployment/file-descriptors -n file-descriptors --timeout=120s
kubectl --context kind-metrics-file-descriptors apply -f labs/file-descriptors/loadgen.yaml
kubectl --context kind-metrics-file-descriptors get hpa,scaledobjects,pods -n file-descriptors -w
```

The image helper uses Docker Buildx to build and load the image into this lab's kind cluster. If you rebuild an image after its Deployment is already running, restart that Deployment to make Kubernetes use the newly loaded `:local` image.

Inspect the framework exposition with `kubectl --context kind-metrics-file-descriptors port-forward -n file-descriptors svc/file-descriptors 8080:8080`, then open `http://localhost:8080/metrics`. The process-level descriptor total includes baseline sockets and runtime handles, while each request can add up to eight bounded descriptors; the `ScaledObject` caps the Deployment at five replicas. A manual request is `curl 'http://localhost:8080/work?count=8&duration=3s'`.

The k6 Job runs for three minutes at 12 virtual users, opening four descriptors per request. The k6 script ConfigMap is installed in the `file-descriptors` namespace by setup. In a separate terminal, follow k6 output with `kubectl --context kind-metrics-file-descriptors logs -n file-descriptors job/file-descriptors-load -f`. k6 counts HTTP 503 responses as overload and records other non-2xx statuses separately; neither stops the run. Stop it with `kubectl --context kind-metrics-file-descriptors delete job file-descriptors-load -n file-descriptors --ignore-not-found`; delete the Job before reapplying its manifest if its TTL has not expired. Remove the lab service with `kubectl --context kind-metrics-file-descriptors delete -f labs/file-descriptors/kubernetes.yaml`.