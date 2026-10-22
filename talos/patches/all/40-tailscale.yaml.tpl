---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - {{ printf "TS_AUTHKEY=%s" (env "TS_AUTHKEY") | quote }}
  - TS_AUTH_ONCE=true
