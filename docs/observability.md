# Observability

## Son durum — 2026-09-25

| Katman | Ne var | Durum |
|---|---|---|
| Log | stdout'a tek satır JSON: `timestamp`, `level`, `service`, `trace_id`, `message` + istek alanları | Kodda; bir sonraki imajla canlıya çıkar |
| Metrik (RED) | `:9090/metrics` — istek sayısı, hata kodu, süre histogramı; DB havuzu; Go runtime | Kodda; toplayıcı henüz kurulu değil |
| İş olayı | `hive_stock_movements_total`, her hareket için `stock movement` log satırı | Kodda |
| Alarm | — | Yok. Aşağıdaki "sonraki adım" |
| Tracing | `trace_id` = ALB'nin eklediği `X-Amzn-Trace-Id` | Sadece log korelasyonu; dağıtık tracing yok |

`/metrics` ayrı portta: Service ve ALB sadece 8080'i yönlendirir, metrikler internete açılmaz.
Sağlık kontrolü istekleri (`/health`, `/healthz`) `DEBUG` seviyesinde loglanır; `LOG_LEVEL=debug` ile görünür.

## Metrikler

| Metrik | Etiketler | Ne için |
|---|---|---|
| `http_requests_total` | `method`, `route`, `code` | Rate ve hata oranı |
| `http_request_duration_seconds` | `method`, `route` | p50/p95/p99 gecikme |
| `hive_stock_movements_total` | `result` | Yazılan stok hareketi |
| `go_sql_*{db_name="hive"}` | | Açık/boştaki DB bağlantısı, bekleme süresi |

### İş metrikleri — "veri doğru mu?"

2026-09-25 veri incelemesi: sistem **insülin −23, T-Compound −99** gösteriyordu ve kimse fark etmemişti;
kontrollü maddelerde büyük hareketler izlenmiyordu. Veritabanına "stok < 0 olamaz" kısıtı **eklenmedi**
(mevcut istemcilerin yazmaları hata alırdı); bunun yerine görünür kılındı.

| Metrik | Ne için | Önerilen alarm |
|---|---|---|
| `hive_product_quantity{product_id,product,warehouse}` | Ürün bazında anlık stok | kritik ilaçlarda < eşik |
| `hive_products_negative_stock` | Stoku eksi olan ürün sayısı | > 0 (veri bütünlüğü) |
| `hive_negative_stock_writes_total{product_id}` | Stoku eksiye iten yazmalar (+ `WARN stock below zero` log) | artış > 0 |
| `hive_controlled_movements_total{product_id,direction}` | Kontrollü madde hareketleri (+ her biri için log satırı) | uyum raporu |
| `hive_large_movements_total{product_id,direction}` | \|delta\| ≥ `HIVE_LARGE_DELTA` (varsayılan 50) | olağan dışı artış |
| `hive_movements_last_5m` | Son 5 dk yazılan hareket | = 0 → yazma trafiği kesildi (göçte yeni DB'ye yazma başladı mı?) |
| `hive_report_age_seconds` | Son rapordan beri geçen süre | > 1200 → rapor görevi durdu |
| `hive_business_metrics_up` | Bu metrikler okunabildi mi | = 0 |

Ayarlar: `HIVE_CONTROLLED_PRODUCT_IDS` (varsayılan `5,10`: Morphine, Diazepam), `HIVE_LARGE_DELTA` (50).
Ürün/rapor metrikleri `/metrics` okunduğunda DB'den okunur (18 satır + iki tek satırlık sorgu, 2 sn zaman aşımı).

`route` ham path değil, sabit rota adıdır (`/api/stock/{id}`, `other`); kardinalite sınırlı kalır.

## Bakmak

```bash
kubectl -n hive logs deploy/hive --tail=20
kubectl -n hive port-forward deploy/hive 9090:9090
curl -s localhost:9090/metrics | grep -E '^http_requests_total|^hive_'
```

Örnek sorgular (Prometheus kurulunca):

```
sum(rate(http_requests_total[5m])) by (route)
sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))
```

## Sonraki adım: alarmlar

Semptoma alarm, sebebe değil. Uygulamadan bağımsız, dış sayaç olarak ALB metrikleri
(CloudWatch `AWS/ApplicationELB`) — puanlama botunun gördüğünü en doğru yansıtan kaynak:

| Alarm | Koşul | Önem |
|---|---|---|
| 5XX oranı | `HTTPCode_Target_5XX_Count` / `RequestCount` > %1, 2 dk | critical |
| Sağlıklı hedef yok | `HealthyHostCount` < 1, 1 dk | critical |
| Gecikme | `TargetResponseTime` p95 > 500 ms, 5 dk | warning |
| RDS bağlantı | `DatabaseConnections` > 80 | warning |

Her alarmın açıklamasında runbook bağlantısı olmalı ([`README.md`](../README.md) → Deploy runbook).
ALB'yi Load Balancer Controller oluşturduğu için adı Terraform'da sabit değil; alarm boyutu için
Ingress'e sabit bir `load-balancer-name` vermek ALB'yi yeniden yaratır (yeni DNS) — göç bitmeden yapılmamalı.
