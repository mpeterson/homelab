# Alertmanager notification policy

`alertmanager-config.yaml` contains native Alertmanager configuration wrapped as
additional Helm values. Native time intervals support an IANA timezone; the
installed `AlertmanagerConfig` CRD does not expose that field.

## Opt-in incident severity

Incident severity and notification delivery priority are independent.

| Label | Notification window |
| --- | --- |
| `incident_severity: sev1` or `sev2` | Anytime |
| `incident_severity: sev3` and higher numbered severities | Business hours |
| No `incident_severity` label | Existing routing, unchanged |

Business hours use `Asia/Jerusalem`, including daylight-saving transitions:

- Sunday–Thursday: 09:00–22:00.
- Friday–Saturday: 10:00–22:00.

Opening times are inclusive; closing times are exclusive. Notification grouping
can add up to the configured group interval after a window opens.

Only Kometa currently opts in. Do not infer incident severity from existing
`severity: critical` or `warning` labels; those continue to serve the existing
inhibition policy. Review other alerts separately before opting them in.

Scheduled routes stop further matching, so an opted-in Sev3 alert cannot fall
through to an anytime route outside business hours.

## Native scheduling limitations

Alertmanager does not provide a durable queue of every alert event. An alert
outside business hours is delivered at the next window only if it still fires.
An alert that resolves beforehand may never notify. Recovery notifications are
also subject to the route's window.

No failure latch, artificial lookback, queue, on-call rota, acknowledgement
workflow, or escalation service is added. Discuss any requirement for those
behaviors explicitly rather than silently extending native scheduling.

## Pushover and iOS

The existing Pushover receiver sends firing notifications at high priority (`1`)
and recovery notifications at normal priority (`0`). This is independent of both
severity labels. Pushover emergency priority (`2`), which requires retries and
acknowledgement, is not used.

Enable Pushover's **Critical Alerts for high-priority** setting and the iOS
Critical Alerts permission to make firing notifications audible through Focus
and the mute switch. API acceptance cannot verify those device settings.

Credentials remain in the existing SOPS-managed `alertmanager-secrets` Secret,
mounted under `/etc/alertmanager/secrets/alertmanager-secrets`. The native
receivers read the Pushover keys and Watchdog URL from files; values contain no
plaintext credentials.

## Shared configuration and rollout

Existing receiver identifiers, Pushover templates/priorities, grouping,
Watchdog cadence, Velero maintenance-Job suppression, and warning/critical
inhibition are retained. Additional `AlertmanagerConfig` resources, including
cert-manager's suppression, remain discoverable across namespaces.

Discovery excludes resources labeled
`app.kubernetes.io/instance: kube-prometheus-stack`, including the retired global
`monitoring/alertmanager` object. This prevents it from being merged back into
the native configuration during migration. Supplemental configurations must not
use that reserved instance label.

The migration replaces the global configuration source and adds a credential
Secret mount to the single Alertmanager instance. Deployment can roll its pod,
briefly interrupt notification delivery, and cause notification resends. Obtain
explicit approval before rollout and pruning the retired object. Do not disable
Watchdog or change unrelated alert severities as part of this migration.

`just validate kometa` checks the rendered configuration with `amtool`, exercises
route selection, and checks business-window boundaries in standard and
daylight-saving time. It also tests Kometa failures and their natural recovery
with `promtool`.
