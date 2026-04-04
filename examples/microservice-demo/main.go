package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	version = "dev"

	requestCounter = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests",
		},
		[]string{"path", "method", "status"},
	)
	requestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"path", "method"},
	)
)

func init() {
	prometheus.MustRegister(requestCounter, requestDuration)
}

// logJSON writes a structured JSON log line to stdout.
func logJSON(level, msg string, fields map[string]string) {
	entry := map[string]string{
		"timestamp": time.Now().UTC().Format(time.RFC3339),
		"level":     level,
		"msg":       msg,
	}
	for k, v := range fields {
		entry[k] = v
	}
	_ = json.NewEncoder(os.Stdout).Encode(entry)
}

// instrumentedHandler wraps an HTTP handler with metrics and logging.
func instrumentedHandler(pattern string, handler http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		handler(w, r)
		duration := time.Since(start).Seconds()
		status := "200"
		requestCounter.WithLabelValues(pattern, r.Method, status).Inc()
		requestDuration.WithLabelValues(pattern, r.Method).Observe(duration)
		logJSON("info", "request", map[string]string{
			"method":   r.Method,
			"path":     r.URL.Path,
			"remote":   r.RemoteAddr,
			"duration": fmt.Sprintf("%.4f", duration),
		})
	}
}

var ready bool

func healthzHandler(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func readyzHandler(w http.ResponseWriter, _ *http.Request) {
	if !ready {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("not ready"))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ready"))
}

func indexHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html>
<head><title>Platform Demo</title></head>
<body>
  <h1>Platform Demo</h1>
  <p>Version: %s</p>
  <ul>
    <li><a href="/healthz">Liveness probe</a></li>
    <li><a href="/readyz">Readiness probe</a></li>
    <li><a href="/metrics">Prometheus metrics</a></li>
    <li><a href="/files/">File browser</a></li>
  </ul>
</body>
</html>`, version)
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	dataDir := os.Getenv("DATA_DIR")
	if dataDir == "" {
		dataDir = "/data"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)
	mux.HandleFunc("/readyz", readyzHandler)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/", instrumentedHandler("/", indexHandler))
	mux.Handle("/files/", instrumentedHandler("/files/",
		http.StripPrefix("/files/", http.FileServer(http.Dir(dataDir))).ServeHTTP))

	// Simulate startup delay then mark ready
	go func() {
		time.Sleep(2 * time.Second)
		ready = true
		logJSON("info", "server ready", map[string]string{"port": port, "version": version})
	}()

	logJSON("info", "server starting", map[string]string{"port": port, "version": version})
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		logJSON("error", "server failed", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
