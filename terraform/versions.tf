terraform {
  required_version = ">= 1.9"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # State is kept locally (terraform.tfstate, git-ignored).
  # For team work switch to a remote backend with locking, e.g. "s3".
}
