---
machine:
  sysctls:
    net.core.bpf_jit_harden: 1
{{ if .Node.Data.gpu }}
  kernel:
    modules:
      - name: nvidia
      - name: nvidia_uvm
      - name: nvidia_drm
      - name: nvidia_modeset
{{ end }}
