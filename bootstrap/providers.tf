terraform {
  # >= 1.11 for write-only attributes, required by the
  # flux-operator-bootstrap module (OpenTofu >= 1.11.0).
  required_version = ">= 1.11.0"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}

# Read through terraform_data.cluster.output, not the variables directly. The
# output is known-after-apply, which defers provider configuration until the
# cluster exists; a static path configures at plan time and fails with
# "context kind-abox does not exist" on a first apply.
provider "helm" {
  kubernetes = {
    config_path    = terraform_data.cluster.output.kubeconfig
    config_context = terraform_data.cluster.output.context
  }
}

provider "kubernetes" {
  config_path    = terraform_data.cluster.output.kubeconfig
  config_context = terraform_data.cluster.output.context
}

provider "kubectl" {
  config_path      = terraform_data.cluster.output.kubeconfig
  config_context   = terraform_data.cluster.output.context
  load_config_file = true
}
