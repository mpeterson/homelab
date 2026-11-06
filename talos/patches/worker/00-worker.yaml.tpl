---
apiVersion: v1alpha1
kind: SysctlConfig
params:
  net.core.bpf_jit_harden: "1"
{{ if .Node.Data.gpu }}
---
apiVersion: v1alpha1
kind: KernelModuleConfig
name: nvidia
---
apiVersion: v1alpha1
kind: KernelModuleConfig
name: nvidia_uvm
---
apiVersion: v1alpha1
kind: KernelModuleConfig
name: nvidia_drm
---
apiVersion: v1alpha1
kind: KernelModuleConfig
name: nvidia_modeset
{{ end }}
