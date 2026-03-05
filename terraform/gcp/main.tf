# ──────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────

variable "gcp_project" {
  description = "GCP project ID (injected from Infisical)"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for the subnet and resources"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone for the compute instance"
  type        = string
  default     = "us-central1-a"
}

variable "ssh_enabled" {
  description = "Whether SSH ingress should be managed for the witness instance"
  type        = bool
  default     = true
}

variable "ssh_allowed_cidrs" {
  description = "List of IPv6 CIDR blocks allowed to SSH into the witness instance"
  type        = list(string)

  validation {
    condition = (
      alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0)) && strcontains(cidr, ":")]) &&
      (!var.ssh_enabled || length(var.ssh_allowed_cidrs) > 0)
    )
    error_message = "ssh_allowed_cidrs must contain valid IPv6 CIDRs and must be non-empty when ssh_enabled=true."
  }
}

locals {
  common_labels = {
    project    = "goodoldme"
    managed_by = "terraform"
  }
}

# ──────────────────────────────────────────────────
# Networking — VPC, Subnet, Firewall
# ──────────────────────────────────────────────────

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

# Allow ICMPv4 from all IPv4 sources
resource "google_compute_firewall" "allow_icmp" {
  name    = "allow-icmp"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

# Allow ICMPv6 from all IPv6 sources
resource "google_compute_firewall" "allow_icmpv6" {
  name    = "allow-icmpv6"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "58" # ICMPv6
  }

  source_ranges = ["::/0"]
}

# Allow SSH for initial Ansible connectivity
resource "google_compute_firewall" "allow_ssh" {
  count   = var.ssh_enabled ? 1 : 0
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_allowed_cidrs
  target_tags   = ["ssh-access"]
}

# ──────────────────────────────────────────────────
# Compute — Swarm Witness (e2-micro)
# ──────────────────────────────────────────────────

resource "google_compute_instance" "witness" {
  name         = "swarm-witness"
  machine_type = "e2-micro"
  zone         = var.gcp_zone
  labels       = local.common_labels
  tags         = ["ssh-access"]

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

# ──────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────

output "witness_ipv6" {
  description = "External IPv6 address of the Swarm witness instance"
  value       = google_compute_instance.witness.network_interface[0].ipv6_access_config[0].external_ipv6
}
