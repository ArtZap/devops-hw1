terraform {
  required_version = ">= 1.9"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
  }

  # State is kept locally (terraform.tfstate, git-ignored).
  # For team work switch to a remote backend with locking, e.g. "s3".
}

# The provider talks to the VM's Docker daemon over SSH ("docker system
# dial-stdio" on the remote side), so the daemon socket is never exposed on TCP.
# deployer is created by Ansible and is in the docker group: run Ansible first.
provider "docker" {
  host     = "ssh://${var.ssh_user}@${var.vm_ip}:22"
  ssh_opts = ["-i", pathexpand(var.ssh_private_key_path), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new"]
}
