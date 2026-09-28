variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key_path" {
  type = string
}

variable "ssh_cidrs" {
  description = "Sources allowed to SSH."
  type        = list(string)
}

variable "public_tcp_ports" {
  type = list(number)
}

locals {
  rules = concat(
    [for c in var.ssh_cidrs : "allow proto tcp from ${c} to any port 22 comment 'ssh-admin'"],
    [for p in var.public_tcp_ports : "allow proto tcp from any to any port ${p} comment 'public'"],
  )
}

# "Security group" of the VM, enforced by ufw: default deny inbound, SSH only
# from admin_cidrs, public ports for everyone. Any rule change replaces the
# resource, which re-applies the whole rule set from scratch.
resource "terraform_data" "security_group" {
  triggers_replace = {
    host  = var.host
    rules = local.rules
  }

  # Destroy-time provisioners can only see self, so keep the connection data here.
  input = {
    host     = var.host
    user     = var.ssh_user
    key_path = var.ssh_private_key_path
  }

  connection {
    type        = "ssh"
    host        = self.input.host
    user        = self.input.user
    private_key = file(self.input.key_path)
  }

  # ufw reset leaves the firewall disabled, so the SSH session survives until
  # "enable", and by then the allow rule for our address is already in place.
  provisioner "remote-exec" {
    inline = concat(
      [
        "sudo ufw --force reset >/dev/null",
        "sudo ufw default deny incoming",
        "sudo ufw default allow outgoing",
      ],
      [for r in local.rules : "sudo ufw ${r}"],
      [
        "sudo ufw --force enable",
        "sudo ufw status verbose",
      ],
    )
  }

  provisioner "remote-exec" {
    when   = destroy
    inline = ["sudo ufw --force disable"]
  }
}

output "rules" {
  value = local.rules
}
