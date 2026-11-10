#!/usr/bin/env bash
#
# RIOT-PURGE — cautious application/service cleanup for Debian & Ubuntu
# Keeps the OS, SSH, networking, systemd, kernel, bootloader and package manager.
#
# Usage:
#   sudo bash riot-purge.sh --dry-run
#   sudo bash riot-purge.sh
#
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="1.0.0"
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
run(){ if [[ "$DRY_RUN" == true ]]; then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

printf "\n%b RIOT-PURGE v%s%b\nHost: %s | OS: %s\n" "$CYAN" "$VERSION" "$RESET" "$(hostname)" "${PRETTY_NAME:-$ID}"
warn "This removes selected application services, manually-installed packages and app data."
warn "It deliberately does NOT perform a blanket APT purge or delete all startup entries."
warn "SSH, networking, systemd, kernel, GRUB, LVM, users and home directories are protected."
if [[ "$DRY_RUN" != true ]]; then
  ask "Continue to interactive review?" || { echo "Cancelled."; exit 0; }
fi

# Hard protection: units required for remote access and OS operation.
protected_unit_re='^(ssh|sshd|systemd-|networking|NetworkManager|network-manager|dbus|cron|rsyslog|systemd-resolved|unattended-upgrades|apt-daily|apt-daily-upgrade|cloud-init|serial-getty|console-getty| rescue|emergency|user@|getty)'
section(){ printf "\n%b== %s ==%b\n" "$CYAN" "$1" "$RESET"; }

section "APPLICATION SERVICE CANDIDATES"
mapfile -t units < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | sort -u)
for unit in "${units[@]}"; do
  [[ "$unit" == *.service ]] || continue
  name="${unit%.service}"
  [[ "$name" =~ $protected_unit_re ]] && continue
  # Show only enabled/running services; avoid touching ordinary OS services.
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  [[ "$enabled" == enabled || "$active" == active ]] || continue
  # Never auto-classify common core daemons as application services.
  case "$name" in
    ssh|sshd|cron|atd|dbus|systemd-*|networking|NetworkManager|rsyslog|ufw|fail2ban|fail2ban-server|polkit|accounts-daemon|irqbalance|haveged|apparmor|getty@*|serial-getty@*|cloud-init*) continue;;
  esac
  printf "Candidate: %-42s enabled=%-10s active=%s\n" "$unit" "$enabled" "$active"
  if [[ "$DRY_RUN" != true ]] && ask "Disable and remove this unit file ($unit)?"; then
    run systemctl disable --now "$unit" || true
    unit_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    case "$unit_path" in /etc/systemd/system/*|/usr/local/lib/systemd/system/*)
      [[ -f "$unit_path" ]] && run rm -f -- "$unit_path"
      ;;
      *) skip "Unit file is package-owned or outside the safe custom-unit paths: $unit_path";;
    esac
  fi
done
if [[ "$DRY_RUN" == true ]]; then
  skip "Dry-run lists service candidates only; no changes were made."
fi
if [[ "$DRY_RUN" != true ]]; then
  run systemctl daemon-reload
fi

section "MANUALLY INSTALLED APT PACKAGE CANDIDATES"
# Deliberately do not mass-purge packages. Each package requires a separate confirmation.
mapfile -t manual_packages < <(apt-mark showmanual 2>/dev/null | sort -u)
for pkg in "${manual_packages[@]}"; do
  [[ "$pkg" =~ ^[a-zA-Z0-9][a-zA-Z0-9+.-]*(:[a-zA-Z0-9_-]+)?$ ]] || continue
  # Explicit base-system protections.
  case "$pkg" in
    apt|apt-*|base-files|base-passwd|bash|bsdutils|coreutils|dash|debconf|debian-archive-keyring|dpkg|e2fsprogs|findutils|grep|grub*|init|init-system-helpers|initramfs-tools*|iproute2|iputils*|kmod|libc6|libpam*|login|lsb-base|mawk|mount|ncurses-base|ncurses-bin|openssh*|passwd|procps|sed|systemd*|sysvinit*|tar| udev|util-linux| usrmerge|zlib1g|linux-*|openssh-server|ifupdown|netbase|net-tools|sudo|ca-certificates|curl|wget)
      continue;;
  esac
  # Only show packages that are installed and explicitly marked manual.
  dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed || continue
  printf "Manual package candidate: %s\n" "$pkg"
  if [[ "$DRY_RUN" != true ]] && ask "Purge package '$pkg'?"; then
    run apt-get purge -y "$pkg"
  fi
done
if [[ "$DRY_RUN" == true ]]; then
  skip "Dry-run lists manual package candidates; no packages were changed."
fi

section "APPLICATION DATA DIRECTORY CANDIDATES"
# Only immediate child directories are considered; never recurse-delete a parent.
for base in /opt /srv /var/www /usr/local/src /usr/local/share; do
  [[ -d "$base" ]] || continue
  while IFS= read -r -d '' path; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    printf "Directory candidate: %s\n" "$path"
    if [[ "$DRY_RUN" != true ]] && ask "Permanently delete this directory and its contents?"; then
      run rm -rf --one-file-system -- "$path"
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
done
if [[ "$DRY_RUN" == true ]]; then
  skip "Dry-run lists immediate child directories only; no data was changed."
fi

section "CRON / STARTUP REVIEW"
echo "Cron jobs and shell startup files are NOT automatically deleted."
echo "Review manually if needed:"
for path in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly /etc/rc.local /etc/profile.d; do
  [[ -e "$path" ]] && printf "  %s\n" "$path"
done
echo "User crontabs are preserved. No user accounts or home directories are removed."

if [[ "$DRY_RUN" != true ]]; then
  section "APT HOUSEKEEPING"
  warn "APT autoremove can remove dependencies; inspect the simulation first."
  apt-get -s autoremove --purge
  if ask "Run APT autoremove --purge after reviewing the simulation?"; then
    apt-get autoremove --purge -y
  else
    skip "APT autoremove skipped."
  fi
  apt-get autoclean -y
  apt-get clean
  systemctl daemon-reload
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
  log "Interactive cleanup complete. Review output before rebooting."
fi
warn "Docker is handled separately by riot-clean.sh. Run it only if you also want to delete all Docker volumes and data."
