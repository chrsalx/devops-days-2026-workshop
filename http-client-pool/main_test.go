package main

import (
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func TestHTTPClientPoolMetrics(t *testing.T) {
	registry := prometheus.NewRegistry()
	metrics := newLabMetrics(registry)
	assertMetric(t, registry, "http_client_pool_waiters", dto.MetricType_GAUGE, 0)
	assertMetric(t, registry, "http_client_pool_wait_seconds_total", dto.MetricType_COUNTER, 0)

	metrics.poolWaiters.Inc()
	metrics.poolWait.Add(0.25)
	assertMetric(t, registry, "http_client_pool_waiters", dto.MetricType_GAUGE, 1)
	assertMetric(t, registry, "http_client_pool_wait_seconds_total", dto.MetricType_COUNTER, 0.25)

	metrics.poolWaiters.Dec()
	assertMetric(t, registry, "http_client_pool_waiters", dto.MetricType_GAUGE, 0)
}

func assertMetric(t *testing.T, registry *prometheus.Registry, name string, wantType dto.MetricType, wantValue float64) {
	t.Helper()
	families, err := registry.Gather()
	if err != nil {
		t.Fatalf("gather metrics: %v", err)
	}
	for _, family := range families {
		if family.GetName() != name {
			continue
		}
		if family.GetType() != wantType {
			t.Fatalf("metric %q type = %s, want %s", name, family.GetType(), wantType)
		}
		if len(family.Metric) != 1 {
			t.Fatalf("metric %q sample count = %d, want 1", name, len(family.Metric))
		}
		var got float64
		switch wantType {
		case dto.MetricType_GAUGE:
			got = family.Metric[0].GetGauge().GetValue()
		case dto.MetricType_COUNTER:
			got = family.Metric[0].GetCounter().GetValue()
		default:
			t.Fatalf("unsupported metric type %s", wantType)
		}
		if got != wantValue {
			t.Fatalf("metric %q = %g, want %g", name, got, wantValue)
		}
		return
	}
	t.Fatalf("metric %q not registered", name)
}

func TestBoundedDuration(t *testing.T) {
	if got, err := boundedDuration("", 2*time.Second, maxUpstreamDuration); err != nil || got != 2*time.Second {
		t.Fatalf("default duration = %s, %v; want 2s, nil", got, err)
	}
	for _, input := range []string{"bad", "-1s", "6s"} {
		if _, err := boundedDuration(input, time.Second, maxUpstreamDuration); err == nil {
			t.Errorf("boundedDuration(%q) unexpectedly succeeded", input)
		}
	}
}
