output "url" {
  value = "http://${var.vm_ip}:${var.external_port}/"
}

output "curl_check" {
  value = "curl -i http://${var.vm_ip}:${var.external_port}/"
}

output "container" {
  value = docker_container.nginx.name
}

output "network" {
  value = {
    name   = docker_network.web.name
    subnet = var.network_subnet
    ip     = docker_container.nginx.network_data[0].ip_address
  }
}

output "volume" {
  value = docker_volume.web_content.name
}
