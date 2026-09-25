package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
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

// istek govdesi siniri - Movement JSON'u birkac yuz byte, 64KB fazlasiyla yeter
const maxBodyBytes = 64 << 10

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

// sifre gibi degerler icin: varsayilan yok, eksikse uygulama acilmaz
func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("%s is required", key)
	}
	return v
}

func getEnvDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, v, err)
	}
	return d
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// hata detayi log'a, istemciye jenerik mesaj - sema/tablo isimleri disari sizmasin
func serverError(w http.ResponseWriter, where string, err error) {
	log.Printf("%s: %v", where, err)
	http.Error(w, "internal error", 500)
}

// ORDER BY parametre alamaz, bu yuzden sadece bu listedeki ifadeler kullanilabilir
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
	return products, rows.Err()
}

// bos bir veritabaninda tablolari ve ornek veriyi olusturur. Sadece HIVE_BOOTSTRAP_DB=true
// iken calisir: goc sirasinda yeni uygulama bos RDS'e baglanirsa ornek urunleri
// id 1..18 ile yazip tasinan veriyle cakismasin.
func bootstrapDB() {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name TEXT, warehouse TEXT, quantity INTEGER, updated_at TIMESTAMP DEFAULT NOW());
		CREATE TABLE IF NOT EXISTS movements (id SERIAL PRIMARY KEY, product_id INTEGER REFERENCES products(id), delta INTEGER, note TEXT, created_at TIMESTAMP DEFAULT NOW());
		CREATE TABLE IF NOT EXISTS daily_reports (id SERIAL PRIMARY KEY, generated_at TIMESTAMP DEFAULT NOW(), total_products INTEGER, total_quantity INTEGER);
	`)
	if err != nil {
		log.Fatal(err)
	}

	var count int
	if err = db.QueryRow("SELECT COUNT(*) FROM products").Scan(&count); err != nil {
		log.Fatal(err)
	}
	if count == 0 {
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
			_, err = db.Exec("INSERT INTO products (name, warehouse, quantity, updated_at) VALUES ($1, $2, $3, NOW())", s.name, s.wh, s.qty)
			if err != nil {
				log.Fatal(err)
			}
		}
	}
}

func main() {
	dbHost := getEnv("DB_HOST", "localhost")
	dbPort := getEnv("DB_PORT", "5432")
	dbUser := getEnv("DB_USER", "hive")
	dbPass := mustEnv("DB_PASSWORD")
	dbName := getEnv("DB_NAME", "hive")
	dbSSLMode := getEnv("DB_SSLMODE", "disable") // RDS icin "require"
	port := getEnv("PORT", "8080")
	connectTimeout := getEnvDuration("DB_CONNECT_TIMEOUT", 2*time.Minute)
	// SIGTERM sonrasi yeni istek kabul etmeye devam edilen sure: load balancer'in pod'u
	// hedeflerden cikarmasina zaman tanir, boylece rolling update'te istek dusmez
	shutdownDelay := getEnvDuration("SHUTDOWN_DELAY", 10*time.Second)

	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=%s connect_timeout=5",
		dbHost, dbPort, dbUser, dbPass, dbName, dbSSLMode)
	var err error
	db, err = sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}
	// Postgres max_connections=100; birden fazla replica ayni DB'yi paylasacak
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(1 * time.Minute)

	// db gec acilabilir; sabit 5 deneme yerine DB_CONNECT_TIMEOUT boyunca dene
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

	if getEnv("HIVE_BOOTSTRAP_DB", "false") == "true" {
		bootstrapDB()
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.PingContext(r.Context()); err != nil {
			log.Println("health check failed:", err)
			writeJSON(w, 500, map[string]string{"status": "error"})
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("/api/stock", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
			var m Movement
			err := json.NewDecoder(r.Body).Decode(&m)
			if err != nil {
				http.Error(w, "invalid body", 400)
				return
			}
			tx, err := db.Begin()
			if err != nil {
				serverError(w, "begin tx", err)
				return
			}
			res, err := tx.Exec("UPDATE products SET quantity = quantity + $1, updated_at = NOW() WHERE id = $2", m.Delta, m.ProductID)
			if err != nil {
				tx.Rollback()
				serverError(w, "update product", err)
				return
			}
			n, _ := res.RowsAffected()
			if n == 0 {
				tx.Rollback()
				http.Error(w, "product not found", 404)
				return
			}
			err = tx.QueryRow("INSERT INTO movements (product_id, delta, note, created_at) VALUES ($1, $2, $3, NOW()) RETURNING id, created_at",
				m.ProductID, m.Delta, m.Note).Scan(&m.ID, &m.CreatedAt)
			if err != nil {
				tx.Rollback()
				serverError(w, "insert movement", err)
				return
			}
			err = tx.Commit()
			if err != nil {
				serverError(w, "commit", err)
				return
			}
			log.Printf("movement %d: product=%d delta=%d note=%s\n", m.ID, m.ProductID, m.Delta, m.Note)
			writeJSON(w, 201, m)
			return
		}

		products, err := getProducts("id")
		if err != nil {
			serverError(w, "list products", err)
			return
		}
		writeJSON(w, 200, products)
	})

	// mobil uygulama bu endpoint'i kullaniyor, degistirme!
	mux.HandleFunc("/api/stock/", func(w http.ResponseWriter, r *http.Request) {
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
			serverError(w, "get product", err)
			return
		}
		writeJSON(w, 200, p)
	})

	mux.HandleFunc("/api/movements", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, product_id, delta, COALESCE(note, ''), created_at FROM movements ORDER BY id DESC LIMIT 100")
		if err != nil {
			serverError(w, "list movements", err)
			return
		}
		defer rows.Close()
		movements := []Movement{}
		for rows.Next() {
			var m Movement
			err = rows.Scan(&m.ID, &m.ProductID, &m.Delta, &m.Note, &m.CreatedAt)
			if err != nil {
				serverError(w, "scan movement", err)
				return
			}
			movements = append(movements, m)
		}
		writeJSON(w, 200, movements)
	})

	mux.HandleFunc("/api/reports", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, generated_at, total_products, total_quantity FROM daily_reports ORDER BY generated_at DESC LIMIT 50")
		if err != nil {
			serverError(w, "list reports", err)
			return
		}
		defer rows.Close()
		reports := []Report{}
		for rows.Next() {
			var rp Report
			err = rows.Scan(&rp.ID, &rp.GeneratedAt, &rp.TotalProducts, &rp.TotalQuantity)
			if err != nil {
				serverError(w, "scan report", err)
				return
			}
			reports = append(reports, rp)
		}
		writeJSON(w, 200, reports)
	})

	tmpl := template.Must(template.New("index").Parse(indexHTML))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		products, err := getProducts("warehouse")
		if err != nil {
			serverError(w, "list products", err)
			return
		}
		if err := tmpl.Execute(w, products); err != nil {
			log.Println("render index:", err)
		}
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 16,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Println("HIVE listening on :" + port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutdown signal received, serving for %s more before draining", shutdownDelay)
	time.Sleep(shutdownDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Println("graceful shutdown failed:", err)
	}
	db.Close()
	log.Println("HIVE stopped")
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
