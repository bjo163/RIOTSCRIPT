#!/usr/bin/env bash
#
# RIOT-PURGE — conservative application cleanup for Debian/Ubuntu.
# Only explicitly custom systemd units and selected app directories are eligible.
# Core OS, SSH, networking, kernel, boot, users and home directories are protected.
#
# Usage:
#   sudo bash riot-purge.sh --dry-run
#   sudo bash riot-purge.sh
#
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="1.1.0"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run]" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo "Cannot identify OS." >&2; exit 1; }
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) echo "Debian/Ubuntu only." >&2; exit 1;; esac
command -v apt-get >/dev/null
command -v systemctl >/dev/null

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log(){ printf "%b[+]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn(){ printf "%b[!]%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
skip(){ printf "%b[-]%b %s\n" "$CYAN" "$RESET" "$*"; }
ask(){ local reply; read -r -p "$1 [y/N] " reply; [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]; }
section(){ printf "\n%b== %s ==%b\n" "$CYAN" "$1" "$RESET"; }

printf "\n%b RIOT-PURGE v%s%b\nHost: %s | OS: %s\n" "$CYAN" "$VERSION" "$RESET" "$(hostname)" "${PRETTY_NAME:-$ID}"
warn "This is an interactive cleanup, not an OS reset."
warn "Only custom units in /etc/systemd/system or /usr/local/lib/systemd/system are considered."
warn "APT packages are NOT bulk-selected from apt-mark; that list includes essential Debian libraries."
warn "SSH, networking, systemd, kernel, GRUB, LVM, users and home directories are protected."
if [[ "$DRY_RUN" != true ]]; then
  ask "Continue to interactive review?" || { echo "Cancelled."; exit 0; }
fi

section "CUSTOM APPLICATION SERVICE CANDIDATES"
# A unit is eligible only if its actual unit file is in an administrator-managed
# custom location. Package-owned units under /lib or /usr/lib are never candidates.
mapfile -t units < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | sort -u)
for unit in "${units[@]}"; do
  [[ "$unit" == *.service ]] || continue
  name="${unit%.service}"
  case "$name" in
    ssh|sshd|systemd-*|networking|NetworkManager|network-manager|dbus|cron|rsyslog|ufw|fail2ban|polkit|apparmor|cloud-init*|getty*|serial-getty*|console-getty*|user@*|emergency|rescue|lvm2*|blk-availability|ifupdown*|keyboard-setup|console-setup|kmod*|udev*|procps|e2scrub*)
      continue;;
  esac
  fragment="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
  case "$fragment" in
    /etc/systemd/system/*|/usr/local/lib/systemd/system/*) ;;
    *) continue;;
  esac
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  [[ "$enabled" == enabled || "$active" == active || "$active" == failed ]] || continue
  printf "Custom service: %-38s state=%s enabled=%s file=%s\n" "$unit" "$active" "$enabled" "$fragment"
  if [[ "$DRY_RUN" != true ]] && ask "Disable service and remove this custom unit file? ($unit)"; then
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f -- "$fragment"
    systemctl daemon-reload
    log "Removed custom unit: $unit"
  fi
done
[[ "$DRY_RUN" == true ]] && skip "Preview only: no service changes made."

section "KNOWN APPLICATION PACKAGE CANDIDATES"
# Intentionally narrow allowlist. Review each package; do not infer from apt-mark.
app_packages=(
  nodejs npm masscan
  python3-pip python3-venv python3.11-venv
  build-essential
)
for pkg in "${app_packages[@]}"; do
  status="$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == installed ]] || continue
  printf "Known app/tool package: %s\n" "$pkg"
  if [[ "$DRY_RUN" != true ]] && ask "Purge package '$pkg'?"; then
    apt-get purge "$pkg"
  fi
done
skip "Docker/containerd packages and data are handled separately by riot-clean.sh."
skip "No blanket apt-mark showmanual purge is performed; manual status does not mean optional."

section "APPLICATION DATA DIRECTORY CANDIDATES"
# Review immediate child directories only. Never touch generic system share data.
for base in /opt /srv /var/www /usr/local/src; do
  [[ -d "$base" ]] || continue
  while IFS= read -r -d '' path; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    printf "Directory candidate: %s\n" "$path"
    if [[ "$DRY_RUN" != true ]] && ask "Permanently delete this directory and its contents?"; then
      rm -rf --one-file-system -- "$path"
      log "Removed $path"
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
done
[[ "$DRY_RUN" == true ]] && skip "Preview only: no directories changed."

section "CRON / STARTUP REVIEW"
echo "Cron jobs, user crontabs, /etc/profile.d and shell startup files are preserved."
echo "They require manual inspection; this script will not bulk-delete startup configuration."
for path in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /etc/profile.d; do
  [[ -e "$path" ]] && printf "  Preserved: %s\n" "$path"
done

section "APT HOUSEKEEPING"
if [[ "$DRY_RUN" != true ]]; then
  warn "Review the APT simulation carefully; do not proceed if it proposes removing SSH, networking, systemd, kernel, GRUB, LVM or core libraries."
  apt-get -s autoremove --purge
  if ask "Run the simulated APT autoremove plan?"; then
    apt-get autoremove --purge
  else
    skip "APT autoremove skipped."
  fi
  apt-get autoclean
  apt-get clean
  systemctl daemon-reload
else
  skip "Dry-run: no APT operations, services or files were changed."
fi

section "FINAL STATUS"
printf "OS: %s\n" "${PRETTY_NAME:-$ID}"
printf "SSH: %s\n" "$(systemctl is-active ssh.service 2>/dev/null || systemctl is-active sshd.service 2>/dev/null || true)"
printf "Networking: networking=%s NetworkManager=%s systemd-networkd=%s\n" \
  "$(systemctl is-active networking.service 2>/dev/null || true)" \
  "$(systemctl is-active NetworkManager.service 2>/dev/null || true)" \
  "$(systemctl is-active systemd-networkd.service 2>/dev/null || true)"
if [[ "$DRY_RUN" == true ]]; then
  log "Dry-run complete. No changes were made."
else
  log "Interactive cleanup complete. Verify SSH/network access before rebooting."
fi
warn "For Docker cleanup, run riot-clean.sh separately. It permanently deletes Docker volumes and data."
