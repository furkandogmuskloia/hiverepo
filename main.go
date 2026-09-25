package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

var db *sql.DB

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

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func getProducts(order string) ([]Product, error) {
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

func main() {
	dbHost := getEnv("DB_HOST", "localhost")
	dbPort := getEnv("DB_PORT", "5432")
	dbUser := getEnv("DB_USER", "hive")
	dbPass := getEnv("DB_PASSWORD", "umbrella2019")
	dbName := getEnv("DB_NAME", "hive")
	port := getEnv("PORT", "8080")

	connStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable", dbHost, dbPort, dbUser, dbPass, dbName)
	var err error
	db, err = sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}
	// TODO: connection pool ayarla - 2021

	// db bazen gec aciliyor, biraz bekle
	for i := 0; i < 5; i++ {
		if err = db.Ping(); err == nil {
			break
		}
		log.Println("db not ready, retrying...", err)
		time.Sleep(3 * time.Second)
	}
	if err != nil {
		log.Fatal("could not connect to db: ", err)
	}
	log.Println("connected to db at", dbHost)

	// reports tablosu - v2'de uygulama kendisi rapor uretecek
	_, err = db.Exec(`
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

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(); err != nil {
			log.Println("health check failed:", err)
			writeJSON(w, 500, map[string]string{"status": "error", "error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})

	http.HandleFunc("/api/stock", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" {
			var m Movement
			err := json.NewDecoder(r.Body).Decode(&m)
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			tx, err := db.Begin()
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			res, err := tx.Exec("UPDATE products SET quantity = quantity + $1, updated_at = NOW() WHERE id = $2", m.Delta, m.ProductID)
			if err != nil {
				tx.Rollback()
				http.Error(w, err.Error(), 500)
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
				http.Error(w, err.Error(), 500)
				return
			}
			err = tx.Commit()
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			log.Printf("movement %d: product=%d delta=%d note=%s\n", m.ID, m.ProductID, m.Delta, m.Note)
			writeJSON(w, 201, m)
			return
		}

		products, err := getProducts("id")
		if err != nil {
			http.Error(w, err.Error(), 500)
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
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, 200, p)
	})

	http.HandleFunc("/api/movements", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, product_id, delta, COALESCE(note, ''), created_at FROM movements ORDER BY id DESC LIMIT 100")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		defer rows.Close()
		movements := []Movement{}
		for rows.Next() {
			var m Movement
			err = rows.Scan(&m.ID, &m.ProductID, &m.Delta, &m.Note, &m.CreatedAt)
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			movements = append(movements, m)
		}
		writeJSON(w, 200, movements)
	})

	http.HandleFunc("/api/reports", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query("SELECT id, generated_at, total_products, total_quantity FROM daily_reports ORDER BY generated_at DESC LIMIT 50")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		defer rows.Close()
		reports := []Report{}
		for rows.Next() {
			var rp Report
			err = rows.Scan(&rp.ID, &rp.GeneratedAt, &rp.TotalProducts, &rp.TotalQuantity)
			if err != nil {
				http.Error(w, err.Error(), 500)
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
		products, err := getProducts("warehouse, name")
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		tmpl.Execute(w, products)
	})

	log.Println("HIVE listening on :" + port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
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
