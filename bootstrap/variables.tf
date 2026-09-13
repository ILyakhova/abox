variable "cluster_name" {
  description = "Cluster Name"
  type        = string
  default     = "abox"
}

variable "node_image" {
  description = "KinD node image. Ceiling is the kind CLI version installed by scripts/setup.sh."
  type        = string
  default     = "kindest/node:v1.37.0"
}

variable "kubeconfig_path" {
  description = "Kubeconfig written by kind and read by the helm/kubernetes/kubectl providers."
  type        = string
  default     = "~/.kube/config"
}

variable "oci_registry" {
  description = "OCI registry base URL"
  type        = string
  default     = "oci://ghcr.io/den-vasyliev/abox"
}

variable "releases_version" {
  description = "Default tag for releases OCI artifact bootstrap"
  type        = string
  default     = "0.1.0"
}

variable "flux_operator_version" {
  description = "flux-operator Helm chart version. Unset in the module defaults, which floats to latest."
  type        = string
  default     = "0.59.0"
}

variable "bootstrap_revision" {
  description = "Bump to force the flux-operator bootstrap Job to re-run without an input change"
  type        = number
  default     = 1
}
