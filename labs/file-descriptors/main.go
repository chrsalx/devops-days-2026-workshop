package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	ginprom "github.com/logocomune/gin-prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	maxOpenFilesPerRequest = 8
	maxOpenFilesPerProcess = 64
	maxHoldDuration        = 5 * time.Second
)

var fileAllocationMu sync.Mutex

func main() {
	server := &http.Server{Addr: ":8080", Handler: newRouter(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("file-descriptors lab listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func newRouter() *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.HandleMethodNotAllowed = true
	router.Use(gin.Recovery(), ginprom.Middleware())
	fileSlots := make(chan struct{}, maxOpenFilesPerProcess)
	router.GET("/metrics", gin.WrapH(promhttp.Handler()))
	router.GET("/livez", func(c *gin.Context) {
		c.String(http.StatusOK, "ok\n")
	})
	router.GET("/work", func(c *gin.Context) {
		count, err := boundedInteger(c.Query("count"), 4, 1, maxOpenFilesPerRequest)
		if err != nil {
			c.String(http.StatusBadRequest, "count must be between 1 and 8\n")
			return
		}
		duration, err := boundedDuration(c.Query("duration"), 2*time.Second, maxHoldDuration)
		if err != nil {
			c.String(http.StatusBadRequest, "duration must be between 0 and 5s\n")
			return
		}

		files, cleanup, err := openFiles(c.Request.Context(), count, fileSlots)
		if err != nil {
			c.String(http.StatusServiceUnavailable, "could not open requested file descriptors\n")
			return
		}
		defer cleanup()

		timer := time.NewTimer(duration)
		defer timer.Stop()
		select {
		case <-timer.C:
			c.String(http.StatusOK, "held %d file descriptors for %s\n", len(files), duration)
		case <-c.Request.Context().Done():
			c.String(http.StatusRequestTimeout, "request canceled\n")
		}
	})
	return router
}

func openFiles(ctx context.Context, count int, slots chan struct{}) ([]*os.File, func(), error) {
	fileAllocationMu.Lock()
	defer fileAllocationMu.Unlock()

	files := make([]*os.File, 0, count)
	cleanup := func() {
		for _, file := range files {
			_ = file.Close()
			<-slots
		}
	}
	for range count {
		if err := ctx.Err(); err != nil {
			cleanup()
			return nil, func() {}, err
		}
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			cleanup()
			return nil, func() {}, ctx.Err()
		}
		file, err := os.Open("/dev/null")
		if err != nil {
			<-slots
			cleanup()
			return nil, func() {}, err
		}
		files = append(files, file)
	}
	return files, cleanup, nil
}

func boundedInteger(raw string, fallback, minimum, maximum int) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < minimum || value > maximum {
		return 0, fmt.Errorf("value must be between %d and %d", minimum, maximum)
	}
	return value, nil
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
