---
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
$patch: delete
---
apiVersion: v1alpha1
kind: SecurityProfileConfig
$patch: delete
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/sda"
  wipe: false
---
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
---
apiVersion: v1alpha1
kind: KubeNetworkConfig
podSubnets:
  - 10.244.0.0/16
serviceSubnets:
  - 10.96.0.0/12
---
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  rotate-server-certificates: "true"
---
apiVersion: v1alpha1
kind: EtcFileConfig
name: nfsmount.conf
mode: 0o644
contents: |
  [ NFSMount_Global_Options ]
  nfsvers=4.2
  hard=True
  noatime=True
  nconnect=16
---
apiVersion: v1alpha1
kind: CRICustomizationConfig
name: 20-customization
content: |
  [plugins."io.containerd.cri.v1.images"]
    discard_unpacked_layers = false
---
apiVersion: v1alpha1
kind: UdevRulesConfig
rules:
  - SUBSYSTEM=="apex", KERNEL=="apex*", GROUP="44", MODE="0660"
---
apiVersion: v1alpha1
kind: ResolverConfig
hostDNS:
  enabled: true
  resolveMemberNames: true
  forwardKubeDNSToHost: false
