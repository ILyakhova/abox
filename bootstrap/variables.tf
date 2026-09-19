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

variable "releases_artifact" {
  description = "OCI repository holding the releases artifact, under var.oci_registry"
  type        = string
  # main publishes to "releases". Every v* tag cut from a feature branch would
  # land in that same stream -- the RSIP filter is ^\d+\.\d+\.\d+$ with
  # limit 1, so the newest tag from any branch would win and a cluster
  # bootstrapped from main would get this branch's bundle. feat/xray-memory
  # therefore has its own repository, matching the name
  # .github/workflows/flux-push.yaml derives from the branch.
  #
  # It is empty until the first v* tag is cut FROM THIS BRANCH -- the RSIP has
  # nothing to resolve before that, and the branch must be pushed first or
  # `git branch -r --contains` in the workflow cannot map the tag back to it.
  # The migration-exercise tags (0.9.5 llama.cpp, 0.9.4 llm-d) stay behind in
  # releases-llmd-embeddings.
  default = "releases-xray-memory"
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
