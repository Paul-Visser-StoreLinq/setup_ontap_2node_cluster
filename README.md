# setup_ontap_2node_cluster

A Bash script that automates the initial provisioning of a 2-node NetApp ONTAP cluster via SSH.

## What it does

The script connects to the cluster management IP and walks through every provisioning step in the right order. Every step is idempotent — it checks whether the object already exists before creating it, so the script can be re-run safely after a failure or to add objects that were skipped.

### Provisioning order

| Step | What is created |
|------|----------------|
| 1 | NTP server(s) |
| 2 | Data aggregate per node (using spare disks) |
| 3 | VLAN ports on each node (e.g. `e0d-20`) |
| 4 | Broadcast domains (`bd_cifs` and `bd_vlan20`) in ipspace Default |
| 5 | SVMs: `svm_cifs01` (CIFS), `svm_nfs01` (NFS), `svm_iscsi01` (iSCSI) |
| 6 | Export policies + rules for CIFS and NFS SVMs |
| 7 | LIFs — one per node per SVM, IPs assigned sequentially from a start address |
| 8 | Volumes — configurable count per SVM, round-robin across both aggregates |

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Bash 4.0+ | No other local dependencies |
| ONTAP cluster already initialised | Cluster setup wizard must have been completed |
| SSH access to the cluster management IP | Key-based auth preferred; password via `sshpass` also supported |
| Sufficient spare disks on each node | Default: 8 disks per aggregate + 1 spare reserve |

### Password authentication (optional)

The script tries SSH key-based authentication first. If that fails it falls back to password auth using `sshpass`.

```bash
# Install sshpass on macOS
brew install hudochenkov/sshpass/sshpass

# Supply the password as an environment variable (avoids a prompt per command)
export NETAPP_PASSWORD="yourpassword"
```

If `NETAPP_PASSWORD` is not set, the script prompts once at startup.

## Quick start

```bash
# 1. Clone the repository
git clone https://github.com/your-org/setup_ontap_2node_cluster.git
cd setup_ontap_2node_cluster

# 2. Edit the config
cp setup_ontap_2node_cluster.conf my-cluster.conf
vi my-cluster.conf          # set CLUSTER_MGMT_IP, CLUSTER_NAME, IPs, etc.

# 3. Dry-run first (no writes, shows what would happen)
./setup_ontap_2node_cluster.sh --config my-cluster.conf --dry-run --verbose

# 4. Run for real
./setup_ontap_2node_cluster.sh --config my-cluster.conf
```

## Command-line options

```
Usage: setup_ontap_2node_cluster.sh [OPTIONS]

  --config FILE              Config file  (default: setup_ontap_2node_cluster.conf)
  --dry-run                  Print actions without executing any write operations
  --verbose                  Enable DEBUG-level log output
  --color auto|always|never  Coloured log output  (default: auto)
  -h, --help                 Show help
```

## Configuration reference

Copy `setup_ontap_2node_cluster.conf` and adjust for your environment. Variables marked **required** must be set; all others have defaults.

### Connection

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLUSTER_MGMT_IP` | **yes** | — | Cluster management IP address |
| `CLUSTER_NAME` | **yes** | — | Base name for the cluster. Node names are derived as `<name>-01` and `<name>-02` |
| `NETAPP_USER` | no | `admin` | SSH login username |

### Network

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CIFS_HOME_PORT` | no | `e0c` | Physical port used for CIFS LIFs |
| `VLAN20_BASE_PORT` | no | `e0d` | Physical port on which the VLAN port is created |
| `VLAN_ID` | no | `20` | VLAN ID; VLAN port name becomes `<base>-<id>` |
| `CIFS_PORTS` | no | derived | Override `node:port` pairs for CIFS broadcast domain |
| `VLAN20_BASE_PORTS` | no | derived | Override `node:port` pairs for VLAN base ports |
| `BROADCAST_DOMAIN_CIFS` | no | `bd_cifs` | Name of the CIFS broadcast domain |
| `BROADCAST_DOMAIN_VLAN20` | no | `bd_vlan20` | Name of the VLAN20 broadcast domain |
| `CIFS_MTU` | no | `1500` | MTU for the CIFS broadcast domain |
| `NFS_ISCSI_MTU` | no | `9000` | MTU for the NFS/iSCSI broadcast domain |

> **Port overrides** — by default the script applies `CIFS_HOME_PORT` and `VLAN20_BASE_PORT` to both nodes. Set `CIFS_PORTS` / `VLAN20_BASE_PORTS` as explicit `node:port` arrays to use different ports per node or to exclude a node:
> ```bash
> CIFS_PORTS=("na-clus01-01:e0e" "na-clus01-02:e0f")
> VLAN20_BASE_PORTS=("na-clus01-01:e0d")   # only node 01
> ```

### LIF IP addressing

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CIFS_START_IP` | **yes** | — | First IP assigned to CIFS LIFs; incremented per LIF |
| `NFS_ISCSI_START_IP` | **yes** | — | First IP assigned to NFS/iSCSI LIFs |
| `LIF_NETMASK_CIFS` | **yes** | — | Subnet mask for CIFS LIFs |
| `LIF_NETMASK_NFS_ISCSI` | **yes** | — | Subnet mask for NFS/iSCSI LIFs |
| `EXCLUDED_IPS` | no | `()` | IPs to skip during assignment (Bash array or comma-separated string) |

### Aggregates

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AGGR_PREFIX` | no | `aggr_data` | Aggregate name prefix; node suffix is appended automatically |
| `AGGR_DISKCOUNT` | no | `8` | Number of disks per aggregate |
| `AGGR_RAIDTYPE` | no | `raid_dp` | RAID type (`raid_dp` or `raid4`) |
| `AGGR_SPARE_RESERVE` | no | `1` | Minimum spare disks to keep per node after aggregate creation |

### SVMs

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VSERVER_BASE_cifs` | no | `svm_cifs01` | Name for the CIFS SVM |
| `VSERVER_BASE_nfs` | no | `svm_nfs01` | Name for the NFS SVM |
| `VSERVER_BASE_iscsi` | no | `svm_iscsi01` | Name for the iSCSI SVM |

### Volumes

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `VOLUMES_PER_SVM` | no | `2` | Number of volumes to create per SVM |
| `VOL_SIZE` | no | `100G` | Size of each volume |
| `VOL_PREFIX` | no | `vol` | Volume name prefix |
| `JUNCTION_BASE` | no | `/` | Junction path prefix for NFS/CIFS volumes |

### Export policy

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `EXPORT_CLIENTMATCH` | no | `0.0.0.0/0` | Client match for the export rule |
| `EXPORT_RORULE` | no | `any` | Read-only rule |
| `EXPORT_RWRULE` | no | `any` | Read-write rule |

### NTP

```bash
NTP_SERVERS=("192.168.1.1" "192.168.1.2")   # array — all entries are added
```

## Log files

Every run writes a timestamped log to `./logs/` (configurable with `LOG_DIR`):

```
logs/netapp-cluster-v3.7.0-20260427-142813.log
```

The summary (Created / Skipped / Warnings / Failed counts) is also printed to stdout at the end of each run.

## Re-run behaviour

The script is safe to re-run at any time:

- Objects that already exist are **skipped** and counted as `Skipped`.
- Objects that failed to create in a prior run are **retried**.
- IPs that are already assigned to a LIF are **skipped** automatically during IP selection.

## Known limitations

- Designed for exactly 2-node clusters. The node name convention is `<CLUSTER_NAME>-01` / `<CLUSTER_NAME>-02`.
- Failover groups are not created (deprecated in modern ONTAP; LIFs fail over automatically).
- Only one VLAN ID is supported per run. For multiple VLANs, run the script with different configs.
- iSCSI volumes are created but iSCSI service, igroups, and LUNs are not configured — that is left to the storage administrator.

## Version history

| Version | Date | Summary |
|---------|------|---------|
| v3.7.0 | 2026-04-27 | Bug fixes from live testing (ipspace Cluster, `\r\n` stripping, broadcast domain port check, vserver name fallback) |
| v3.6.0 | 2026-04-24 | `CLUSTER_NAME` drives node names; `NODES` removed from config |
| v3.5.0 | 2026-04-24 | Network ports driven by config (`CIFS_PORTS`, `VLAN20_BASE_PORTS`) |
| v3.4.0 | 2026-04-20 | Removed IPspace config; always uses Default ipspace |
| v3.3.0 | 2026-04-16 | Synchronized config/script variable names |
| v3.2.6 | — | Original version |
