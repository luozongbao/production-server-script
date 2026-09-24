#!/usr/bin/env bash
#
# Production Server Setup Script
# Target: Ubuntu / Debian (systemd-based)
#
# Sections (each can be enabled/disabled via flags):
#   timezone   — set timezone via timedatectl, verify NTP
#   hostname   — set hostname via hostnamectl, update /etc/hosts
#   firewall   — UFW with default-deny inbound + extras
#   ssh-key    — install your public key for passwordless login
#   swap       — create swapfile at /swapfile
#   fail2ban   — install + enable SSH jail
#   ssh-harden — advisory only: prints recommended sshd_config
#
# Usage:
#   sudo ./setup.sh                          # run all sections (interactive)
#   sudo ./setup.sh --swap                   # run only swap
#   sudo ./setup.sh --swap --firewall        # run swap + firewall
#   sudo ./setup.sh --hostname web01 --swap  # override hostname, run swap
#   sudo ./setup.sh --no-fail2ban            # run all except fail2ban
#   sudo ./setup.sh --non-interactive        # fail fast on missing values
#   sudo ./setup.sh --help                   # show usage
#
# Precedence: CLI flag > .env value > interactive prompt > built-in default
# Re-running is safe; the script is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical section list — used by is_enabled auto-detect, Plan, Summary, and
# NONINTERACTIVE preflight. Keep in sync with run_section calls at the bottom.
SECTIONS=(timezone hostname firewall ssh-key swap fail2ban ssh-harden apt-upgrade add-repo install-defaults)

# ===========================================================================
# CLI argument parsing
# ===========================================================================
# After parsing, each of these holds "true" or "false".
# Default: all sections enabled (matches old "run everything" behavior).
# If user passes any --<feature> or --no-<feature>, we start with NONE
# enabled and only enable what was explicitly requested.
FLAG_TIMEZONE=""
FLAG_HOSTNAME=""
FLAG_FIREWALL=""
FLAG_SSH_KEY=""
FLAG_SWAP=""
FLAG_FAIL2BAN=""
FLAG_SSH_HARDEN=""
FLAG_APT_UPGRADE=""
FLAG_ADD_REPO=""
FLAG_INSTALL_DEFAULTS=""
FLAG_NONINTERACTIVE="false"
CLI_FLAG_GIVEN=false
CLI_ENABLE_LIST=()   # section names explicitly enabled via CLI
CLI_DISABLE_LIST=()  # section names explicitly disabled via CLI

usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh [OPTIONS]

Sections (composable; default if no section flag given: run all):
  -t, --timezone        Set timezone
      --no-timezone     Skip timezone
  -n, --hostname NAME   Set hostname (overrides .env/HOSTNAME)
      --no-hostname     Skip hostname
  -f, --firewall        Apply UFW firewall rules
      --no-firewall     Skip firewall
  -k, --ssh-key         Install SSH public key
      --no-ssh-key      Skip SSH key install
  -s, --swap            Create swapfile
      --no-swap         Skip swap
  -b, --fail2ban        Install + enable fail2ban
      --no-fail2ban     Skip fail2ban
  -h, --ssh-harden      Show SSH hardening recommendations (advisory)
      --no-ssh-harden   Skip SSH hardening advisory
  -u, --apt-upgrade     Run apt update + upgrade (and optionally autoremove)
      --no-apt-upgrade  Skip apt update + upgrade
  -r, --add-repo        Add 3rd-party APT repositories from .env, then apt update
      --no-add-repo     Skip add-repo
  -p, --install-defaults Install baseline server packages from DEFAULT_PACKAGES
      --no-install-defaults  Skip install-defaults

Behavior:
  -y, --non-interactive Skip all prompts; fail fast on missing required values
  -h, --help            Show this help

If no section flag is passed, ALL sections run.
If any section flag is passed, ONLY those sections run (plus any --no-X
exclusions).

Examples:
  sudo ./setup.sh                          # interactive, all sections
  sudo ./setup.sh --swap --firewall        # only swap and firewall
  sudo ./setup.sh --hostname web01 --swap  # override hostname, run swap
  sudo ./setup.sh --no-fail2ban            # all except fail2ban
  sudo ./setup.sh --non-interactive        # CI/cloud-init style

Env file precedence: CLI flag > .env value > interactive prompt > default
EOF
}

# Parse args
while (( $# > 0 )); do
  case "$1" in
    -t|--timezone)         FLAG_TIMEZONE=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(timezone); shift ;;
    --no-timezone)         FLAG_TIMEZONE=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(timezone); shift ;;
    -n|--hostname)         FLAG_HOSTNAME=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(hostname); shift ;;
      --hostname=*)        FLAG_HOSTNAME=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(hostname)
                           CLI_HOSTNAME_VALUE="${1#*=}"; shift ;;
      --hostname)          FLAG_HOSTNAME=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(hostname)
                           [[ "${2:-}" =~ ^[^-] ]] && { CLI_HOSTNAME_VALUE="$2"; shift; }; shift ;;
    --no-hostname)         FLAG_HOSTNAME=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(hostname); shift ;;
    -f|--firewall)         FLAG_FIREWALL=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(firewall); shift ;;
    --no-firewall)         FLAG_FIREWALL=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(firewall); shift ;;
    -k|--ssh-key)          FLAG_SSH_KEY=true;   CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(ssh-key); shift ;;
    --no-ssh-key)          FLAG_SSH_KEY=false;  CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(ssh-key); shift ;;
    -s|--swap)             FLAG_SWAP=true;      CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(swap); shift ;;
    --no-swap)             FLAG_SWAP=false;     CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(swap); shift ;;
    -b|--fail2ban)         FLAG_FAIL2BAN=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(fail2ban); shift ;;
    --no-fail2ban)         FLAG_FAIL2BAN=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(fail2ban); shift ;;
    --ssh-harden)          FLAG_SSH_HARDEN=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(ssh-harden); shift ;;
    --no-ssh-harden)       FLAG_SSH_HARDEN=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(ssh-harden); shift ;;
    -u|--apt-upgrade)      FLAG_APT_UPGRADE=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(apt-upgrade); shift ;;
    --no-apt-upgrade)      FLAG_APT_UPGRADE=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(apt-upgrade); shift ;;
    -r|--add-repo)         FLAG_ADD_REPO=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(add-repo); shift ;;
    --no-add-repo)         FLAG_ADD_REPO=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(add-repo); shift ;;
    -p|--install-defaults) FLAG_INSTALL_DEFAULTS=true;  CLI_FLAG_GIVEN=true; CLI_ENABLE_LIST+=(install-defaults); shift ;;
    --no-install-defaults) FLAG_INSTALL_DEFAULTS=false; CLI_FLAG_GIVEN=true; CLI_DISABLE_LIST+=(install-defaults); shift ;;
    -y|--non-interactive)  FLAG_NONINTERACTIVE=true; shift ;;
    -h|--help)             usage; exit 0 ;;
    --)                    shift; break ;;
    -*)                    printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    *)                     printf 'Unexpected positional arg: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

# Resolve final section-enabled state.
# Sections listed in OPT_IN_SECTIONS only run when explicitly requested
# (via CLI flag or .env-required-key presence). They never run on a bare
# `sudo ./setup.sh` with no flags. Other sections default to enabled when
# no flag is given, and to CLI_ENABLE_LIST when flags are given.
OPT_IN_SECTIONS=(add-repo install-defaults)
_section_is_opt_in() {
  local s="$1"
  for o in "${OPT_IN_SECTIONS[@]}"; do [[ "$o" == "$s" ]] && return 0; done
  return 1
}

is_enabled() {
  local s="$1"
  for d in "${CLI_DISABLE_LIST[@]:-}"; do [[ "$d" == "$s" ]] && return 1; done
  if [[ "$CLI_FLAG_GIVEN" == "true" ]]; then
    for e in "${CLI_ENABLE_LIST[@]:-}"; do [[ "$e" == "$s" ]] && return 0; done
    return 1
  fi
  # No CLI flag: opt-in sections stay disabled unless required .env keys exist
  if _section_is_opt_in "$s"; then
    # Auto-enable opt-in section if its required .env key is set
    local rk
    rk=$(required_keys_for_section "$s")
    if [[ -n "$rk" ]] && [[ -n "${ENV[$rk]:-}" ]]; then
      return 0
    fi
    return 1
  fi
  return 0
}

# ===========================================================================
# Preflight
# ===========================================================================
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd is required (this script targets Ubuntu/Debian)" >&2
  exit 1
fi

# ===========================================================================
# Load .env
# ===========================================================================
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
declare -A ENV=()

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  info "Loading config from $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line## }"; line="${line%% }"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      ENV["$k"]="$v"
    fi
  done < "$file"
}

# ===========================================================================
# Helpers
# ===========================================================================
section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
ok()      { printf '  \033[1;32m[OK]\033[0m %s\n' "$1"; }
info()    { printf '  [..] %s\n' "$1"; }
warn()    { printf '  \033[1;33m[WARN]\033[0m %s\n' "$1"; }
err()     { printf '  \033[1;31m[ERR]\033[0m %s\n' "$1"; }

# Load .env AFTER helpers are defined (so load_env_file can use info)
load_env_file "$ENV_FILE"

MISSING_REQUIRED=()
require_env() {
  local key="$1"
  if [[ -z "${ENV[$key]:-}" ]] && [[ "$NONINTERACTIVE" == "true" ]]; then
    MISSING_REQUIRED+=("$key")
  fi
}

# env_or_prompt KEY [DEFAULT] [LABEL]
env_or_prompt() {
  local key="$1"
  local prompt_default="${2:-}"
  local prompt_label="${3:-$key}"
  local val="${ENV[$key]:-}"

  # CLI flag override wins
  if [[ "$key" == "HOSTNAME" ]] && [[ -n "${CLI_HOSTNAME_VALUE:-}" ]]; then
    val="$CLI_HOSTNAME_VALUE"
    printf '  %s (from CLI)\n' "$val"
    printf '%s' "$val"
    return 0
  fi

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

# ===========================================================================
# Validation helpers
# ===========================================================================
validate_timezone() {
  local tz="$1"
  if timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
    return 0
  fi
  err "Invalid timezone: '$tz' (expected IANA name, e.g. 'Asia/Shanghai')"
  return 1
}

validate_hostname() {
  local h="$1"
  if [[ ${#h} -gt 253 ]]; then err "Hostname too long (max 253 chars)"; return 1; fi
  # RFC 1123: each label must start with a letter (not digit), end with letter/digit
  # Pure-numeric labels like "123" are technically valid per the loose regex but
  # systemd rejects them with "Name or service not known".
  if ! [[ "$h" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
    err "Invalid hostname: '$h' (expected RFC 1123, e.g. 'web-prod-01', must start with a letter)"
    return 1
  fi
  return 0
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

# ===========================================================================
# Determine NONINTERACTIVE mode
# ===========================================================================
# 1. --non-interactive CLI flag → true
# 2. NONINTERACTIVE=true in .env → true
# 3. Auto-detect: if .env has every required key for enabled sections → true
# 4. Otherwise → false (interactive)

NONINTERACTIVE="false"
[[ "${ENV[NONINTERACTIVE]:-}" =~ ^[Tt]rue$ ]] && NONINTERACTIVE="true"
[[ "$FLAG_NONINTERACTIVE" == "true" ]] && NONINTERACTIVE="true"

# Auto-detect: required keys per section
required_keys_for_section() {
  case "$1" in
    timezone)  echo "TIMEZONE" ;;
    hostname)  echo "HOSTNAME" ;;
    firewall)  echo "FIREWALL_APPLY" ;;
    ssh-key)   echo "SSH_PUBLIC_KEY" ;;
    swap)      echo "SWAP_SIZE_MB" ;;
    fail2ban)  echo "FAIL2BAN_ENABLED" ;;
    ssh-harden) echo "" ;;  # no required key
    apt-upgrade) echo "APT_UPGRADE" ;;
    add-repo)    echo "APT_REPOSITORIES" ;;
    install-defaults) echo "DEFAULT_PACKAGES" ;;
  esac
}

if [[ "$NONINTERACTIVE" == "false" ]]; then
  # Check if all required keys for enabled sections are present in .env
  auto_ok=true
  auto_missing=()
  for sec in "${SECTIONS[@]}"; do
    is_enabled "$sec" || continue
    rk=$(required_keys_for_section "$sec")
    [[ -z "$rk" ]] && continue
    # ssh-key has special handling: ssh_key.pub file counts too
    if [[ "$rk" == "SSH_PUBLIC_KEY" ]]; then
      if [[ -z "${ENV[$rk]:-}" ]] && [[ ! -f "${SCRIPT_DIR}/ssh_key.pub" ]]; then
        auto_ok=false; auto_missing+=("$rk")
      fi
    else
      if [[ -z "${ENV[$rk]:-}" ]]; then
        auto_ok=false; auto_missing+=("$rk")
      fi
    fi
  done
  if [[ "$auto_ok" == "true" ]] && (( ${#auto_missing[@]} == 0 )); then
    NONINTERACTIVE="true"
    info "Auto-detected fully configured .env — running non-interactive"
  fi
fi

# ===========================================================================
# NONINTERACTIVE preflight — validate everything BEFORE touching the system
# ===========================================================================
# Required keys for any enabled section must be present
for sec in "${SECTIONS[@]}"; do
  is_enabled "$sec" || continue
  rk=$(required_keys_for_section "$sec")
  [[ -z "$rk" ]] && continue
  if [[ "$rk" == "SSH_PUBLIC_KEY" ]]; then
    if [[ -z "${ENV[$rk]:-}" ]] && [[ ! -f "${SCRIPT_DIR}/ssh_key.pub" ]]; then
      require_env "$rk"
    fi
  else
    require_env "$rk"
  fi
done

if [[ "$NONINTERACTIVE" == "true" ]]; then
  if (( ${#MISSING_REQUIRED[@]} > 0 )); then
    err "NONINTERACTIVE=true but required variables are missing:"
    for k in "${MISSING_REQUIRED[@]}"; do printf '    - %s\n' "$k"; done
    exit 2
  fi

  # Validate .env values up-front
  if is_enabled timezone && [[ -n "${ENV[TIMEZONE]:-}" ]]; then
    validate_timezone "${ENV[TIMEZONE]}" || exit 2
  fi
  if is_enabled hostname; then
    hn="${CLI_HOSTNAME_VALUE:-${ENV[HOSTNAME]:-}}"
    [[ -n "$hn" ]] && validate_hostname "$hn" || exit 2
  fi
  if is_enabled firewall && [[ -n "${ENV[FIREWALL_EXTRA_PORTS]:-}" ]]; then
    IFS=',' read -ra _pl <<< "${ENV[FIREWALL_EXTRA_PORTS]}"
    for _p in "${_pl[@]}"; do
      _p="${_p// /}"; [[ -z "$_p" ]] && continue
      validate_port_spec "$_p" || exit 2
    done
  fi
  if is_enabled swap && [[ -n "${ENV[SWAP_SIZE_MB]:-}" ]]; then
    [[ "${ENV[SWAP_SIZE_MB]}" =~ ^[0-9]+$ ]] || \
      { err "SWAP_SIZE_MB must be an integer"; exit 2; }
  fi
  if is_enabled fail2ban; then
    if [[ -n "${ENV[FAIL2BAN_BANTIME]:-}" ]]; then
      [[ "${ENV[FAIL2BAN_BANTIME]}" =~ ^[0-9]+[mhd]?$ ]] || \
        { err "FAIL2BAN_BANTIME must be like 1h, 30m, 1d, or 3600"; exit 2; }
    fi
    if [[ -n "${ENV[FAIL2BAN_FINDTIME]:-}" ]]; then
      [[ "${ENV[FAIL2BAN_FINDTIME]}" =~ ^[0-9]+[mhd]?$ ]] || \
        { err "FAIL2BAN_FINDTIME must be like 1h, 30m, 1d, or 3600"; exit 2; }
    fi
    if [[ -n "${ENV[FAIL2BAN_MAXRETRY]:-}" ]]; then
      validate_positive_int "FAIL2BAN_MAXRETRY" "${ENV[FAIL2BAN_MAXRETRY]}" || exit 2
    fi
  fi
  ok "All .env values valid"
fi

# ===========================================================================
# Show plan
# ===========================================================================
section "Plan"
info "Sections enabled: $(for s in "${SECTIONS[@]}"; do is_enabled "$s" && printf '%s ' "$s"; done)"
info "Mode: $([[ "$NONINTERACTIVE" == "true" ]] && echo non-interactive || echo interactive)"
[[ -f "$ENV_FILE" ]] && info "Config: $ENV_FILE"
echo

# ===========================================================================
# Section: timezone
# ===========================================================================
section_timezone() {
  section "Timezone"
  current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
  info "Current timezone: $current_tz"
  new_tz=$(env_or_prompt "TIMEZONE (e.g. Asia/Shanghai, UTC)" "$current_tz") || return 1
  validate_timezone "$new_tz" || return 1
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
}

# ===========================================================================
# Section: hostname
# ===========================================================================
section_hostname() {
  section "Hostname"
  current_host=$(hostnamectl hostname 2>/dev/null || hostname)
  info "Current hostname: $current_host"
  new_host=$(env_or_prompt "HOSTNAME" "$current_host") || return 1
  validate_hostname "$new_host" || return 1
  if [[ "$new_host" != "$current_host" ]]; then
    hostnamectl set-hostname "$new_host"
    if ! grep -qE "[[:space:]]${new_host}([[:space:]]|$)" /etc/hosts; then
      echo "127.0.1.1 $new_host" >> /etc/hosts
      info "Added 127.0.1.1 $new_host to /etc/hosts"
    fi
    ok "Hostname set to $new_host"
  else
    info "No change"
  fi
}

# ===========================================================================
# Section: firewall
# ===========================================================================
section_firewall() {
  section "Firewall (UFW)"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw is not installed — installing"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ufw
  fi

  info "Current UFW status:"
  ufw status verbose || true

  fw_apply="${ENV[FIREWALL_APPLY]:-}"
  fw_decided=false
  [[ "$fw_apply" =~ ^[Tt]rue$ ]]  && { fw_apply=true;  fw_decided=true; }
  [[ "$fw_apply" =~ ^[Ff]alse$ ]] && { fw_apply=false; fw_decided=true; }

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
        validate_port_spec "$p" || return 1
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
}

# ===========================================================================
# Section: ssh-key
# ===========================================================================
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

section_ssh_key() {
  section "SSH key installation (for $TARGET_USER)"
  local ssh_dir="$TARGET_HOME/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"

  local key_file="${SCRIPT_DIR}/ssh_key.pub"
  local file_pubkey=""
  if [[ -f "$key_file" ]]; then
    file_pubkey=$(awk '{$1=$1; print}' "$key_file" | tr -d '\r')
    info "Loaded public key from $key_file"
  fi

  local env_pubkey="${ENV[SSH_PUBLIC_KEY]:-}"
  if [[ -z "$file_pubkey" ]] && [[ -n "$env_pubkey" ]]; then
    # Strip CRLF in case the value came from a Windows-saved file or quoted paste
    file_pubkey="${env_pubkey//$'\r'/}"
    info "Loaded public key from .env SSH_PUBLIC_KEY"
  fi

  if [[ -f "$auth_keys" ]] && [[ -s "$auth_keys" ]]; then
    ok "authorized_keys already exists at $auth_keys"
    info "Existing keys:"
    awk '{print "    " NR": " substr($0,1,40) "..."}' "$auth_keys"

    if [[ -n "$file_pubkey" ]] && ! grep -qxF "$file_pubkey" "$auth_keys"; then
      local append_pref="${ENV[SSH_PUBLIC_KEY_APPEND]:-}"
      if [[ "$append_pref" =~ ^[Tt]rue$ ]]; then
        echo "$file_pubkey" >> "$auth_keys"
        chown "$TARGET_USER":"$TARGET_USER" "$auth_keys"
        ok "Appended public key"
      elif [[ "$NONINTERACTIVE" == "true" ]]; then
        # Silent skip is dangerous — admin may think new key was installed
        warn "SSH_PUBLIC_KEY provided but not in authorized_keys — set SSH_PUBLIC_KEY_APPEND=true to install"
      elif ask "Append ssh_key.pub to authorized_keys"; then
        echo "$file_pubkey" >> "$auth_keys"
        chown "$TARGET_USER":"$TARGET_USER" "$auth_keys"
        ok "Appended public key"
      fi
    fi
  else
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_keys"
    chmod 600 "$auth_keys"
    chown -R "$TARGET_USER":"$TARGET_USER" "$ssh_dir"

    if [[ -n "$file_pubkey" ]]; then
      echo "$file_pubkey" >> "$auth_keys"
      chown "$TARGET_USER":"$TARGET_USER" "$auth_keys"
      ok "Installed public key for $TARGET_USER"
    elif [[ "$NONINTERACTIVE" == "true" ]]; then
      err "No public key available (need ssh_key.pub or SSH_PUBLIC_KEY) and NONINTERACTIVE=true"
      return 1
    elif ask "No authorized_keys found — paste a public key now to install it"; then
      echo "  Paste the public key (starts with ssh-rsa / ssh-ed25519 / ecdsa-sha2-):"
      read -r pubkey
      if [[ -z "$pubkey" ]]; then
        err "No key provided — skipping"
      else
        echo "$pubkey" >> "$auth_keys"
        chown "$TARGET_USER":"$TARGET_USER" "$auth_keys"
        ok "Public key installed for $TARGET_USER"
      fi
    else
      info "Skipped — add a key manually later"
    fi
  fi
}

# ===========================================================================
# Section: swap
# ===========================================================================
section_swap() {
  section "Swap file"
  local swap_size_mb
  swap_size_mb=$(env_or_prompt "SWAP_SIZE_MB" "0") || return 1
  if ! [[ "$swap_size_mb" =~ ^[0-9]+$ ]]; then
    err "SWAP_SIZE_MB must be an integer (got: '$swap_size_mb')"
    return 1
  fi

  if (( swap_size_mb > 0 )); then
    local swap_file="/swapfile"
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
      if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
      fi
      sysctl -w vm.swappiness=10 >/dev/null
      if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
      fi
      ok "Swap enabled (${swap_size_mb}MB, swappiness=10)"
    fi
  else
    info "SWAP_SIZE_MB=0 — skipping swap configuration"
  fi
}

# ===========================================================================
# Section: fail2ban
# ===========================================================================
section_fail2ban() {
  section "fail2ban"
  local f2b_enabled
  f2b_enabled=$(env_or_prompt "FAIL2BAN_ENABLED" "true") || return 1

  if [[ "$f2b_enabled" =~ ^[Tt]rue$ ]]; then
    if ! command -v fail2ban-client >/dev/null 2>&1; then
      info "Installing fail2ban"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq fail2ban
    else
      info "fail2ban already installed"
    fi

    local bantime="${ENV[FAIL2BAN_BANTIME]:-1h}"
    local findtime="${ENV[FAIL2BAN_FINDTIME]:-10m}"
    local maxretry="${ENV[FAIL2BAN_MAXRETRY]:-5}"
    validate_positive_int "FAIL2BAN_MAXRETRY" "$maxretry" || return 1

    local jail_local="/etc/fail2ban/jail.local"
    local managed_marker="Managed by production-server-script"
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
}

# ===========================================================================
# Section: ssh-harden (advisory)
# ===========================================================================
section_ssh_harden() {
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
  warn "Applying PasswordAuthentication=no without a working key will lock you out."
  warn "Before applying, verify you can log in via key in a NEW terminal session:"
  echo "    ssh ${TARGET_USER}@<server>"
  echo

  if [[ "$NONINTERACTIVE" == "true" ]] || ask "Show the exact sed commands you would run manually"; then
    cat <<EOF

  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.\$(date +%F)
  sudo sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/'  /etc/ssh/sshd_config
  sudo sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  sudo sed -i 's/^#\\?PubkeyAuthentication.*/PubkeyAuthentication yes/'     /etc/ssh/sshd_config
  sudo sshd -t && sudo systemctl reload ssh

EOF
  fi
}

# ===========================================================================
# Section: add-repo — add 3rd-party APT repositories, then apt update
# Configured via APT_REPOSITORIES in .env:
#   APT_REPOSITORIES="name1|url1|suite1|component1|key_url1;name2|url2|..."
# Or a simpler key=value list:
#   APT_REPOSITORIES="docker|https://download.docker.com/linux/ubuntu"
# When the flag is passed, only this section runs (default behavior of section
# registry) — it does NOT trigger apt-upgrade.
# ===========================================================================
section_add_repo() {
  section "add 3rd-party APT repositories"
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found — skipping (this script targets Debian/Ubuntu)"
    return 0
  fi

  local raw="${ENV[APT_REPOSITORIES]:-}"
  if [[ -z "$raw" ]] && [[ "$NONINTERACTIVE" != "true" ]]; then
    read -r -p "  Enter APT_REPOSITORIES (blank to skip): " raw
  fi
  if [[ -z "$raw" ]]; then
    info "No APT_REPOSITORIES configured — skipping"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    apt-get install -y -qq curl ca-certificates
  fi

  local added=0 skipped=0
  IFS=';' read -ra repos <<< "$raw"
  for entry in "${repos[@]}"; do
    entry="${entry## }"; entry="${entry%% }"
    [[ -z "$entry" ]] && continue

    # Format A: name|url|suite|components|key_url
    # Format B: name|url  (suite/components/key are auto/optional)
    IFS='|' read -ra parts <<< "$entry"
    local name="${parts[0]:-}"
    local url="${parts[1]:-}"
    local suite="${parts[2]:-}"
    local comps="${parts[3]:-}"
    local key_url="${parts[4]:-}"

    if [[ -z "$name" || -z "$url" ]]; then
      warn "Skipping malformed entry: $entry"
      skipped=$((skipped+1))
      continue
    fi

    local list_file="/etc/apt/sources.list.d/${name}.list"
    if [[ -f "$list_file" ]]; then
      info "$list_file already exists — skipping"
      skipped=$((skipped+1))
      continue
    fi

    # Auto-fill suite + components if not given
    if [[ -z "$suite" ]]; then
      suite="$(. /etc/os-release 2>/dev/null && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
      [[ -z "$suite" ]] && { warn "Could not detect distro codename — provide suite explicitly for $name"; skipped=$((skipped+1)); continue; }
    fi
    if [[ -z "$comps" ]]; then comps="main"; fi

    # Fetch signing key FIRST so we don't leave a broken sources.list if the fetch fails.
    # Skip sources.list write entirely on key fetch failure.
    local key_ok=true
    if [[ -n "$key_url" ]]; then
      mkdir -p /etc/apt/keyrings
      local fetch_cmd
      if command -v curl >/dev/null 2>&1; then
        fetch_cmd="curl -fsSL"
      else
        fetch_cmd="wget -qO-"
      fi
      if $fetch_cmd "$key_url" | gpg --dearmor -o "/etc/apt/keyrings/${name}.gpg" >/dev/null 2>&1; then
        ok "Fetched key for $name"
      else
        warn "Failed to fetch key for $name from $key_url — skipping sources.list write"
        skipped=$((skipped+1))
        key_ok=false
      fi
    else
      warn "No key URL for $name — you may need to add the signing key manually"
    fi

    if [[ "$key_ok" == "true" ]]; then
      echo "deb [signed-by=/etc/apt/keyrings/${name}.gpg] ${url} ${suite} ${comps}" > "$list_file"
      ok "Wrote $list_file"
      added=$((added+1))
    fi
  done

  info "Running apt-get update"
  apt-get update -qq
  ok "add-repo complete (added=$added skipped=$skipped)"
}

# ===========================================================================
# Section: apt-upgrade
# ===========================================================================
section_apt_upgrade() {
  section "apt update + upgrade"
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found — skipping (this script targets Debian/Ubuntu)"
    return 0
  fi

  local apply
  apply=$(env_or_prompt "APT_UPGRADE (true/false)" "true") || return 1
  if ! [[ "$apply" =~ ^[Tt]rue$ ]]; then
    info "APT_UPGRADE=$apply — skipping"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  info "Running apt-get update"
  apt-get update -qq
  info "Running apt-get upgrade"
  apt-get upgrade -y -qq
  if [[ "${ENV[APT_AUTOREMOVE]:-false}" =~ ^[Tt]rue$ ]]; then
    info "Running apt-get autoremove"
    apt-get autoremove -y -qq
  fi
  ok "apt update + upgrade complete"
}

# ===========================================================================
# Section: install-defaults — install baseline server packages
# Configured via DEFAULT_PACKAGES in .env (space-separated).
# Users comment out or remove packages they don't want. Idempotent: skips
# packages already installed. --install-defaults / -p (or DEFAULT_PACKAGES set
# in .env) is required to run this section.
# ===========================================================================
section_install_defaults() {
  section "install baseline server packages"
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found — skipping (this script targets Debian/Ubuntu)"
    return 0
  fi

  local raw="${ENV[DEFAULT_PACKAGES]:-}"
  if [[ -z "$raw" ]] && [[ "$NONINTERACTIVE" != "true" ]]; then
    read -r -p "  Enter DEFAULT_PACKAGES (blank to skip): " raw
  fi
  if [[ -z "$raw" ]]; then
    info "No DEFAULT_PACKAGES configured — skipping"
    return 0
  fi

  # Parse space-separated list, support inline comments (#)
  local to_install=()
  for p in $raw; do
    [[ "$p" =~ ^# ]] && continue
    [[ -z "$p" ]] && continue
    if dpkg -s "$p" >/dev/null 2>&1; then
      info "already installed: $p"
    else
      to_install+=("$p")
    fi
  done

  if (( ${#to_install[@]} == 0 )); then
    ok "All DEFAULT_PACKAGES already installed"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  info "Installing: ${to_install[*]}"
  if apt-get install -y -qq "${to_install[@]}"; then
    ok "Installed ${#to_install[@]} package(s)"
  else
    warn "Some packages failed to install — check apt output above"
    return 1
  fi
}

# ===========================================================================
# Dispatch — run only enabled sections
# ===========================================================================
SECTIONS_RUN=()
SECTIONS_FAILED=()

run_section() {
  local name="$1"; shift
  if is_enabled "$name"; then
    if "$@"; then
      SECTIONS_RUN+=("$name")
    else
      SECTIONS_FAILED+=("$name")
      warn "Section '$name' reported an error — continuing"
    fi
  fi
}

run_section timezone    section_timezone
run_section hostname    section_hostname
run_section firewall    section_firewall
run_section ssh-key     section_ssh_key
run_section swap        section_swap
run_section fail2ban    section_fail2ban
run_section ssh-harden  section_ssh_harden
run_section apt-upgrade section_apt_upgrade
run_section add-repo    section_add_repo
run_section install-defaults section_install_defaults

# ===========================================================================
# Summary
# ===========================================================================
section "Summary"
if (( ${#SECTIONS_RUN[@]} > 0 )); then
  for s in "${SECTIONS_RUN[@]}"; do ok "ran: $s"; done
fi
if is_enabled timezone;  then ok "Timezone:     $(timedatectl show -p Timezone --value 2>/dev/null)"; fi
if is_enabled hostname;  then ok "Hostname:     $(hostnamectl hostname 2>/dev/null)"; fi
if is_enabled firewall;  then ok "UFW status:   $(ufw status 2>/dev/null | head -n1)"; fi
if is_enabled swap;      then
  swap_summary=$(swapon --show --noheadings 2>/dev/null | awk '{print $3, $4}' | tr '\n' ' ')
  [[ -z "$swap_summary" ]] && swap_summary="none"
  ok "Swap:         $swap_summary"
fi
if is_enabled fail2ban;  then ok "fail2ban:     $(systemctl is-active fail2ban 2>/dev/null || echo inactive)"; fi
if is_enabled ssh-key;   then
  ssh_dir="$TARGET_HOME/.ssh"
  auth_keys="$ssh_dir/authorized_keys"
  ok "SSH keys:     $([[ -s "$auth_keys" ]] && echo "installed ($auth_keys)" || echo "NONE")"
fi
if is_enabled apt-upgrade; then
  pkg_count=$(dpkg -l 2>/dev/null | wc -l)
  ok "apt:          $pkg_count packages on system"
fi
if is_enabled add-repo; then
  repo_count=$(ls /etc/apt/sources.list.d/*.list 2>/dev/null | wc -l)
  ok "APT repos:    $repo_count sources.list files"
fi
if is_enabled install-defaults; then
  installed=0
  for p in ${ENV[DEFAULT_PACKAGES]:-}; do
    [[ -z "$p" || "$p" =~ ^# ]] && continue
    dpkg -s "$p" >/dev/null 2>&1 && installed=$((installed+1))
  done
  ok "DEFAULT_PACKAGES:  $installed installed"
fi
if (( ${#SECTIONS_FAILED[@]} > 0 )); then
  warn "Failed sections: ${SECTIONS_FAILED[*]}"
fi
echo
info "Review the SSH hardening section above before disabling password auth."
