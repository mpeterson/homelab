set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    @just --unstable --list k8s

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

[doc('List all ArgoCD applications and their sync status')]
apps: (_require "kubectl")
    kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,NAMESPACE:.spec.destination.namespace'

[doc('Force sync an ArgoCD application')]
sync app: (_require "argocd" "kubectl")
    #!/usr/bin/env bash
    set -euo pipefail
    KCTX=$(kubectl config current-context)
    argocd app sync {{app}} --core --kube-context "$KCTX"

[doc('Hard refresh an ArgoCD application (clear cache)')]
hard-refresh app: (_require "kubectl")
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/refresh=hard --overwrite
    @echo "Hard refresh triggered for '{{app}}'"

[doc('Open a shell on a Kubernetes node')]
node-shell node: (_require "kubectl")
    kubectl debug node/{{node}} -it --image=alpine:latest -- sh

[doc('Browse the contents of a PVC')]
browse-pvc ns pvc: (_require "kubectl")
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl run pvc-browser-{{pvc}} --rm -it \
      --namespace {{ns}} \
      --image alpine:latest \
      --overrides '{
        "spec": {
          "containers": [{
            "name": "browser",
            "image": "alpine:latest",
            "command": ["sh"],
            "stdin": true,
            "tty": true,
            "volumeMounts": [{
              "name": "pvc",
              "mountPath": "/data"
            }]
          }],
          "volumes": [{
            "name": "pvc",
            "persistentVolumeClaim": {
              "claimName": "{{pvc}}"
            }
          }]
        }
      }'

[doc('Show resource usage across all nodes')]
node-resources: (_require "kubectl")
    kubectl top nodes

[doc('Show pod resource usage in a namespace (or all with "-A")')]
pod-resources ns="-A": (_require "kubectl")
    kubectl top pods {{ns}}
