# ==========================================
# Construct KinD cluster
# ==========================================
# Uses the kind CLI, not the tehcyx/kind provider: that provider vendors kind
# v0.31.0, which emits kubeadm.k8s.io/v1beta3 only, and Kubernetes 1.36 removed
# v1beta3. Provider config reads a kubeconfig path so it no longer derives from
# the cluster resource.

locals {
  kubeconfig_path = pathexpand(var.kubeconfig_path)
}

resource "local_file" "kind_config" {
  filename        = "${path.module}/.kind-config.yaml"
  file_permission = "0644"

  content = <<-YAML
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    networking:
      kubeProxyMode: ipvs
    nodes:
      - role: control-plane
      - role: worker
      - role: worker
  YAML
}

resource "terraform_data" "cluster" {
  # Destroy-time provisioners may only reference self.
  input = {
    name       = var.cluster_name
    kubeconfig = local.kubeconfig_path
    context    = "kind-${var.cluster_name}"
  }

  triggers_replace = [
    var.cluster_name,
    var.node_image,
    local_file.kind_config.content,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # On replacement the new create runs before the old destroy.
      if kind get clusters 2>/dev/null | grep -qxF '${var.cluster_name}'; then
        kind delete cluster --name '${var.cluster_name}'
      fi

      kind create cluster \
        --name '${var.cluster_name}' \
        --image '${var.node_image}' \
        --config '${local_file.kind_config.filename}' \
        --kubeconfig '${local.kubeconfig_path}' \
        --wait 5m
    EOT
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "kind delete cluster --name '${self.input.name}'"
  }
}
