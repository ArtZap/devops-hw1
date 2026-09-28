variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key_path" {
  type = string
}

# The VM itself is provided by the course (VMware, no nested virtualization),
# so this resource adopts it: it proves SSH access, a supported OS and sudo.
resource "terraform_data" "vm" {
  triggers_replace = [var.host]
  input            = var.host

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      ". /etc/os-release && echo \"OS: $PRETTY_NAME\"",
      "case \"$(. /etc/os-release; echo $ID-$VERSION_ID)\" in ubuntu-20.04|ubuntu-22.04|ubuntu-24.04) ;; *) echo 'unsupported OS' >&2; exit 1 ;; esac",
      "sudo -n true",
    ]
  }
}

output "ip" {
  value = terraform_data.vm.output
}
