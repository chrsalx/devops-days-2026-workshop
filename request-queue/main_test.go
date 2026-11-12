package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func TestWorkHandlerRejectsFullQueueWithoutLeakingGauge(t *testing.T) {
	registry := prometheus.NewRegistry()
	metrics := newLabMetrics(registry)
	queue := make(chan job, 1)
	queue <- job{}
	handler := workHandler(queue, metrics)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/work", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
	if len(queue) != 1 {
		t.Fatalf("queue length = %d, want 1", len(queue))
	}
	assertMetric(t, registry, "request_queue_depth", dto.MetricType_GAUGE, 0)
}

func TestCanceledQueuedJobIsRemovedAndGaugeDecrements(t *testing.T) {
	registry := prometheus.NewRegistry()
	metrics := newLabMetrics(registry)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	current := job{ctx: ctx, done: make(chan struct{})}
	queue := make(chan job, 1)
	queue <- current
	close(queue)
	metrics.queueDepth.Inc()
	go runWorker(queue, metrics)

	select {
	case <-current.done:
	case <-time.After(time.Second):
		t.Fatal("worker did not finish canceled job")
	}
	assertMetric(t, registry, "request_queue_depth", dto.MetricType_GAUGE, 0)
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
		got := family.Metric[0].GetGauge().GetValue()
		if got != wantValue {
			t.Fatalf("metric %q = %g, want %g", name, got, wantValue)
		}
		return
	}
	t.Fatalf("metric %q not registered", name)
}
