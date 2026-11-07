# 02. Deploying the Passport Proxy

> **Audience**: Administrators (platform / infrastructure)
> **Time required**: 30-45 minutes
> **Previous step**: [01. Infrastructure](01-infrastructure.md)
> **Next step**: [03. DNS and public exposure](03-dns-and-exposure.md)

Pull the Passport image and chart, generate the keys, and deploy with Helm.

## What Passport is (in three minutes)

Passport is a mechanism that lets you use API secrets (API keys, tokens) **without
handing them out to developers**.

Developer code contains a **secret reference** instead of the real key. Requests travel
through the Passport Proxy, which resolves the reference to the real secret and forwards
the request to the API. Developers never see the real key.

```
Developer code                Passport Proxy              The real API
(secret reference)  ──────▶  resolves the reference  ──▶  (authenticated
                              and attaches the              with the real key)
                              real key
                                    │
                                    ▼
                              logs API traffic
                              in OTEL format
```

| Component | Where it runs | Who configures it | Role |
| --- | --- | --- | --- |
| **Passport Proxy** | Your own Kubernetes | Administrator (02-03) | Relays and logs traffic, resolves secrets |
| **Passport CLI** | The developer's machine | Developer (04) | The developer-side daemon. Points local traffic at the Proxy |
| **Namespaces** | Passport Cloud | Administrator (03) | Defines who can access which endpoints |

---

## What to prepare in advance

This chart is **fail-closed by design**. If a required item is unset, either
`helm install` stops right there or the Pod refuses to start. "Install it for now and fix
it later" is not an option, so gather these first.

### Always required

| What you need | How to get it | What happens without it |
| --- | --- | --- |
| **Registry credentials** | Issued from Passport's Registry settings screen | No image or chart can be pulled at all |
| **Postman Team ID** | [Step 4-1](#step-4-1-set-the-postman-team-id) | **The Pod refuses to start** |
| **CA key / reference key** | Generate them yourself ([Step 4-2](#step-4-2-create-the-secret-holding-the-ca-key-and-reference-key)) | **The Pod refuses to start**. Real keys are required unconditionally |
| **IRSA role ARN** | `terraform output` from 01 | Secrets Manager resolution fails |
| **ACM certificate ARN** | Step 6 of 01 | The management plane Ingress cannot terminate TLS |

### Required depending on conditions

The following **work as-is with the defaults**, so they are unnecessary during
verification.

| Item | Default | Condition that makes it necessary |
| --- | --- | --- |
| `audit.sink` | **`stdout` (enabled)** | Production. `stdout` only goes to the Pod log and is not persisted |
| `bundle.jwksUrl` | **Postman's public JWKS is already configured** | Normally no change needed. It is a public endpoint, so no credentials either |
| S3 bucket | — | Only when using the Proxy Console (`console.enabled`) |

> **Differences from the official procedure**
>
> The official procedure describes `audit.sink` and `bundle.jwksUrl` as "required; startup
> fails if unset", but the actual `values.yaml` **ships with default values**.
> Conversely, the **real required items are the Team ID and the CA key / reference key**,
> which the official procedure does not mention.

---

## Step 1. Issue registry credentials

Issue credentials from Passport's **Registry settings**. One issuance by an organization
administrator is enough for the whole team to use.

```bash
read -s PASSPORT_REGISTRY_KEY
export PASSPORT_REGISTRY_KEY
```

> **Handling the secret**
> This key grants access to the registry. Entering it with `read -s` as shown above keeps
> it out of your shell history. Take care not to commit it to the repository.

## Step 2. Create the namespace and the pull secret

This **must match** `passport_namespace` from 01 (default `passport`).

```bash
kubectl create namespace passport

kubectl create secret docker-registry passport-registry \
  --docker-server=ociregistry.usepassport.ai \
  --docker-username=passport \
  --docker-password="$PASSPORT_REGISTRY_KEY" \
  -n passport
```

If you want to inspect the image locally (optional):

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | docker login ociregistry.usepassport.ai \
  --username passport --password-stdin
docker pull ociregistry.usepassport.ai/passport/passport-proxy:v0.6.0
```

## Step 3. Pull the Helm chart and write out the values

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | helm registry login ociregistry.usepassport.ai \
  --username passport --password-stdin

helm show values oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 > values.yaml
```

> Because the values are written out from the same chart used at install time, there is no
> risk of the defaults and the templates disagreeing.

## Step 4. Configure values.yaml

**This Step is where people get stuck most often.** Work through it in the order below.

### Step 4-1. Set the Postman Team ID

Set it in `values.yaml`.

```yaml
bundle:
  allowedTeamIds: "org_01EXAMPLE000000000000000"
```

> **⚠️ This is the WorkOS-format `org_...` value, not the numeric ID returned by the
> Postman API.**
>
> If you enter the numeric ID, **the Pod still starts normally**, so you will not notice
> the mistake until a developer runs `passport setup` and `/issue-cert` returns 403.
> Check Team Settings → Team Info for the value beginning with `org_`.

### Step 4-2. Create the Secret holding the CA key and reference key

With `keys.mode: existingSecret` (the default), you need a K8s Secret containing the
following two keys.

- **CA signing key** — issues the MITM CA and the per-user client certificates
- **reference key** — the RSA private key that decrypts the vault references encrypted by
  Passport Cloud

> Ephemeral CA mode **has been removed from the runtime**. Real keys are required and
> cannot be omitted.

```bash
umask 077
mkdir -p .keys
openssl genrsa -out .keys/ca-private-key 4096
openssl genrsa -out .keys/reference-private-key 4096

kubectl create secret generic passport-keys \
  --from-file=ca-private-key=.keys/ca-private-key \
  --from-file=reference-private-key=.keys/reference-private-key \
  -n passport
```

Make the file names match `keys.caFileName` / `keys.referenceFileName` in `values.yaml`
(the above matches the defaults).

> **Handling the keys**
> Do not commit the generated keys to the repository. Add `.keys/` to `.gitignore`.
> **The reference key is needed in 03 to extract the public key when registering the
> Access Proxy, so keep it in a safe place even after creating the Secret** (losing it
> means recreating the Access Proxy).

### Step 4-3. Configure the image and pull secret

```yaml
image:
  repository: ociregistry.usepassport.ai/passport/passport-proxy
  tag: "v0.6.0"
  pullSecrets:
    - name: passport-registry    # ← "- name:" is required, not "- passport-registry"
```

> **⚠️ The easiest trap to fall into**
>
> `pullSecrets` is written as a **list of maps**. If you write it as a list of strings,
> `helm install` fails with the following error.
>
> ```text
> .spec.template.spec.imagePullSecrets: element 0:
>   associative list with keys may not have non-map elements
> ```
>
> ```yaml
> # NG                          # OK
> pullSecrets:                  pullSecrets:
>   - passport-registry           - name: passport-registry
> ```
>
> **This error cannot be caught by `--dry-run`** (it only surfaces at server-side apply
> time). It is an example of an install that can fail even though dry-run passed.

### Step 4-4. Configure the data plane for public exposure

**This guide chooses `internet-facing`**, so the setup can be rolled out to the team
without port forwarding.

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  mgmt:
    annotations: {}     # Leave the management plane as ClusterIP. Do not change this
```

> **⚠️ The LB scheme is immutable.**
>
> **Decide it at the time of the first `helm install`.** Trying to switch `internal` ↔
> `internet-facing` later will not take effect via `helm upgrade`; it requires deleting
> and recreating the Service (and the DNS name changes too).

#### Is `internet-facing` defensible from a security standpoint

For the data plane, **yes**. The reasoning:

| Defense layer | Detail |
| --- | --- |
| **mTLS required** | Without a client certificate signed by the Passport CA, the TLS handshake is cut off. You cannot get in without authentication |
| **Certificate issuance path is limited** | Certificates are only issued to legitimate users who present a Postman access bundle (ES256/JWKS verified) |
| **Tenant pinning** | `bundle.allowedTeamIds` restricts it to your own organization |
| **Short-lived certificates** | The TTL measures out to roughly 300 seconds |
| **Secrets never travel the path** | The real API credentials are resolved as vault references, so no plaintext secret passes through the client side |

The chart defaulting to `internal` is defense-in-depth; public exposure is not a design
error.

> **If you choose `internal`**
>
> If security requirements mean it must stay inside the VPC, leave it as `internal`.
> In that case you need **a VPN, a bastion host, or port-forward** to connect the
> developers' CLI. Everything from 03 onward in this guide assumes `internet-facing`, so
> see [Troubleshooting](troubleshooting.md#reaching-an-internal-lb).

### Step 4-5. Expose the management plane via Ingress

The management plane (:8081) **must not be a LoadBalancer**. Use the `ingress` block the
chart provides (with its path allowlist).

```yaml
ingress:
  enabled: true
  className: alb
  host: passport-mgmt.example.com
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-1:123456789012:certificate/xxxx
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /readyz
    alb.ingress.kubernetes.io/group.name: passport-mgmt
  paths:                 # ← these two are the only paths to expose
    - /ca.pem
    - /issue-cert
  tls: []                # Unnecessary because the ALB terminates TLS (set it only for nginx)
```

Put the ARN issued in Step 6 of 01 into `certificate-arn`.

> **⚠️ Do not widen `paths`.**
>
> Port :8081 hosts both `/ca.pem` and `/issue-cert` (which you want to expose) and the
> `/metrics` and `/revocation` admin APIs plus the Console UI (which you **do not** want
> to expose). Setting `paths` to `/` exposes all of them.
>
> As things stand, `console.enabled: false` and an unset `revocation.adminTokenSecretRef`
> make it fail-closed, but that is not "locked" — it is "**the feature simply isn't
> registered yet**". The moment you enable them in the future, they are exposed.
>
> The mgmt Service stays ClusterIP regardless of `type`, so nothing outside these two
> paths is reachable from outside.

> **If you want to scrape `/metrics` with Prometheus**, do not add it to the Ingress; use
> `metrics.serviceMonitor.enabled: true` and scrape from inside the cluster.

### Step 4-6. IRSA and the remaining items

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/passport-sandbox-dev-passport-proxy

vault:
  source: aws-secrets-manager
  aws:
    region: ap-northeast-1      # ← the default is us-east-1. Must be changed

namespace:
  create: false                 # Already created with kubectl create namespace in Step 2
```

| Item | Example setting | Notes |
| --- | --- | --- |
| `serviceAccount.annotations` | `passport_proxy_irsa_role_arn` from 01 | Without this, Secrets Manager resolution fails |
| `vault.aws.region` | `ap-northeast-1` | **The default is `us-east-1`**, so it must be changed |
| `namespace.create` | `false` | Because it was already created in Step 2 |
| `audit.sink` | `stdout` (verification) / `s3` (production) | `stdout` is not persisted |
| `proxy.dataplaneCertSANs` | **Leave empty at this point** | Set in 03 (the reason follows below) |
| `proxy.managementHost` | **Leave empty at this point** | Same as above |

### Step 4-7. Consider enabling these as well if exposing publicly (optional)

**This section includes items that have not been verified.** During verification, proceed
with the defaults and enable them one at a time when needed, checking that the Pod starts
each time.

```yaml
rateLimit:
  enabled: true                 # Protection against brute force on /issue-cert
  perToken: { rps: 10, burst: 20 }

audit:
  sink: s3                      # stdout is lost when the Pod restarts
  s3: { bucket: "my-audit-bucket", region: "ap-northeast-1", prefix: passport-audit }
```

> **⚠️ `bundle.requireBundleClaims` will not let the Pod start unless all three settings
> are present.**
>
> If you enable it, you must also set **both** `audience` and `issuer`. If only one is
> set, or both are missing, it fail-closes and refuses to start.
>
> ```text
> startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both
>   PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set
> ```
>
> **The chart's `values.yaml` does not document this dependency.** Both `issuer` and
> `audience` are commented merely as "optional"; the constraint exists only inside the
> binary.
>
> Furthermore, the value that belongs in `issuer` (the bundle JWT's `iss` claim)
> **cannot be confirmed without decoding an actually issued bundle**. If you put in a
> guess, the Pod starts but `/issue-cert` returns 403, so you notice late (the same
> failure pattern as getting the Team ID wrong).
>
> **During verification, we recommend leaving `requireBundleClaims: false` (the default).**
> Even when disabled, JWKS signature verification and tenant pinning via `allowedTeamIds`
> work independently; this setting merely "additionally enforces the presence of the
> claims".
>
> If you do enable it, first get `passport login` working with the default settings, check
> the `iss` of the bundle you obtain, and then configure it.

> **We recommend holding off on `networkPolicy.enabled: true` during verification.**
> As the comment in `values.yaml` notes, there is a history of the per-port, all-or-nothing
> NetworkPolicy silently breaking `/issue-cert`. If you do enable it, be sure to enumerate
> the setup client and Prometheus in `ingress.mgmt.from`.

---

## Step 5. Deploy the Proxy

### Why this takes two stages

`proxy.dataplaneCertSANs` takes **the hostname the CLI connects to**. If it does not match
the actual connection target, the CLI's TLS handshake fails with
`ERR_TLS_CERT_ALT_NAME_INVALID`.

When using your own domain, **the LB DNS name that the CNAME points at cannot be known
until it has been created**, which gives this ordering.

```
02: install → the NLB / ALB is created → get the DNS name
                                           │
03:                                        ▼
    point a Route53 CNAME at it → set the FQDN in values → helm upgrade
                                                           (the CLI can now connect)
```

### 5-1. Verify the rendering

Check that the chart renders without creating real resources.

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport --dry-run=client
```

Because you chose `internet-facing`, **warnings about a public LB are expected** (they are
accepted on the grounds given in Step 4-4). Deal with any other errors.

### 5-2. Install

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

> **⚠️ `install` is for the first time only. Use `upgrade` from the second time on.**
>
> If you run `helm install` while the release already exists, it is rejected with the
> following error **regardless of whether the previous attempt succeeded or failed**.
>
> ```text
> Error: INSTALLATION FAILED: release name check failed:
>   cannot reuse a name that is still in use
> ```
>
> Applying changes to `values.yaml` is also `upgrade`.
>
> ```bash
> helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
>   --version 0.6.0 -f values.yaml -n passport
> ```
>
> **If you are unsure which to use, add `--install`** — it installs if absent and upgrades
> if present (being idempotent, it suits trial and error during verification).
>
> ```bash
> helm upgrade --install passport oci://ociregistry.usepassport.ai/passport/passport \
>   --version 0.6.0 -f values.yaml -n passport
> ```
>
> You can check the current state with `helm list -n passport` /
> `helm status passport -n passport`. Only when you want to start over do you use
> `helm uninstall passport -n passport`.

### 5-3. Check the state of the Pods and the release

```bash
kubectl -n passport get pods,svc,ingress
helm status passport -n passport
```

Success means both Pods are `1/1 Running` with `RESTARTS 0` and the release shows
`STATUS: deployed`.

> **⚠️ `helm status` showing `deployed` does not guarantee the Pods are running.**
>
> This chart is fail-closed by design, and configuration inconsistencies surface not at
> install time but **at Pod startup**. If you get `CrashLoopBackOff`, look at the logs for
> the reason first.
>
> ```bash
> kubectl -n passport get pods
> kubectl -n passport logs -l app.kubernetes.io/instance=passport --tail=20
>
> # If it has already restarted and the current log is empty, look at the container that died
> kubectl -n passport logs <pod-name> --previous --tail=20
> ```
>
> If there is a single line beginning with `startup failed: config: ...`, that is the
> cause. For the common ones, see [Troubleshooting](troubleshooting.md#startup).

```text
NAME                         TYPE           EXTERNAL-IP                              PORT(S)
svc/passport-passport        LoadBalancer   k8s-passport-....elb.amazonaws.com        8443:xxxxx/TCP
svc/passport-passport-mgmt   ClusterIP      <none>                                    8081/TCP

NAME                                CLASS   HOSTS                       ADDRESS
ingress/passport-passport-setup     alb     passport-mgmt.example.com   k8s-passportmgmt-....elb.amazonaws.com
```

Be sure to confirm that **`passport-passport-mgmt` is still `ClusterIP`**.

### 5-4. Check the startup log

> **⚠️ Do not use `--tail`.**
>
> The startup log appears in the **first few lines**. Meanwhile the NLB health check keeps
> emitting `TLS handshake error` every few seconds
> ([described below](#tls-handshake-error-is-normal)), so within a few minutes it swells to
> thousands of lines. With `--tail=30` all you see is health check noise.

Strip the noise and read from the top.

```bash
POD=$(kubectl -n passport get pods -l app.kubernetes.io/instance=passport \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n passport logs "$POD" | grep -v "TLS handshake error" | head -10
```

The logs are OTEL-format JSON and hard to read, so to extract just the essentials:

```bash
kubectl -n passport logs "$POD" | grep -v "TLS handshake error" \
  | python3 -c 'import json,sys
for l in sys.stdin:
    try: d = json.loads(l)
    except ValueError: continue
    print(d["SeverityText"].ljust(5), d["Body"]["Value"])'
```

```text
WARN  passport: revocation disabled (set PASSPORT_PROXY_REVOCATION_STORE, ...)
INFO  passport: rate limiting enabled (in-memory per-pod)
WARN  passport: console auth disabled (PASSPORT_PROXY_CONSOLE_USER and/or ... unset)
INFO  passport: /issue-cert enabled
INFO  passport: managed bootstrap disabled; /issue-cert requires a valid bundle
INFO  starting management server
INFO  starting HTTPS proxy
```

Things are healthy if the following three appear.

| Log | Meaning |
| --- | --- |
| `passport: /issue-cert enabled` | jwksUrl and allowedTeamIds were loaded |
| `starting HTTPS proxy` (port 8443) | The data plane has started listening |
| `starting management server` (port 8081) | The management plane has started listening |

The following WARNs are **normal depending on your configuration**. Ignore them if you
have the corresponding feature disabled.

```text
passport: revocation disabled (set PASSPORT_PROXY_REVOCATION_STORE, ...)
passport: console auth disabled (PASSPORT_PROXY_CONSOLE_USER and/or ... unset)
passport: managed bootstrap disabled; /issue-cert requires a valid bundle
```

#### `TLS handshake error` is normal

```text
2026/11/05 08:03:21 http: TLS handshake error from 10.0.138.89:51114: EOF
```

It appears because **the NLB health check hits :8443 without a client certificate**. The
data plane requires mTLS, so cutting off a connection that has no certificate is by
design. You can confirm this from the source IP being a private IP inside the VPC
(`10.x.x.x`).

If the Pod is `1/1 Running`, ignore it. **If the log being flooded gets in the way**, you
can reduce it by pointing the health check at the management plane.

```yaml
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "8081"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: http
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /readyz
```

> These annotations have not been verified. If you apply them, confirm that the Pod starts
> and that the NLB targets stay `healthy`.

### 5-5. Get the LB DNS names

They are used for the Route53 CNAMEs in 03.

```bash
# data plane (NLB)
kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

# management plane (ALB)
kubectl -n passport get ingress -l app.kubernetes.io/instance=passport \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'; echo
```

> **⚠️ The Ingress name is not the same as the release name.**
>
> The Ingress the chart creates is **`<release>-<chart>-setup`**, which with the default
> release name is `passport-passport-setup`. `get ingress passport` will not find it.
>
> The command above selects by label (`app.kubernetes.io/instance`), so it works even if
> the name changes. You can check the actual name with
> `kubectl -n passport get ingress`.

ALB provisioning takes **2-3 minutes**. If it returns empty, wait a little and run it
again.

---

## Confirming completion

- [ ] Both Pods are `1/1 Running`
- [ ] `helm status` shows `deployed`
- [ ] `passport-passport` is a LoadBalancer and has an EXTERNAL-IP
- [ ] **`passport-passport-mgmt` is still ClusterIP**
- [ ] The Ingress has an ADDRESS
- [ ] The startup log contains `/issue-cert enabled`

Values to record:

| Item | How to get it |
| --- | --- |
| **NLB DNS name** | `kubectl -n passport get svc passport-passport -o jsonpath='{...}'` |
| **ALB DNS name** | `kubectl -n passport get ingress -l app.kubernetes.io/instance=passport -o jsonpath='{...}'` (the Ingress name is `passport-passport-setup`) |

→ Continue to [03. DNS and public exposure](03-dns-and-exposure.md)
