#!/bin/bash
# Restore the execute bit that a default ACL on Docker's data-root strips from
# unpacked container layers.
#
# GitHub Codespaces puts Docker's data-root on /tmp -- a large ext4 volume, since
# / is a 32G overlay -- and that /tmp carries a POSIX default ACL of
# "other::rw-": read and write, no execute. /tmp/docker/volumes inherits it.
#
# kind mounts each node's /var as an anonymous Docker volume, so every image layer
# the node's containerd unpacks lands under that ACL with the search bit missing:
#
#   drwxr-xr--+  .../snapshots/89/fs
#
# The container's / is then not traversable by a non-root uid. Containers running
# as root are unaffected (CAP_DAC_OVERRIDE), so the cluster comes up looking half
# healthy -- etcd, kube-apiserver, kube-proxy and kindnet Running -- while every
# non-root image dies at exec:
#
#   stat /coredns: permission denied
#   /busybox/sh: can't open '/usr/local/bin/bootstrap.sh': Permission denied
#
# Drops the default ACLs so new layers unpack correctly, then puts the search bit
# back on what already exists. chmod o+X only touches directories and files that
# are already executable, so it cannot make a data file executable.
#
# Safe to run anywhere: it no-ops off Linux, without passwordless sudo, or when
# the data-root carries no offending default ACL.
#
# Usage:
#   scripts/fix-docker-acl.sh              # apply the fix
#   scripts/fix-docker-acl.sh verify NAME  # check layer modes on cluster NAME
set -uo pipefail

log() { echo "[$(date '+%H:%M:%S')] fix-docker-acl: $*"; }

SNAPSHOTS=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots

data_root() {
  docker info --format '{{.DockerRootDir}}' 2>/dev/null
}

apply_fix() {
  if [ "$(uname -s)" != "Linux" ]; then
    log "not Linux, nothing to do"
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    log "WARNING: passwordless sudo unavailable, skipping ACL check"
    return 0
  fi

  local root
  root=$(data_root)
  if [ -z "${root}" ]; then
    log "Docker is not running, nothing to do"
    return 0
  fi

  # getfacl/setfacl are not in the Codespaces base image.
  if ! command -v setfacl >/dev/null 2>&1; then
    log "installing acl..."
    sudo -n apt-get update -qq >/dev/null 2>&1
    sudo -n apt-get install -y -qq acl >/dev/null 2>&1
  fi
  if ! command -v setfacl >/dev/null 2>&1; then
    log "WARNING: setfacl unavailable, cannot clear the default ACL"
    return 0
  fi

  # A default "other" entry without x is what poisons every new layer directory.
  if ! sudo -n getfacl -p "${root}/volumes" "$(dirname "${root}")" 2>/dev/null \
       | grep -q '^default:other::r\?w\?-$'; then
    log "no non-executable default ACL on ${root}, nothing to do"
    return 0
  fi

  log "default ACL on ${root} strips o+x from unpacked layers"
  sudo -n setfacl -k "$(dirname "${root}")"
  sudo -n setfacl -R -k "${root}"
  sudo -n chmod -R o+X "${root}/volumes"
  log "default ACLs cleared and search bits restored under ${root}"
}

# verify_cluster counts layer roots that a non-root container could not traverse.
verify_cluster() {
  local cluster="$1" nodes node bad failed=0

  nodes=$(docker ps --filter "label=io.x-k8s.kind.cluster=${cluster}" --format '{{.Names}}' 2>/dev/null)
  if [ -z "${nodes}" ]; then
    log "no running nodes for cluster '${cluster}', skipping verification"
    return 0
  fi

  for node in ${nodes}; do
    bad=$(docker exec "${node}" bash -c "ls -ld ${SNAPSHOTS}/*/fs 2>/dev/null | grep -cv '^d.\{8\}x'" 2>/dev/null)
    if [ "${bad:-0}" -eq 0 ]; then
      log "${node}: layer modes OK"
    else
      log "${node}: ${bad} layer roots not traversable by non-root -- those images will fail at exec"
      failed=1
    fi
  done

  if [ "${failed}" -eq 1 ]; then
    log "run 'make fix-docker-acl' and recreate the cluster, or chmod -R o+X the"
    log "Docker data-root, before expecting non-root workloads to start"
    return 1
  fi
}

case "${1:-apply}" in
  verify) verify_cluster "${2:-abox}" ;;
  *)      apply_fix ;;
esac
