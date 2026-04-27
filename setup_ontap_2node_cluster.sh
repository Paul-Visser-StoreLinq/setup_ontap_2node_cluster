#!/usr/bin/env bash
# ==============================================================================
# setup_ontap_2node_cluster.sh
#
# PURPOSE
#   Automates the initial provisioning of a 2-node NetApp ONTAP cluster.
#   The script connects to the cluster management IP over SSH and issues
#   ONTAP CLI commands to build a standard storage environment from scratch.
#   It is fully idempotent: every step checks whether the object already
#   exists before attempting to create it, so re-running the script after a
#   partial failure or to add missing objects is safe.
#
# WHAT IT CONFIGURES  (in order)
#   1. NTP servers
#   2. Data aggregates  (one per node, using spare disks)
#   3. VLAN ports        (e.g. e0d-20) on each node
#   4. Broadcast domains (bd_cifs on Default ipspace, bd_vlan20 on Default)
#   5. Storage Virtual Machines / SVMs
#        svm_cifs01  — CIFS protocol
#        svm_nfs01   — NFS protocol
#        svm_iscsi01 — iSCSI protocol
#   6. Export policies + rules for CIFS and NFS SVMs
#   7. LIFs  (one per node per SVM, IPs assigned from configured start address)
#   8. Volumes (configurable count per SVM, round-robin across aggregates)
#
# PREREQUISITES
#   - Bash 4.0 or later  (uses arrays and mapfile)
#   - SSH access to the ONTAP cluster management IP
#     Authentication order: SSH key → sshpass (password) → interactive
#   - sshpass (optional, for unattended password auth)
#     macOS: brew install hudochenkov/sshpass/sshpass
#   - The cluster must already be initialised (cluster setup complete)
#   - Sufficient spare disks available on each node
#
# USAGE
#   ./setup_ontap_2node_cluster.sh [OPTIONS]
#
#   --config FILE          Config file to use  (default: setup_ontap_2node_cluster.conf)
#   --dry-run              Print actions without executing any write operations
#   --verbose              Enable DEBUG-level log output
#   --color auto|always|never  Coloured log output  (default: auto)
#   -h, --help             Show this help message
#
# CONFIGURATION
#   All deployment-specific values live in the companion .conf file.
#   The minimum required settings are:
#     CLUSTER_MGMT_IP    — management IP of the cluster
#     CLUSTER_NAME       — base name; nodes are derived as <name>-01 / <name>-02
#     CIFS_START_IP      — first IP to assign to CIFS LIFs
#     NFS_ISCSI_START_IP — first IP to assign to NFS/iSCSI LIFs
#     LIF_NETMASK_CIFS / LIF_NETMASK_NFS_ISCSI
#
# NOTES
#   - The "Cluster" broadcast domain lives in ipspace "Cluster"; the script
#     removes base ports from that domain before creating VLAN ports on them.
#   - ONTAP SSH sessions return \r\n line endings; the script strips \r where
#     command output is used as a variable value.
#   - Failover groups are not created (deprecated in modern ONTAP).
#
# VERSION HISTORY
# ------------------------------------------------------------------------------
# v3.7.0  2026-04-27  Bug fixes from live testing:
#                       - CLUSTER_NAME default corrected to na-clus01
#                       - Cluster broadcast domain queries use -ipspace Cluster
#                       - Strip \r from vserver show output (ONTAP SSH \r\n)
#                       - Suppress noisy stdout from best-effort bd remove
#                       - Port-in-broadcast-domain check uses exists_cmd
#                         instead of brittle output parsing
#                       - ensure_vserver falls back to name-based check before
#                         attempting to create (handles prior partial runs)
# v3.6.0  2026-04-24  CLUSTER_NAME drives node names (clustername-01/02)
#                     NODES is derived; no longer set in config
# v3.5.0  2026-04-24  Network ports driven by config (CIFS_PORTS, VLAN20_BASE_PORTS)
#                     Falls back to NODES+CIFS_HOME_PORT / NODES+VLAN20_BASE_PORT
# v3.4.0  2026-04-20  Removed IPspace: always uses Default ipspace
#                     No new vserver created if one for that protocol exists
#                     Removed unused variables and functions
# v3.3.0  2026-04-16  Synchronized config/script variable names
# v3.2.6  (original)
# ==============================================================================
set -euo pipefail

SCRIPT_VERSION="v3.7.0"
SCRIPT_DATE="2026-04-27"

# =========================
# Defaults
# =========================
CONFIG_FILE="setup_ontap_2node_cluster.conf"
VERBOSE=0
DRY_RUN=0
COLOR_MODE="auto"
LOG_DIR="./logs"
LOG_FILE=""

CREATED_COUNT=0
SKIPPED_COUNT=0
WARN_COUNT=0
FAILED_COUNT=0

# Global return value for ensure_vserver()
SVM_RESULT=""

# SSH auth mode: 0=interactive/key, 1=sshpass
SSH_USE_SSHPASS=0

# Port arrays — populated from config or built from NODES + base port defaults
CIFS_PORTS=()
VLAN20_BASE_PORTS=()
VLAN20_PORTS=()   # derived: VLAN20_BASE_PORTS + VLAN_ID

# =========================
# Logging
# =========================
setup_colors() {
  local enable=0
  case "$COLOR_MODE" in
    always) enable=1 ;;
    never)  enable=0 ;;
    auto)   [[ -t 1 ]] && enable=1 || enable=0 ;;
  esac

  if [[ "$enable" -eq 1 ]]; then
    C_RESET='\033[0m'
    C_INFO='\033[0;36m'
    C_WARN='\033[1;33m'
    C_ERR='\033[0;31m'
    C_SUM='\033[1;32m'
    C_DBG='\033[0;35m'
  else
    C_RESET=''; C_INFO=''; C_WARN=''; C_ERR=''; C_SUM=''; C_DBG=''
  fi
}

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    INFO|WARN|ERROR|DEBUG|DRYRUN) ;;
    SUMMARY)
      # SUMMARY goes to stdout so it can be piped/captured separately
      printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
      return 0
      ;;
    *) level="INFO" ;;
  esac
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}

record_created() { CREATED_COUNT=$((CREATED_COUNT + 1)); }
record_skipped() { SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); }
record_warn()    { WARN_COUNT=$((WARN_COUNT + 1)); }
record_failed()  { FAILED_COUNT=$((FAILED_COUNT + 1)); }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--config FILE] [--dry-run] [--verbose] [--color auto|always|never]

Version: ${SCRIPT_VERSION} (${SCRIPT_DATE})

Options:
  --config FILE   Config file to source
  --dry-run       Log actions without executing write operations
  --verbose       Enable debug logging
  --color MODE    auto|always|never
  -h, --help      Show this help

Requirements:
  - SSH access to NETAPP_USER@CLUSTER_MGMT_IP (key or password)
  - Bash 4.0+  (no other local dependencies)
USAGE
}

# =========================
# Args / config
# =========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "--config requires a file argument" >&2; exit 1; }
      CONFIG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --color)
      [[ $# -ge 2 ]] || { echo "--color requires a mode argument" >&2; exit 1; }
      COLOR_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || { echo "--config is required" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Parse EXCLUDED_IPS from comma-separated string to array
if [[ -n "${EXCLUDED_IPS:-}" ]]; then
  IFS=',' read -ra EXCLUDED_IPS <<< "$EXCLUDED_IPS"
fi

# --- Config alias: COLOR_OUTPUT (config) → COLOR_MODE (script) ---
# Support both names so the config value COLOR_OUTPUT also works
if [[ -n "${COLOR_OUTPUT:-}" && "${COLOR_MODE}" == "auto" ]]; then
  COLOR_MODE="$COLOR_OUTPUT"
fi

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/netapp-cluster-${SCRIPT_VERSION}-$(date +%Y%m%d-%H%M%S).log"
setup_colors

# =========================
# Validate config variables
# =========================
: "${CLUSTER_MGMT_IP:?CLUSTER_MGMT_IP missing in config}"
: "${CLUSTER_NAME:?CLUSTER_NAME missing in config}"
: "${AGGR_PREFIX:=aggr_data}"
: "${AGGR_DISKCOUNT:=8}"
: "${AGGR_RAIDTYPE:=raid_dp}"
: "${AGGR_SPARE_RESERVE:=1}"
: "${VSERVER_BASE_cifs:=svm_cifs01}"
: "${VSERVER_BASE_nfs:=svm_nfs01}"
: "${VSERVER_BASE_iscsi:=svm_iscsi01}"
: "${VSERVER_PROTOCOLS_cifs:=cifs}"
: "${VSERVER_PROTOCOLS_nfs:=nfs}"
: "${VSERVER_PROTOCOLS_iscsi:=iscsi}"
: "${CIFS_HOME_PORT:=e0c}"
: "${VLAN20_BASE_PORT:=e0d}"
: "${VLAN_ID:=20}"
: "${CIFS_MTU:=1500}"
: "${NFS_ISCSI_MTU:=9000}"
: "${BROADCAST_DOMAIN_CIFS:=bd_cifs}"
: "${BROADCAST_DOMAIN_VLAN20:=bd_vlan20}"
: "${CIFS_START_IP:?CIFS_START_IP missing in config}"
: "${NFS_ISCSI_START_IP:?NFS_ISCSI_START_IP missing in config}"
: "${LIF_NETMASK_CIFS:?LIF_NETMASK_CIFS missing in config}"
: "${LIF_NETMASK_NFS_ISCSI:?LIF_NETMASK_NFS_ISCSI missing in config}"
: "${EXCLUDED_IPS:=}"
: "${VOL_PREFIX:=vol}"
: "${VOLUMES_PER_SVM:=2}"
: "${VOL_SIZE:=100G}"
: "${JUNCTION_BASE:=/}"
: "${EXPORT_CLIENTMATCH:=0.0.0.0/0}"
: "${EXPORT_RORULE:=any}"
: "${EXPORT_RWRULE:=any}"

# --- NETAPP_USER: config may use SSH_USER, script uses NETAPP_USER ---
# Support both; SSH_USER is used as fallback if NETAPP_USER is not set.
if [[ -z "${NETAPP_USER:-}" ]]; then
  NETAPP_USER="${SSH_USER:-admin}"
fi

# --- NTP: config uses NTP_SERVERS (array), NTP_SERVER for compatibility ---
if [[ -z "${NTP_SERVER:-}" ]]; then
  NTP_SERVER="${NTP_SERVERS[0]:-}"
fi

# Normalize excluded IPs so config can use array or comma-separated string
if [[ -n "${EXCLUDED_IPS:-}" ]]; then
  if ! declare -p EXCLUDED_IPS 2>/dev/null | grep -q 'declare -a'; then
    IFS=', ' read -ra EXCLUDED_IPS <<< "${EXCLUDED_IPS}"
  fi
fi

# --- Derive node names from CLUSTER_NAME ---
NODES=("${CLUSTER_NAME}-01" "${CLUSTER_NAME}-02")

# --- Port arrays ---
# If CIFS_PORTS was not defined in config, build it from NODES + CIFS_HOME_PORT.
if [[ "${#CIFS_PORTS[@]}" -eq 0 ]]; then
  for _n in "${NODES[@]}"; do CIFS_PORTS+=("${_n}:${CIFS_HOME_PORT}"); done
fi

# If VLAN20_BASE_PORTS was not defined in config, build from NODES + VLAN20_BASE_PORT.
if [[ "${#VLAN20_BASE_PORTS[@]}" -eq 0 ]]; then
  for _n in "${NODES[@]}"; do VLAN20_BASE_PORTS+=("${_n}:${VLAN20_BASE_PORT}"); done
fi

# Derive VLAN20_PORTS (actual VLAN port name per node) from VLAN20_BASE_PORTS + VLAN_ID.
VLAN20_PORTS=()
for _bp in "${VLAN20_BASE_PORTS[@]}"; do
  VLAN20_PORTS+=("${_bp%:*}:${_bp#*:}-${VLAN_ID}")
done
unset _n _bp

# =========================
# SSH helpers
# =========================
# Base options without BatchMode so password auth also works.
# BatchMode=yes is tried first (key-auth); on failure reconnects
# without BatchMode so SSH can prompt for a password.
SSH_OPTS=(-T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o ServerAliveInterval=30 -o LogLevel=ERROR)
SSH_OPTS_BATCH=("${SSH_OPTS[@]}" -o BatchMode=yes)

check_ssh_connectivity() {
  log "INFO" "Checking SSH connection to ${NETAPP_USER}@${CLUSTER_MGMT_IP} ..."

  # Try key-based auth first (no interaction)
  if ssh "${SSH_OPTS_BATCH[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null 2>&1; then
    log "INFO" "SSH connection successful (key-based authentication)."
    return 0
  fi

  # Key-auth failed: try password via sshpass
  log "INFO" "Key-based authentication not available, trying password..."

  # Try to install sshpass if not available
  if ! command -v sshpass >/dev/null 2>&1; then
    log "INFO" "sshpass not available."
    echo -n "Install sshpass with brew? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      if command -v brew >/dev/null 2>&1; then
        log "INFO" "Installing sshpass..."
        if brew install hudochenkov/sshpass/sshpass; then
          log "INFO" "sshpass installed successfully."
        else
          log "WARN" "Could not install sshpass."
        fi
      else
        log "WARN" "brew not available, cannot install sshpass."
      fi
    else
      log "INFO" "sshpass installation skipped."
    fi
  fi

  if command -v sshpass >/dev/null 2>&1 && [[ -n "${NETAPP_PASSWORD:-}" ]]; then
    export SSHPASS="$NETAPP_PASSWORD"
    # sshpass available and password set via NETAPP_PASSWORD environment variable
    if sshpass -e ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null 2>&1; then
      log "INFO" "SSH connection successful (sshpass password auth)."
      SSH_USE_SSHPASS=1
      return 0
    else
      log "ERROR" "SSH connection failed with sshpass. Check NETAPP_PASSWORD."
      exit 1
    fi
  fi

  # No sshpass: allow interactive connection
  log "INFO" "No sshpass or NETAPP_PASSWORD found."
  log "INFO" "SSH will interactively prompt for a password on each command."
  log "WARN" "Tip: export NETAPP_PASSWORD and install sshpass for automation."
  SSH_USE_SSHPASS=0

  # Test whether connection is possible at all (interactive)
  if ! ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null; then
    log "ERROR" "SSH connection failed to ${CLUSTER_MGMT_IP} as user ${NETAPP_USER}."
    exit 1
  fi
  log "INFO" "SSH connection successful (password)."
}

_ssh_exec() {
  # Central SSH execution function: automatically selects key-, sshpass- or password auth
  if [[ "${SSH_USE_SSHPASS:-0}" -eq 1 ]]; then
    sshpass -e ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "$@"
  else
    ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "$@"
  fi
}

run_remote() {
  local cmd="$1"
  [[ "$VERBOSE" -eq 1 ]] && log "DEBUG" "RUN: $cmd"
  _ssh_exec "$cmd" 2>&1
}

run_write() {
  local cmd="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRYRUN" "$cmd"
    return 0
  fi
  _ssh_exec "$cmd" 2>&1
}

safe_change() {
  local desc="$1" cmd="$2"
  local output
  if output="$(run_write "$cmd" 2>&1)" && [[ $? -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "INFO" "Dry-run: $desc"
    else
      log "INFO" "$desc"
    fi
    record_created
    return 0
  else
    log "ERROR" "Failed: $desc"
    log "DEBUG" "ONTAP command failed: $cmd"
    log "DEBUG" "ONTAP error output: $output"
    record_failed
    return 1
  fi
}

exists_cmd() {
  local cmd="$1"
  local out
  out="$(run_remote "$cmd" || true)"

  # Strip SSH banners, blank lines and known noise
  out="$(printf '%s\n' "$out" \
    | grep -Ev '^(Warning: Permanently added|Last login|Authorized users only|This system is)' \
    | sed '/^[[:space:]]*$/d' \
    || true)"

  [[ "$VERBOSE" -eq 1 ]] && log "DEBUG" "exists_cmd output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"

  # Empty = object does not exist
  [[ -z "$out" ]] && return 1

  # ONTAP "not found" messages — match as broadly as possible
  # Tested against: "There are no entries matching your query."
  #                 "Error: show failed: Aggregate "x" does not exist."
  #                 "no entries were found"
  if printf '%s\n' "$out" | grep -Eiq \
    'no entries|not found|does not exist|doesn.t exist|this table is currently empty|0 entries|matching your query|show failed|invalid|is an invalid'; then
    return 1
  fi

  return 0
}

# =========================
# Utility
# =========================
next_ip() {
  local base_ip="$1" offset="$2"
  # Pure Bash implementation: no python3 needed
  local a b c d
  IFS='.' read -r a b c d <<< "$base_ip"
  local num=$(( (a << 24) + (b << 16) + (c << 8) + d + offset ))
  printf '%d.%d.%d.%d\n' \
    $(( (num >> 24) & 255 )) \
    $(( (num >> 16) & 255 )) \
    $(( (num >>  8) & 255 )) \
    $(( num & 255 ))
}

is_ip_used() {
  local ip="$1"
  local result
  result="$(run_remote "network interface show -address ${ip}" 2>/dev/null || true)"
  log "DEBUG" "Checking if IP ${ip} is used, result: $(echo "$result" | head -3 | tr '\n' '|')"
  if echo "$result" | grep -q "There are no entries matching your query"; then
    return 1  # Not used
  else
    return 0  # Used
  fi
}

next_available_ip() {
  local base_ip="$1" offset="$2"
  local candidate_ip current_offset="$offset"

  log "DEBUG" "next_available_ip called with base_ip=$base_ip, offset=$offset"
  log "DEBUG" "EXCLUDED_IPS has ${#EXCLUDED_IPS[@]} elements"
  for i in "${!EXCLUDED_IPS[@]}"; do
    log "DEBUG" "EXCLUDED_IPS[$i] = '${EXCLUDED_IPS[$i]}'"
  done

  while true; do
    candidate_ip="$(next_ip "$base_ip" "$current_offset")"

    # Check if this IP is in the exclusion list
    local is_excluded=0
    for excluded_ip in "${EXCLUDED_IPS[@]}"; do
      if [[ "$candidate_ip" == "$excluded_ip" ]]; then
        log "DEBUG" "IP $candidate_ip is excluded, trying next"
        is_excluded=1
        break
      fi
    done

    if [[ $is_excluded -eq 1 ]]; then
      current_offset=$((current_offset + 1))
      continue
    fi

    if is_ip_used "$candidate_ip"; then
      log "DEBUG" "IP $candidate_ip is already in use, trying next"
      current_offset=$((current_offset + 1))
      continue
    fi

    log "DEBUG" "Using available IP: $candidate_ip"
    printf '%s\n' "$candidate_ip"
    return 0
  done
}

# =========================
# Config steps
# =========================
ensure_ntp() {
  # Process all NTP servers from NTP_SERVERS array; fall back to NTP_SERVER
  local servers=()
  if [[ "${#NTP_SERVERS[@]}" -gt 0 ]] 2>/dev/null; then
    servers=("${NTP_SERVERS[@]}")
  elif [[ -n "${NTP_SERVER:-}" ]]; then
    servers=("$NTP_SERVER")
  else
    log "INFO" "No NTP server configured, step skipped"
    return 0
  fi

  for srv in "${servers[@]}"; do
    if exists_cmd "cluster time-service ntp server show -server ${srv}"; then
      log "INFO" "NTP server ${srv} already exists"
      record_skipped
    else
      safe_change "Add NTP server ${srv}" \
        "cluster time-service ntp server create -server ${srv}"
    fi
  done
}

count_spare_disks_for_node() {
  local node="$1"
  local raw count
  raw="$(run_remote "storage disk show -node ${node} -container-type spare" || true)"
  log "DEBUG" "Raw spare disks output for ${node}: $(printf '%s' "$raw" | head -10 | tr '\n' '|')"
  # Filter lines that match disk names (e.g., NET-1.11, NET-2.28)
  count="$(printf '%s\n' "$raw" | tail -n +2 | grep -Ec '^[A-Z]+-[0-9]+\.[0-9]+[[:space:]]' || true)"
  printf '%s\n' "$count"
}

ensure_data_aggr_per_node() {
  local required_disks="${AGGR_DISKCOUNT}"
  local reserve="${AGGR_SPARE_RESERVE}"
  # Total spare disks needed = aggregate disks + spare reserve
  local min_spares=$(( required_disks + reserve ))

  for node in "${NODES[@]}"; do
    local aggr="${AGGR_PREFIX}_${node//-/_}"

    if exists_cmd "storage aggregate show -aggregate ${aggr}"; then
      log "INFO" "Data aggregate ${aggr} already exists"
      record_skipped
      continue
    fi

    local spare_count
    spare_count="$(count_spare_disks_for_node "$node")"
    log "INFO" "Node ${node}: ${spare_count} spare disks available (needed: ${required_disks} + ${reserve} reserve = ${min_spares})"

    if [[ "$spare_count" -ge "$min_spares" ]]; then
      safe_change "Create data aggregate ${aggr} on ${node} (${spare_count} spare, ${reserve} reserve kept)" \
        "storage aggregate create -aggregate ${aggr} -node ${node} -diskcount ${required_disks} -raidtype ${AGGR_RAIDTYPE}"
      # Short pause between aggregate creations to avoid SSH rate limiting
      sleep 2
    else
      log "WARN" "Node ${node}: insufficient spare disks for ${aggr} (${spare_count} available, ${min_spares} needed incl. ${reserve} reserve)"
      record_warn
    fi
  done
}

ensure_vlan20_ports() {
  for port_spec in "${VLAN20_BASE_PORTS[@]}"; do
    local node="${port_spec%:*}" base_port="${port_spec#*:}"
    local vlan_name="${base_port}-${VLAN_ID}"
    # Remove the base port from the Cluster broadcast domain if needed
    if exists_cmd "network port broadcast-domain show -ipspace Cluster -broadcast-domain Cluster -ports ${node}:${base_port}"; then
      safe_change "Remove port ${node}:${base_port} from Cluster broadcast domain" \
        "network port broadcast-domain remove-ports -ipspace Cluster -broadcast-domain Cluster -ports ${node}:${base_port}"
    fi
    if exists_cmd "network port vlan show -node ${node} -vlan-name ${vlan_name}"; then
      log "INFO" "VLAN port ${node}:${vlan_name} already exists"
      record_skipped
    else
      safe_change "Create VLAN port ${node}:${vlan_name}" \
        "network port vlan create -node ${node} -port ${base_port} -vlan-id ${VLAN_ID}"
    fi
  done
}

ensure_port_mtu_all() {
  # In ONTAP the port MTU follows the broadcast domain automatically.
  # MTU must be set on the broadcast domain, not directly on the port.
  # network port modify fails if the port is already in a broadcast domain.
  # We update the MTU on the broadcast domain if it already exists,
  # otherwise the MTU is passed during broadcast-domain create (see ensure_broadcast_domain).
  for bd_name in "$BROADCAST_DOMAIN_CIFS" "$BROADCAST_DOMAIN_VLAN20"; do
    local mtu
    if [[ "$bd_name" == "$BROADCAST_DOMAIN_CIFS" ]]; then
      mtu="$CIFS_MTU"
    else
      mtu="$NFS_ISCSI_MTU"
    fi
    if exists_cmd "network port broadcast-domain show -broadcast-domain ${bd_name} -ipspace Default"; then
      safe_change "Set MTU ${mtu} on broadcast domain ${bd_name}" \
        "network port broadcast-domain modify -broadcast-domain ${bd_name} -ipspace Default -mtu ${mtu}" || true
    fi
  done
}

ensure_broadcast_domain() {
  local bd_name="$1" mtu="$2"
  shift 2
  local ports=("$@")
  local port_csv
  port_csv="$(IFS=,; echo "${ports[*]}")"

  # Verify all ports exist
  for port in "${ports[@]}"; do
    local node="${port%:*}" port_name="${port#*:}"
    if ! exists_cmd "network port show -node ${node} -port ${port_name}"; then
      log "ERROR" "Port ${port} does not exist on node ${node}. Check the configuration."
      record_failed
      return 1
    fi
  done

  # Best-effort: remove ports from Default broadcast domain before reassigning.
  # Suppress all output — the port may already be unassigned or in another domain.
  for port in "${ports[@]}"; do
    run_remote "network port broadcast-domain remove-ports -broadcast-domain Default -ports ${port}" > /dev/null 2>&1 || true
  done

  if exists_cmd "network port broadcast-domain show -broadcast-domain ${bd_name} -ipspace Default"; then
    log "INFO" "Broadcast domain ${bd_name} already exists"
    # Add any ports not yet in the broadcast domain, using ONTAP's own filter to check.
    for port in "${ports[@]}"; do
      if exists_cmd "network port broadcast-domain show -broadcast-domain ${bd_name} -ipspace Default -ports ${port}"; then
        log "DEBUG" "Port ${port} already in broadcast domain ${bd_name}"
      else
        safe_change "Add port ${port} to broadcast domain ${bd_name}" \
          "network port broadcast-domain add-ports -broadcast-domain ${bd_name} -ipspace Default -ports ${port}"
      fi
    done
    record_skipped
  else
    safe_change "Create broadcast domain ${bd_name}" \
      "network port broadcast-domain create -broadcast-domain ${bd_name} -ipspace Default -mtu ${mtu} -ports ${port_csv}"
  fi

  # Note: Failover groups are deprecated in modern ONTAP.
  # LIFs can fail over automatically without explicit failover groups.
}

build_ports_for_cifs() {
  printf '%s\n' "${CIFS_PORTS[@]}"
}

build_ports_for_vlan20() {
  printf '%s\n' "${VLAN20_PORTS[@]}"
}

ensure_vserver() {
  local proto_type="${1:-}"
  if [[ -z "$proto_type" ]]; then
    log "ERROR" "ensure_vserver expects 1 argument (type)"
    record_failed
    return 1
  fi

  local base_var="VSERVER_BASE_${proto_type}"
  local proto_var="VSERVER_PROTOCOLS_${proto_type}"
  local base_name protocols root_aggr existing_svm

  eval "base_name=\${${base_var}}"
  eval "protocols=\${${proto_var}}"
  root_aggr="${AGGR_PREFIX}_${NODES[0]//-/_}"

  # Check if a vserver with this protocol already exists; if so, use it.
  # tr -d '\r' strips the carriage returns ONTAP SSH sessions add to line endings.
  existing_svm="$(run_remote "vserver show -allowed-protocols ${protocols} -fields vserver" 2>/dev/null \
    | tr -d '\r' \
    | grep -v '^vserver\|^---\|^[[:space:]]*$\|There are no entries' \
    | awk '{print $1}' | head -1 || true)"

  if [[ -n "$existing_svm" ]]; then
    log "INFO" "Vserver ${existing_svm} for protocol ${proto_type} already exists"
    record_skipped
    SVM_RESULT="$existing_svm"
    return 0
  fi

  # Also check by name: the vserver may exist from a prior run where protocol
  # assignment failed or the protocol-based query above missed it.
  if exists_cmd "vserver show -vserver ${base_name}"; then
    log "INFO" "Vserver ${base_name} already exists (found by name)"
    record_skipped
    SVM_RESULT="$base_name"
    return 0
  fi

  safe_change "Create vserver ${base_name} (${proto_type})" \
    "vserver create -vserver ${base_name} -subtype default -rootvolume ${base_name}_root -rootvolume-security-style unix -aggregate ${root_aggr}"

  safe_change "Enable protocols ${protocols} for ${base_name}" \
    "vserver modify -vserver ${base_name} -allowed-protocols ${protocols}" || true

  SVM_RESULT="$base_name"
  return 0
}

ensure_export_policy() {
  local svm="$1"
  local policy="exp_${svm}"
  if exists_cmd "vserver export-policy show -vserver ${svm} -policyname ${policy}"; then
    log "INFO" "Export policy ${policy} already exists"
    record_skipped
  else
    safe_change "Create export policy ${policy}" \
      "vserver export-policy create -vserver ${svm} -policyname ${policy}"
    safe_change "Create export policy rule for ${policy}" \
      "vserver export-policy rule create -vserver ${svm} -policyname ${policy} -ruleindex 1 -protocol any -clientmatch ${EXPORT_CLIENTMATCH} -rorule ${EXPORT_RORULE} -rwrule ${EXPORT_RWRULE}"
  fi
}

ensure_lifs_for_cifs() {
  local svm="$1" offset_base="${2:-0}" i=0
  for port_spec in "${CIFS_PORTS[@]}"; do
    local node="${port_spec%:*}" port_name="${port_spec#*:}"
    local lif="lif_cifs_${node//-/_}" ip

    if ! exists_cmd "network port show -node ${node} -port ${port_name}"; then
      log "ERROR" "Port ${port_name} does not exist on node ${node}. Check the configuration."
      record_failed
      i=$((i+1))
      continue
    fi

    if ! exists_cmd "network port broadcast-domain show -broadcast-domain ${BROADCAST_DOMAIN_CIFS} -ipspace Default -ports ${node}:${port_name}"; then
      log "ERROR" "Port ${port_name} on node ${node} is not in broadcast domain ${BROADCAST_DOMAIN_CIFS}. Check the configuration."
      record_failed
      i=$((i+1))
      continue
    fi

    ip="$(next_available_ip "$CIFS_START_IP" $((offset_base + i)))"
    if exists_cmd "network interface show -vserver ${svm} -lif ${lif}"; then
      log "INFO" "LIF ${svm}:${lif} already exists"
      record_skipped
    else
      log "DEBUG" "Creating CIFS LIF ${svm}:${lif} with IP ${ip} on port ${port_name} for node ${node}"
      safe_change "Create CIFS LIF ${svm}:${lif} with IP ${ip}" \
        "network interface create -vserver ${svm} -lif ${lif} -service-policy default-data-files -home-node ${node} -home-port ${port_name} -address ${ip} -netmask ${LIF_NETMASK_CIFS}"
      sleep 2
    fi
    i=$((i+1))
  done
}

ensure_lifs_for_vlan20_svm() {
  local svm="$1" lif_prefix="$2" offset_base="${3:-0}" i=0
  for port_spec in "${VLAN20_PORTS[@]}"; do
    local node="${port_spec%:*}" vlan_port="${port_spec#*:}"
    local lif="${lif_prefix}_${node//-/_}" ip
    ip="$(next_available_ip "$NFS_ISCSI_START_IP" $((offset_base + i)))"
    if exists_cmd "network interface show -vserver ${svm} -lif ${lif}"; then
      log "INFO" "LIF ${svm}:${lif} already exists"
      record_skipped
    else
      safe_change "Create VLAN20 LIF ${svm}:${lif} with IP ${ip}" \
        "network interface create -vserver ${svm} -lif ${lif} -service-policy default-data-files -home-node ${node} -home-port ${vlan_port} -address ${ip} -netmask ${LIF_NETMASK_NFS_ISCSI}"
      sleep 2
    fi
    i=$((i+1))
  done
}

ensure_volumes() {
  local svm="$1"
  local proto_type="${2:-}"
  if [[ -z "$proto_type" ]]; then
    log "ERROR" "ensure_volumes expects 2 arguments (svm, type)"
    record_failed
    return 1
  fi

  local node_count="${#NODES[@]}"
  local aggr1="${AGGR_PREFIX}_${NODES[0]//-/_}"
  local aggr2="${AGGR_PREFIX}_${NODES[1]//-/_}"
  local policy="exp_${svm}"

  for i in $(seq 1 "${VOLUMES_PER_SVM}"); do
    local vol="${VOL_PREFIX}_${proto_type}_${i}"

    # Round-robin distribution across nodes
    local node_idx=$(( (i - 1) % node_count ))
    local aggr
    if [[ "$node_idx" -eq 0 ]]; then
      aggr="$aggr1"
    else
      aggr="$aggr2"
    fi

    if exists_cmd "volume show -vserver ${svm} -volume ${vol}"; then
      log "INFO" "Volume ${svm}:${vol} already exists"
      record_skipped
      continue
    fi

    local cmd="volume create -vserver ${svm} -volume ${vol} -aggregate ${aggr} -size ${VOL_SIZE} -state online -space-guarantee none"
    if [[ "$proto_type" == "nfs" || "$proto_type" == "cifs" ]]; then
      local junction="${JUNCTION_BASE%/}/${vol}"
      cmd+=" -junction-path ${junction} -policy ${policy}"
    fi

    safe_change "Create volume ${svm}:${vol} on ${aggr}" "$cmd"
  done
}

print_summary() {
  log "SUMMARY" "=============================="
  log "SUMMARY" "Run completed  (${SCRIPT_VERSION})"
  log "SUMMARY" "Created:  ${CREATED_COUNT}"
  log "SUMMARY" "Skipped:  ${SKIPPED_COUNT}"
  log "SUMMARY" "Warnings: ${WARN_COUNT}"
  log "SUMMARY" "Failed:   ${FAILED_COUNT}"
  log "SUMMARY" "Log file: ${LOG_FILE}"
  log "SUMMARY" "=============================="
}

main() {
  log "INFO" "=============================="
  log "INFO" "Starting NetApp cluster setup ${CLUSTER_MGMT_IP}"
  log "INFO" "Version:       ${SCRIPT_VERSION} (${SCRIPT_DATE})"
  log "INFO" "Config:        ${CONFIG_FILE}"
  log "INFO" "Log file:      ${LOG_FILE}"
  log "INFO" "Verbose:       ${VERBOSE} | Dry-run: ${DRY_RUN} | Color: ${COLOR_MODE}"
  log "INFO" "User:          ${NETAPP_USER}"
  log "INFO" "Nodes:         ${NODES[*]}"
  log "INFO" "RAID type:     ${AGGR_RAIDTYPE} | Disks: ${AGGR_DISKCOUNT} | Spare reserve: ${AGGR_SPARE_RESERVE}"
  log "INFO" "=============================="

  # Prompt for password at startup if not already set
  if [[ -z "${NETAPP_PASSWORD:-}" ]]; then
    echo -n "Enter password for ${NETAPP_USER}@${CLUSTER_MGMT_IP}: "
    read -s NETAPP_PASSWORD
    echo ""
    export SSHPASS="$NETAPP_PASSWORD"
    SSH_USE_SSHPASS=1
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    check_ssh_connectivity
  else
    log "INFO" "Dry-run mode: SSH connectivity check skipped"
  fi

  ensure_ntp
  ensure_data_aggr_per_node
  ensure_vlan20_ports
  ensure_port_mtu_all

  mapfile -t cifs_ports   < <(build_ports_for_cifs)
  mapfile -t vlan20_ports < <(build_ports_for_vlan20)

  ensure_broadcast_domain "$BROADCAST_DOMAIN_CIFS"   "$CIFS_MTU"      "${cifs_ports[@]}"
  ensure_broadcast_domain "$BROADCAST_DOMAIN_VLAN20" "$NFS_ISCSI_MTU" "${vlan20_ports[@]}"

  local svm_cifs svm_nfs svm_iscsi
  svm_cifs="" svm_nfs="" svm_iscsi=""

  ensure_vserver cifs
  svm_cifs="$SVM_RESULT"

  ensure_vserver nfs
  svm_nfs="$SVM_RESULT"

  ensure_vserver iscsi
  svm_iscsi="$SVM_RESULT"

  # Export policy only for CIFS and NFS (not for iSCSI)
  ensure_export_policy "$svm_cifs"
  ensure_export_policy "$svm_nfs"

  ensure_lifs_for_cifs       "$svm_cifs"  0
  ensure_lifs_for_vlan20_svm "$svm_nfs"   "lif_nfs"   0
  ensure_lifs_for_vlan20_svm "$svm_iscsi" "lif_iscsi" 2

  ensure_volumes "$svm_cifs"  cifs
  ensure_volumes "$svm_nfs"   nfs
  ensure_volumes "$svm_iscsi" iscsi

  print_summary
}

main "$@"
