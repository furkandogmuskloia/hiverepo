// Eski ortamın VPC'si 10.0.0.0/x aralığında (umb-app-01 = 10.0.1.136).
// Çakışmasın ve ileride peering/replikasyon mümkün olsun diye 10.20.0.0/16.
inputs = {
  region         = "eu-central-1"
  azs            = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  vpc_cidr_block = "10.20.0.0/16"
}
