variable "gcp_project" {}
variable "gcp_region" { default = "us-central1" }
variable "gcp_zone" { default = "us-central1-a" }

resource "google_compute_instance" "witness" {
  name         = "swarm-witness"
  machine_type = "f1-micro"
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Ephemeral public IP
    }
  }
}

output "witness_public_ip" {
  value = google_compute_instance.witness.network_interface[0].access_config[0].nat_ip
}
