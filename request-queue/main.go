package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	queueCapacity = 32
	workerCount   = 2
	workDuration  = 1500 * time.Millisecond
)

type job struct {
	ctx  context.Context
	done chan struct{}
}

type labMetrics struct {
	queueDepth prometheus.Gauge
}

func newLabMetrics(registerer prometheus.Registerer) *labMetrics {
	metrics := &labMetrics{
		queueDepth: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "request_queue_depth",
			Help: "Requests waiting for a worker",
		}),
	}
	metrics.queueDepth.Set(0)
	registerer.MustRegister(metrics.queueDepth)
	return metrics
}

func main() {
	metrics := newLabMetrics(prometheus.DefaultRegisterer)
	queue := make(chan job, queueCapacity)
	for range workerCount {
		go runWorker(queue, metrics)
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/livez", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("/work", workHandler(queue, metrics))

	server := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("request-queue lab listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func workHandler(queue chan<- job, metrics *labMetrics) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "use GET", http.StatusMethodNotAllowed)
			return
		}
		current := job{ctx: r.Context(), done: make(chan struct{})}
		metrics.queueDepth.Inc()
		select {
		case queue <- current:
		default:
			metrics.queueDepth.Dec()
			http.Error(w, "request queue is full", http.StatusServiceUnavailable)
			return
		}
		select {
		case <-current.done:
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = w.Write([]byte("work completed\n"))
		case <-r.Context().Done():
			http.Error(w, "request canceled", http.StatusRequestTimeout)
		}
	})
}

func runWorker(queue <-chan job, metrics *labMetrics) {
	for current := range queue {
		metrics.queueDepth.Dec()
		if current.ctx.Err() != nil {
			close(current.done)
			continue
		}
		timer := time.NewTimer(workDuration)
		select {
		case <-timer.C:
		case <-current.ctx.Done():
			timer.Stop()
		}
		close(current.done)
	}
}
