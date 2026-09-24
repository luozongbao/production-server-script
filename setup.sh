#!/usr/bin/env bash
#
# Production Server Setup Script
# Target: Ubuntu / Debian (systemd-based)
#
# Sections:
#   1. Timezone
#   2. Hostname
#   3. Firewall (UFW)
#   4. SSH key installation
#   5. Swap file
#   6. fail2ban
#   7. SSH hardening (ADVISORY ONLY — prints recommended sshd_config, does not apply)
#
# Usage:
#   sudo ./setup.sh
#
# Re-running is safe; the script is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd is required (this script targets Ubuntu/Debian)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load .env (if present) — variables override defaults, missing keys prompt
# ---------------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# Associative array of env values: KEY -> VALUE
declare -A ENV=()

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  info "Loading config from $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip comments and blank lines
    line="${line%%#*}"
    line="${line## }"; line="${line%% }"
    [[ -z "$line" ]] && continue
    # KEY=VALUE (VALUE may be quoted)
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      # strip surrounding single or double quotes
      v="${v%\"}"; v="${v#\"}"
      v="${v%\'}"; v="${v#\'}"
      ENV["$k"]="$v"
    fi
  done < "$file"
}

load_env_file "$ENV_FILE"

NONINTERACTIVE="false"
[[ "${ENV[NONINTERACTIVE]:-}" =~ ^[Tt]rue$ ]] && NONINTERACTIVE="true"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
ok()      { printf '  \033[1;32m[OK]\033[0m %s\n' "$1"; }
info()    { printf '  [..] %s\n' "$1"; }
warn()    { printf '  \033[1;33m[WARN]\033[0m %s\n' "$1"; }
err()     { printf '  \033[1;31m[ERR]\033[0m %s\n' "$1"; }

MISSING_REQUIRED=()
require_env() {
  local key="$1"
  if [[ -z "${ENV[$key]:-}" ]] && [[ "$NONINTERACTIVE" == "true" ]]; then
    MISSING_REQUIRED+=("$key")
  fi
}

# env_or_prompt KEY [DEFAULT] [LABEL]
#   Returns the .env value if set, otherwise interactively prompts.
env_or_prompt() {
  local key="$1"
  local prompt_default="${2:-}"
  local prompt_label="${3:-$key}"
  local val="${ENV[$key]:-}"

  if [[ -n "$val" ]]; then
    printf '  %s (from .env)\n' "$val"
    printf '%s' "$val"
    return 0
  fi

  if [[ "$NONINTERACTIVE" == "true" ]]; then
    err "$key is required when NONINTERACTIVE=true"
    return 1
  fi

  local prompt_text="Enter $prompt_label"
  [[ -n "$prompt_default" ]] && prompt_text+=" [$prompt_default]"
  local reply
  read -r -p "  ${prompt_text}: " reply
  reply="${reply:-$prompt_default}"
  printf '%s' "$reply"
}

ask() {
  local prompt="$1" default="${2:-N}" reply
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    if [[ "${default^^}" == "Y" ]]; then
      printf '  %s [y/N] -> Y (non-interactive)\n' "$prompt"
      return 0
    fi
    printf '  %s [y/N] -> N (non-interactive)\n' "$prompt"
    return 1
  fi
  read -r -p "$(printf '  %s [y/N]: ' "$prompt")" reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
validate_timezone() {
  local tz="$1"
  if timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
    return 0
  fi
  err "Invalid timezone: '$tz' (expected IANA name, e.g. 'Asia/Shanghai')"
  return 1
}

# RFC 1123 hostname: labels of [a-zA-Z0-9-], 1-63 chars, total <= 253
validate_hostname() {
  local h="$1"
  if [[ ${#h} -gt 253 ]]; then
    err "Hostname too long (max 253 chars)"; return 1
  fi
  if ! [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
    err "Invalid hostname: '$h' (expected RFC 1123, e.g. 'web-prod-01')"
    return 1
  fi
}

validate_port_spec() {
  local spec="$1"
  if ! [[ "$spec" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]]; then
    err "Invalid port spec: '$spec' (expected N, N/tcp, or Start:End/proto)"
    return 1
  fi
  local range="${spec%/*}"
  for p in ${range//:/ }; do
    if (( p < 1 || p > 65535 )); then
      err "Port out of range (1-65535): '$p' in '$spec'"
      return 1
    fi
  done
}

validate_positive_int() {
  local key="$1" val="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < 1 )); then
    err "$key must be a positive integer, got: '$val'"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# NONINTERACTIVE preflight — validate everything BEFORE touching the system
# ---------------------------------------------------------------------------
require_env "TIMEZONE"
require_env "HOSTNAME"
require_env "FIREWALL_APPLY"
require_env "SSH_PUBLIC_KEY"
require_env "SWAP_SIZE_MB"
require_env "FAIL2BAN_ENABLED"

if [[ "$NONINTERACTIVE" == "true" ]]; then
  if (( ${#MISSING_REQUIRED[@]} > 0 )); then
    err "NONINTERACTIVE=true but required variables are missing:"
    for k in "${MISSING_REQUIRED[@]}"; do printf '    - %s\n' "$k"; done
    exit 2
  fi

  info "Validating .env values..."
  validate_timezone  "${ENV[TIMEZONE]}" || exit 2
  validate_hostname "${ENV[HOSTNAME]}" || exit 2
  if [[ -n "${ENV[FIREWALL_EXTRA_PORTS]:-}" ]]; then
    IFS=',' read -ra _pl <<< "${ENV[FIREWALL_EXTRA_PORTS]}"
    for _p in "${_pl[@]}"; do
      _p="${_p// /}"; [[ -z "$_p" ]] && continue
      validate_port_spec "$_p" || exit 2
    done
  fi
  if ! [[ "${ENV[SWAP_SIZE_MB]}" =~ ^[0-9]+$ ]]; then
    err "SWAP_SIZE_MB must be an integer"; exit 2
  fi
  if [[ -n "${ENV[FAIL2BAN_BANTIME]:-}" ]]; then
    [[ "${ENV[FAIL2BAN_BANTIME]}" =~ ^[0-9]+[mhd]?$ ]] || \
      { err "FAIL2BAN_BANTIME must be like 1h, 30m, 1d, or 3600"; exit 2; }
  fi
  if [[ -n "${ENV[FAIL2BAN_MAXRETRY]:-}" ]]; then
    validate_positive_int "FAIL2BAN_MAXRETRY" "${ENV[FAIL2BAN_MAXRETRY]}" || exit 2
  fi
  ok "All .env values valid"
fi

# ---------------------------------------------------------------------------
# 1. Timezone
# ---------------------------------------------------------------------------
section "Timezone"
current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
info "Current timezone: $current_tz"

new_tz=$(env_or_prompt "TIMEZONE (e.g. Asia/Shanghai, UTC)" "$current_tz") || exit 2
validate_timezone "$new_tz" || exit 2

if [[ "$new_tz" != "$current_tz" ]]; then
  timedatectl set-timezone "$new_tz"
  ok "Timezone set to $new_tz"
else
  info "No change"
fi

if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "NTP synchronized"
else
  warn "NTP not synchronized — enable with: sudo timedatectl set-ntp true"
fi

# ---------------------------------------------------------------------------
# 2. Hostname
# ---------------------------------------------------------------------------
section "Hostname"
current_host=$(hostnamectl hostname 2>/dev/null || hostname)
info "Current hostname: $current_host"

new_host=$(env_or_prompt "HOSTNAME" "$current_host") || exit 2
validate_hostname "$new_host" || exit 2

if [[ "$new_host" != "$current_host" ]]; then
  hostnamectl set-hostname "$new_host"
  # Ensure /etc/hosts has an entry for the new hostname so resolution works
  if ! grep -qE "[[:space:]]${new_host}([[:space:]]|$)" /etc/hosts; then
    echo "127.0.1.1 $new_host" >> /etc/hosts
    info "Added 127.0.1.1 $new_host to /etc/hosts"
  fi
  ok "Hostname set to $new_host"
else
  info "No change"
fi

# ---------------------------------------------------------------------------
# 3. Firewall (UFW)
# ---------------------------------------------------------------------------
section "Firewall (UFW)"
if ! command -v ufw >/dev/null 2>&1; then
  warn "ufw is not installed — installing"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ufw
fi

info "Current UFW status:"
ufw status verbose || true

# FIREWALL_APPLY controls whether we proceed; default is interactive prompt
fw_apply="${ENV[FIREWALL_APPLY]:-}"
fw_decided=false
if [[ "$fw_apply" =~ ^[Tt]rue$ ]];  then fw_apply=true;  fw_decided=true; fi
if [[ "$fw_apply" =~ ^[Ff]alse$ ]]; then fw_apply=false; fw_decided=true; fi

if [[ "$fw_decided" == "true" ]]; then
  info "FIREWALL_APPLY=$fw_apply (from .env)"
elif ask "Apply recommended firewall rules (default deny inbound, allow 22/80/443)"; then
  fw_apply=true
else
  fw_apply=false
fi

if [[ "$fw_apply" == "true" ]]; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp   comment 'SSH'
  ufw allow 80/tcp   comment 'HTTP'
  ufw allow 443/tcp  comment 'HTTPS'

  extra_ports="${ENV[FIREWALL_EXTRA_PORTS]:-}"
  if [[ -n "$extra_ports" ]]; then
    IFS=',' read -ra port_list <<< "$extra_ports"
    for p in "${port_list[@]}"; do
      p="${p// /}"
      [[ -z "$p" ]] && continue
      validate_port_spec "$p" || exit 2
      ufw allow "$p"
      info "Opened $p (from FIREWALL_EXTRA_PORTS)"
    done
  fi

  ufw --force enable
  ok "Firewall rules applied"
  ufw status verbose
else
  info "Skipped firewall changes"
fi

# ---------------------------------------------------------------------------
# 4. SSH key installation
# ---------------------------------------------------------------------------
section "SSH key installation (for the invoking sudo user)"
target_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
target_home=$(getent passwd "$target_user" | cut -d: -f6)
info "Target user: $target_user  (home: $target_home)"

ssh_dir="$target_home/.ssh"
auth_keys="$ssh_dir/authorized_keys"

# Load public key from ssh_key.pub if present
key_file="${SCRIPT_DIR}/ssh_key.pub"
file_pubkey=""
if [[ -f "$key_file" ]]; then
  file_pubkey=$(awk '{$1=$1; print}' "$key_file")
  info "Loaded public key from $key_file"
fi

if [[ -f "$auth_keys" ]] && [[ -s "$auth_keys" ]]; then
  ok "authorized_keys already exists at $auth_keys"
  info "Existing keys:"
  awk '{print "    " NR": " substr($0,1,40) "..."}' "$auth_keys"

  # If we have a key from ssh_key.pub, offer to append if not already present
  if [[ -n "$file_pubkey" ]] && ! grep -qxF "$file_pubkey" "$auth_keys"; then
    if ask "Append ssh_key.pub to authorized_keys"; then
      echo "$file_pubkey" >> "$auth_keys"
      chown "$target_user":"$target_user" "$auth_keys"
      ok "Appended public key"
    fi
  fi
else
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_keys"
  chmod 600 "$auth_keys"
  chown -R "$target_user":"$target_user" "$ssh_dir"

  if [[ -n "$file_pubkey" ]]; then
    echo "$file_pubkey" >> "$auth_keys"
    chown "$target_user":"$target_user" "$auth_keys"
    ok "Installed public key from ssh_key.pub for $target_user"
  elif ask "No authorized_keys found — paste a public key now to install it"; then
    echo "  Paste the public key (starts with ssh-rsa / ssh-ed25519 / ecdsa-sha2-):"
    read -r pubkey
    if [[ -z "$pubkey" ]]; then
      err "No key provided — skipping"
    else
      echo "$pubkey" >> "$auth_keys"
      chown "$target_user":"$target_user" "$auth_keys"
      ok "Public key installed for $target_user"
    fi
  else
    info "Skipped — add a key manually later"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Swap file
# ---------------------------------------------------------------------------
section "Swap file"
swap_size_mb=$(env_or_prompt "SWAP_SIZE_MB" "0") || exit 2
if ! [[ "$swap_size_mb" =~ ^[0-9]+$ ]]; then
  err "SWAP_SIZE_MB must be an integer (got: '$swap_size_mb')"; exit 2
fi

if (( swap_size_mb > 0 )); then
  swap_file="/swapfile"
  if swapon --show | grep -q "$swap_file"; then
    ok "Swap already active at $swap_file"
  elif [[ -f "$swap_file" ]]; then
    warn "$swap_file exists but is not active — leaving as-is"
  else
    info "Creating ${swap_size_mb}MB swap file at $swap_file"
    fallocate -l "${swap_size_mb}M" "$swap_file" || dd if=/dev/zero of="$swap_file" bs=1M count="$swap_size_mb" status=none
    chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null
    swapon "$swap_file"
    # Persist across reboots via fstab (idempotent)
    if ! grep -q "$swap_file" /etc/fstab; then
      echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi
    # Sensible swappiness for servers
    sysctl -w vm.swappiness=10 >/dev/null
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
      echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    ok "Swap enabled (${swap_size_mb}MB, swappiness=10)"
  fi
else
  info "SWAP_SIZE_MB=0 or unset — skipping swap configuration"
fi

# ---------------------------------------------------------------------------
# 6. fail2ban
# ---------------------------------------------------------------------------
section "fail2ban"
f2b_enabled=$(env_or_prompt "FAIL2BAN_ENABLED" "true") || exit 2

if [[ "$f2b_enabled" =~ ^[Tt]rue$ ]]; then
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    info "Installing fail2ban"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq fail2ban
  else
    info "fail2ban already installed"
  fi

  bantime="${ENV[FAIL2BAN_BANTIME]:-1h}"
  findtime="${ENV[FAIL2BAN_FINDTIME]:-10m}"
  maxretry="${ENV[FAIL2BAN_MAXRETRY]:-5}"
  validate_positive_int "FAIL2BAN_MAXRETRY" "$maxretry" || exit 2

  jail_local="/etc/fail2ban/jail.local"
  managed_marker="Managed by production-server-script"
  if [[ -f "$jail_local" ]] && ! grep -qF "$managed_marker" "$jail_local"; then
    warn "$jail_local exists but is not managed by this script — leaving untouched"
  else
    cat > "$jail_local" <<EOF
# $managed_marker
[DEFAULT]
bantime  = $bantime
findtime = $findtime
maxretry = $maxretry
backend  = systemd

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF
    ok "Wrote $jail_local"
  fi

  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl is-active --quiet fail2ban; then
    systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
    ok "fail2ban reloaded"
  else
    systemctl start fail2ban
    ok "fail2ban started"
  fi
  info "Active jails:"
  fail2ban-client status 2>/dev/null | sed 's/^/    /' || warn "fail2ban-client not yet ready"
else
  info "FAIL2BAN_ENABLED=false — skipping fail2ban"
fi

# ---------------------------------------------------------------------------
# 7. SSH hardening (ADVISORY ONLY)
# ---------------------------------------------------------------------------
section "SSH hardening — ADVISORY ONLY"
info "Recommended /etc/ssh/sshd_config settings:"
cat <<'EOF'
    PasswordAuthentication no
    PermitRootLogin prohibit-password
    PubkeyAuthentication yes
    ChallengeResponseAuthentication no
    UsePAM yes
    X11Forwarding no
    MaxAuthTries 3
    LoginGraceTime 30
    ClientAliveInterval 300
    ClientAliveCountMax 2
EOF

warn "This script will NOT apply these changes automatically."
warn "Reason: applying PasswordAuthentication=no without a working key will lock you out."
warn "Before applying, verify you can log in via key:"
echo "    ssh ${target_user}@<server>   # in a NEW terminal session"
echo
if ask "Show the exact sed commands you would run manually"; then
  cat <<EOF

  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.\$(date +%F)
  sudo sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config
  sudo sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  sudo sed -i 's/^#\\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
  sudo sshd -t && sudo systemctl reload ssh

EOF
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
section "Summary"
ok "Timezone:     $(timedatectl show -p Timezone --value)"
ok "Hostname:     $(hostnamectl hostname)"
ok "UFW status:   $(ufw status | head -n1)"
swap_summary=$(swapon --show --noheadings 2>/dev/null | awk '{print $3, $4}' | tr '\n' ' ')
[[ -z "$swap_summary" ]] && swap_summary="none"
ok "Swap:         $swap_summary"
ok "fail2ban:     $(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
ok "SSH keys:     $([[ -s "$auth_keys" ]] && echo "installed ($auth_keys)" || echo "NONE — log in with password only")"
echo
info "Review the SSH hardening section above before disabling password auth."
