################################################################################
# Cluster Autoscaler priority expander
#
# CA olceklenirken hangi node group'a node ekleyecegini buradan secer.
# Yuksek sayi = yuksek oncelik:
#   50 -> spot grubu once denenir (ucuz)
#   10 -> spot kapasitesi yoksa ondemand'a duser (guvenli)
#
# Sonuc: buyume spot uzerinden gider, ama spot havuzu kururken servis
# durmaz - ondemand devreye girer. Taban kapasite zaten ondemand'da.
################################################################################

resource "kubernetes_config_map_v1" "autoscaler_priority" {
  metadata {
    name      = "cluster-autoscaler-priority-expander"
    namespace = "kube-system"
  }

  data = {
    # CA bu regexleri ASG adiyla eslestirir. EKS'in urettigi ad
    # "eks-hive-spot-<hash>" / "eks-hive-ondemand-<hash>" seklinde oldugu icin
    # serbest eslesme kullaniliyor - ondemand adi "spot" icermiyor, tersi de.
    priorities = <<-EOT
      50:
        - .*spot.*
      10:
        - .*ondemand.*
    EOT
  }

  depends_on = [module.eks]
}
