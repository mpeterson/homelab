# Kometa

Kometa runs daily at midnight in `Asia/Jerusalem` and processes the Movies and
Series libraries, including their configured overlays.

## Runtime and failure detection

The container keeps its root filesystem read-only. Writable `/tmp` provides
temporary storage for SQLite cache initialization and other operations.
Without it, the observed run logged `disk I/O error` and processed neither library.

Kometa runs directly with `--run --read-only-config`, without a log-parsing
wrapper. Logs remain in `/config/logs` on the existing PVC; Kometa rotates them.
Inspect PVC capacity if logs or overlay assets grow.

Kometa v2.5.5 has no fail-on-error flag. Its
[run handler](https://github.com/Kometa-Team/Kometa/blob/1ec206b4c9dd0e9f9ea7b9e7a4e2e56b349e68d0/kometa.py#L760-L761)
catches and logs runtime exceptions without returning a failing exit status.
Job success therefore does not guarantee successful overlay processing.

The normal run retains the existing collection, rating, playlist, and overlay
configuration. Recovery does not require deleting the cache, clearing poster
backups, or forcing every overlay to be reapplied.

## MDBList-dependent ribbon badges

The default ribbon overlays for Rotten Tomatoes Verified Hot, Rotten Tomatoes
Certified Fresh, Metacritic Must See, and Commonsense Selection use MDBList.
MDBList list requests now require authentication; without an API key they return
HTTP 401 and those badges cannot be built.

Obtain an API key from [MDBList preferences](https://mdblist.com/preferences/).
Add `KOMETA_MDBLISTAPIKEY` to `secret.sops.yaml` with SOPS, then configure the
root mapping in `config/config.yml`:

```yaml
mdblist:
  apikey: <<MDBLISTAPIKEY>>
  cache_expiration: 60
```

Never paste the key into chat or commit plaintext. Do not silently disable these
badges to hide authentication errors. Kometa can still apply other overlays
despite MDBList errors, and its Job may report success.

## Alerts

Kometa uses the monitoring stack's bundled Job alerts:

- `KubeJobFailed` fires when a Job failure persists for 15 minutes.
- `KubeJobNotCompleted` fires when an active Job has run for more than 12 hours.

Both alerts use `severity: warning`. Pushover notifications for `kometa-*` Jobs in
`media` are restricted to the normal hours documented in
[the Alertmanager policy](../../infra/prometheus-operator/README.md).
Kometa alerts classified as `critical` notify anytime.

No custom Kometa alert rules are installed. Application errors that exit zero,
partial overlay failures, and a missing or suspended CronJob are not detected.
A retained failed Job can keep alerting even after a newer run succeeds.

## Investigation

Use `kubectl -n media get cronjob kometa` and inspect the latest Job immediately
with `kubectl -n media logs -f job/<job-name>`. Completed pods may be removed
before the retained Job, so a Job's `Complete` status alone is not overlay
verification. Persistent `meta.log` and per-library logs provide run evidence.

For an approved one-off overlay run, use a Job named `kometa-manual-*` based on
the deployed CronJob and append `--overlays-only` to the Kometa command.
Do not overlap another Kometa run: manually created Jobs do not
inherit the CronJob controller's concurrency enforcement.

Confirm `Finished Movies Library Overlays`, `Finished Series Library Overlays`,
and `Finished Run` in the current log, and inspect representative Plex posters.
Obtain approval before deleting Jobs, resetting poster backups, changing
collections, or sending a real test notification.
