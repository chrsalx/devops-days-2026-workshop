package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestOpenFilesAndCleanup(t *testing.T) {
	slots := make(chan struct{}, maxOpenFilesPerProcess)
	files, cleanup, err := openFiles(context.Background(), 3, slots)
	if err != nil {
		t.Fatalf("openFiles() error = %v", err)
	}
	if len(files) != 3 || len(slots) != 3 {
		t.Fatalf("opened files = %d, reserved slots = %d, want 3 each", len(files), len(slots))
	}

	cleanup()
	if len(slots) != 0 {
		t.Fatalf("reserved slots after cleanup = %d, want 0", len(slots))
	}
}

func TestOpenFilesStopsWhenCanceledAndSlotsAreFull(t *testing.T) {
	slots := make(chan struct{}, maxOpenFilesPerProcess)
	for range maxOpenFilesPerProcess {
		slots <- struct{}{}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, _, err := openFiles(ctx, 1, slots)
	if err != context.Canceled {
		t.Fatalf("openFiles() error = %v, want context.Canceled", err)
	}
	if len(slots) != maxOpenFilesPerProcess {
		t.Fatalf("reserved slots after canceled acquisition = %d, want %d", len(slots), maxOpenFilesPerProcess)
	}
}

func TestFrameworkMetricsEndpoint(t *testing.T) {
	router := newRouter()
	response := httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/livez", nil))

	response = httptest.NewRecorder()
	router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := response.Body.String()
	if response.Code != http.StatusOK || !strings.Contains(body, "go_goroutines") || !strings.Contains(body, "http_requests_total") {
		t.Fatalf("GET /metrics did not expose Go and Gin collectors: status=%d body=%s", response.Code, body)
	}
	if runtime.GOOS == "linux" && !strings.Contains(body, "process_open_fds") {
		t.Fatalf("GET /metrics did not expose Linux descriptor metrics: %s", body)
	}
}

func TestBoundedInputs(t *testing.T) {
	if got, err := boundedInteger("", 4, 1, maxOpenFilesPerRequest); err != nil || got != 4 {
		t.Fatalf("boundedInteger default = %d, %v; want 4, nil", got, err)
	}
	for _, input := range []string{"0", "9", "nope"} {
		if _, err := boundedInteger(input, 4, 1, maxOpenFilesPerRequest); err == nil {
			t.Errorf("boundedInteger(%q) unexpectedly succeeded", input)
		}
	}
	if got, err := boundedDuration("3s", time.Second, maxHoldDuration); err != nil || got != 3*time.Second {
		t.Fatalf("boundedDuration = %s, %v; want 3s, nil", got, err)
	}
	for _, input := range []string{"-1s", "6s", "bad"} {
		if _, err := boundedDuration(input, time.Second, maxHoldDuration); err == nil {
			t.Errorf("boundedDuration(%q) unexpectedly succeeded", input)
		}
	}
}
