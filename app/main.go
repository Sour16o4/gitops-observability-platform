package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Define Prometheus metrics to track request rates and latencies.
// In production, these metrics form the basis of our RED (Rate, Errors, Duration) dashboards.
var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests handled by the server.",
		},
		[]string{"path", "method", "status"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Latency of HTTP requests in seconds.",
			Buckets: prometheus.DefBuckets, // Standard buckets: 0.005s, 0.01s, 0.025s, 0.05s, 0.1s, 0.25s, 0.5s, 1s, 2.5s, 5s, 10s
		},
		[]string{"path", "method"},
	)
)

func init() {
	// Register metrics with the default Prometheus registry
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
}

// loggingResponseWriter intercepts the status code for Prometheus metric tracking
type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.statusCode = code
	lrw.ResponseWriter.WriteHeader(code)
}

// prometheusMiddleware wraps handler functions to automatically track request rate and latency
func prometheusMiddleware(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		
		lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		
		next(lrw, r)
		
		duration := time.Since(start).Seconds()
		statusStr := fmt.Sprintf("%d", lrw.statusCode)
		
		// Record RED metrics
		httpRequestsTotal.WithLabelValues(path, r.Method, statusStr).Inc()
		httpRequestDuration.WithLabelValues(path, r.Method).Observe(duration)
	}
}

func main() {
	// Determine port from environment or default to 8080
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Retrieve pod hostname (will be returned in GET / response)
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	mux := http.NewServeMux()

	// Endpoints setup
	mux.HandleFunc("/", prometheusMiddleware("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "OK - Hostname: %s\n", hostname)
	}))

	mux.HandleFunc("/health", prometheusMiddleware("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	}))

	// Expose standard Prometheus metrics (/metrics is scraped by Prometheus)
	// We don't wrap this endpoint in our middleware to avoid scraping telemetry itself polluting application logs
	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Channel to listen for operating system interrupts
	shutdownChan := make(chan os.Signal, 1)
	signal.Notify(shutdownChan, os.Interrupt, syscall.SIGTERM, syscall.SIGINT)

	// Start server in a background goroutine
	go func() {
		log.Printf("Starting HTTP server on port %s (hostname: %s)...", port, hostname)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server startup failed: %s", err)
		}
	}()

	// Block until a signal is received
	sig := <-shutdownChan
	log.Printf("Received signal %s, initiating graceful shutdown...", sig)

	// Context for graceful shutdown period (15 seconds)
	// Gives running HTTP requests time to complete before terminating the container
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Graceful shutdown failed: %s", err)
	}

	log.Println("Server exited cleanly. Goodbye!")
}
