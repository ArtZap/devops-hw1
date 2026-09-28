variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key_path" {
  type = string
}

variable "operator_user" {
  type = string

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.operator_user))
    error_message = "operator_user must be a valid Linux user name."
  }
}

variable "operator_public_key" {
  type = string
}

locals {
  # Exact command lines only: in sudoers a command without arguments allows any
  # arguments, so "" forbids them. "systemctl status" is left out on purpose -
  # it opens a pager as root, which is a shell escape.
  # Staging dir in the admin's home (mode 0750), not world-writable /tmp.
  stage = "/home/${var.ssh_user}/.tf-iam-${var.operator_user}"

  sudoers = <<-EOT
    # Managed by Terraform (modules/iam). Least privilege: Docker service control and reboot.
    Cmnd_Alias VM_DOCKER = /usr/bin/systemctl start docker, \
                           /usr/bin/systemctl stop docker, \
                           /usr/bin/systemctl restart docker
    Cmnd_Alias VM_POWER  = /usr/sbin/reboot ""
    ${var.operator_user} ALL=(root) NOPASSWD: VM_DOCKER, VM_POWER
  EOT
}

# Cloud IAM analogue on a single host: a dedicated role account that can manage
# the VM (Docker service, reboot) and nothing else. Password is locked, key only.
resource "terraform_data" "operator" {
  triggers_replace = {
    host    = var.host
    user    = var.operator_user
    key     = sha256(var.operator_public_key)
    sudoers = sha256(local.sudoers)
  }

  input = {
    host     = var.host
    user     = var.ssh_user
    key_path = var.ssh_private_key_path
    operator = var.operator_user
  }

  connection {
    type        = "ssh"
    host        = self.input.host
    user        = self.input.user
    private_key = file(self.input.key_path)
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 ${local.stage}"]
  }

  provisioner "file" {
    content     = local.sudoers
    destination = "${local.stage}/sudoers"
  }

  provisioner "file" {
    content     = "${var.operator_public_key}\n"
    destination = "${local.stage}/authorized_keys"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "id -u ${var.operator_user} >/dev/null 2>&1 || sudo useradd --create-home --shell /bin/bash ${var.operator_user}",
      "sudo passwd --lock ${var.operator_user} >/dev/null",
      "sudo install -d -m 0700 -o ${var.operator_user} -g ${var.operator_user} /home/${var.operator_user}/.ssh",
      "sudo install -m 0600 -o ${var.operator_user} -g ${var.operator_user} ${local.stage}/authorized_keys /home/${var.operator_user}/.ssh/authorized_keys",
      "sudo visudo -cf ${local.stage}/sudoers",
      "sudo install -m 0440 -o root -g root ${local.stage}/sudoers /etc/sudoers.d/${var.operator_user}",
      "rm -rf ${local.stage}",
      "sudo -l -U ${var.operator_user}",
    ]
  }

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "sudo rm -f /etc/sudoers.d/${self.input.operator}",
      "! id -u ${self.input.operator} >/dev/null 2>&1 || sudo userdel --remove ${self.input.operator}",
    ]
  }
}

output "operator_user" {
  value = terraform_data.operator.input.operator
}
