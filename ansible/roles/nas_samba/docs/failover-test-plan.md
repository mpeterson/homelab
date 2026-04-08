# NAS Samba Failover Test Plan

This document provides procedures to validate Samba failover behavior on the HA NAS cluster managed by Pacemaker. The NAS uses active/passive HA with PCS constraints (no CTDB clustering). SMB sessions do **not** survive failover.

## System Overview

- **Hardware**: 2-node active/passive HA cluster, Rocky Linux
- **Cluster Manager**: Pacemaker (PCS)
- **Storage**: ZFS pool with shared datasets
- **Resources**: VIP (virtual IP), iSCSI, NFS, Samba (SMB3)
- **Resource Constraints**: Colocation and ordering constraints (not groups)
- **Expected Failover Duration**: 30–180 seconds (dominated by ZFS import time)
- **Client Handling**: SMB clients must reconnect after failover; sessions are NOT persistent

---

## Pre-Flight Checks

Before starting any failover test, verify cluster health:

```bash
# On either node, check cluster status
pcs status

# Expected output: Both nodes online, all resources running on active node

# Verify Samba is running on active node
systemctl status smb

# Verify VIP is assigned to active node
ip addr show | grep "inet <VIP_ADDRESS>"

# Verify NFS and iSCSI are running
systemctl status nfs-server
systemctl status target

# Verify ZFS pool is imported
zpool status
```

**Pass Criteria**: Cluster is healthy, Samba running on active node, VIP present, all resources online.

---

## Test 1: Graceful Failover

**Objective**: Migrate Samba resource to standby node using `pcs resource move`.

### Procedure

1. **Identify active node**:
   ```bash
   pcs status
   ```
   Note which node is running `smb-service`.

2. **Trigger failover**:
   ```bash
   pcs resource move smb-service
   ```
   This moves Samba to the standby node. ZFS, NFS, iSCSI, and VIP will migrate together due to colocation constraints.

3. **Monitor failover progress** (on either node):
   ```bash
   watch -n 2 'pcs status | grep -A 20 "Resources:"'
   ```
   Watch until:
   - Samba stops on node A
   - Samba starts on node B
   - All other resources complete migration

4. **Verify Samba stopped on original active node**:
   ```bash
   # SSH to node A
   ssh node-a
   systemctl is-active smb
   # Expected output: inactive
   ```

5. **Verify Samba started on new active node**:
   ```bash
   # SSH to node B
   ssh node-b
   systemctl is-active smb
   # Expected output: active (running)
   ```

6. **Verify VIP is still present** (now on node B):
   ```bash
   ip addr show | grep "<VIP_ADDRESS>"
   # Expected: inet <VIP_ADDRESS>/32 dev <interface>
   ```

7. **Verify ZFS datasets remain**:
   ```bash
   zpool status
   zfs list
   # Expected: All datasets still present and mounted
   ```

8. **Client reconnection test**:
   - From Windows/macOS client, disconnect and reconnect to `\\<VIP_ADDRESS>\<share>`
   - Verify shares are accessible
   - Verify file integrity (checksum or size comparison)

9. **Clear resource move constraint**:
   ```bash
   pcs resource clear smb-service
   ```
   This allows normal cluster failover rules to apply again.

### Pass Criteria

- ✓ Samba stops cleanly on node A
- ✓ Samba starts successfully on node B
- ✓ VIP migrates with Samba
- ✓ ZFS datasets remain mounted
- ✓ Clients can reconnect without data loss
- ✓ `pcs resource clear` succeeds

---

## Test 2: Node Failure Simulation

**Objective**: Simulate complete node failure and verify full cluster failover (including all resources).

### Procedure

1. **Identify the active node**:
   ```bash
   pcs status
   ```

2. **Stop corosync on the active node** to simulate a complete node failure:
   ```bash
   # SSH to active node
   ssh node-a
   systemctl stop corosync
   ```

3. **Monitor failover from the standby node**:
   ```bash
   # SSH to node B
   ssh node-b
   watch -n 1 'pcs status'
   ```

4. **Expect STONITH (Shoot The Other Node In The Head)**:
   - Pacemaker will detect node A is offline
   - Watchdog or power device will be triggered to fence node A
   - Verify STONITH event in logs:
     ```bash
     tail -50 /var/log/pacemaker/pacemaker.log
     grep -i "stonith\|fence" /var/log/pacemaker/pacemaker.log
     ```

5. **Verify full resource migration**:
   ```bash
   pcs status
   # Expected: All resources (ZFS, VIP, NFS, iSCSI, Samba) now running on node B
   ```

6. **Verify VIP is on node B**:
   ```bash
   ip addr show | grep "<VIP_ADDRESS>"
   ```

7. **Verify Samba is running on node B**:
   ```bash
   systemctl is-active smb
   systemctl status smb
   ```

8. **Client reconnection test**:
   - SMB client will receive connection timeout
   - Client reconnects to VIP (DNS/hostname resolution or direct VIP connect)
   - Verify shares are accessible
   - Re-open any files or projects

9. **Recover failed node**:
   ```bash
   # Power on or restart node A
   # Verify it rejoins the cluster
   pcs node online node-a
   # Monitor recovery
   watch -n 2 'pcs status'
   ```

### Pass Criteria

- ✓ STONITH fires successfully
- ✓ All resources migrate to node B
- ✓ VIP is accessible on node B
- ✓ Samba is running on node B
- ✓ Clients can reconnect after failover
- ✓ Failed node rejoins cluster cleanly
- ✓ Downtime: 30–180 seconds (primarily ZFS import)

---

## Test 3: Samba Process Crash

**Objective**: Verify Pacemaker detects and responds to Samba process failure.

### Procedure

1. **Identify active node and Samba PID**:
   ```bash
   pcs status
   ssh node-a
   ps aux | grep smbd | grep -v grep
   ```

2. **Kill the smbd process**:
   ```bash
   killall smbd
   ```

3. **Monitor cluster response** (watch from node B or via pcs):
   ```bash
   watch -n 1 'pcs status'
   ```

4. **Observe one of two outcomes**:

   **Scenario A** — Samba restarts on the same node (if within failure threshold):
   ```bash
   systemctl is-active smb
   # Should transition to active again within 30 seconds
   ```

   **Scenario B** — Cluster fails over to node B:
   ```bash
   pcs status
   # Samba now running on node B
   ```

5. **Check Pacemaker monitor logs**:
   ```bash
   tail -50 /var/log/pacemaker/pacemaker.log
   grep -i "smb\|restart\|migrate" /var/log/pacemaker/pacemaker.log
   ```

6. **Test client connectivity**:
   - If restarted locally: clients may reconnect immediately
   - If failed over: clients will experience brief timeout, then reconnect to new node

### Pass Criteria

- ✓ Pacemaker detects process exit via monitor operation
- ✓ Either local restart or failover occurs
- ✓ Service is available again within expected time
- ✓ Clients can reconnect or continue

---

## Test 4: Client-Side Verification

**Objective**: Verify end-to-end client experience during failover events, especially for video editing workloads.

### Prerequisites

- Windows or macOS client with SMB3 support
- Mapped SMB share on VIP
- Large test file (~5GB) for copy testing
- NLE software with project stored on share (optional but recommended)

### Procedure

1. **Map SMB share** (Windows example):
   ```
   \\<VIP_ADDRESS>\<share_name>
   ```
   Verify encryption and signing are enforced (check share properties).

2. **Copy large file during idle**:
   ```bash
   # Client-side: copy 5GB test file from share to local drive
   # Compare checksum before and after
   # Expected: ~800+ MB/s read speed
   ```

3. **Trigger failover while file copy is in progress**:
   - On cluster: `pcs resource move smb-service` or `systemctl stop corosync` (on active node)
   - On client: Large file copy should pause or timeout

4. **Verify client behavior post-failover**:
   - Share is inaccessible for 30–180 seconds
   - Share becomes accessible again
   - File copy can resume or restart
   - File integrity check: no corruption

5. **Open video project in NLE** (if available):
   - Project stored on share
   - Media files on share
   - Trigger failover
   - NLE may lose connection temporarily
   - After reconnection, re-link media or reload project
   - Verify video plays without glitches or corruption

6. **Test multi-stream scenario**:
   - Multiple clients simultaneously copying files
   - Trigger failover
   - Verify all clients can reconnect
   - No data loss across simultaneous transfers

### Pass Criteria

- ✓ File copy succeeds with correct checksum
- ✓ Share reconnects after failover
- ✓ No file corruption or data loss
- ✓ NLE project relinks and plays correctly
- ✓ Multi-client failover is clean

---

## Troubleshooting

### Failover does not complete

- Check if node is STONITH'd: `pcs status` for fence history
- Check if ZFS import is slow: `zpool import -l` to see pool status
- Check for resource dependencies: `pcs resource show --full`

### Samba fails to start on new node

```bash
# Check SMB daemon logs
tail -50 /var/log/samba/log.smbd

# Verify share configuration exists
smbclient -L localhost -U%
```

### VIP does not migrate

- Verify colocation constraint: `pcs constraint show`
- Check if network interface is up on target node: `ip addr show`

### Client cannot reconnect after failover

- Verify firewall rules allow SMB (port 445) on VIP
- Check if DNS/hostname resolves to correct VIP
- Try explicit IP: `\\<VIP_ADDRESS>\<share>`

---

## Post-Test

After each test, verify the cluster is stable:

```bash
pcs status
pcs resource show --full
zpool status
systemctl status smb nfs-server target
```

Document any anomalies or extended recovery times for capacity planning.
