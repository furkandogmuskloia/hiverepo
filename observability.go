package main

import (
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Kloia observability standardi: yapisal JSON log (timestamp, level, service,
// trace_id, message) ve her servis icin RED metrikleri (rate, errors, duration).

const serviceName = "hive"

var (
	httpRequests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP istek sayisi (rate + errors)",
	}, []string{"method", "route", "code"})

	httpDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP istek suresi (p50/p95/p99 icin)",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
	}, []string{"method", "route"})

	stockMovements = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hive_stock_movements_total",
		Help: "Yazilan stok hareketleri (is olayi)",
	}, []string{"result"})
)

// initLogging varsayilan logger'i JSON'a cevirir. slog.SetDefault'tan sonra
// mevcut log.Printf cagrilari da ayni JSON handler'dan INFO olarak gecer.
func initLogging() {
	level := slog.LevelInfo
	if strings.EqualFold(os.Getenv("LOG_LEVEL"), "debug") {
		level = slog.LevelDebug
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.TimeKey:
				a.Key = "timestamp"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	})
	slog.SetDefault(slog.New(h).With("service", serviceName))
}

// route, etiket kardinalitesi sinirli kalsin diye ham path yerine sabit rota adi dondurur.
func route(path string) string {
	switch path {
	case "/", "/health", "/healthz", "/api/stock", "/api/movements", "/api/reports":
		return path
	}
	if strings.HasPrefix(path, "/api/stock/") {
		return "/api/stock/{id}"
	}
	return "other"
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// traceID ALB'nin ekledigi X-Amzn-Trace-Id'yi kullanir; yoksa istemcinin X-Request-Id'si.
func traceID(r *http.Request) string {
	if v := r.Header.Get("X-Amzn-Trace-Id"); v != "" {
		return v
	}
	return r.Header.Get("X-Request-Id")
}

// instrument her istegi olcer ve tek satir JSON olarak loglar. Saglik kontrolleri
// (ALB + kubelet, saniyede birkac kez) DEBUG'ta kalir ki log'u bogmasin.
func instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		elapsed := time.Since(start)

		rt := route(r.URL.Path)
		httpRequests.WithLabelValues(r.Method, rt, strconv.Itoa(rec.status)).Inc()
		httpDuration.WithLabelValues(r.Method, rt).Observe(elapsed.Seconds())

		level := slog.LevelInfo
		switch {
		case rec.status >= 500:
			level = slog.LevelError
		case rt == "/health" || rt == "/healthz":
			level = slog.LevelDebug
		}
		slog.Log(r.Context(), level, "request",
			"trace_id", traceID(r),
			"method", r.Method,
			"route", rt,
			"status", rec.status,
			"duration_ms", elapsed.Milliseconds(),
			"remote", r.RemoteAddr,
		)
	})
}

// startMetricsServer /metrics'i ayri portta sunar: ALB sadece uygulama portunu
// yonlendirdigi icin metrikler internete acilmaz.
func startMetricsServer(port string) {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		httpRequests, httpDuration, stockMovements,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		collectors.NewDBStatsCollector(db, "hive"),
	)
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		slog.Info("metrics listening", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("metrics server failed", "error", err.Error())
		}
	}()
}
