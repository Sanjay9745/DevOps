#!/usr/bin/env bash
# Install Docker, Kind, and kubectl, then create a Kind Kubernetes cluster.
# Defaults: 1 control-plane node + 2 worker nodes.
#
# Examples:
#   bash setup-kind.sh
#   WORKER_COUNT=3 bash setup-kind.sh
#   CLUSTER_NAME=testing WORKER_COUNT=4 bash setup-kind.sh
#
# Run as a regular Ubuntu user with sudo privileges (NOT with sudo bash).

set -Eeuo pipefail

# -------- Configurable variables --------
WORKER_COUNT="${WORKER_COUNT:-2}"
CLUSTER_NAME="${CLUSTER_NAME:-dev-cluster}"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
CLUSTER_WAIT="${CLUSTER_WAIT:-5m}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/kind-${CLUSTER_NAME}.yaml}"
# ----------------------------------------

log() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] || fail "Run as your normal Ubuntu user, e.g. bash setup-kind.sh (not sudo bash setup-kind.sh)."
[[ "$(uname -s)" == Linux ]] || fail "This script supports Ubuntu Linux only."
[[ -r /etc/os-release ]] || fail "Cannot detect OS: /etc/os-release missing."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail "This script is designed for Ubuntu; detected ${ID:-unknown}."
[[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || fail "WORKER_COUNT must be a non-negative integer."
(( ${#WORKER_COUNT} <= 3 )) || fail "WORKER_COUNT is unexpectedly large."
(( 10#$WORKER_COUNT <= 99 )) || fail "WORKER_COUNT must be between 0 and 99."
WORKER_COUNT="$((10#$WORKER_COUNT))"
[[ "$CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "CLUSTER_NAME must use lowercase letters, digits, or interior hyphens."
(( ${#CLUSTER_NAME} <= 40 )) || fail "CLUSTER_NAME must be at most 40 characters."

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "Unsupported CPU architecture: $(uname -m)" ;;
esac

command -v sudo >/dev/null 2>&1 || fail "sudo is required."
sudo -v

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

install_prereqs() {
  log "Installing basic packages if needed..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed: $(docker --version)"
  else
    log "Installing Docker Engine from the official Ubuntu repository..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl --fail --silent --show-error --location --retry 3 \
      https://download.docker.com/linux/ubuntu/gpg \
      --output /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    local ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$ubuntu_codename" ]] || fail "Ubuntu release codename unavailable."
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<APT_SOURCE
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
APT_SOURCE

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker
  fi
  sudo docker info >/dev/null 2>&1 || fail "Docker daemon is not responding; run: sudo systemctl status docker"
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then
    log "Kind is already installed: $(kind version)"
    return
  fi

  log "Installing Kind ${KIND_VERSION} (${ARCH})..."
  curl --fail --silent --show-error --location --retry 3 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
    --output "${TMP_DIR}/kind"
  sudo install -m 0755 "${TMP_DIR}/kind" /usr/local/bin/kind
  kind version
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl is already installed."
    kubectl version --client
    return
  fi

  log "Installing latest stable kubectl (${ARCH})..."
  local kube_version
  kube_version="$(curl --fail --silent --show-error --location --retry 3 \
    https://dl.k8s.io/release/stable.txt)"
  [[ "$kube_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid Kubernetes version received: $kube_version"

  curl --fail --silent --show-error --location --retry 3 \
    "https://dl.k8s.io/release/${kube_version}/bin/linux/${ARCH}/kubectl" \
    --output "${TMP_DIR}/kubectl"
  sudo install -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl
  kubectl version --client
}

# Run a command with the Docker group without forcing a logout/login.
# 'sg docker' keeps the current user's UID/HOME while changing the effective group.
USE_SG=0
prepare_docker_access() {
  if docker info >/dev/null 2>&1; then
    log "Docker is accessible by the current user."
    return
  fi

  log "Granting $(id -un) Docker group access..."
  if ! getent group docker >/dev/null 2>&1; then
    sudo groupadd docker
  fi
  sudo usermod -aG docker "$(id -un)"
  USE_SG=1
  warn "This terminal may need a fresh login to run Docker directly. The script will use sg docker meanwhile."
}

run_with_docker_access() {
  if (( USE_SG )); then
    local escaped_command
    printf -v escaped_command '%q ' "$@"
    sg docker -c "$escaped_command"
  else
    "$@"
  fi
}

write_cluster_config() {
  log "Writing ${CONFIG_FILE} for 1 control-plane + ${WORKER_COUNT} worker(s)..."
  mkdir -p -- "$(dirname -- "$CONFIG_FILE")"
  {
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n'
    printf '  - role: control-plane\n'
    for ((i = 0; i < WORKER_COUNT; i++)); do
      printf '  - role: worker\n'
    done
  } > "$CONFIG_FILE"
}

create_cluster() {
  local existing_clusters
  existing_clusters="$(run_with_docker_access kind get clusters)"

  if grep -Fxq -- "$CLUSTER_NAME" <<< "$existing_clusters"; then
    warn "Cluster '${CLUSTER_NAME}' already exists. Leaving it unchanged."
    warn "To change the node count, delete it first: kind delete cluster --name ${CLUSTER_NAME}"
  else
    log "Creating Kind cluster '${CLUSTER_NAME}'..."
    run_with_docker_access kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$CONFIG_FILE" \
      --wait "$CLUSTER_WAIT"
  fi

  # Refresh kubeconfig even for clusters that already exist.
  run_with_docker_access kind export kubeconfig --name "$CLUSTER_NAME"

  log "Waiting for all nodes to be Ready..."
  kubectl --context "kind-${CLUSTER_NAME}" wait \
    --for=condition=Ready nodes --all --timeout=300s

  log "Cluster nodes:"
  kubectl --context "kind-${CLUSTER_NAME}" get nodes -o wide
  log "Done: Kind cluster '${CLUSTER_NAME}' is available."
  printf '\nUseful commands:\n'
  printf '  kubectl --context kind-%s get nodes\n' "$CLUSTER_NAME"
  printf '  kubectl --context kind-%s get pods -A\n' "$CLUSTER_NAME"
  printf '  kind delete cluster --name %s\n' "$CLUSTER_NAME"
}

log "Starting Kind setup: cluster=${CLUSTER_NAME}, workers=${WORKER_COUNT}, platform=linux/${ARCH}"
install_prereqs
install_docker
install_kind
install_kubectl
prepare_docker_access
write_cluster_config
create_cluster
