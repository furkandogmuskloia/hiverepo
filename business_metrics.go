package main

import (
	"context"
	"database/sql"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Is metrikleri: "sistem calisiyor mu" degil "veri dogru mu".
//
// Veri incelemesinde (2026-09-25) bulunanlar: stok eksiye dusebiliyor (insulin
// -23 gosterdi, kimse fark etmedi), kontrollu maddelerde buyuk hareketler
// izlenmiyor, rapor gorevi durursa bunu gosteren bir sey yok. Veritabanina
// "stok < 0 olamaz" kisiti eklenmedi - mevcut istemcilerin yazmalari hata
// alirdi. Onun yerine gorunur kiliniyor ve alarm uretilebiliyor.

var (
	negativeStockWrites = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hive_negative_stock_writes_total",
		Help: "Stogu sifirin altina indiren (veya altinda birakan) yazmalar",
	}, []string{"product_id"})

	controlledMovements = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hive_controlled_movements_total",
		Help: "Kontrollu madde hareketleri (HIVE_CONTROLLED_PRODUCT_IDS)",
	}, []string{"product_id", "direction"})

	largeMovements = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hive_large_movements_total",
		Help: "Mutlak degeri HIVE_LARGE_DELTA'dan buyuk hareketler",
	}, []string{"product_id", "direction"})
)

type movementPolicy struct {
	controlled map[int]bool
	largeDelta int
}

func loadMovementPolicy() movementPolicy {
	p := movementPolicy{controlled: map[int]bool{}, largeDelta: 50}
	// Varsayilan: Morphine Sulfate (5), Diazepam (10) - seed verisindeki id'ler.
	for _, s := range strings.Split(getEnv("HIVE_CONTROLLED_PRODUCT_IDS", "5,10"), ",") {
		if id, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
			p.controlled[id] = true
		}
	}
	if v, err := strconv.Atoi(getEnv("HIVE_LARGE_DELTA", "50")); err == nil && v > 0 {
		p.largeDelta = v
	}
	return p
}

// observeMovement yazma basarili olduktan sonra cagrilir; istegi etkilemez.
func (p movementPolicy) observeMovement(traceID string, m Movement, newQty int) {
	pid := strconv.Itoa(m.ProductID)
	dir := "in"
	if m.Delta < 0 {
		dir = "out"
	}
	if newQty < 0 {
		negativeStockWrites.WithLabelValues(pid).Inc()
		slog.Warn("stock below zero", "trace_id", traceID, "product_id", m.ProductID,
			"quantity", newQty, "delta", m.Delta, "movement_id", m.ID)
	}
	if p.controlled[m.ProductID] {
		controlledMovements.WithLabelValues(pid, dir).Inc()
		slog.Info("controlled substance movement", "trace_id", traceID, "product_id", m.ProductID,
			"delta", m.Delta, "quantity", newQty, "movement_id", m.ID, "note", m.Note)
	}
	if m.Delta >= p.largeDelta || -m.Delta >= p.largeDelta {
		largeMovements.WithLabelValues(pid, dir).Inc()
	}
}

// businessCollector /metrics okundugunda veritabanindan anlik durumu okur.
// Tablolar kucuk (18 urun); sorgular index'li veya tek satir.
type businessCollector struct {
	db *sql.DB

	up            *prometheus.Desc
	quantity      *prometheus.Desc
	lastMovement  *prometheus.Desc
	movements5m   *prometheus.Desc
	lastReport    *prometheus.Desc
	reportAge     *prometheus.Desc
	negativeCount *prometheus.Desc
}

func newBusinessCollector(db *sql.DB) *businessCollector {
	return &businessCollector{
		db:            db,
		up:            prometheus.NewDesc("hive_business_metrics_up", "Is metrikleri okunabildi mi (1/0)", nil, nil),
		quantity:      prometheus.NewDesc("hive_product_quantity", "Urun bazinda anlik stok", []string{"product_id", "product", "warehouse"}, nil),
		negativeCount: prometheus.NewDesc("hive_products_negative_stock", "Stogu sifirin altinda olan urun sayisi", nil, nil),
		lastMovement:  prometheus.NewDesc("hive_last_movement_timestamp_seconds", "Son stok hareketinin zamani", nil, nil),
		movements5m:   prometheus.NewDesc("hive_movements_last_5m", "Son 5 dakikada yazilan hareket sayisi (yazma trafigi kesildi mi?)", nil, nil),
		lastReport:    prometheus.NewDesc("hive_last_report_timestamp_seconds", "Son daily_reports satirinin zamani", nil, nil),
		reportAge:     prometheus.NewDesc("hive_report_age_seconds", "Son rapordan bu yana gecen sure (rapor gorevi calisiyor mu?)", nil, nil),
	}
}

func (c *businessCollector) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{c.up, c.quantity, c.negativeCount, c.lastMovement, c.movements5m, c.lastReport, c.reportAge} {
		ch <- d
	}
}

func (c *businessCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	if err := c.collect(ctx, ch); err != nil {
		slog.Warn("business metrics unavailable", "error", err.Error())
		ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 0)
		return
	}
	ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 1)
}

func (c *businessCollector) collect(ctx context.Context, ch chan<- prometheus.Metric) error {
	rows, err := c.db.QueryContext(ctx, "SELECT id, COALESCE(name, ''), COALESCE(warehouse, ''), COALESCE(quantity, 0) FROM products")
	if err != nil {
		return err
	}
	defer rows.Close()
	negative := 0
	for rows.Next() {
		var id, qty int
		var name, wh string
		if err := rows.Scan(&id, &name, &wh, &qty); err != nil {
			return err
		}
		if qty < 0 {
			negative++
		}
		ch <- prometheus.MustNewConstMetric(c.quantity, prometheus.GaugeValue, float64(qty), strconv.Itoa(id), name, wh)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	ch <- prometheus.MustNewConstMetric(c.negativeCount, prometheus.GaugeValue, float64(negative))

	// Hareket tablosu buyuk (400k+); son satir id index'iyle, son 5 dk id araligiyla okunur.
	var lastMove sql.NullTime
	var recent int
	err = c.db.QueryRowContext(ctx, `
		SELECT (SELECT created_at FROM movements ORDER BY id DESC LIMIT 1),
		       (SELECT COUNT(*) FROM (SELECT created_at FROM movements ORDER BY id DESC LIMIT 5000) t
		         WHERE created_at > NOW() - INTERVAL '5 minutes')`).Scan(&lastMove, &recent)
	if err != nil {
		return err
	}
	if lastMove.Valid {
		ch <- prometheus.MustNewConstMetric(c.lastMovement, prometheus.GaugeValue, float64(lastMove.Time.Unix()))
	}
	ch <- prometheus.MustNewConstMetric(c.movements5m, prometheus.GaugeValue, float64(recent))

	var lastReport sql.NullTime
	var ageSeconds sql.NullFloat64
	err = c.db.QueryRowContext(ctx, `
		SELECT MAX(generated_at), EXTRACT(EPOCH FROM NOW() - MAX(generated_at)) FROM daily_reports`).Scan(&lastReport, &ageSeconds)
	if err != nil {
		return err
	}
	if lastReport.Valid {
		ch <- prometheus.MustNewConstMetric(c.lastReport, prometheus.GaugeValue, float64(lastReport.Time.Unix()))
		ch <- prometheus.MustNewConstMetric(c.reportAge, prometheus.GaugeValue, ageSeconds.Float64)
	}
	return nil
}
