package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func TestGORMPoolMetrics(t *testing.T) {
	pool, err := openDatabase("postgres://workshop:workshop@127.0.0.1:1/workshop?sslmode=disable")
	if err != nil {
		t.Fatalf("openDatabase() error = %v", err)
	}
	defer pool.Close()

	deadline := time.Now().Add(3 * time.Second)
	var maxOpen, inUse float64
	for time.Now().Before(deadline) {
		families, err := prometheus.DefaultGatherer.Gather()
		if err != nil {
			t.Fatalf("gather metrics: %v", err)
		}
		var hasMaxOpen, hasInUse bool
		maxOpen, hasMaxOpen = gaugeValue(families, "gorm_dbstats_max_open_connections")
		inUse, hasInUse = gaugeValue(families, "gorm_dbstats_in_use")
		if hasMaxOpen && hasInUse && maxOpen == maxPoolConnections {
			if inUse != 0 {
				t.Fatalf("pool metric in use = %g, want 0", inUse)
			}
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("GORM pool metrics did not report the configured pool: max open=%g, in use=%g", maxOpen, inUse)
}

func gaugeValue(families []*dto.MetricFamily, name string) (float64, bool) {
	for _, family := range families {
		if family.GetName() != name {
			continue
		}
		for _, metric := range family.Metric {
			for _, label := range metric.Label {
				if label.GetName() == "db_name" && label.GetValue() == "workshop" {
					return metric.GetGauge().GetValue(), true
				}
			}
		}
	}
	return 0, false
}

func TestGinMetricsEndpoint(t *testing.T) {
	router := newRouter(nil)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/livez", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("GET /livez status = %d, want %d", response.Code, http.StatusOK)
	}

	response = httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "go_goroutines") {
		t.Fatalf("GET /metrics did not expose the Go collectors: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRequestedDuration(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    time.Duration
		wantErr bool
	}{
		{name: "default", input: "", want: 2 * time.Second},
		{name: "valid", input: "3s", want: 3 * time.Second},
		{name: "zero", input: "0s", want: 0},
		{name: "invalid", input: "later", wantErr: true},
		{name: "negative", input: "-1s", wantErr: true},
		{name: "over maximum", input: "6s", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := requestedDuration(test.input, 2*time.Second, maxConnectionHold)
			if (err != nil) != test.wantErr {
				t.Fatalf("requestedDuration(%q) error = %v, wantErr %v", test.input, err, test.wantErr)
			}
			if err == nil && got != test.want {
				t.Errorf("requestedDuration(%q) = %s, want %s", test.input, got, test.want)
			}
		})
	}
}
