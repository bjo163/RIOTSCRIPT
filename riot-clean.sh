#!/usr/bin/env bash
#
# RIOT-CLEAN — destructive Docker/container runtime cleanup
# Supported: Ubuntu and Debian (APT-based)
#
# Usage:
#   sudo bash riot-clean.sh
#   sudo bash riot-clean.sh --yes
#
# WARNING:
#   Removes Docker containers, images, networks, volumes and Docker data.
#   Data stored in Docker volumes (including databases) is permanently lost.
#
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()  { printf "%b[+]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf "%b[✗]%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

YES=false
[[ "${1:-}" == "--yes" ]] && YES=true
[[ $# -le 1 ]] || die "Usage: sudo bash $0 [--yes]"
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "Ubuntu/Debian only. Detected: ${PRETTY_NAME:-unknown}";; esac
command -v apt-get >/dev/null 2>&1 || die "APT is required."

printf "\n%b  RIOT-CLEAN v%s%b\n" "$CYAN" "$VERSION" "$RESET"
printf "  Host: %s | OS: %s\n\n" "$(hostname)" "${PRETTY_NAME:-$ID}"
warn "This permanently deletes Docker containers, images, networks, volumes and local Docker data."
warn "Back up databases and application data before continuing."
if [[ "$YES" != true ]]; then
  read -r -p 'Type WIPE-DOCKER to proceed: ' answer
  [[ "$answer" == "WIPE-DOCKER" ]] || die "Cancelled; no changes made."
fi

# Do not remove a shared containerd runtime while a Kubernetes distribution is active.
K8S_ACTIVE=false
for unit in kubelet.service k3s.service rke2-server.service rke2-agent.service snap.microk8s.daemon-containerd.service; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then K8S_ACTIVE=true; fi
done
if [[ "$K8S_ACTIVE" == true ]]; then
  die "An active Kubernetes/k3s/rke2/MicroK8s service was detected. Stopping to protect its containerd data."
fi

export DEBIAN_FRONTEND=noninteractive

# Capture Docker's configured data root before removing its daemon configuration.
DOCKER_ROOT=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
fi
if [[ -z "$DOCKER_ROOT" && -f /etc/docker/daemon.json ]]; then
  DOCKER_ROOT="$(python3 -c 'import json; print(json.load(open("/etc/docker/daemon.json")).get("data-root",""))' 2>/dev/null || true)"
fi

# Refuse dangerous or ambiguous custom paths; standard paths are handled below.
case "$DOCKER_ROOT" in
  ""|/var/lib/docker|/var/snap/docker/common/var-lib-docker) ;;
  /) die "Docker reports data-root=/; refusing to delete the filesystem root." ;;
  *) warn "Custom Docker data-root detected: $DOCKER_ROOT";;
esac

log "Stopping Docker services and socket activation..."
for unit in docker.service docker.socket docker-rootless.service containerd.service buildkit.service; do
  systemctl disable --now "$unit" 2>/dev/null || true
done

# Stop rootless Docker services for users; do not alter unrelated user services.
if command -v loginctl >/dev/null 2>&1; then
  while IFS=: read -r username _ uid _; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    loginctl disable-linger "$username" 2>/dev/null || true
    runuser -u "$username" -- systemctl --user disable --now docker.service docker.socket 2>/dev/null || true
  done < /etc/passwd
fi

log "Removing Docker/container packages installed through APT..."
mapfile -t packages < <(
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
    grep -E '^(docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker.io|docker-doc|docker-compose|docker-compose-plugin|docker-buildx-plugin|containerd.io|containerd|runc|podman-docker|moby-engine|moby-cli|moby-containerd|moby-runc)(:.*)?$' |
    sort -u || true
)
if (("${#packages[@]}")); then
  apt-get purge -y "${packages[@]}" || warn "APT reported package-removal errors; review the output."
else
  log "No matching APT packages found."
fi

log "Removing Docker Snap package, if installed..."
if command -v snap >/dev/null 2>&1; then
  snap remove docker --purge 2>/dev/null || true
fi

log "Removing Docker data and configuration..."
paths=(
  /var/lib/docker
  /var/lib/containerd
  /var/lib/buildkit
  /etc/docker
  /etc/containerd
  /etc/buildkit
  /run/docker
  /run/containerd
  /run/buildkit
  /var/run/docker
  /var/run/docker.sock
  /var/run/docker.pid
  /var/snap/docker
  /root/.docker
)
for path in "${paths[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf --one-file-system -- "$path"
    log "Removed $path"
  fi
done

# Remove the custom data-root only when explicitly confirmed interactively.
if [[ -n "$DOCKER_ROOT" && "$DOCKER_ROOT" != /var/lib/docker && "$DOCKER_ROOT" != /var/snap/docker/common/var-lib-docker ]]; then
  if [[ "$YES" == true ]]; then
    warn "Keeping custom data-root in --yes mode for safety: $DOCKER_ROOT"
  else
    read -r -p "Delete custom Docker data-root '$DOCKER_ROOT'? Type DELETE-PATH: " custom_answer
    if [[ "$custom_answer" == "DELETE-PATH" && -d "$DOCKER_ROOT" && "$DOCKER_ROOT" != "/" ]]; then
      rm -rf --one-file-system -- "$DOCKER_ROOT"
      log "Removed custom data-root: $DOCKER_ROOT"
    else
      warn "Custom data-root preserved."
    fi
  fi
fi

log "Removing Docker APT source entries and signing keys..."
rm -f \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/docker.sources \
  /etc/apt/keyrings/docker.asc \
  /etc/apt/keyrings/docker.gpg \
  /usr/share/keyrings/docker-archive-keyring.gpg \
  /etc/apt/trusted.gpg.d/docker.gpg

log "Removing standalone Docker Compose binaries..."
for binary in /usr/local/bin/docker-compose /usr/bin/docker-compose; do
  [[ -e "$binary" ]] && rm -f -- "$binary"
done

# Remove the docker group only if no account is a member.
if getent group docker >/dev/null 2>&1; then
  docker_gid="$(getent group docker | cut -d: -f3)"
  members="$(getent group docker | cut -d: -f4)"
  if [[ -z "$members" ]] && ! awk -F: -v gid="$docker_gid" '$4 == gid { found=1 } END { exit found ? 0 : 1 }' /etc/passwd; then
    groupdel docker 2>/dev/null || true
  else
    warn "Preserving docker group because it still has members."
  fi
fi

log "Cleaning APT package cache and unused dependencies..."
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean
apt-get update -y

printf "\n%b========== RIOT-CLEAN REPORT ==========%b\n" "$CYAN" "$RESET"
printf "\nRemaining matching packages:\n"
dpkg-query -W -f='${binary:Package} ${Version}\n' 2>/dev/null |
  grep -Ei '^(docker|containerd|runc|buildkit|moby)' || printf "  None detected by package name.\n"

printf "\nRemaining commands:\n"
for cmd in docker dockerd docker-compose containerd containerd-shim runc buildkitd; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  WARNING: %s still present at %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "  OK: %s not found\n" "$cmd"
  fi
done

printf "\nDocker/containerd service status:\n"
for unit in docker.service docker.socket containerd.service buildkit.service; do
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  printf "  %-24s %s\n" "$unit" "${state:-not-found}"
done

printf "\n%bRIOT-CLEAN completed.%b\n" "$GREEN" "$RESET"
warn "Review the report, then reboot when convenient: sudo reboot"
warn "This utility does not remove Podman, Kubernetes, firewall rules, network configuration, or unrelated runtimes."
