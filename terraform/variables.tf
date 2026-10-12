variable "vm_ip" {
  description = "Public IP of the VM whose Docker daemon Terraform manages."
  type        = string

  validation {
    condition     = can(cidrhost("${var.vm_ip}/32", 0))
    error_message = "vm_ip must be a valid IPv4 address."
  }
}

variable "ssh_user" {
  description = "SSH user for the Docker connection; must be in the docker group (Ansible: deployer)."
  type        = string
  default     = "deployer"
}

variable "ssh_private_key_path" {
  description = "Private key for ssh_user."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "nginx_image" {
  description = "nginx image, pinned to a tag for reproducible runs."
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "external_port" {
  description = "Host port for HTTP. Must not be 80: that one belongs to the compose proxy."
  type        = number
  default     = 8080

  validation {
    condition     = var.external_port >= 1024 && var.external_port <= 65535 && var.external_port != 8081
    error_message = "external_port must be a non-privileged port (1024-65535), and 8081 is taken on the VM."
  }
}

variable "network_name" {
  description = "Dedicated Docker network for the Terraform-managed nginx."
  type        = string
  default     = "tf_web_net"
}

variable "network_subnet" {
  description = "Subnet of the dedicated network."
  type        = string
  default     = "10.30.0.0/24"

  validation {
    condition     = can(cidrhost(var.network_subnet, 0))
    error_message = "network_subnet must be a valid IPv4 CIDR."
  }
}

variable "reserved_cidrs" {
  description = "Networks the new subnet must not overlap: the VM LAN and the compose app_net."
  type        = list(string)
  default     = ["10.10.10.0/24", "10.20.1.0/24"]
}
