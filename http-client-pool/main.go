package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	maxConnectionsPerPod = 2
	maxRequestsInFlight  = 66
	maxUpstreamDuration  = 5 * time.Second
)

type labMetrics struct {
	poolWaiters prometheus.Gauge
	poolWait    prometheus.Counter
}

func newLabMetrics(registerer prometheus.Registerer) *labMetrics {
	metrics := &labMetrics{
		poolWaiters: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_client_pool_waiters",
			Help: "Requests waiting for an outbound HTTP connection slot",
		}),
		poolWait: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "http_client_pool_wait_seconds_total",
			Help: "Cumulative time spent waiting for outbound HTTP connection slots",
		}),
	}
	metrics.poolWaiters.Set(0)
	registerer.MustRegister(metrics.poolWaiters, metrics.poolWait)
	return metrics
}

func main() {
	upstreamURL := os.Getenv("UPSTREAM_URL")
	if upstreamURL == "" {
		upstreamURL = "http://upstream:8081/slow"
	}
	parsedUpstream, err := url.Parse(upstreamURL)
	if err != nil || parsedUpstream.Scheme == "" || parsedUpstream.Host == "" {
		log.Fatalf("invalid UPSTREAM_URL %q", upstreamURL)
	}

	metrics := newLabMetrics(prometheus.DefaultRegisterer)
	connections := make(chan struct{}, maxConnectionsPerPod)
	admission := make(chan struct{}, maxRequestsInFlight)
	transport := &http.Transport{
		MaxConnsPerHost:     maxConnectionsPerPod,
		MaxIdleConnsPerHost: maxConnectionsPerPod,
		IdleConnTimeout:     30 * time.Second,
	}
	client := &http.Client{Transport: transport, Timeout: 7 * time.Second}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/livez", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/work", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "use GET", http.StatusMethodNotAllowed)
			return
		}
		select {
		case admission <- struct{}{}:
			defer func() { <-admission }()
		default:
			http.Error(w, "too many requests in flight", http.StatusServiceUnavailable)
			return
		}

		waitStarted := time.Now()
		metrics.poolWaiters.Inc()
		select {
		case connections <- struct{}{}:
			metrics.poolWaiters.Dec()
			metrics.poolWait.Add(time.Since(waitStarted).Seconds())
			defer func() { <-connections }()
		case <-r.Context().Done():
			metrics.poolWaiters.Dec()
			metrics.poolWait.Add(time.Since(waitStarted).Seconds())
			http.Error(w, "request canceled while waiting for a connection", http.StatusRequestTimeout)
			return
		}

		duration, err := boundedDuration(r.URL.Query().Get("duration"), 2*time.Second, maxUpstreamDuration)
		if err != nil {
			http.Error(w, "duration must be between 0 and 5s", http.StatusBadRequest)
			return
		}
		destination := *parsedUpstream
		query := destination.Query()
		query.Set("duration", duration.String())
		destination.RawQuery = query.Encode()
		request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, destination.String(), nil)
		if err != nil {
			http.Error(w, "could not create upstream request", http.StatusInternalServerError)
			return
		}
		response, err := client.Do(request)
		if err != nil {
			http.Error(w, "upstream request failed", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			http.Error(w, "upstream returned an error", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintf(w, "upstream completed after waiting %s for a connection\n", time.Since(waitStarted))
	})

	server := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("http-client-pool lab listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	transport.CloseIdleConnections()
}

func boundedDuration(raw string, fallback, maximum time.Duration) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(raw)
	if err != nil || duration < 0 || duration > maximum {
		return 0, fmt.Errorf("duration must be between 0 and %s", maximum)
	}
	return duration, nil
}
