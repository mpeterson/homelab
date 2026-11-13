# Kometa

Kometa runs daily at midnight in `Asia/Jerusalem` and processes the Movies and
Series libraries, including their configured overlays.

## Runtime and failure detection

The container keeps its root filesystem read-only. A writable `/tmp` is required
for SQLite cache migrations and other temporary files. Without it, Kometa can log
`disk I/O error` during cache initialization and exit zero without processing
either library.

Kometa v2.5.5 has no fail-on-error flag. Its
[run handler](https://github.com/Kometa-Team/Kometa/blob/1ec206b4c9dd0e9f9ea7b9e7a4e2e56b349e68d0/kometa.py#L760-L761)
catches and logs runtime exceptions without returning a failing exit status.

The mounted `config/run.py` runner preserves subprocess failures and also fails
the Job when the current main log contains an `ERROR` or `CRITICAL` record, lacks
run completion, or lacks overlay completion for a configured library. Warnings
alone do not fail the run. Logs remain in `/config/logs` on the existing PVC;
Kometa rotates them. Inspect PVC capacity if logs or overlay assets grow.

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
badges to hide authentication errors. Kometa can still apply other overlays, but
the runner correctly marks a run with MDBList errors as failed.

## Alerts

`KometaRunFailed` fires after five minutes when a scheduled Job or a
`kometa-manual-*` Job fails and no newer successful run exists. A successful retry
clears the alert even while Kubernetes retains the failed Job.

`KometaRunStale` fires after 15 minutes if the CronJob is absent or its last
successful scheduled run is older than 36 hours. The 36-hour budget allows the
daily schedule plus 12 hours for a long library run; a new, never-successful
CronJob receives the same grace period. A manual run does not update the
CronJob controller's last-success timestamp.

These alerts use `severity: warning`. Pushover notifications are restricted to
the normal hours documented in
[the Alertmanager policy](../../infra/prometheus-operator/README.md).
Kometa alerts classified as `critical` notify anytime.
Generic Kometa `KubeJobFailed` and `KubeJobNotCompleted` notifications are
suppressed to avoid bypassing that policy; the Kometa rules provide failure and
staleness coverage.

## Investigation

Use `kubectl -n media get cronjob kometa` and inspect the latest Job immediately
with `kubectl -n media logs -f job/<job-name>`. Completed pods may be removed
before the retained Job, so a Job's `Complete` status alone is not overlay
verification. Persistent `meta.log` and per-library logs provide run evidence.

For an approved one-off overlay run, use a Job named `kometa-manual-*` based on
the deployed CronJob, retain the mounted runner, and append `--overlays-only` to
its arguments. Do not overlap another Kometa run: manually created Jobs do not
inherit the CronJob controller's concurrency enforcement.

Confirm `Finished Movies Library Overlays`, `Finished Series Library Overlays`,
and `Finished Run` in the current log, and inspect representative Plex posters.
Obtain approval before deleting Jobs, resetting poster backups, changing
collections, or sending a real test notification.
