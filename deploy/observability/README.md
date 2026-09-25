# İzleme ve alarmlar (GitOps)

## Son durum — 2026-09-25

| Bileşen | Ne | Durum |
|---|---|---|
| `kube-prometheus-stack` 91.5.2 (ArgoCD, Helm) | Prometheus (24 saat, disk yok), Alertmanager, Grafana, kube-state-metrics. node-exporter kapalı | Planlandı |
| `hive-monitoring` (ArgoCD, bu klasör) | `PodMonitor` (HIVE `:9090/metrics`), 12 alarm kuralı, Grafana dashboard'u | Planlandı |
| Uygulama metrikleri | RED + iş metrikleri (stok, eksi stok, yazma trafiği, rapor yaşı) | Kod main'de (#8); yeni imaj ECR'a push edilip `newTag` güncellenince dolar, o zamana kadar bu alarmlar "no data" |

**Dokunmadığı:** HIVE pod'ları, Ingress, veritabanı. Yığın `monitoring` namespace'inde; HIVE'dan sadece metrik okur.

## Alarmlar

| Alarm | Koşul | Önem |
|---|---|---|
| `HiveDown` | 2 dk metrik veren HIVE pod'u yok | critical |
| `HiveHighErrorRate` | 5xx > %1 (5 dk), 2 dk | critical |
| `HiveSlowResponses` | p95 > 500 ms, 5 dk | warning |
| `HiveDbPoolSaturated` / `HiveDbWaiting` | havuz > %80 / bağlantı bekleme | warning |
| `HiveNegativeStock` | stoku eksi ürün > 0, 1 dk | critical |
| `HiveCriticalMedicineLow` | İnsülin/Adrenalin/Heparin/Morfin < 20 | warning |
| `HiveNoStockWrites` | 10 dk hiç hareket yazılmadı | critical |
| `HiveReportStale` / `HiveReportJobFailed` | rapor 20 dk yok / rapor job'u başarısız | warning |
| `HiveBusinessMetricsDown` | iş metrikleri DB'den okunamıyor | warning |
| `HiveControlledSubstanceLargeMovement` | kontrollü maddede ≥ 50'lik hareket | info |

Bildirim kanalı (Slack/e-posta) henüz yok: alarmlar Alertmanager ve Grafana'da görünür. Sonraki adım:
Alertmanager'a bir Slack webhook'u (secret olarak).

## Kurulum

Elle bir şey çalıştırılmaz (app-of-apps). `deploy/k8s/kustomization.yaml` bu klasörü (`../observability`)
dahil ediyor; main'e girdiğinde mevcut **`hive`** ArgoCD uygulaması iki alt Application'ı
(`kube-prometheus-stack`, `hive-monitoring`) `argocd` namespace'inde oluşturur, onlar da yığını kurar.
İlk senkron 3–5 dk; cluster-autoscaler gerekirse bir node ekler.

## Doğrulama (salt okunur)

```bash
kubectl -n argocd get applications.argoproj.io kube-prometheus-stack hive-monitoring
kubectl -n monitoring get pods
kubectl -n hive get podmonitor,prometheusrule
```

Beklenen: iki uygulama `Synced` / `Healthy`; `monitoring`'de `kps-operator`, `prometheus-kps-prometheus-0`,
`alertmanager-kps-alertmanager-0`, `kps-grafana`, `kps-kube-state-metrics` `Running`.

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090
# tarayici: http://localhost:9090/targets  -> podMonitor/hive/hive  UP
#           http://localhost:9090/alerts   -> hive.service, hive.data grupları

kubectl -n monitoring port-forward svc/kps-grafana 3000:80
kubectl -n monitoring get secret kps-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
# tarayici: http://localhost:3000  (admin / yukaridaki sifre) -> "HIVE — Stok ve Servis"
```

## Geri alma

`deploy/k8s/kustomization.yaml`'dan `- ../observability` satırını kaldıran bir commit. `hive` uygulaması iki
alt Application'ı, onlar da kendi kaynaklarını siler (`prune`). HIVE'ı etkilemez. Operator CRD'leri cluster'da kalır; zararsız.
