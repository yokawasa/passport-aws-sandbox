# 03. DNS and Public Exposure

> **Audience**: Administrators (platform / infrastructure)
> **Time required**: 30-40 minutes
> **Previous step**: [02. Deploying the Passport Proxy](02-passport-proxy.md)
> **Next step**: [04. Developer Setup](04-developer-setup.md)

Create CNAMEs in Route53 to pin the hostnames, update the certificate SANs with
`helm upgrade`, and verify connectivity **without port forwarding**. Finally, configure
Namespaces in Passport Cloud.

## What this step creates

| What | How | Purpose |
| --- | --- | --- |
| `passport-proxy` CNAME → NLB | AWS CLI (manual) | The data plane the CLI connects to over mTLS |
| `passport-mgmt` CNAME → ALB | AWS CLI (manual) | `/ca.pem` and `/issue-cert` |
| Certificate SAN update | `helm upgrade` | So the TLS handshake succeeds |
| Access Proxy / Namespace | Passport Cloud (UI) | Issuing secret references |

---

## Step 1. Create the CNAMEs in Route53

### 1-1. Prepare the variables

```bash
export AWS_PROFILE=my-aws-profile   # adjust for your environment
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ               # example.com
export DOMAIN=example.com
export MGMT_HOST=passport-mgmt
export PROXY_HOST=passport-proxy

# LB DNS names from step 5-5 of 02
NLB_DNS=$(kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_DNS=$(kubectl -n passport get ingress -l app.kubernetes.io/instance=passport \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

echo "NLB: $NLB_DNS"
echo "ALB: $ALB_DNS"
```

Confirm that neither is empty. If one is empty, the LB is still being provisioned.

> The Ingress name differs from the release name: it is **`passport-passport-setup`**
> (`<release>-<chart>-setup`). The command above selects by label, so it does not depend
> on the name.

### 1-2. Create the records

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Comment\": \"Passport (JP team) data plane and management plane\",
    \"Changes\": [
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"$PROXY_HOST.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$NLB_DNS\"}]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"$MGMT_HOST.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$ALB_DNS\"}]
        }
      }
    ]
  }"
```

> **Why a CNAME is used for stability**
>
> If the LB is recreated its DNS name changes, `dataplaneCertSANs` no longer matches, and
> the CLI fails with `ERR_TLS_CERT_ALT_NAME_INVALID`. **With a CNAME in between, recreating
> the LB only requires repointing the CNAME, so the SANs and the instructions given to
> developers stay unchanged.**

### 1-3. Verify propagation

```bash
dig +short $PROXY_HOST.$DOMAIN
dig +short $MGMT_HOST.$DOMAIN
```

If the global IP behind the CNAME is returned, you are set. The TTL is 300, so changes
normally take effect immediately.

> **Difference from an `internal` configuration**
>
> With an `internal` NLB, DNS resolves but returns a private IP inside the VPC (`10.x.x.x`),
> which is unreachable from outside the organization. With `internet-facing` you get a global
> IP. **If an IP starting with `10.` comes back**, check the `scheme` setting.

---

## Step 2. Pin the hostnames and run helm upgrade

Set the finalized FQDNs in two places in `values.yaml`.

```yaml
proxy:
  dataplaneCertSANs: "passport-proxy.example.com"
  managementHost: "passport-mgmt.example.com"
```

| Item | Value to set | Role |
| --- | --- | --- |
| `dataplaneCertSANs` | **The data plane FQDN** | Goes into the SAN of the TLS certificate the Proxy generates. Must match what the CLI connects to |
| `managementHost` | **The management plane FQDN** | Goes into the CRL distribution point of the issued client certificates |

```bash
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

### Restart the Pods

```bash
kubectl -n passport rollout restart deploy/passport-passport
kubectl -n passport rollout status deploy/passport-passport
```

> **⚠️ IRSA does not take effect from `helm upgrade` alone.**
> The EKS webhook injects the credential environment variables **only at Pod creation time**.
> If you change or add `serviceAccount.annotations`, you must recreate the Pods.
> Forget this and Secrets Manager resolution will fail.

---

## Step 3. Verify connectivity (without port forwarding)

This is the biggest difference from the previous configuration: **`kubectl port-forward` is
no longer needed**.

### 3-1. Can the management plane be reached from outside?

```bash
export MGMT=https://passport-mgmt.example.com

# Can the CA certificate be fetched? (a publicly exposed path)
curl -fsS "$MGMT/ca.pem" | head -1
```

```text
-----BEGIN CERTIFICATE-----
```

If this comes back, the path ALB → TLS termination → mgmt Service is working.

### 3-2. Are the non-public paths blocked?

**Always perform this check.** It verifies that the allowlist is in effect.

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/metrics"
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/readyz"
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/console"
```

**The correct state is `404` for all of them** (the ALB does not route them). If any path
returns `200`, `ingress.paths` is too broad.

> `/readyz` is used for the ALB health check, but since it is not in `paths` it cannot be
> reached from outside. That is the intended state.

### 3-3. Check the health check

`/readyz` is not publicly exposed, so **judge by the Pod's `READY` column**.

```bash
kubectl -n passport get pods -l app.kubernetes.io/instance=passport
```

```text
NAME                                 READY   STATUS    RESTARTS   AGE
passport-passport-5779ff65fb-b6t6f   1/1     Running   0          10m
passport-passport-5779ff65fb-m4rqp   1/1     Running   0          10m
```

**If `READY` is `1/1`, `/readyz` is passing.** The kubelet hits `/readyz` every 10 seconds as
a readiness probe, and on failure the Pod drops to `0/1`. You can check the probe
configuration like this.

```bash
kubectl -n passport get deploy passport-passport \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'; echo
```

```text
{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"mgmt","scheme":"HTTP"},
 "initialDelaySeconds":3,"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}
```

If it stays at `0/1`, the reason for the probe failure appears in Events.

```bash
kubectl -n passport describe pod -l app.kubernetes.io/instance=passport | grep -A10 "^Events:"
```

> **⚠️ You cannot hit it from inside the container with `kubectl exec`.**
>
> The image is distroless: there is no shell, no `curl`, and no `wget`.
>
> ```text
> OCI runtime exec failed: exec failed: unable to start container process:
>   exec: "wget": executable file not found in $PATH
> ```
>
> If you want to see the contents of `/readyz` (which check is failing), temporarily start a
> separate Pod and hit the Service from inside the cluster.
>
> ```bash
> kubectl -n passport run curl-tmp --rm -it --restart=Never \
>   --image=curlimages/curl -- \
>   curl -s http://passport-passport-mgmt:8081/readyz
> ```
>
> ```json
> {"status":"ready","checks":[
>   {"name":"signing_key_loaded","ready":true},
>   {"name":"data_plane_listener_up","ready":true},
>   {"name":"audit_sink_initialized","ready":true},
>   {"name":"startup_complete","ready":true}]}
> ```
>
> The name of any check with `ready":false` can be used directly to narrow down the cause
> (for example, if `signing_key_loaded` is false, suspect the CA key Secret).
> Because `--rm` is given, the Pod is deleted when it exits.

### 3-4. Verify the data plane's TLS certificate and SAN

**This is the single most important check for preventing
`ERR_TLS_CERT_ALT_NAME_INVALID` up front.**

```bash
export PROXY_FQDN=passport-proxy.example.com

openssl s_client -connect "$PROXY_FQDN:8443" -servername "$PROXY_FQDN" </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
```

```text
            X509v3 Subject Alternative Name:
                IP Address:127.0.0.1, DNS:passport-proxy.example.com, DNS:localhost, DNS:passport-proxy
```

> **`openssl x509 -ext subjectAltName` is more concise, but the openssl bundled with macOS
> (LibreSSL) has no `-ext`** (you get `unknown option -ext`). `-text | grep` works with
> either, so that is what is used here.

**Confirm that `DNS:passport-proxy.example.com` is included.**

If the SAN contains **only the LB DNS name (`k8s-passport-passport-....elb.amazonaws.com`)**,
the `dataplaneCertSANs` from Step 2 has not taken effect yet. Run `helm upgrade` and restart
the Pods. You can check the value actually injected like this.

```bash
kubectl -n passport get deploy passport-passport -o jsonpath=\
'{.spec.template.spec.containers[0].env[?(@.name=="PASSPORT_PROXY_DATAPLANE_CERT_SANS")].value}'; echo
```

> **The SANs are filled in automatically**
> In addition to the value given in `dataplaneCertSANs`, the runtime adds `localhost` /
> `127.0.0.1` / `passport-proxy` (the in-cluster Service DNS name is not included).

> **Confirming that mTLS is in effect**
> If you connect without a client certificate, the handshake itself may proceed but the
> CONNECT is rejected. This is the core justification for exposing the proxy publicly, so it
> is worth confirming that
> `curl -x https://$PROXY_FQDN:8443 https://httpbin.org/get` does not succeed without a
> certificate.

---

## Step 4. Prepare the public key for Access Proxy registration

Prepare the value used in Step 5-2 below. **This is the easiest thing in the whole process
to get wrong.**

> **Note**: Access Proxy is the Passport Proxy, under the name used in the Passport Cloud UI.
> The screen calls it **Team Settings → Access Proxies**, so this document follows the UI's
> wording.

### 4-1. What you register is the public key of the reference key

In Step 4-2 of 02 you created two keys. Their purposes are completely different.

| Key | Purpose | Register with Access Proxy? |
| --- | --- | --- |
| `ca-private-key` | Signing client certificates (MITM CA) | ❌ **Do not register** |
| **`reference-private-key`** | **Decrypting `vaultKEK`** | ✅ **Register this public key** |

The comment in `values.yaml` is the basis for this.

> **reference (KEK)** → RSA private half that decrypts the vault references ACS
> envelope-encrypts with the **tenant public key**

Passport Cloud (ACS) envelope-encrypts `vaultKEK` with the tenant public key, and the Proxy
decrypts it with the reference private key. What you register is therefore **the public key
of the reference key**.

```bash
openssl rsa -in .keys/reference-private-key -pubout -out passport-reference-pubkey.pem
```

> **⚠️ Recovery is painful if you mix them up, so register the correct key the first time.**
> The public key cannot be changed after registration; you have to recreate the Access Proxy
> and the secret references.
> See [Troubleshooting](troubleshooting.md#connectivity) for symptoms and remedies.

### 4-2. Detecting a mixed-up key

Comparing modulus fingerprints tells you which key you extracted.

```bash
openssl rsa -in .keys/ca-private-key        -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -in .keys/reference-private-key -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -pubin -in passport-reference-pubkey.pem -noout -modulus | md5
```

It is correct if the third **matches the second (the reference key)**. If it matches the
first, you extracted the CA key.

### 4-3. Also fetch the CA certificate

This one is for the CLI side to trust. It is not registered with the Access Proxy.

```bash
curl -fsS "$MGMT/ca.pem" > passport-ca.pem
openssl x509 -in passport-ca.pem -noout -subject -dates
```

| File | Header | Purpose |
| --- | --- | --- |
| `passport-ca.pem` | `-----BEGIN CERTIFICATE-----` | The CA certificate the CLI trusts |
| **`passport-reference-pubkey.pem`** | `-----BEGIN PUBLIC KEY-----` | **The value to paste into the Access Proxy registration** |

> Pasting a certificate (`BEGIN CERTIFICATE`) into the Access Proxy's public key field is
> rejected by validation.
>
> ```text
> Enter a PEM-encoded public key or leave this field empty.
> ```
>
> However, anything that is `BEGIN PUBLIC KEY` passes, so **a public key extracted from the
> CA key is accepted**. The result is the 502 described in 4-1. A correct format is not
> enough: the content must be the reference key.

---

## Step 5. Configure Namespaces (on the Passport Cloud side)

### 5-1. Sign up for Passport

Sign up at [app.usepassport.ai](https://app.usepassport.ai). Enter your email address, check the verification code, and set a password.

### 5-2. Register the Access Proxy

Click **Top Menu** > **Access Proxies** >
**Create Access Proxy** and enter the following.

| Item | Value to enter |
| --- | --- |
| **Proxy URL** | `https://passport-proxy.example.com:8443` |
| **Management Host** | `https://passport-mgmt.example.com` |
| **Public key** | The contents of `passport-reference-pubkey.pem` (**the reference key**) |
| **Vault provider** | `aws-secrets-manager` |

### 5-3. Configure the API resources

Create a namespace from Home and choose **Add Resources**.

There are three ways to add them.

| Method | Description |
| --- | --- |
| **OTEL logs** | Ingest logs exported from the Proxy and turn the observed endpoints into resources (recommended) |
| **cURL** | Start from the provided sample and adjust it |
| **Manual** | Add the endpoint directly. **The path must match exactly** |

#### Attach a secret reference

Create a secret reference for the resource and specify the key name on the vault side. If you
set `passport_create_demo_secret = true` in 01, the key name is
`passport/demo/httpbin-token`.

The issued **UUID** is the secret reference itself.

> **⚠️ What goes in `{{vault:...}}` is the UUID issued by Passport.**
> It is not the Secrets Manager key name (`passport/demo/httpbin-token`).
> Mix them up and the reference will not resolve.

### 5-4. Verify the configuration took effect

Get the Namespace UUID from the Passport Cloud URL.

```text
https://app.usepassport.ai/namespaces/00000000-1111-2222-3333-444444444444
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

To confirm it actually took effect, have the developer run `passport whoami` and check that
the resource appears in `allowedApiRefs` (done in 04).

### 5-5. Invite the team members

Once the Namespaces setup is complete, invite the team. After signing in, members can request
access to the endpoints they need.

---

## Step 6. Hand off to the developers

**All you need to tell them is where the instructions are** → [04-developer-setup.md](04-developer-setup.md)

No port-forwarding steps, no connection URLs, no Namespace ID. On the developer side, this is
all it takes.

```bash
passport login          # runs through setup automatically
passport whoami         # done once the resource appears in allowedApiRefs
```

> **There is no need to communicate URLs.** After `passport login`, passport-service
> discovery automatically resolves `managementUrl` / `proxyUrl` and records them in
> `~/.passport/identity.json`. There is no point at which a developer enters a URL.

### Reference values if auto-resolution fails

For narrowing things down when a developer cannot connect. Compare against the output of
`passport setup --verbose`.

| Item | Value |
| --- | --- |
| Management URL | `https://passport-mgmt.example.com` |
| Proxy URL | `https://passport-proxy.example.com:8443` |

The command for specifying them explicitly:

```bash
passport setup \
  --management-url https://passport-mgmt.example.com \
  --proxy-url https://passport-proxy.example.com:8443 \
  --proxy-server-name passport-proxy.example.com \
  --namespace-id <Namespace UUID>
```

> **⚠️ MDM profiles take precedence over command-line arguments.**
> If the company Mac is under MDM management, you must also update `ManagementURL` /
> `ProxyURL` in the distributed MDM profile to the new hostnames; otherwise **the old
> endpoints keep being used even when you specify them as arguments**. Check them against
> the values in the table above. For details, see
> [Troubleshooting](troubleshooting.md#endpoint-resolution-priority).

---

## Completion checklist

- [ ] `dig` resolves both hostnames to global IPs
- [ ] Both Pods are `READY 1/1` (= `/readyz` passing)
- [ ] `curl $MGMT/ca.pem` returns a certificate
- [ ] `curl $MGMT/metrics` returns **404** (the allowlist is in effect)
- [ ] The data plane certificate SAN contains the data plane FQDN
- [ ] The public key of the **reference key** is registered with the Access Proxy
- [ ] The Namespace, resources, and secret references are created

→ Proceed to [04. Developer Setup](04-developer-setup.md)
