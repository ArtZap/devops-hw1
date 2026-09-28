output "vm_ip" {
  value = module.host.ip
}

output "ssh_command" {
  value = "ssh ${var.ssh_user}@${module.host.ip}"
}

output "app_subnet" {
  value = module.network.app_subnet
}

output "operator_user" {
  value = module.iam.operator_user
}

output "firewall_rules" {
  value = module.firewall.rules
}
