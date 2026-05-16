terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = ">= 3.0.0"
      configuration_aliases = [kubernetes]
    }
  }
}
