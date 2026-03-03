variable "gcp_project" {}
variable "gcp_region" { default = "us-central1" }
variable "gcp_zone" { default = "us-central1-a" }

resource "google_compute_network" "vpc_network" {
  name                    = "hybrid-swarm-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "ipv6_subnet" {
  name          = "hybrid-swarm-ipv6-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.gcp_region
  network       = google_compute_network.vpc_network.id

  stack_type       = "IPV4_IPV6"
  ipv6_access_type = "EXTERNAL"
}

resource "google_compute_firewall" "allow_icmpv6" {
  name    = "allow-icmpv6"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "58" # IPv6-ICMP
  }

  source_ranges = ["::/0"]
}

resource "google_compute_instance" "witness" {
  name         = "swarm-witness"
  machine_type = "e2-micro"
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.ipv6_subnet.id

    stack_type = "IPV4_IPV6"
    ipv6_access_config {
      network_tier = "PREMIUM"
    }
  }
}

output "witness_ipv6" {
  value = google_compute_instance.witness.network_interface[0].ipv6_access_config[0].external_ipv6
}
