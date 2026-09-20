# Travel Plans

Private offline-first Travel Plans PWA at
`https://vacations.peterson.com.ar`. The origin is a ClusterIP Service and is
reachable only from its dedicated `cloudflared` Deployment. There is
intentionally no `HTTPRoute`, LoadBalancer, NodePort, or shared public-gateway
route.

The initial GitOps state is bootstrap-safe: the Service and both controllers
are disabled because no `vacations-site` image has been published yet. The
first validated `vacations-image-published` dispatch inserts the real
digest-pinned image and enables all resources atomically. Later promotions
change only the source SHA and image tag/digest.

## Required Kubernetes secrets

Create a classic PAT owned by a read-only machine user with only
`read:packages` and access to the private
`ghcr.io/mpeterson/vacations-site` package. Create a remotely managed
Cloudflare Tunnel as described below and copy its token.

From this directory, create both manifests without writing plaintext secrets
to Git:

```sh
read -rp "GHCR username: " GHCR_USERNAME
read -rsp "GHCR pull token: " GHCR_PULL_TOKEN
echo
kubectl create secret docker-registry vacations-ghcr \
  --namespace vacations \
  --docker-server ghcr.io \
  --docker-username "$GHCR_USERNAME" \
  --docker-password "$GHCR_PULL_TOKEN" \
  --dry-run=client \
  --output yaml |
  yq '.metadata.annotations."kustomize.config.k8s.io/needs-hash" = "true"' |
  sops --encrypt \
    --filename-override ghcr-secret.sops.yaml \
    /dev/stdin > ghcr-secret.sops.yaml
unset GHCR_USERNAME GHCR_PULL_TOKEN

read -rsp "Cloudflare Tunnel token: " TUNNEL_TOKEN
echo
kubectl create secret generic vacations-cloudflared \
  --namespace vacations \
  --from-literal "TUNNEL_TOKEN=$TUNNEL_TOKEN" \
  --dry-run=client \
  --output yaml |
  yq '.metadata.annotations."kustomize.config.k8s.io/needs-hash" = "true"' |
  sops --encrypt \
    --filename-override cloudflared-secret.sops.yaml \
    /dev/stdin > cloudflared-secret.sops.yaml
unset TUNNEL_TOKEN

yq -i '.generators = ["secret-generator.yaml"]' kustomization.yaml
sops --decrypt ghcr-secret.sops.yaml |
  yq -e '.type == "kubernetes.io/dockerconfigjson"
    and (.data.".dockerconfigjson" | length > 0)' >/dev/null
sops --decrypt cloudflared-secret.sops.yaml |
  yq -e '.data.TUNNEL_TOKEN | length > 0' >/dev/null
```

Commit the two encrypted files and the generator change through a PR before
the first image promotion. Never commit the generated plaintext. The required
keys are `.dockerconfigjson` in `vacations-ghcr` and `TUNNEL_TOKEN` in
`vacations-cloudflared`.

## Cloudflare Tunnel and Access

1. In Zero Trust, create a remotely managed tunnel named `vacations`. Do not
   reuse a tunnel that publishes other origins.
2. Add exactly one public hostname:
   `vacations.peterson.com.ar` -> HTTP ->
   `vacations.vacations.svc.cluster.local:8080`. Do not add a wildcard,
   private-network route, or alternate origin.
3. Create a self-hosted Access application for
   `vacations.peterson.com.ar`. Enable Instant Auth and the One-time PIN
   identity provider.
4. Add an Allow policy containing only the explicit guest email addresses.
   Add a separate Service Auth policy containing only the smoke-test service
   token. Do not add an Everyone, Bypass, or broad email-domain policy; all
   unmatched identities remain denied.
5. In the tunnel public-hostname settings, enable **Protect with Access** and
   configure the Access team name and this application's AUD tag. This makes
   `cloudflared` validate the Access JWT before forwarding to the origin.
6. Confirm the public hostname shows a healthy tunnel and that an unauthenticated
   request is redirected to Access, an unlisted OTP email is denied, and an
   a listed guest email succeeds.

The Cilium policy resolves Cloudflare's documented tunnel FQDNs dynamically
and permits TCP/UDP 7844. Static IP allowlists are intentionally avoided
because Kubernetes NetworkPolicy cannot track DNS changes. TCP 443 is limited
to `*.cloudflareaccess.com` for Access JWT validation. `cloudflared` can reach
only cluster DNS, the vacations Service, tunnel endpoints, and Access
validation; the application has no egress.

## PMTiles cache rule

Create one Cache Rule with this expression:

```text
(http.host eq "vacations.peterson.com.ar" and
 ends_with(http.request.uri.path, ".pmtiles"))
```

Set **Cache eligibility** to eligible for cache, set a 30-day Edge TTL, and
respect the origin Browser TTL. Keep the full query string in the cache key.
Do not create a Cache Everything rule for the hostname. Access must remain in
front of the cache, and the PMTiles response must remain uncompressed so byte
ranges can be served correctly.

Before saving, verify the account still shows the Free plan, the Access user
count is within the free seat allowance, and the tunnel, Access policies,
service token, and Cache Rule do not show a paid-plan prompt. Recheck the
Billing and Usage pages after setup.

## GitHub automation

The promotion workflow accepts only `vacations-image-published` dispatches
whose payload has exactly these fields:

```json
{
  "source_repository": "mpeterson/vacations",
  "source_sha": "<40 lowercase hex characters>",
  "image": "ghcr.io/mpeterson/vacations-site",
  "digest": "sha256:<64 lowercase hex characters>"
}
```

Create a GitHub App installed only on `mpeterson/vacations` and
`mpeterson/homelab`. Grant repository **Contents: Read and write** and **Pull
requests: Read and write**; grant no administration, workflow, issue, or
organization permissions. Configure in `mpeterson/homelab`:

- Repository variable `VACATIONS_PROMOTER_APP_ID`
- Actions secret `VACATIONS_PROMOTER_APP_PRIVATE_KEY`

Use the same App from the vacations publishing workflow to send the repository
dispatch. In the `vacations-site` package settings, grant the homelab
repository Actions access. This lets the promotion workflow verify the private
tag and canonical digest with its short-lived `GITHUB_TOKEN`; no long-lived
GHCR token is needed in GitHub Actions.

The bot maintains `automation/vacations-image`, runs `just lint` and
`just validate`, and enables squash auto-merge. The protected `main` branch
still requires `All linters passed`, `All CI gates passed`, and
`All validations passed`. A newer dispatch cancels a pending workflow and
updates the same PR without bypassing those checks.

Create an Access service token restricted to the application's Service Auth
policy, then configure these homelab Actions secrets:

- `VACATIONS_ACCESS_CLIENT_ID`
- `VACATIONS_ACCESS_CLIENT_SECRET`

After each promotion reaches `main`, the smoke workflow waits up to 20 minutes
for ArgoCD reconciliation. It verifies the expected source SHA, cache headers,
same-origin PMTiles discovery, uncompressed valid and suffix ranges, and the
required invalid-range response. A timeout or mismatch fails explicitly.

## Verification and rollback

Verify there is no origin bypass:

```sh
kubectl get service,httproute -n vacations
kubectl get networkpolicy,ciliumnetworkpolicy -n vacations
kubectl get pods -n vacations
```

The only Service must be `ClusterIP`, and no `HTTPRoute` may exist. Test the
hostname only through Cloudflare Access; do not expose a temporary NodePort or
Gateway route.

For an application rollback, open a PR restoring the previous known-good
source SHA and digest in `app.yaml` and `values.yaml`. ArgoCD will reconcile
the prior immutable image. To cut external access while investigating, disable
the tunnel public hostname in Cloudflare; do not add an origin bypass. Revert
through Git rather than editing the ArgoCD-managed Deployment in the cluster.
