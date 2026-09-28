variable "vpc_cidr" {
  type = string
}

variable "vm_private_cidr" {
  type = string
}

locals {
  # 10.20.0.0/16 -> 10.20.1.0/24 for the application network.
  app_subnet  = cidrsubnet(var.vpc_cidr, 8, 1)
  app_gateway = cidrhost(local.app_subnet, 1)

  # Two CIDRs overlap iff their network addresses match when both are cut to the shorter prefix.
  min_prefix = min(tonumber(split("/", var.vpc_cidr)[1]), tonumber(split("/", var.vm_private_cidr)[1]))
  overlaps = (
    cidrhost("${cidrhost(var.vpc_cidr, 0)}/${local.min_prefix}", 0) ==
    cidrhost("${cidrhost(var.vm_private_cidr, 0)}/${local.min_prefix}", 0)
  )
}

# The VM has no cloud VPC, so the "VPC" is the address plan for its container networks.
# Keeping it as a resource puts it in state and lets a plan show changes to it.
resource "terraform_data" "vpc" {
  input = {
    cidr        = var.vpc_cidr
    app_subnet  = local.app_subnet
    app_gateway = local.app_gateway
  }

  lifecycle {
    precondition {
      condition     = !local.overlaps
      error_message = "vpc_cidr ${var.vpc_cidr} overlaps the VM LAN ${var.vm_private_cidr}."
    }
  }
}

output "app_subnet" {
  value = terraform_data.vpc.output.app_subnet
}

output "app_gateway" {
  value = terraform_data.vpc.output.app_gateway
}
