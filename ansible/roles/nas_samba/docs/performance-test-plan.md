# NAS Samba Performance Test Plan

This document provides procedures to benchmark Samba (SMB3) performance on the HA NAS cluster over a 10GbE network. These tests establish baseline performance for 4K/8K video editing workloads and compare SMB against NFS.

## System Overview

- **Network**: 10GbE (theoretical max: 10 Gbps ≈ 1.25 GB/s)
- **Protocol**: SMB3 with encryption and signing enabled
- **Storage**: ZFS pool with tuned recordsize and compression
- **Client**: 10GbE-capable machine (Windows/macOS/Linux with SMB3 support)
- **Workload**: 4K/8K video editing with frequent I/O and random seeks

---

## Prerequisites

### Cluster Health

Before testing, ensure the NAS is fully operational:

```bash
# On cluster node
pcs status
zpool status
systemctl status smb nfs-server

# Expected: All resources online, no degraded pools
```

### Network Baseline

Verify 10GbE connectivity between client and NAS:

```bash
# Install iperf3 on both client and NAS
# macOS: brew install iperf3
# Linux: apt install iperf3 / yum install iperf3

# On NAS, start iperf3 server
iperf3 -s -D

# On client, test connection to VIP
iperf3 -c <VIP_ADDRESS> -P 1 -t 30
```

**Expected Result**: ~9.3 Gbps (90% of 10 Gbps wire speed is normal; overhead accounts for ~10%)

If below 8.5 Gbps, investigate:
- Network interface negotiation: `ethtool <interface>`
- Switch settings: verify 10GbE full duplex
- Jumbo frames: `ip link show <interface>` (MTU should be ≥ 9000)

---

## Test 1: Network Baseline (iperf3)

### Procedure

1. **Start iperf3 server on NAS**:
   ```bash
   # On NAS (node with active resources)
   iperf3 -s -D --logfile /tmp/iperf3_server.log
   ```

2. **Run 3 iterations from client**:
   ```bash
   # On client
   # Iteration 1: Bidirectional
   iperf3 -c <VIP_ADDRESS> -P 1 -t 30 -R
   
   # Iteration 2: Reverse direction
   iperf3 -c <VIP_ADDRESS> -P 1 -t 30
   
   # Iteration 3: Parallel streams (simulates concurrent clients)
   iperf3 -c <VIP_ADDRESS> -P 4 -t 30
   ```

3. **Record results**:
   - Single stream throughput (both directions)
   - 4-stream aggregate throughput
   - Jitter and lost packets

### Expected Results

- Single direction: **8.5–9.3 Gbps** (typically 9 Gbps with tuning)
- Reverse direction: **8.5–9.3 Gbps**
- 4-stream parallel: **8.5–9.3 Gbps aggregate** (close to wire speed)
- Lost packets: **0** (no packet loss on stable network)

### Pass Criteria

- ✓ Single stream ≥ 8.5 Gbps
- ✓ No significant packet loss
- ✓ Bidirectional symmetry within 5%

---

## Test 2: SMB Sequential Read

**Objective**: Benchmark maximum sequential read throughput (share pull).

### Procedure

1. **Create large test file on share** (use existing or create 10GB):
   ```bash
   # On NAS, create test file
   dd if=/dev/zero of=/mnt/zfs/smb_share/testfile-10gb.bin bs=1M count=10240
   
   # Verify file exists
   ls -lh /mnt/zfs/smb_share/testfile-10gb.bin
   ```

2. **Mount share on client**:
   ```bash
   # macOS (SMB3)
   mount_smb smb://<username>@<VIP_ADDRESS>/share /Volumes/nas_share
   
   # Windows (map network drive)
   net use Z: \\<VIP_ADDRESS>\share /user:<username>
   
   # Linux (cifsx with SMB3)
   mount -t cifs //<VIP_ADDRESS>/share /mnt/nas -o username=<user>,vers=3.1.1
   ```

3. **Read test with dd**:
   ```bash
   # Read from share to /dev/null, measure speed
   dd if=/Volumes/nas_share/testfile-10gb.bin of=/dev/null bs=1M
   
   # Example output:
   # 10737418240 bytes transferred in 13.500 secs (796069 bytes/sec)
   # ≈ 758 MB/s
   ```

4. **Read test with smbclient** (Linux/Unix alternative):
   ```bash
   # Use smbclient to read file
   smbclient //<VIP_ADDRESS>/share -U <user> -c "get testfile-10gb.bin /dev/null"
   ```

5. **Repeat 3 times** and average results.

### Expected Results

- Sequential read: **600–900 MB/s** (depends on ZFS tuning and CPU)
- Typical: **750–850 MB/s** for video workload tuning
- Consistency: <10% variation between runs

### Pass Criteria

- ✓ Read throughput ≥ 600 MB/s
- ✓ Variation between runs <15%
- ✓ No timeouts or connection drops

---

## Test 3: SMB Sequential Write

**Objective**: Benchmark maximum sequential write throughput (share push).

### Procedure

1. **Write test with dd**:
   ```bash
   # Write from /dev/zero to share, measure speed
   dd if=/dev/zero of=/Volumes/nas_share/testfile-write-10gb.bin bs=1M count=10240
   
   # Example output:
   # 10737418240 bytes transferred in 17.850 secs (601701 bytes/sec)
   # ≈ 573 MB/s
   ```

2. **Verify file was written**:
   ```bash
   ls -lh /Volumes/nas_share/testfile-write-10gb.bin
   ```

3. **Read back and checksum**:
   ```bash
   md5 testfile-write-10gb.bin
   # Note the hash for comparison
   ```

4. **Repeat 3 times** and average results.

### Expected Results

- Sequential write: **500–700 MB/s** (typically lower than read due to sync overhead)
- Typical: **600–650 MB/s** for optimized ZFS configuration
- Consistency: <10% variation between runs

### Pass Criteria

- ✓ Write throughput ≥ 500 MB/s
- ✓ File integrity verified (checksum match)
- ✓ Variation between runs <15%

---

## Test 4: SMB Random I/O (Video Timeline Scrubbing)

**Objective**: Simulate video editing workload with frequent seeks and random I/O.

### Procedure

1. **Install fio** (benchmark tool):
   ```bash
   # macOS: brew install fio
   # Linux: apt install fio / yum install fio
   ```

2. **Create fio job file** for video timeline scrubbing pattern:
   ```ini
   # Save as /tmp/video-timeline.fio
   [global]
   ioengine=libaio
   iodepth=16
   blocksize=4k
   filesize=50G
   direct=1
   numjobs=1
   runtime=120
   time_based
   group_reporting
   
   [random-read]
   rw=randread
   filename=/Volumes/nas_share/fio-test-random.bin
   name=video-scrub-read
   description=Random 4K reads (simulating video codec seeks)
   ```

3. **Run random read benchmark**:
   ```bash
   fio /tmp/video-timeline.fio
   
   # Key metrics from output:
   # - IOPS (I/O operations per second)
   # - Bandwidth (MB/s)
   # - Latency (mean, p99, p99.9)
   ```

4. **Capture output metrics**:
   - Read IOPS
   - Read bandwidth
   - Read latency (average and 99th percentile)

5. **Create mixed read/write job** for editing operations:
   ```ini
   [global]
   ioengine=libaio
   iodepth=16
   blocksize=4k
   filesize=50G
   direct=1
   numjobs=1
   runtime=120
   time_based
   group_reporting
   
   [mixed-io]
   rw=randrw
   rwmixread=70
   filename=/Volumes/nas_share/fio-test-mixed.bin
   name=video-edit-mixed
   description=70% read / 30% write (simulating editing operations)
   ```

6. **Run mixed I/O benchmark**:
   ```bash
   fio /tmp/video-timeline.fio
   ```

7. **Record latency percentiles** (especially p99 for NLE responsiveness).

### Expected Results

**Random Read (4K blocks)**:
- IOPS: **5,000–15,000 IOPS** (depends on CPU, RAM, ZFS cache)
- Bandwidth: **20–60 MB/s** (for 4K blocks)
- Latency p99: **<50ms** (acceptable for video scrubbing)

**Mixed I/O (70% read, 30% write)**:
- Combined IOPS: **4,000–10,000 IOPS**
- Latency p99: **<100ms** (editing is more latency-sensitive than scrubbing)

### Pass Criteria

- ✓ Random read IOPS ≥ 5,000
- ✓ Random read latency p99 <100ms
- ✓ Mixed I/O latency p99 <150ms
- ✓ No connection drops during 2-minute test

---

## Test 5: Multi-Stream Concurrent Access

**Objective**: Simulate multiple video editors accessing the share simultaneously.

### Procedure

1. **On client, start concurrent read threads**:
   ```bash
   # Run 4 parallel sequential reads (simulate 4 editors scrubbing timelines)
   for i in {1..4}; do
     (dd if=/Volumes/nas_share/testfile-10gb.bin of=/dev/null bs=1M &)
   done
   wait
   ```

2. **Monitor aggregate throughput** (watch from another terminal):
   ```bash
   # macOS: use Instruments or Activity Monitor
   # Linux: iostat -x 1 or iotop
   
   # Expected: near-full link saturation (approaching 1.25 GB/s on 10GbE)
   ```

3. **Alternative: Use fio with multiple jobs**:
   ```ini
   [global]
   ioengine=libaio
   iodepth=16
   blocksize=1M
   filesize=50G
   direct=1
   numjobs=4
   runtime=60
   time_based
   group_reporting
   
   [4-concurrent-reads]
   rw=read
   filename=/Volumes/nas_share/fio-4stream.bin
   ```

4. **Run and record aggregate throughput**.

### Expected Results

- Aggregate throughput: **800–1,100 MB/s** (4 streams × 200–275 MB/s each)
- Per-stream fairness: Each stream gets ~250 MB/s (1000 MB/s ÷ 4)
- No stream starvation or timeouts

### Pass Criteria

- ✓ Aggregate throughput ≥ 800 MB/s
- ✓ No stream disconnects
- ✓ Fair allocation across streams

---

## Test 6: Comparison Benchmarks (SMB vs NFS)

**Objective**: Quantify SMB overhead relative to NFS on the same hardware.

### Procedure

1. **Configure NFS share** (ensure NFS service is running):
   ```bash
   # Verify NFS is online
   systemctl status nfs-server
   pcs resource show nfs-resource
   ```

2. **Mount NFS on client**:
   ```bash
   # macOS
   mount_nfs -o vers=3,proto=tcp <VIP_ADDRESS>:/export/path /Volumes/nfs_share
   
   # Linux
   mount -t nfs -o vers=3,proto=tcp <VIP_ADDRESS>:/export/path /mnt/nfs
   ```

3. **Run identical sequential read test on NFS**:
   ```bash
   dd if=/Volumes/nfs_share/testfile-10gb.bin of=/dev/null bs=1M
   ```

4. **Run identical random I/O test on NFS**:
   ```bash
   fio /tmp/video-timeline.fio --directory=/Volumes/nfs_share
   ```

5. **Tabulate results**:
   | Metric | SMB | NFS | Ratio (SMB/NFS) |
   |--------|-----|-----|-----------------|
   | Sequential Read (MB/s) | | | |
   | Sequential Write (MB/s) | | | |
   | Random Read IOPS | | | |
   | Random Read Latency (ms) | | | |

### Expected Results

- **Sequential read**: NFS and SMB within 5–10% (both network-limited)
- **Random I/O**: SMB may be 10–20% slower due to encryption/signing overhead
- **Encryption cost**: Typically 5–15% throughput penalty for SMB3 encryption

### Pass Criteria

- ✓ SMB throughput within 10% of NFS for sequential I/O
- ✓ SMB random latency within 20% of NFS
- ✓ Difference is documented for SLA purposes

---

## ZFS Tuning Recommendations

The following ZFS parameters optimize for video editing workloads:

### Dataset Tuning (applied to Samba share dataset)

```bash
# Set recordsize to 1M for large sequential transfers (video files)
zfs set recordsize=1M tank/samba_share

# Enable compression (lz4 is fast, good for video proxies)
zfs set compression=lz4 tank/samba_share

# Set sync mode to standard (not always for performance)
zfs set sync=standard tank/samba_share

# Disable access time logging (improves random I/O)
zfs set atime=off tank/samba_share

# Set primary cache to most (favor ARC over disk reads)
zfs set primarycache=all tank/samba_share
```

### ARC Sizing (in ZFS module parameters)

For video workloads with 64GB+ RAM:

```bash
# Set maximum ARC to 50% of RAM (leave room for other processes)
echo "options zfs zfs_arc_max=34359738368" >> /etc/modprobe.d/zfs.conf
# 34GB = 50% of 68GB; adjust for your hardware

# Disable ARC shrinking to maintain performance
echo "options zfs zfs_arc_shrink_adjust=0" >> /etc/modprobe.d/zfs.conf
```

Then reload ZFS module:

```bash
# Reboot or unload/reload (risky on active system)
# Safer: reboot after load testing
```

### Monitor ARC During Testing

```bash
# Watch ARC hit ratio and size
arcstat.py -i 1

# Expected: Hit ratio >80% during sequential reads, >60% during random I/O
```

---

## Performance Benchmarking Commands Quick Reference

### Sequential Read (SMB)

```bash
# Simple dd benchmark
dd if=<share_path>/testfile-10gb.bin of=/dev/null bs=1M

# With timing
time dd if=<share_path>/testfile-10gb.bin of=/dev/null bs=1M status=progress
```

### Sequential Write (SMB)

```bash
time dd if=/dev/zero of=<share_path>/testfile-write-10gb.bin bs=1M count=10240 status=progress
```

### Random I/O (fio)

```bash
# Random read
fio --name=randread --ioengine=libaio --iodepth=16 --blocksize=4k --filesize=50G \
    --direct=1 --rw=randread --runtime=120 --time_based \
    --filename=<share_path>/fio-test.bin

# Mixed read/write
fio --name=randrw --ioengine=libaio --iodepth=16 --blocksize=4k --filesize=50G \
    --direct=1 --rw=randrw --rwmixread=70 --runtime=120 --time_based \
    --filename=<share_path>/fio-test.bin
```

### Network Baseline (iperf3)

```bash
# Server (on NAS)
iperf3 -s

# Client (single stream)
iperf3 -c <VIP_ADDRESS> -P 1 -t 30

# Client (4 parallel streams)
iperf3 -c <VIP_ADDRESS> -P 4 -t 30
```

### Monitor Live Performance

```bash
# macOS
# Activity Monitor: watch Network tab during tests

# Linux - iostat
iostat -x 1

# Linux - iotop
iotop -o

# Watch NAS CPU/mem during tests
top -o %CPU
```

---

## Test Execution Checklist

- [ ] Network baseline ≥8.5 Gbps
- [ ] SMB sequential read ≥600 MB/s
- [ ] SMB sequential write ≥500 MB/s
- [ ] Random read IOPS ≥5,000, latency p99 <100ms
- [ ] Mixed I/O latency p99 <150ms
- [ ] 4-stream aggregate ≥800 MB/s
- [ ] SMB vs NFS comparison within 10–20%
- [ ] ZFS ARC hit ratio >60%
- [ ] No dropped connections or timeouts
- [ ] Cluster remains stable (pcs status clean)

---

## Troubleshooting Performance Issues

### Sequential throughput <600 MB/s

1. Check CPU utilization: smbench shouldn't saturate all cores
2. Check jumbo frames: `ip link show | grep mtu`
3. Check network switches for errors: `ethtool -S <interface> | grep -i error`
4. Verify SMB3 is negotiated: `smbclient -L <VIP> -m SMB3` (on Linux)

### High latency in random I/O

1. Check ZFS ARC hit ratio: `arcstat.py`
2. Check if ZFS is doing compression/decompression: CPU usage spike
3. Reduce fio iodepth if CPU is saturated
4. Check for PCS failover during test: `pcs status`

### Multi-stream unfairness

1. Check for network QoS limits
2. Verify no per-session rate limiting in Samba config
3. Check SMB signing overhead: disable temporarily for baseline (then re-enable)

### Encryption overhead visible

1. SMB3 encryption is CPU-intensive; ensure no other processes are running
2. Consider AES-NI offloading: `grep aes /proc/cpuinfo` (should show `aes` flag)

---

## Post-Test Documentation

Record results in a spreadsheet for historical tracking:

| Date | Protocol | Test | Throughput | Latency | Notes |
|------|----------|------|-----------|---------|-------|
| 2024-01-15 | SMB3 | Sequential Read | 847 MB/s | N/A | Baseline, ARC hit 82% |
| 2024-01-15 | SMB3 | Random Read | 8,243 IOPS | 28ms p99 | Video timeline scrub simulation |
| 2024-01-15 | NFS | Sequential Read | 921 MB/s | N/A | Comparison baseline |

This enables trend analysis and SLA validation for the video editing workload.
