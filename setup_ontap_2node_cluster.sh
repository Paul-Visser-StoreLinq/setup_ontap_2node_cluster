#!/usr/bin/env bash
# ==============================================================================
# netapp-2node-setup.sh
# Configureert een NetApp ONTAP 2-node cluster via SSH (ONTAP CLI).
#
# VERSIE BEHEER
# ------------------------------------------------------------------------------
# v3.3.0  2026-04-16  Config/script variabelenamen gesynchroniseerd:
#                       - SSH_USER  → NETAPP_USER (beide worden nu ondersteund)
#                       - NTP_SERVERS (array) → correct verwerkt, alle servers
#                       - COLOR_OUTPUT → COLOR_MODE (beide worden ondersteund)
#                     AGGR_RAIDTYPE toegevoegd aan aggregate create commando
#                     AGGR_SPARE_RESERVE: spare-disk check houdt reserve aan
#                     NTP_VERSION verwijderd uit config (niet relevant voor ONTAP)
#                     Versie-beheer changelog toegevoegd bovenaan script
# v3.2.9  2026-04-16  FIX dry-run loop: find_available_vserver_name keert
#                     direct terug in dry-run (SSH-fout werd als "bestaat" gezien)
# v3.2.8  2026-04-16  FIX vserver naamgeneratie: regex ^(.*[^0-9])([0-9]+)$
#                     zodat next_num suffix correct vervangt (was: plakte erachter)
# v3.2.7  2026-04-16  FIX iSCSI export policy aanroep verwijderd
#                     FIX ensure_volumes: round-robin aggregate verdeling
#                     FIX build_ports: ${out[@]} i.p.v. ${out[*]}
#                     FIX run_remote: debug label "READ" → "RUN"
#                     FIX log SUMMARY: naar stdout i.p.v. stderr
#                     Toevoeging: SSH-connectiviteitscheck bij opstarten
# v3.2.6  (origineel)
# ==============================================================================
set -euo pipefail

SCRIPT_VERSION="v3.3.0"
SCRIPT_DATE="2026-04-16"

# =========================
# Defaults
# =========================
CONFIG_FILE=""
VERBOSE=0
DRY_RUN=0
COLOR_MODE="auto"
LOG_DIR="./logs"
LOG_FILE=""

CREATED_COUNT=0
SKIPPED_COUNT=0
WARN_COUNT=0
FAILED_COUNT=0

# Globale terugkeerwaarde voor ensure_vserver()
SVM_RESULT=""

# SSH auth modus: 0=interactief/key, 1=sshpass
SSH_USE_SSHPASS=0

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
      # SUMMARY gaat naar stdout zodat het apart te pipen/capturen is
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

Versie: ${SCRIPT_VERSION} (${SCRIPT_DATE})

Options:
  --config FILE   Config file to source
  --dry-run       Log actions without executing write operations
  --verbose       Enable debug logging
  --color MODE    auto|always|never
  -h, --help      Show this help

Vereisten:
  - SSH key-based authenticatie naar NETAPP_USER@CLUSTER_MGMT_IP
  - python3 beschikbaar op het lokale systeem
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

# --- Config alias: COLOR_OUTPUT (config) → COLOR_MODE (script) ---
# Ondersteun beide namen zodat de config-waarde COLOR_OUTPUT ook werkt
if [[ -n "${COLOR_OUTPUT:-}" && "${COLOR_MODE}" == "auto" ]]; then
  COLOR_MODE="$COLOR_OUTPUT"
fi

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/netapp-cluster-${SCRIPT_VERSION}-$(date +%Y%m%d-%H%M%S).log"
setup_colors

# =========================
# Valideer config variabelen
# =========================
: "${CLUSTER_MGMT_IP:?CLUSTER_MGMT_IP ontbreekt in config}"
: "${NODES:?NODES ontbreekt in config}"
: "${IPSPACE_NAME:=ipspace_data}"
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
: "${FAILOVER_GROUP_CIFS:=fg_cifs}"
: "${FAILOVER_GROUP_VLAN20:=fg_vlan20}"
: "${CIFS_START_IP:?CIFS_START_IP ontbreekt in config}"
: "${NFS_ISCSI_START_IP:?NFS_ISCSI_START_IP ontbreekt in config}"
: "${LIF_NETMASK_CIFS:?LIF_NETMASK_CIFS ontbreekt in config}"
: "${LIF_NETMASK_NFS_ISCSI:?LIF_NETMASK_NFS_ISCSI ontbreekt in config}"
: "${VOL_PREFIX:=vol}"
: "${VOLUMES_PER_SVM:=2}"
: "${VOL_SIZE:=100G}"
: "${JUNCTION_BASE:=/}"
: "${EXPORT_CLIENTMATCH:=0.0.0.0/0}"
: "${EXPORT_RORULE:=any}"
: "${EXPORT_RWRULE:=any}"

# --- NETAPP_USER: config gebruikt SSH_USER, script gebruikt NETAPP_USER ---
# Ondersteun beide; SSH_USER heeft voorrang als NETAPP_USER niet gezet is.
if [[ -z "${NETAPP_USER:-}" ]]; then
  NETAPP_USER="${SSH_USER:-admin}"
fi

# --- NTP: config gebruikt NTP_SERVERS (array), voor compatibiliteit ook NTP_SERVER ---
if [[ -z "${NTP_SERVER:-}" ]]; then
  NTP_SERVER="${NTP_SERVERS[0]:-}"
fi

# =========================
# SSH helpers
# =========================
# Basisopties zonder BatchMode zodat wachtwoordauth ook werkt.
# BatchMode=yes wordt eerst geprobeerd (key-auth); bij falen wordt
# opnieuw verbonden zonder BatchMode zodat SSH om een wachtwoord kan vragen.
SSH_OPTS=(-T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o ServerAliveInterval=30 -o LogLevel=ERROR)
SSH_OPTS_BATCH=("${SSH_OPTS[@]}" -o BatchMode=yes)

check_ssh_connectivity() {
  log "INFO" "Controleer SSH-verbinding naar ${NETAPP_USER}@${CLUSTER_MGMT_IP} ..."

  # Probeer eerst key-based auth (geen interactie)
  if ssh "${SSH_OPTS_BATCH[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null 2>&1; then
    log "INFO" "SSH-verbinding succesvol (key-based authenticatie)."
    return 0
  fi

  # Key-auth mislukt: vraag om wachtwoord via sshpass of interactief
  log "INFO" "Key-based authenticatie niet beschikbaar, probeer wachtwoord..."

  if command -v sshpass >/dev/null 2>&1 && [[ -n "${NETAPP_PASSWORD:-}" ]]; then
    # sshpass beschikbaar en wachtwoord in omgevingsvariabele NETAPP_PASSWORD
    if sshpass -e ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null 2>&1; then
      log "INFO" "SSH-verbinding succesvol (sshpass wachtwoordauth)."
      # Herdefinieer run-functies om sshpass te gebruiken
      SSH_USE_SSHPASS=1
      return 0
    else
      log "ERROR" "SSH-verbinding mislukt met sshpass. Controleer NETAPP_PASSWORD."
      exit 1
    fi
  fi

  # Geen sshpass: maak interactieve verbinding mogelijk
  log "INFO" "Geen sshpass of NETAPP_PASSWORD gevonden."
  log "INFO" "SSH zal interactief om een wachtwoord vragen bij elke opdracht."
  log "WARN" "Tip: exporteer NETAPP_PASSWORD en installeer sshpass voor automatisering."
  SSH_USE_SSHPASS=0

  # Test of verbinding überhaupt mogelijk is (interactief)
  if ! ssh "${SSH_OPTS[@]}" "${NETAPP_USER}@${CLUSTER_MGMT_IP}" "version" >/dev/null; then
    log "ERROR" "SSH-verbinding mislukt naar ${CLUSTER_MGMT_IP} als gebruiker ${NETAPP_USER}."
    exit 1
  fi
  log "INFO" "SSH-verbinding succesvol (wachtwoord)."
}

_ssh_exec() {
  # Centrale SSH-uitvoerfunctie: kiest automatisch key-, sshpass- of wachtwoordauth
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
  if run_write "$cmd" >>"$LOG_FILE" 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "INFO" "Dry-run: $desc"
    else
      log "INFO" "$desc"
    fi
    record_created
    return 0
  else
    log "ERROR" "Mislukt: $desc"
    record_failed
    return 1
  fi
}

exists_cmd() {
  local cmd="$1"
  local out
  out="$(run_remote "$cmd" || true)"

  # Verwijder SSH-banners, lege regels en bekende ruis
  out="$(printf '%s\n' "$out" \
    | grep -Ev '^(Warning: Permanently added|Last login|Authorized users only|This system is)' \
    | sed '/^[[:space:]]*$/d' \
    || true)"

  [[ "$VERBOSE" -eq 1 ]] && log "DEBUG" "exists_cmd output: $(printf '%s' "$out" | head -3 | tr '\n' '|')"

  # Leeg = object bestaat niet
  [[ -z "$out" ]] && return 1

  # ONTAP "niet gevonden" meldingen — zo breed mogelijk matchen
  # Getest tegen: "There are no entries matching your query."
  #               "Error: show failed: Aggregate "x" does not exist."
  #               "no entries were found"
  if printf '%s\n' "$out" | grep -Eiq \
    'no entries|not found|does not exist|doesn.t exist|this table is currently empty|0 entries|matching your query|show failed'; then
    return 1
  fi

  return 0
}

# =========================
# Utility
# =========================
next_ip() {
  local base_ip="$1" offset="$2"
  # Pure Bash implementatie: geen python3 nodig
  local a b c d
  IFS='.' read -r a b c d <<< "$base_ip"
  local num=$(( (a << 24) + (b << 16) + (c << 8) + d + offset ))
  printf '%d.%d.%d.%d\n' \
    $(( (num >> 24) & 255 )) \
    $(( (num >> 16) & 255 )) \
    $(( (num >>  8) & 255 )) \
    $(( num & 255 ))
}

find_available_vserver_name() {
  local base_name="$1"

  # In dry-run zijn er geen echte SSH-antwoorden. exists_cmd zou de
  # SSH-foutmelding als "niet-leeg" zien en altijd true teruggeven,
  # waardoor de while-lus nooit stopt. Dus: direct base_name teruggeven.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s\n' "$base_name"
    return 0
  fi

  if ! exists_cmd "vserver show -vserver ${base_name}"; then
    printf '%s\n' "$base_name"
    return 0
  fi

  local prefix width next_num candidate
  if [[ "$base_name" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    local suffix="${BASH_REMATCH[2]}"
    width="${#suffix}"
    next_num=$((10#$suffix + 1))
  else
    prefix="${base_name}_"
    width=2
    next_num=2
  fi

  while :; do
    candidate="${prefix}$(printf "%0${width}d" "$next_num")"
    if ! exists_cmd "vserver show -vserver ${candidate}"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    next_num=$((next_num + 1))
  done
}

# =========================
# Config steps
# =========================
ensure_ntp() {
  # Verwerk alle NTP servers uit NTP_SERVERS array; val terug op NTP_SERVER
  local servers=()
  if [[ "${#NTP_SERVERS[@]}" -gt 0 ]] 2>/dev/null; then
    servers=("${NTP_SERVERS[@]}")
  elif [[ -n "${NTP_SERVER:-}" ]]; then
    servers=("$NTP_SERVER")
  else
    log "INFO" "Geen NTP server geconfigureerd, stap overgeslagen"
    return 0
  fi

  for srv in "${servers[@]}"; do
    if exists_cmd "cluster time-service ntp server show -server ${srv}"; then
      log "INFO" "NTP server ${srv} bestaat al"
      record_skipped
    else
      safe_change "Voeg NTP server ${srv} toe" \
        "cluster time-service ntp server create -server ${srv}"
    fi
  done
}

count_spare_disks_for_node() {
  local node="$1"
  local raw count
  raw="$(run_remote "storage aggregate show-spare-disks -original-owner ${node}" || true)"
  raw="$(printf '%s\n' "$raw" | grep -Ev '^(Warning: Permanently added|Last login)' || true)"
  count="$({
    printf '%s\n' "$raw" | awk '
      NF == 0 { next }
      /^Note:/ { next }
      /^Original Owner/ { next }
      /^Owner/ { next }
      /^Pool[[:space:]]+/ { next }
      /^Local/ { next }
      /^Spare/ { next }
      /^Disk[[:space:]]+/ { next }
      /^-+[[:space:]]*$/ { next }
      /^[[:space:]]*[0-9]+\.[0-9]+/ { c++ }
      END { print c+0 }
    '
  })"
  printf '%s\n' "$count"
}

ensure_data_aggr_per_node() {
  local required_disks="${AGGR_DISKCOUNT}"
  local reserve="${AGGR_SPARE_RESERVE}"
  # Totaal benodigde spare disks = aggregate disks + spare reserve
  local min_spares=$(( required_disks + reserve ))

  for node in "${NODES[@]}"; do
    local aggr="${AGGR_PREFIX}_${node//-/_}"

    if exists_cmd "storage aggregate show -aggregate ${aggr}"; then
      log "INFO" "Doelaggregate ${aggr} bestaat al"
      record_skipped
      continue
    fi

    # Controleer of er al een niet-root data aggregate bestaat op deze node
    # (anders dan de root aggr die begint met aggr0_)
    # Gebruik expliciete node-filter en sluit root aggregates uit
    local existing_data_aggr
    existing_data_aggr="$(run_remote "storage aggregate show -node ${node} -fields aggregate,node" || true)"
    existing_data_aggr="$(printf '%s\n' "$existing_data_aggr" | grep -v '^aggr0_' | grep -v 'aggregate' | grep -v 'matching your query' | grep -v '^[[:space:]]*$' || true)"
    if [[ -n "$existing_data_aggr" ]]; then
      log "INFO" "Node ${node} heeft al een non-root data aggregate, geen nieuwe create"
      record_skipped
      continue
    fi

    local spare_count
    spare_count="$(count_spare_disks_for_node "$node")"
    [[ "$VERBOSE" -eq 1 ]] && log "DEBUG" "Node ${node}: ${spare_count} spare disks beschikbaar (nodig: ${required_disks} + ${reserve} reserve = ${min_spares})"

    if [[ "$spare_count" -ge "$min_spares" ]]; then
      safe_change "Maak data aggregate ${aggr} op ${node} (${spare_count} spare, ${reserve} reserve aangehouden)" \
        "storage aggregate create -aggregate ${aggr} -node ${node} -diskcount ${required_disks} -raidtype ${AGGR_RAIDTYPE}"
    else
      log "WARN" "Node ${node}: onvoldoende spare disks voor ${aggr} (${spare_count} beschikbaar, ${min_spares} nodig incl. ${reserve} reserve)"
      record_warn
    fi
  done
}

ensure_ipspace() {
  if exists_cmd "network ipspace show -ipspace ${IPSPACE_NAME}"; then
    log "INFO" "IPspace ${IPSPACE_NAME} bestaat al"
    record_skipped
  else
    safe_change "Maak IPspace ${IPSPACE_NAME}" "network ipspace create -ipspace ${IPSPACE_NAME}"
  fi
}

ensure_vlan20_ports() {
  for node in "${NODES[@]}"; do
    local vlan_name="${VLAN20_BASE_PORT}-${VLAN_ID}"
    if exists_cmd "network port vlan show -node ${node} -vlan-name ${vlan_name}"; then
      log "INFO" "VLAN port ${node}:${vlan_name} bestaat al"
      record_skipped
    else
      safe_change "Maak VLAN port ${node}:${vlan_name}" \
        "network port vlan create -node ${node} -port ${VLAN20_BASE_PORT} -vlan-id ${VLAN_ID}"
    fi
  done
}

ensure_port_mtu_all() {
  # In ONTAP volgt de port-MTU automatisch het broadcast domain.
  # De MTU moet op het broadcast domain gezet worden, niet op de port direct.
  # network port modify faalt als de port al in een broadcast domain zit.
  # We passen de MTU aan op het broadcast domain als dat al bestaat,
  # anders wordt de MTU meegegeven bij broadcast-domain create (zie ensure_broadcast_domain).
  for bd_name in "$BROADCAST_DOMAIN_CIFS" "$BROADCAST_DOMAIN_VLAN20"; do
    local mtu
    if [[ "$bd_name" == "$BROADCAST_DOMAIN_CIFS" ]]; then
      mtu="$CIFS_MTU"
    else
      mtu="$NFS_ISCSI_MTU"
    fi
    if exists_cmd "network port broadcast-domain show -broadcast-domain ${bd_name} -ipspace ${IPSPACE_NAME}"; then
      safe_change "Zet MTU ${mtu} op broadcast domain ${bd_name}" \
        "network port broadcast-domain modify -broadcast-domain ${bd_name} -ipspace ${IPSPACE_NAME} -mtu ${mtu}" || true
    fi
  done
}

ensure_broadcast_domain() {
  local bd_name="$1" fg_name="$2" mtu="$3"
  shift 3
  local ports=("$@")
  local port_csv
  port_csv="$(IFS=,; echo "${ports[*]}")"

  if exists_cmd "network port broadcast-domain show -broadcast-domain ${bd_name} -ipspace ${IPSPACE_NAME}"; then
    log "INFO" "Broadcast domain ${bd_name} bestaat al"
    record_skipped
  else
    safe_change "Maak broadcast domain ${bd_name}" \
      "network port broadcast-domain create -broadcast-domain ${bd_name} -ipspace ${IPSPACE_NAME} -mtu ${mtu} -ports ${port_csv}"
  fi

  if exists_cmd "network interface failover-groups show -vserver Cluster -failover-group ${fg_name}"; then
    log "INFO" "Failover group ${fg_name} bestaat al"
    record_skipped
  else
    safe_change "Maak failover group ${fg_name}" \
      "network interface failover-groups create -vserver Cluster -failover-group ${fg_name} -targets ${port_csv}"
  fi
}

build_ports_for_cifs() {
  local out=()
  for node in "${NODES[@]}"; do out+=("${node}:${CIFS_HOME_PORT}"); done
  printf '%s\n' "${out[@]}"
}

build_ports_for_vlan20() {
  local out=() vlan_port="${VLAN20_BASE_PORT}-${VLAN_ID}"
  for node in "${NODES[@]}"; do out+=("${node}:${vlan_port}"); done
  printf '%s\n' "${out[@]}"
}

ensure_vserver() {
  local proto_type="${1:-}"
  if [[ -z "$proto_type" ]]; then
    log "ERROR" "ensure_vserver verwacht 1 argument (type)"
    record_failed
    return 1
  fi

  local base_var="VSERVER_BASE_${proto_type}"
  local proto_var="VSERVER_PROTOCOLS_${proto_type}"
  local base_name protocols svm root_aggr

  eval "base_name=\${${base_var}}"
  eval "protocols=\${${proto_var}}"

  svm="$(find_available_vserver_name "$base_name")"
  root_aggr="${AGGR_PREFIX}_${NODES[0]//-/_}"

  if exists_cmd "vserver show -vserver ${svm}"; then
    log "INFO" "Vserver ${svm} (${proto_type}) bestaat al"
    record_skipped
  else
    safe_change "Maak vserver ${svm} (${proto_type})" \
      "vserver create -vserver ${svm} -subtype default -rootvolume ${svm}_root -rootvolume-security-style unix -rootvolume-aggregate ${root_aggr} -aggregate-limit 0 -ipspace ${IPSPACE_NAME}"
  fi

  safe_change "Enable protocols ${protocols} voor ${svm}" \
    "vserver modify -vserver ${svm} -allowed-protocols ${protocols}" || true

  SVM_RESULT="$svm"
  return 0
}

ensure_export_policy() {
  local svm="$1"
  local policy="exp_${svm}"
  if exists_cmd "vserver export-policy show -vserver ${svm} -policyname ${policy}"; then
    log "INFO" "Export policy ${policy} bestaat al"
    record_skipped
  else
    safe_change "Maak export policy ${policy}" \
      "vserver export-policy create -vserver ${svm} -policyname ${policy}"
    safe_change "Maak export policy rule voor ${policy}" \
      "vserver export-policy rule create -vserver ${svm} -policyname ${policy} -ruleindex 1 -protocol any -clientmatch ${EXPORT_CLIENTMATCH} -rorule ${EXPORT_RORULE} -rwrule ${EXPORT_RWRULE}"
  fi
}

ensure_lifs_for_cifs() {
  local svm="$1" offset_base="${2:-0}" i=0
  for node in "${NODES[@]}"; do
    local lif="lif_cifs_${node//-/_}" ip
    ip="$(next_ip "$CIFS_START_IP" $((offset_base + i)))"
    if exists_cmd "network interface show -vserver ${svm} -lif ${lif}"; then
      log "INFO" "LIF ${svm}:${lif} bestaat al"
      record_skipped
    else
      safe_change "Maak CIFS LIF ${svm}:${lif} met IP ${ip}" \
        "network interface create -vserver ${svm} -lif ${lif} -service-policy default-data-files -home-node ${node} -home-port ${CIFS_HOME_PORT} -address ${ip} -netmask ${LIF_NETMASK_CIFS} -failover-group ${FAILOVER_GROUP_CIFS}"
    fi
    i=$((i+1))
  done
}

ensure_lifs_for_vlan20_svm() {
  local svm="$1" lif_prefix="$2" offset_base="${3:-0}" i=0 vlan_port="${VLAN20_BASE_PORT}-${VLAN_ID}"
  for node in "${NODES[@]}"; do
    local lif="${lif_prefix}_${node//-/_}" ip
    ip="$(next_ip "$NFS_ISCSI_START_IP" $((offset_base + i)))"
    if exists_cmd "network interface show -vserver ${svm} -lif ${lif}"; then
      log "INFO" "LIF ${svm}:${lif} bestaat al"
      record_skipped
    else
      safe_change "Maak VLAN20 LIF ${svm}:${lif} met IP ${ip}" \
        "network interface create -vserver ${svm} -lif ${lif} -service-policy default-data-files -home-node ${node} -home-port ${vlan_port} -address ${ip} -netmask ${LIF_NETMASK_NFS_ISCSI} -failover-group ${FAILOVER_GROUP_VLAN20}"
    fi
    i=$((i+1))
  done
}

ensure_volumes() {
  local svm="$1"
  local proto_type="${2:-}"
  if [[ -z "$proto_type" ]]; then
    log "ERROR" "ensure_volumes verwacht 2 argumenten (svm, type)"
    record_failed
    return 1
  fi

  local node_count="${#NODES[@]}"
  local aggr1="${AGGR_PREFIX}_${NODES[0]//-/_}"
  local aggr2="${AGGR_PREFIX}_${NODES[1]//-/_}"
  local policy="exp_${svm}"

  for i in $(seq 1 "${VOLUMES_PER_SVM}"); do
    local vol="${VOL_PREFIX}_${proto_type}_${i}"

    # Round-robin verdeling over nodes
    local node_idx=$(( (i - 1) % node_count ))
    local aggr
    if [[ "$node_idx" -eq 0 ]]; then
      aggr="$aggr1"
    else
      aggr="$aggr2"
    fi

    if exists_cmd "volume show -vserver ${svm} -volume ${vol}"; then
      log "INFO" "Volume ${svm}:${vol} bestaat al"
      record_skipped
      continue
    fi

    local cmd="volume create -vserver ${svm} -volume ${vol} -aggregate ${aggr} -size ${VOL_SIZE} -state online -space-guarantee none"
    if [[ "$proto_type" == "nfs" || "$proto_type" == "cifs" ]]; then
      local junction="${JUNCTION_BASE%/}/${vol}"
      cmd+=" -junction-path ${junction} -policy ${policy}"
    fi

    safe_change "Maak volume ${svm}:${vol} op ${aggr}" "$cmd"
  done
}

print_summary() {
  log "SUMMARY" "=============================="
  log "SUMMARY" "Run voltooid  (${SCRIPT_VERSION})"
  log "SUMMARY" "Created:  ${CREATED_COUNT}"
  log "SUMMARY" "Skipped:  ${SKIPPED_COUNT}"
  log "SUMMARY" "Warnings: ${WARN_COUNT}"
  log "SUMMARY" "Failed:   ${FAILED_COUNT}"
  log "SUMMARY" "Log file: ${LOG_FILE}"
  log "SUMMARY" "=============================="
}

main() {
  log "INFO" "=============================="
  log "INFO" "Start inrichting NetApp cluster ${CLUSTER_MGMT_IP}"
  log "INFO" "Versie:        ${SCRIPT_VERSION} (${SCRIPT_DATE})"
  log "INFO" "Config:        ${CONFIG_FILE}"
  log "INFO" "Log file:      ${LOG_FILE}"
  log "INFO" "Verbose:       ${VERBOSE} | Dry-run: ${DRY_RUN} | Color: ${COLOR_MODE}"
  log "INFO" "User:          ${NETAPP_USER}"
  log "INFO" "Nodes:         ${NODES[*]}"
  log "INFO" "RAID type:     ${AGGR_RAIDTYPE} | Disks: ${AGGR_DISKCOUNT} | Spare reserve: ${AGGR_SPARE_RESERVE}"
  log "INFO" "=============================="

  if [[ "$DRY_RUN" -eq 0 ]]; then
    check_ssh_connectivity
  else
    log "INFO" "Dry-run modus: SSH-connectiviteitscheck overgeslagen"
  fi

  ensure_ntp
  ensure_data_aggr_per_node
  ensure_ipspace
  ensure_vlan20_ports
  ensure_port_mtu_all

  read -r -a cifs_ports   <<< "$(build_ports_for_cifs)"
  read -r -a vlan20_ports <<< "$(build_ports_for_vlan20)"

  ensure_broadcast_domain "$BROADCAST_DOMAIN_CIFS"   "$FAILOVER_GROUP_CIFS"   "$CIFS_MTU"      "${cifs_ports[@]}"
  ensure_broadcast_domain "$BROADCAST_DOMAIN_VLAN20" "$FAILOVER_GROUP_VLAN20" "$NFS_ISCSI_MTU" "${vlan20_ports[@]}"

  local svm_cifs svm_nfs svm_iscsi
  svm_cifs="" svm_nfs="" svm_iscsi=""

  ensure_vserver cifs
  svm_cifs="$SVM_RESULT"

  ensure_vserver nfs
  svm_nfs="$SVM_RESULT"

  ensure_vserver iscsi
  svm_iscsi="$SVM_RESULT"

  # Export policy alleen voor CIFS en NFS (niet voor iSCSI)
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
