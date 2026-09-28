variable "vm_ip" {
  description = "Public IP of the target VM."
  type        = string

  validation {
    condition     = can(cidrhost("${var.vm_ip}/32", 0))
    error_message = "vm_ip must be a valid IPv4 address."
  }
}

variable "vm_private_cidr" {
  description = "LAN the VM lives in; the container network must not overlap it."
  type        = string
  default     = "10.10.10.0/24"
}

variable "ssh_user" {
  description = "Bootstrap admin account used by Terraform and Ansible."
  type        = string
  default     = "student"
}

variable "ssh_private_key_path" {
  description = "Private key for ssh_user."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_public_key_path" {
  description = "Public key installed for the service users (vm-operator, deployer)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_cidrs" {
  description = "Source networks allowed to reach SSH (security group ingress)."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must be a non-empty list of valid CIDRs."
  }

  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "Opening SSH to the whole Internet is not allowed."
  }
}

variable "public_tcp_ports" {
  description = "TCP ports open to everyone (HTTP for the app)."
  type        = list(number)
  default     = [80]
}

variable "vpc_cidr" {
  description = "Address space for the container networks on the VM."
  type        = string
  default     = "10.20.0.0/16"
}

variable "operator_user" {
  description = "Least-privilege account that may only manage Docker and reboot the VM."
  type        = string
  default     = "vm-operator"
}
