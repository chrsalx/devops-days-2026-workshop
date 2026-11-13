package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	ginprom "github.com/logocomune/gin-prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	gormprom "gorm.io/plugin/prometheus"
)

const (
	maxConnectionHold  = 5 * time.Second
	maxPoolConnections = 4
)

func main() {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		databaseURL = "postgres://workshop:workshop@postgres:5432/workshop?sslmode=disable"
	}

	pool, err := openDatabase(databaseURL)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer pool.Close()

	server := &http.Server{
		Addr:              ":8080",
		Handler:           newRouter(pool),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("database-connections lab listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func openDatabase(databaseURL string) (*sql.DB, error) {
	database, err := gorm.Open(postgres.Open(databaseURL), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		return nil, err
	}

	pool, err := database.DB()
	if err != nil {
		return nil, err
	}
	pool.SetMaxOpenConns(maxPoolConnections)
	if err := database.Use(gormprom.New(gormprom.Config{DBName: "workshop", RefreshInterval: 1})); err != nil {
		_ = pool.Close()
		return nil, err
	}
	return pool, nil
}

func newRouter(pool *sql.DB) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.HandleMethodNotAllowed = true
	router.Use(gin.Recovery(), ginprom.Middleware())
	router.GET("/metrics", gin.WrapH(promhttp.Handler()))
	router.GET("/livez", func(c *gin.Context) {
		c.String(http.StatusOK, "ok\n")
	})
	router.GET("/healthz", func(c *gin.Context) {
		c.String(http.StatusOK, "ok\n")
	})
	router.GET("/work", func(c *gin.Context) {
		duration, err := requestedDuration(c.Query("duration"), 2*time.Second, maxConnectionHold)
		if err != nil {
			c.String(http.StatusBadRequest, "%s\n", err)
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
		defer cancel()
		connection, err := pool.Conn(ctx)
		if err != nil {
			c.String(http.StatusServiceUnavailable, "could not acquire database connection\n")
			return
		}
		defer connection.Close()

		if _, err := connection.ExecContext(ctx, "SELECT pg_sleep($1)", duration.Seconds()); err != nil {
			if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
				log.Printf("hold database connection: %v", err)
			}
			c.String(http.StatusServiceUnavailable, "database work interrupted\n")
			return
		}
		c.String(http.StatusOK, "held one database connection for %s\n", duration)
	})
	return router
}

func requestedDuration(raw string, fallback, maximum time.Duration) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(raw)
	if err != nil || duration < 0 || duration > maximum {
		return 0, fmt.Errorf("duration must be between 0 and %s", maximum)
	}
	return duration, nil
}
