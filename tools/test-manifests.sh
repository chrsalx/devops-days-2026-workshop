#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

ruby -ryaml -rjson <<'RUBY'
labs = %w[database-connections file-descriptors event-loop-lag]

labs.each do |lab|
  lab_dir = "labs/#{lab}"
  documents = ["#{lab_dir}/kubernetes.yaml", "#{lab_dir}/loadgen.yaml"].flat_map do |path|
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

  puts "#{lab}: manifests use the dedicated namespace and scoped KEDA query"
end

config_map = YAML.load_file("tools/k6/configmap.yaml")
unless config_map.dig("metadata", "name") == "k6-load-script" && config_map.dig("metadata", "namespace").nil? && config_map.dig("data", "config.js")
  abort("k6 ConfigMap must have a stable name, script data, and no fixed namespace")
end

dashboard = JSON.parse(File.read("monitoring/grafana/dashboard.json"))
cpu_query = dashboard.dig("panels", 0, "targets", 0, "expr")
memory_query = dashboard.dig("panels", 1, "targets", 0, "expr")
unless cpu_query&.include?('namespace="${lab}"') && memory_query&.include?('namespace="${lab}"')
  abort("Grafana process panels must select the lab-specific namespace")
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