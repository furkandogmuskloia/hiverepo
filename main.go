package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

var db *sql.DB

// pg_advisory_lock anahtari - sema kurulumunu replica'lar arasinda serilestirir
const bootstrapLockID = 727272

type Product struct {
	ID        int       `json:"id"`
	Name      string    `json:"name"`
	Warehouse string    `json:"warehouse"`
	Quantity  int       `json:"quantity"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Movement struct {
	ID        int       `json:"id"`
	ProductID int       `json:"product_id"`
	Delta     int       `json:"delta"`
	Note      string    `json:"note"`
	CreatedAt time.Time `json:"created_at"`
}

type Report struct {
	ID            int       `json:"id"`
	GeneratedAt   time.Time `json:"generated_at"`
	TotalProducts int       `json:"total_products"`
	TotalQuantity int       `json:"total_quantity"`
}

func getEnv(key, def string) string {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	return v
}

// hata detayi log'a, istemciye jenerik mesaj: sema/tablo isimleri disari sizmasin
func serverError(w http.ResponseWriter, err error) {
	log.Println("request failed:", err)
	http.Error(w, "internal error", 500)
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// ORDER BY parametre alamaz; sadece bu listedeki ifadeler kullanilabilir.
var productOrders = map[string]string{
	"id":        "id",
	"warehouse": "warehouse, name",
}

func getProducts(key string) ([]Product, error) {
	order, ok := productOrders[key]
	if !ok {
		order = "id"
	}
	rows, err := db.Query("SELECT id, name, warehouse, quantity, updated_at FROM products ORDER BY " + order)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	products := []Product{}
	for rows.Next() {
		var p Product
		err = rows.Scan(&p.ID, &p.Name, &p.Warehouse, &p.Quantity, &p.UpdatedAt)
		if err != nil {
			return nil, err
		}
		products = append(products, p)
	}
	return products, nil
}

// bootstrap semayi kurar ve tablo bossa ornek veriyi yazar.
// Birden fazla replica ayni anda acildigi icin advisory lock sart: lock olmadan
// her pod "count == 0" gorup seed'i tekrar yaziyor ve urunler cogalliyor.
// Lock connection-scoped oldugundan havuzdan tek bir baglanti alinip uzerinde kalinir.
func bootstrap() error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	if _, err = conn.ExecContext(ctx, "SELECT pg_advisory_lock($1)", bootstrapLockID); err != nil {
		return err
	}
	defer conn.ExecContext(context.Background(), "SELECT pg_advisory_unlock($1)", bootstrapLockID)

	_, err = conn.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name TEXT, warehouse TEXT, quantity INTEGER, updated_at TIMESTAMP DEFAULT NOW());
		CREATE TABLE IF NOT EXISTS movements (id SERIAL PRIMARY KEY, product_id INTEGER REFERENCES products(id), delta INTEGER, note TEXT, created_at TIMESTAMP DEFAULT NOW());
		CREATE TABLE IF NOT EXISTS daily_reports (id SERIAL PRIMARY KEY, generated_at TIMESTAMP DEFAULT NOW(), total_products INTEGER, total_quantity INTEGER);
	`)
	if err != nil {
		return err
	}

	var count int
	if err = conn.QueryRowContext(ctx, "SELECT COUNT(*) FROM products").Scan(&count); err != nil {
		return err
	}
	if count > 0 {
		log.Printf("schema ready, %d products already present", count)
		return nil
	}
	// Goc sirasinda yeni pod'lar bos RDS'e baglanir; ornek urunleri id 1..18 ile
	// yazarsa tasinan gercek veriyle cakisir. Seed sadece acikca istenirse.
	if getEnv("HIVE_SEED_SAMPLE_DATA", "false") != "true" {
		log.Println("products table empty, sample data disabled (HIVE_SEED_SAMPLE_DATA != true)")
		return nil
	}

	log.Println("products table empty, inserting sample data")
	seed := []struct {
		name, wh string
		qty      int
	}{
		{"Paracetamol 500mg", "Dublin-A", 1200}, {"Ibuprofen 400mg", "Dublin-A", 850},
		{"Amoxicillin 250mg", "Dublin-B", 430}, {"Insulin Glargine 100IU", "Frankfurt-1", 75},
		{"Morphine Sulfate 10mg", "Frankfurt-1", 40}, {"Sodium Chloride 0.9%", "London-C", 3000},
		{"Ethanol 96%", "London-C", 500}, {"Hydrogen Peroxide 3%", "Dublin-B", 620},
		{"Adrenaline 1mg/ml", "Frankfurt-1", 90}, {"Diazepam 5mg", "Dublin-A", 310},
		{"Formaldehyde 37%", "London-C", 120}, {"Ceftriaxone 1g", "Dublin-B", 260},
		{"Omeprazole 20mg", "Dublin-A", 980}, {"Chlorhexidine 2%", "London-C", 440},
		{"Heparin 5000IU", "Frankfurt-1", 150}, {"Lidocaine 2%", "Dublin-B", 380},
		{"Acetone", "London-C", 700}, {"T-Compound (sample)", "Frankfurt-1", 3},
	}
	for _, s := range seed {
		if _, err = conn.ExecContext(ctx,
			"INSERT INTO products (name, warehouse, quantity, updated_at) VALUES ($1, $2, $3, NOW())",
			s.name, s.wh, s.qty); err != nil {
			return err
		}
	}
	log.Printf("seeded %d products", len(seed))
	return nil
}

// authorized, HIVE_API_TOKEN set edilmisse yazma isteklerinde bearer token arar.
// Token bos birakilirsa (lokal gelistirme) kontrol devre disi kalir.
func authorized(r *http.Request) bool {
	want := os.Getenv("HIVE_API_TOKEN")
	if want == "" {
		return true
	}
	got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func main() {
	initLogging()

	dbHost := getEnv("DB_HOST", "localhost")
	dbPort := getEnv("DB_PORT", "5432")
	dbUser := getEnv("DB_USER", "hive")
	dbPass := os.Getenv("DB_PASSWORD") // varsayilan yok: sifre koda/binary'e gomulmesin
	if dbPass == "" {
		log.Fatal("DB_PASSWORD is required")
	}
	dbName := getEnv("DB_NAME", "hive")
	dbSSL := getEnv("DB_SSLMODE", "require")
	port := getEnv("PORT", "8080")

	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=%s", dbHost, dbPort, dbUser, dbPass, dbName, dbSSL)
	var err error
	db, err = sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}

	// Pod basina havuz tavani. RDS max_connections'i asmamak icin sart:
	// HPA max 10 pod x 5 baglanti = 50, db.t4g.micro limitinin (~112) altinda.
	maxOpen, _ := strconv.Atoi(getEnv("DB_MAX_OPEN_CONNS", "5"))
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxOpen)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(1 * time.Minute)

	// db gec acilabilir (RDS failover ~60-120sn); 15sn sonra olup crash-loop'a
	// girmek yerine DB_CONNECT_TIMEOUT boyunca dene.
	connectTimeout, err := time.ParseDuration(getEnv("DB_CONNECT_TIMEOUT", "2m"))
	if err != nil {
		log.Fatal("invalid DB_CONNECT_TIMEOUT: ", err)
	}
	deadline := time.Now().Add(connectTimeout)
	for {
		if err = db.Ping(); err == nil {
			break
		}
		if time.Now().After(deadline) {
			log.Fatal("could not connect to db: ", err)
		}
		log.Println("db not ready, retrying...", err)
		time.Sleep(3 * time.Second)
	}
	log.Println("connected to db at", dbHost)

	startMetricsServer(getEnv("METRICS_PORT", "9090"))
	policy := loadMovementPolicy()

	if err = bootstrap(); err != nil {
		log.Fatal("bootstrap failed: ", err)
	}

	// liveness: sadece surecin ayakta oldugunu soyler. DB'ye bakmaz - yoksa
	// gecici bir RDS kesintisi tum podlari kubelet'e oldurtur.
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "alive"})
	})

	// readiness: DB'ye bakar. Basarisiz olursa pod sadece Service'ten dusurulur.
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			log.Println("health check failed:", err)
			writeJSON(w, 500, map[string]string{"status": "error"})
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})

	http.HandleFunc("/api/stock", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			if !authorized(r) {
				log.Printf("unauthorized POST from %s", r.RemoteAddr)
				writeJSON(w, 401, map[string]string{"error": "unauthorized"})
				return
			}
			// ALB internet'e acik - govdeyi sinirla, sinirsiz okuma bellek tuketir
			r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
			var m Movement
			err := json.NewDecoder(r.Body).Decode(&m)
			if err != nil {
				http.Error(w, "invalid body", 400)
				return
			}
			tx, err := db.Begin()
			if err != nil {
				serverError(w, err)
				return
			}
			var newQty int
			err = tx.QueryRow("UPDATE products SET quantity = quantity + $1, updated_at = NOW() WHERE id = $2 RETURNING quantity",
				m.Delta, m.ProductID).Scan(&newQty)
			if err == sql.ErrNoRows {
				tx.Rollback()
				http.Error(w, "product not found", 404)
				return
			}
			if err != nil {
				tx.Rollback()
				serverError(w, err)
				return
			}
			err = tx.QueryRow("INSERT INTO movements (product_id, delta, note, created_at) VALUES ($1, $2, $3, NOW()) RETURNING id, created_at",
				m.ProductID, m.Delta, m.Note).Scan(&m.ID, &m.CreatedAt)
			if err != nil {
				tx.Rollback()
				serverError(w, err)
				return
			}
			err = tx.Commit()
			if err != nil {
				serverError(w, err)
				return
			}
			stockMovements.WithLabelValues("ok").Inc()
			policy.observeMovement(traceID(r), m, newQty)
			slog.Info("stock movement", "trace_id", traceID(r), "movement_id", m.ID,
				"product_id", m.ProductID, "delta", m.Delta, "note", m.Note)
			writeJSON(w, 201, m)
			return
		}

		products, err := getProducts("id")
		if err != nil {
			serverError(w, err)
			return
		}
		writeJSON(w, 200, products)
	})

	// mobil uygulama bu endpoint'i kullaniyor, degistirme!
	http.HandleFunc("/api/stock/", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/api/stock/"))
		if err != nil {
			http.Error(w, "invalid id", 400)
			return
		}
		var p Product
		err = db.QueryRow("SELECT id, name, warehouse, quantity, updated_at FROM products WHERE id = $1", id).
			Scan(&p.ID, &p.Name, &p.Warehouse, &p.Quantity, &p.UpdatedAt)
		if err == sql.ErrNoRows {
			http.Error(w, "product not found", 404)
			return
		}
		if err != nil {
			serverError(w, err)
			return
		}
		writeJSON(w, 200, p)
	})

	http.HandleFunc("/api/movements", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, product_id, delta, COALESCE(note, ''), created_at FROM movements ORDER BY id DESC LIMIT 100")
		if err != nil {
			serverError(w, err)
			return
		}
		defer rows.Close()
		movements := []Movement{}
		for rows.Next() {
			var m Movement
			err = rows.Scan(&m.ID, &m.ProductID, &m.Delta, &m.Note, &m.CreatedAt)
			if err != nil {
				serverError(w, err)
				return
			}
			movements = append(movements, m)
		}
		writeJSON(w, 200, movements)
	})

	http.HandleFunc("/api/reports", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, generated_at, total_products, total_quantity FROM daily_reports ORDER BY generated_at DESC LIMIT 50")
		if err != nil {
			serverError(w, err)
			return
		}
		defer rows.Close()
		reports := []Report{}
		for rows.Next() {
			var rp Report
			err = rows.Scan(&rp.ID, &rp.GeneratedAt, &rp.TotalProducts, &rp.TotalQuantity)
			if err != nil {
				serverError(w, err)
				return
			}
			reports = append(reports, rp)
		}
		writeJSON(w, 200, reports)
	})

	tmpl := template.Must(template.New("index").Parse(indexHTML))
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		products, err := getProducts("warehouse")
		if err != nil {
			serverError(w, err)
			return
		}
		tmpl.Execute(w, products)
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           instrument(http.DefaultServeMux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 16,
	}

	// Rolling update sirasinda ucan istek dusmesin: SIGTERM gelince yeni
	// baglanti almayi birak, acik olanlari 20sn icinde bitir.
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		log.Println("shutdown signal received, draining connections")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Println("graceful shutdown failed:", err)
		}
		close(idle)
	}()

	log.Println("HIVE listening on :" + port)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-idle
	log.Println("stopped")
}

// TODO: bunu ayri dosyaya tasi
const indexHTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>HIVE - Stock</title>
<style>
body { font-family: Arial, sans-serif; background: #f4f4f4; margin: 0; }
header { background: #b00; color: #fff; padding: 12px 24px; }
header h1 { margin: 0 12px 0 0; font-size: 22px; letter-spacing: 3px; display: inline; }
main { padding: 24px; }
table { border-collapse: collapse; width: 100%; background: #fff; }
th, td { padding: 8px 12px; border-bottom: 1px solid #ddd; text-align: left; }
th { background: #333; color: #fff; }
.low { color: #b00; font-weight: bold; }
</style></head>
<body>
<header><h1>HIVE</h1><small>Umbrella Corporation &middot; Warehouse Stock System</small></header>
<main><table>
<tr><th>ID</th><th>Product</th><th>Warehouse</th><th>Quantity</th><th>Last Update</th></tr>
{{range .}}<tr><td>{{.ID}}</td><td>{{.Name}}</td><td>{{.Warehouse}}</td>
<td{{if lt .Quantity 100}} class="low"{{end}}>{{.Quantity}}</td><td>{{.UpdatedAt.Format "2006-01-02 15:04"}}</td></tr>
{{end}}</table></main>
</body></html>`
