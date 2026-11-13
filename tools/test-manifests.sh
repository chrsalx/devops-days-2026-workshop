#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

ruby -ryaml -rjson <<'RUBY'
labs = %w[database-connections file-descriptors event-loop-lag]

labs.each do |lab|
  lab_dir = "labs/#{lab}"
  paths = ["#{lab_dir}/kubernetes.yaml", "#{lab_dir}/loadgen.yaml"]
  paths << "#{lab_dir}/scaledobject.yaml" if File.exist?("#{lab_dir}/scaledobject.yaml")
  documents = paths.flat_map do |path|
    YAML.load_stream(File.read(path)).compact
  end

  dockerfile = File.read("#{lab_dir}/Dockerfile")
  unless dockerfile.match?(/^COPY(?: --[^\s]+)* labs\/#{Regexp.escape(lab)}\//)
    abort("#{lab}: Dockerfile must copy sources from its labs/ directory")
  end

  %w[setup.sh build-images.sh].each do |script|
    script_path = "#{lab_dir}/scripts/#{script}"
    unless File.read(script_path).include?('"${SCRIPT_DIR}/../../.."')
      abort("#{lab}: #{script} must resolve the repository root from labs/<lab>/scripts")
    end
  end

  unless documents.all? { |document| document.dig("metadata", "namespace") == lab }
    abort("#{lab}: every lab workload, service, ScaledObject, and Job must use namespace #{lab}")
  end

  scaled_object = documents.find { |document| document["kind"] == "ScaledObject" }
  queries = scaled_object&.dig("spec", "triggers")&.map { |trigger| trigger.dig("metadata", "query") } || []
  unless queries.any? { |query| query&.include?(%Q(namespace="#{lab}")) }
    abort("#{lab}: KEDA query must select metrics in namespace #{lab}")
  end

  job = documents.find { |document| document["kind"] == "Job" }
  config_map_name = job&.dig("spec", "template", "spec", "volumes")&.find { |volume| volume["name"] == "load-script" }&.dig("configMap", "name")
  unless config_map_name == "k6-load-script"
    abort("#{lab}: k6 Job must mount the shared script ConfigMap")
  end
  unless job&.dig("spec", "template", "spec", "containers", 0, "args")&.include?("--include-system-env-vars")
    abort("#{lab}: k6 must expose the Job's environment variables to the shared script")
  end

  deployment = documents.find { |document| document["kind"] == "Deployment" && document.dig("metadata", "name") == lab }
  readiness_path = deployment&.dig("spec", "template", "spec", "containers", 0, "readinessProbe", "httpGet", "path")
  if lab == "database-connections" && readiness_path != "/healthz"
    abort("#{lab}: application readiness probe must use /healthz")
  end

  puts "#{lab}: manifests use the dedicated namespace and scoped KEDA query"
end

config_map = YAML.load_file("tools/k6/configmap.yaml")
unless config_map.dig("metadata", "name") == "k6-load-script" && config_map.dig("metadata", "namespace").nil? && config_map.dig("data", "config.js")
  abort("k6 ConfigMap must have a stable name, script data, and no fixed namespace")
end

database_documents = %w[kubernetes.yaml loadgen.yaml].flat_map do |path|
  YAML.load_stream(File.read("labs/database-connections/#{path}")).compact
end
database_deployment = database_documents.find { |document| document["kind"] == "Deployment" && document.dig("metadata", "name") == "database-connections" }
database_scaled_object = YAML.load_file("labs/database-connections/scaledobject.yaml")
triggers = database_scaled_object.dig("spec", "triggers") || []
prometheus_trigger = triggers.find { |trigger| trigger["type"] == "prometheus" }
cpu_trigger = triggers.find { |trigger| trigger["type"] == "cpu" }
cpu_request = database_deployment&.dig("spec", "template", "spec", "containers", 0, "resources", "requests", "cpu")
unless cpu_request == "25m" &&
       database_scaled_object.dig("kind") == "ScaledObject" &&
       database_scaled_object.dig("metadata", "namespace") == "database-connections" &&
       database_scaled_object.dig("spec", "scaleTargetRef", "name") == "database-connections" &&
       database_scaled_object.dig("spec", "minReplicaCount") == 1 &&
       database_scaled_object.dig("spec", "maxReplicaCount") == 5 &&
       triggers.length == 2 &&
       prometheus_trigger&.dig("metadata", "query")&.include?('db_name="workshop"') &&
       cpu_trigger&.dig("metricType") == "Utilization" &&
       cpu_trigger&.dig("metadata", "value") == "70"
  abort("database ScaledObject must contain both the connection and CPU triggers, target the application, and match the CPU request")
end
unless database_documents.none? { |document| document["kind"] == "ScaledObject" } && database_documents.none? { |document| document["kind"] == "HorizontalPodAutoscaler" }
  abort("database kubernetes.yaml and loadgen.yaml must not embed autoscaling objects")
end

database_job = database_documents.find { |document| document["kind"] == "Job" }
job_env = database_job.dig("spec", "template", "spec", "containers", 0, "env").to_h { |entry| [entry["name"], entry["value"]] }
k6_script = config_map.dig("data", "config.js")
unless job_env["STAGED_VUS"] == "true" &&
       job_env["DURATION"] == "10m" &&
       job_env["K6_PROMETHEUS_RW_TREND_STATS"] == "p(95)" &&
       k6_script.include?("executor: 'ramping-vus'") &&
       k6_script.scan(/\{ duration: '\d+s', target: \d+ \}/).length == 7 &&
       k6_script.include?("{ duration: '5s', target: 3 }") &&
       [1, 3, 6, 12].all? { |target| k6_script.include?("target: #{target}") }
  abort("database k6 Job must use the 10-minute staged ramp with 5-second transitions")
end

%w[file-descriptors event-loop-lag].each do |lab|
  lab_job = YAML.load_stream(File.read("labs/#{lab}/loadgen.yaml")).compact.find { |document| document["kind"] == "Job" }
  lab_env = lab_job.dig("spec", "template", "spec", "containers", 0, "env").to_h { |entry| [entry["name"], entry["value"]] }
  unless lab_env["STAGED_VUS"] == "true" && lab_env["DURATION"] == "10m"
    abort("#{lab}: k6 Job must use the shared 10-minute staged ramp")
  end
end

dashboard = JSON.parse(File.read("monitoring/grafana/dashboard.json"))
cpu_query = dashboard.dig("panels", 0, "targets", 0, "expr")
memory_query = dashboard.dig("panels", 1, "targets", 0, "expr")
unless cpu_query&.include?('namespace="${lab}"') && memory_query&.include?('namespace="${lab}"')
  abort("Grafana process panels must select the lab-specific namespace")
end

k6_panel = dashboard.fetch("panels").find { |panel| panel["title"] == "k6 request rate by HTTP status" }
k6_query = k6_panel&.dig("targets", 0, "expr")
unless k6_query == 'sum by (status) (rate(k6_http_reqs_total{lab="${lab}"}[1m]))'
  abort("Grafana k6 panel must aggregate all runs for the selected lab by status")
end
unless dashboard.dig("templating", "list").map { |variable| variable["name"] } == ["lab"]
  abort("Grafana dashboard must not require a k6 run selector")
end

panel_queries = dashboard.fetch("panels").to_h do |panel|
  [panel["title"], panel.fetch("targets", []).map { |target| target["expr"] }]
end
unless panel_queries["Database connection pool occupancy"]&.first&.include?("gorm_dbstats_in_use") &&
       panel_queries["Database connection pool occupancy"].first.include?("gorm_dbstats_max_open_connections") &&
       panel_queries["k6 request latency p95"]&.first&.include?("max by (status)") &&
       panel_queries["k6 request latency p95"].first.include?("k6_http_req_duration_p95") &&
       panel_queries["Observed application pods"]&.first&.include?("count(count by (pod)") &&
       panel_queries["Application CPU utilization vs CPU HPA target"]&.include?("vector(70)") &&
       panel_queries["Application CPU utilization vs CPU HPA target"].first.include?("/ 0.025")
  abort("Grafana dashboard must compare database pool pressure, k6 p95 latency, observed pods, and CPU with its HPA target")
end

rendered = IO.popen(["kubectl", "kustomize", "monitoring/grafana"], &:read)
abort("failed to render Grafana dashboard Kustomize resources") unless $?.success?
dashboard_config_map = YAML.load_stream(rendered).compact.fetch(0)
unless dashboard_config_map.dig("metadata", "namespace") == "monitoring" &&
       dashboard_config_map.dig("metadata", "labels", "grafana_dashboard") == "1" &&
       dashboard_config_map.dig("data", "dashboard.json") == File.read("monitoring/grafana/dashboard.json")
  abort("rendered dashboard ConfigMap does not match the Grafana sidecar contract")
end

puts "k6 ConfigMap is namespace-neutral; dashboard selectors and rendered ConfigMap are valid"
RUBY