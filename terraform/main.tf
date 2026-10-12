locals {
  name = "tf-nginx"

  # Two CIDRs overlap iff their network addresses match when both are cut to the shorter prefix.
  net_prefix = tonumber(split("/", var.network_subnet)[1])
  overlapping = [
    for c in var.reserved_cidrs : c
    if cidrhost("${cidrhost(var.network_subnet, 0)}/${min(local.net_prefix, tonumber(split("/", c)[1]))}", 0) ==
    cidrhost("${cidrhost(c, 0)}/${min(local.net_prefix, tonumber(split("/", c)[1]))}", 0)
  ]
}

# A new user-defined bridge network, separate from the compose project's app_net:
# containers in different bridge networks cannot reach each other.
resource "docker_network" "web" {
  name   = var.network_name
  driver = "bridge"

  ipam_config {
    subnet  = var.network_subnet
    gateway = cidrhost(var.network_subnet, 1)
  }

  lifecycle {
    precondition {
      condition     = length(local.overlapping) == 0
      error_message = "network_subnet ${var.network_subnet} overlaps ${join(", ", local.overlapping)}."
    }
  }
}

# Named volume with the site content. It lives independently of the container:
# replacing the container keeps the data, "terraform destroy" removes it.
resource "docker_volume" "web_content" {
  name = "tf_web_content"
}

resource "docker_image" "nginx" {
  name = var.nginx_image
  # The same image is used by the compose project; do not delete it on destroy.
  keep_locally = true
}

resource "docker_container" "nginx" {
  name    = local.name
  image   = docker_image.nginx.image_id
  restart = "unless-stopped"

  # Wait for the healthcheck: apply fails if nginx does not come up.
  wait         = true
  wait_timeout = 60

  # Only the new network; no attachment to the default bridge.
  network_mode = "bridge"
  networks_advanced {
    name         = docker_network.web.id
    ipv4_address = cidrhost(var.network_subnet, 10)
  }

  # Non-standard host port -> nginx :80 inside the container.
  ports {
    internal = 80
    external = var.external_port
  }

  volumes {
    volume_name    = docker_volume.web_content.name
    container_path = "/usr/share/nginx/html"
  }

  # Written into the container (and through the mount, into the volume) before start.
  upload {
    file = "/usr/share/nginx/html/index.html"
    content = templatefile("${path.module}/site/index.html.tftpl", {
      network = var.network_name
      subnet  = var.network_subnet
      volume  = docker_volume.web_content.name
      port    = var.external_port
    })
  }

  upload {
    file    = "/etc/nginx/conf.d/default.conf"
    content = file("${path.module}/site/nginx.conf")
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://127.0.0.1/healthz"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }

  # MiB. Docker defaults swap to 2x memory and the plan would see drift; equal values = no swap.
  memory      = 128
  memory_swap = 128

  labels {
    label = "managed-by"
    value = "terraform"
  }
}
