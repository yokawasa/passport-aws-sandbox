# Troubleshooting

Items actually encountered (★) are listed alongside ones predicted from the configuration.

- [Teardown and destroy](#teardown-and-destroy)
- [Installation](#installation)
- [Startup](#startup)
- [Connectivity](#connectivity)
- [Developer setup](#developer-setup)
- [Public exposure](#public-exposure)
- [Reaching an internal LB](#reaching-an-internal-lb)

---

## Teardown and destroy

| Symptom | Cause | Fix |
| --- | --- | --- |
| ★ **`DependencyViolation: The subnet 'subnet-xxxx' has dependencies and cannot be deleted`** | An LB (ALB/NLB) is left over and its ENI is holding the subnet | [Recovery steps for the LB and ENI](#destroy-fails-with-dependencyviolation) |
| ★ **`DependencyViolation: The vpc 'vpc-xxxx' has dependencies and cannot be deleted`** | The security group that came with the LB (`k8s-...`) is left over | [Recovery steps for the SG](#vpc-dependencyviolation-leftover-security-groups) |
| ★ `No valid credential sources found` / `InvalidGrantException` | The AWS SSO token has expired | Log in again with `aws sso login --profile <profile>`. **Terraform can fail even when `aws sts get-caller-identity` succeeds** (see below) |
| ★ `error asking for approval: EOF` | `terraform destroy` was run in a non-interactive environment | `terraform -chdir=terraform destroy -auto-approve` (**check the targets with `plan -destroy` first**) |

> **⚠️ In this actual run, teardown failed in two stages.**
> First the **subnet** was blocked by the LB's ENI; once that was resolved, the **VPC** was
> then blocked by an SG. Both have the same root cause: resources created by the AWS Load
> Balancer Controller are outside Terraform's management. Deleting the LB itself **leaves
> the accompanying SG behind**, so keep checking after that.

### destroy fails with DependencyViolation

**Cause**: ALB / NLB are **outside Terraform's management**. The AWS Load Balancer
Controller creates them by watching `Ingress` and `type: LoadBalancer` Services, so
`terraform destroy` never tries to delete them. If you destroy with them still in place,
the LB's ENI keeps holding a private subnet and the subnet cannot be deleted.

```text
Error: deleting EC2 Subnet (subnet-0a331fca695911125): operation error EC2: DeleteSubnet,
  api error DependencyViolation: The subnet 'subnet-0a331fca695911125' has dependencies
  and cannot be deleted.
```

**Forgetting to run `helm uninstall passport` is the classic case.** Both the data plane
NLB and the management plane ALB are under Helm's management.

#### Identify the leftovers

```bash
# Which ENI is holding it
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=subnet-id,Values=subnet-xxxx \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Status:Status,Type:InterfaceType}' \
  --output table
```

If `Description` is `ELB net/k8s-passport-passport-.../...` and `InterfaceType` is
`network_load_balancer`, the Passport NLB is the cause.

#### Recovery steps

> **If the EKS cluster has already been destroyed, the route of deleting the Service and
> letting it be removed automatically is closed off** (the controller is gone too). Delete
> directly from the AWS side.

```bash
VPC_ID=<the VPC ID at the time of failure>

# 1. Identify the remaining LBs
aws elbv2 describe-load-balancers --region ap-northeast-1 \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].{Name:LoadBalancerName,ARN:LoadBalancerArn}" \
  --output table

# 2. Delete it and wait until it is fully gone
ARN=<the ARN obtained above>
aws elbv2 delete-load-balancer --region ap-northeast-1 --load-balancer-arn "$ARN"
aws elbv2 wait load-balancers-deleted --region ap-northeast-1 --load-balancer-arns "$ARN"

# 3. Confirm the ENIs have been released (wait until it reaches 0)
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=vpc-id,Values=$VPC_ID --query 'length(NetworkInterfaces)' --output text

# 4. Re-run destroy
make tf-destroy
```

> **⚠️ Wait at step 3 until the ENIs are gone.**
> Even after the `delete-load-balancer` API returns, releasing the ENIs lags by **another
> few tens of seconds to a few minutes**. Re-running destroy too early gives you the same
> error. (Measured: release happened about 30 seconds after `wait` completed.)

#### Preventing a recurrence

Run `make destroy-check` before destroying. It stops with exit 1 if an LB is left in the
VPC.

```bash
helm uninstall passport -n passport   # ← easy to forget
make destroy-check                    # wait until it reports "(none)"
make tf-destroy
```

### VPC DependencyViolation: leftover security groups

After resolving the subnet problem, deletion can then stall on the VPC.

```text
Error: deleting EC2 VPC (vpc-xxxx): operation error EC2: DeleteVpc,
  api error DependencyViolation: The vpc 'vpc-xxxx' has dependencies and cannot be deleted.
```

**Cause**: The AWS Load Balancer Controller creates not only the LB itself but also the
security groups that go with it. **Deleting the LB by hand does not delete the SGs
automatically** (normally the controller cleans them up, but that never runs if the EKS
cluster is gone first). A VPC cannot be deleted while non-default SGs remain.

#### Identify the remaining SGs

```bash
VPC_ID=<the VPC ID at the time of failure>

aws ec2 describe-security-groups --region ap-northeast-1 \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Name:GroupName,Desc:Description}' \
  --output table
```

A real example (the `k8s-` prefix is the giveaway):

```text
sg-06827cbb3ea3d87fa  k8s-traffic-eksapidev-329d1fe766   [k8s] Shared Backend SecurityGroup for LoadBalancer
sg-0d9f17e3b9364e10a  k8s-passport-passport-166f3ee611   [k8s] Managed SecurityGroup for LoadBalancer
```

`k8s-passport-passport-*` belongs to the Passport Proxy NLB, and `k8s-traffic-*` to the
management plane ALB.

#### Delete them

```bash
aws ec2 delete-security-group --region ap-northeast-1 --group-id <SG-ID>
```

> **SG deletion takes effect immediately.** There is no waiting period like there is for
> ENIs.
>
> **Watch the deletion order when there are cross-references.** If another SG references
> it, you get a `DependencyViolation`. To check beforehand:
>
> ```bash
> aws ec2 describe-security-groups --region ap-northeast-1 \
>   --filters Name=vpc-id,Values=$VPC_ID \
>   --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='<SG-ID>']]].GroupId" \
>   --output text
> ```

#### Check for dependencies other than the VPC

If the VPC still cannot be deleted after removing the SGs, other dependencies remain.
Check them all at once.

```bash
VPC_ID=<VPC ID>; R=ap-northeast-1
aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values=$VPC_ID --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
aws ec2 describe-internet-gateways  --region $R --filters Name=attachment.vpc-id,Values=$VPC_ID --query 'InternetGateways[].InternetGatewayId' --output text
aws ec2 describe-nat-gateways       --region $R --filter Name=vpc-id,Values=$VPC_ID --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text
aws ec2 describe-vpc-endpoints      --region $R --filters Name=vpc-id,Values=$VPC_ID --query 'VpcEndpoints[].VpcEndpointId' --output text
aws ec2 describe-instances          --region $R --filters Name=vpc-id,Values=$VPC_ID Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
```

If all of them are empty, the VPC can be deleted.

#### Confirming teardown is complete

```bash
# Whether the VPC is gone (OK if InvalidVpcID.NotFound comes back)
aws ec2 describe-vpcs --region ap-northeast-1 --vpc-ids $VPC_ID 2>&1 | grep -o 'InvalidVpcID.NotFound'

# Whether any resources that keep billing are left
aws eks list-clusters --region ap-northeast-1 --query 'clusters' --output text
aws ec2 describe-nat-gateways --region ap-northeast-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region ap-northeast-1 --query 'Addresses[?AssociationId==null].PublicIp' --output text
```

> **Do not mistake these for another project's resources.** If the same account has other
> VPCs, the commands above pick those up too. Filter by `VpcId` and confirm they belong to
> your own VPC before deleting.

### AWS SSO token expiry

**The confusing part: Terraform fails even when `aws sts get-caller-identity` succeeds.**

```text
Error: No valid credential sources found
Error: failed to refresh cached credentials, refresh cached SSO token failed,
  unable to refresh SSO token, ... InvalidGrantException
```

The AWS CLI caches the role credentials it already obtained, and succeeds as long as those
are still valid. Terraform's SDK, on the other hand, **tries to refresh the SSO token**, so
it fails once the token itself has expired.

```bash
# Check the token expiry
for f in ~/.aws/sso/cache/*.json; do
  python3 -c "import json;d=json.load(open('$f'));print(d.get('expiresAt','-'),d.get('startUrl','-'))" 2>/dev/null
done
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

```bash
# Log in again (a browser opens)
aws sso login --profile my-aws-profile
```

---

## Installation

| Symptom | Cause | Fix |
| --- | --- | --- |
| ★ `imagePullSecrets: element 0: associative list with keys may not have non-map elements` | `image.pullSecrets` was written as a list of strings | Change it to the `- name: passport-registry` form. **`--dry-run` cannot detect this** |
| ★ `cannot reuse a name that is still in use` | **`helm install` was run while the release already existed.** Same result whether the previous run succeeded (`deployed`) or failed (`failed`) | **Use `helm upgrade` from the second run on** (`helm upgrade --install` if unsure). Check the state with `helm list -n passport`. To start over, `helm uninstall` |
| ★ `helm list -a` gives `unknown shorthand flag` | The flag changed in helm 4.x | Use `helm list` or `helm status <release> -n <ns>` |
| Chart rendering fails | `bundle.allowedTeamIds` is unset | Set your own Team ID (`org_...`) |
| The `service.type=LoadBalancer ... may provision a PUBLIC LB` warning | `internet-facing` is selected | This is the **intended configuration** in this guide, so it is expected. Change the annotation if you want `internal` |

## Startup

| Symptom | Cause | Fix |
| --- | --- | --- |
| The Pod does not start | The Secret for the CA key / reference key is missing | Generate the keys and create the Secret. Real keys are required unconditionally |
| The Pod does not start | `bundle.allowedTeamIds` is empty | By design, startup is refused when `jwksUrl` is set and `allowedTeamIds` is empty |
| ★ A `revocation disabled` WARN | `revocation.enabled: false` | **Normal** if you are not using the feature. Safe to ignore |
| ★ A `console auth disabled` WARN | `console.enabled: false` | Same as above. Set `user` and `passwordHash` only if you use the Console |
| ★ **`startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set`** → CrashLoopBackOff | `bundle.requireBundleClaims: true` was set but `audience` / `issuer` are unset | Set all three together, or revert to `requireBundleClaims: false` ([below](#the-pod-does-not-start-with-requirebundleclaims)) |
| ★ `openssl x509: unknown option -ext` | **The openssl bundled with macOS is LibreSSL**, which has no `-ext` | Use `-text \| grep -A2 "Subject Alternative Name"` ([steps](03-dns-and-exposure.md#3-4-verify-the-data-planes-tls-certificate-and-san)). Check with `openssl version` |
| ★ `exec: "wget"/"sh"/"curl": executable file not found in $PATH` | **The image is distroless.** It has no shell and no commands, so you cannot inspect it with `kubectl exec` | Judge `/readyz` from the Pod being `READY 1/1`. To look inside, `kubectl run curl-tmp --rm -it --image=curlimages/curl -- curl -s http://passport-passport-mgmt:8081/readyz` ([steps](03-dns-and-exposure.md#3-3-check-the-health-check)) |
| ★ `http: TLS handshake error from 10.x.x.x: EOF` keeps streaming in the logs | The NLB health check is hitting :8443 without a client certificate | **Normal, since mTLS is required.** Safe to ignore as long as the Pod is `1/1 Running`. [How to reduce it](02-passport-proxy.md#tls-handshake-error-is-normal) |
| ★ The startup log cannot be found (`--tail` fills up with health checks) | The startup log is the first few lines, but `TLS handshake error` is appended every few seconds and grows to thousands of lines | Read from the top without `--tail`: `logs "$POD" \| grep -v "TLS handshake error" \| head` ([steps](02-passport-proxy.md#tls-handshake-error-is-normal)) |
| ★ Secrets Manager resolution fails | IRSA is not in effect | **`helm upgrade` alone is not enough.** The webhook injects the env only at Pod creation, so `kubectl -n passport rollout restart deploy/passport-passport` is required |

### The Pod does not start with requireBundleClaims

```text
startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both
  PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set
```

**Cause**: Enabling `bundle.requireBundleClaims` requires **both** `bundle.audience` and
`bundle.issuer`. With only one of them, it fails closed and refuses to start.

**This dependency is not documented in the chart's `values.yaml`.** Both are merely
commented as "optional"; the constraint exists only in the binary.

```bash
# Check the env that was actually injected
kubectl -n passport get deploy passport-passport -o json | \
  python3 -c "import json,sys; [print(e['name'],'=',e.get('value')) \
    for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env'] \
    if 'BUNDLE' in e['name'] or 'CLAIMS' in e['name']]"
```

**Fix**: During validation, reverting to disabled is the easy route.

```yaml
bundle:
  requireBundleClaims: false
```

```bash
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

Even when disabled, JWKS signature verification and tenant pinning via `allowedTeamIds`
still work independently.

If you do want to enable it, set `issuer` to the bundle JWT's `iss` claim, but **that value
cannot be confirmed without decoding an actually issued bundle**. Put in a guessed value
and the Pod starts while `/issue-cert` returns 403, which makes the cause hard to pin down.

## Connectivity

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ERR_TLS_CERT_ALT_NAME_INVALID` | `dataplaneCertSANs` does not match the hostname being connected to | Set the FQDN, `helm upgrade`, then restart the Pod. Check the SAN with `openssl s_client` |
| ★ DNS resolves but the connection times out | You are trying to reach an internal LB from outside the VPC | [See below](#reaching-an-internal-lb) |
| The image / chart cannot be pulled | `PASSPORT_REGISTRY_KEY` has not been issued, or is wrong | Re-check the credentials in the Registry settings |
| ★ `Enter a PEM-encoded public key or leave this field empty.` during Access Proxy registration | A certificate (`BEGIN CERTIFICATE`) was pasted into the public key field | Extract the reference key's public key and paste that |
| ★ **502 `decrypt-failed`** / `failed to decrypt vault reference` | The **CA key's** public key was registered with the Access Proxy (the reference key is correct) | Re-create the Access Proxy, and **re-create the secret reference too**. The public key cannot be changed |
| ★ **403 `unauthorized`** / `not authorized for vault refs` | `--namespace-id` was not specified, or the secret is not linked in the Namespace | `passport setup --namespace-id <UUID>`. Check with `allowedApiRefs` in `whoami` |
| ★ `{{vault:...}}` is not resolved | A Secrets Manager key name was written | Write the **UUID issued by Passport**. Check with the certificate's `secretReference` |
| ★ `error: unknown option '--endpoint'` | **`--endpoint` was removed in CLI 0.7.0 and later.** The target is determined by the Namespace's resource definitions | Specify only `--namespace-id` ([above](#allowedapirefs-stays-none)) |
| ★ The certificate goes `EXPIRED` | The TTL is **300 seconds at most** (and the default is also 300 in 0.7.x) | Re-issue with `passport refresh`. `passport request` renews automatically |
| ★ `error: missing required argument 'url'` | The URL was written after the options in `passport request` | Put the URL as the first argument |
| ★ `HTTPS_PROXY` still has no effect after `daemon install` | Existing terminals do not pick it up | Open a new terminal |
| ★ MDM settings override the arguments | The macOS managed plist takes top priority | Ask your IT administrator to update the profile |
| Resources do not match under Namespaces | The path did not match during Manual registration | **An exact match down to the path** is required. Importing from OTEL logs is recommended |
| ★ No logs appear | With multiple replicas, only the one that handled the request logs it | Check the logs of all Pods |

## Developer setup

Fixes for when `passport login` alone is not enough. Normally the steps in
[04](04-developer-setup.md) are all you need.

### `allowedApiRefs` stays `(none)`

The secret reference permissions are not carried on the certificate. Redo setup with
`--namespace-id` specified explicitly.

```bash
passport setup --namespace-id <Namespace UUID>
```

> **What the `--namespace-id` flag actually does**
>
> ACS issues the bundle **after verifying the VIEW_NAMESPACE permission**, and the secret
> references you are allowed to use get burned into the certificate. Rather than specifying
> "which Namespace", it **makes explicit what the permission check applies to**.
>
> In this repository's validation environment (admin role + a single Namespace), **the
> permissions were carried even without specifying it** (confirmed by deleting
> `~/.passport` and running only `passport login`). This is presumably because the access
> token includes `namespace:view` and the target is uniquely determined. It may become
> necessary with ordinary member permissions or in environments with multiple Namespaces.

Get the Namespace UUID from your administrator, or from the Passport Cloud URL.

```text
https://app.usepassport.ai/namespaces/00000000-1111-2222-3333-444444444444
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

If it is still `(none)`, the administrator has not finished linking the Namespace's
resources with the secret reference.

### Connecting to an unintended Proxy

Adding `--verbose` prints every endpoint it connects to and the reason why.

```bash
passport setup --verbose
```

```text
   managementHost = passport-mgmt.example.com
     ✗ macOS managed plist        (not present)
     ✗ --management-url           (not present)
     ✗ PASSPORT_MGMT_HOST         (not present)
     ✓ passport-service discovery ← used
   proxyHost = passport-proxy.example.com
     ...
```

#### Endpoint resolution priority

Note that **the MDM profile is stronger than command-line arguments**.

| Priority | Source | Notes |
| --- | --- | --- |
| 1 | **macOS managed plist (MDM)** | **Overrides even an explicit `--proxy-url`** |
| 2 | `--management-url` / `--proxy-url` | Command-line arguments |
| 3 | `PASSPORT_MGMT_HOST` / `PASSPORT_PROXY_HOST` | Environment variables |
| 4 | passport-service discovery | Automatic resolution |

```bash
defaults read /Library/Managed\ Preferences/com.postman.passport
```

```text
{
    ManagementURL = "https://passport-mgmt.example.com";
    ProxyURL = "https://passport-proxy.example.com:8443";
    RoutingPolicy = { Mode = "forward-all"; Strict = 1; ... };
}
```

**If it contains an old hostname (or `localhost`), arguments cannot switch it.** Ask your
IT administrator to update the profile.

### Running setup with explicit URLs

For environments where automatic resolution does not work (effective only when there is no
MDM configuration).

```bash
passport setup \
  --management-url https://passport-mgmt.example.com \
  --proxy-url https://passport-proxy.example.com:8443 \
  --proxy-server-name passport-proxy.example.com
```

> If you omit `--management-url`, the same value as `--proxy-url` is used. In this
> configuration **the management plane and the data plane have different hostnames**, so
> specify both when you specify them explicitly. Check the correct values with your
> administrator ([Step 6 of 03](03-dns-and-exposure.md#step-6-hand-off-to-the-developers)).

### setup exit codes

| Code | Meaning | Fix |
| --- | --- | --- |
| `0` | Full success (certificate + daemon running) | — |
| `1` | Failure (failed to obtain the certificate) | Check the cause with `--verbose` |
| `2` | **Partial success** (the certificate was obtained but the daemon failed to start) | Check with `passport daemon status` |

> Code `2` is not "success". The certificate exists but the daemon is not running, so
> transparent routing does not work.

### Main setup options

| Option | Purpose |
| --- | --- |
| `--namespace-id <id>` | The Namespace UUID. Specify it when `allowedApiRefs` is empty |
| `--ttl <seconds>` | The certificate's validity period. **Default 300 seconds, and the range is 60-300 too** |
| `--proxy-server-name <host>` | The hostname used for SNI. Use it to work around a SAN mismatch |
| `--management-url <url>` / `--proxy-url <url>` | Explicit connection targets (resolved automatically when omitted) |
| `--email` / `--user-id` / `--team-id` | Override the profile you are logged in with |
| `--no-daemon` | Do not start the daemon and do not set `HTTPS_PROXY` (for CI / headless) |
| `--verbose` | Print the full endpoint resolution priority (also enabled by `PASSPORT_DEBUG=1`) |

---

## Public exposure

| Symptom | Cause | Fix |
| --- | --- | --- |
| Changing `scheme` has no effect | **An LB's scheme is immutable** | Delete the Service, then re-create it with `helm upgrade`. The DNS name changes |
| `dig` returns `10.x.x.x` | It is still `internal` | Change the annotation to `internet-facing` and re-create the Service |
| The ACM certificate stays `PENDING_VALIDATION` | The validation CNAME does not resolve | Check with `dig +short <validation-name> CNAME`. Match `Name` exactly, down to the trailing dot |
| `/metrics` and `/console` are reachable from outside | `ingress.paths` was widened too far | Revert it to only `/ca.pem` and `/issue-cert` |
| The Ingress gets no ADDRESS | Waiting on ALB provisioning, or missing subnet tags | Wait 2-3 minutes. Check the `kubernetes.io/role/elb` tag |
| ★ `kubectl get ingress passport` returns `NotFound` | **The Ingress name differs from the release name.** It is actually `<release>-<chart>-setup` (`passport-passport-setup` by default) | Select by label instead of by name: `kubectl -n passport get ingress -l app.kubernetes.io/instance=passport -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'` |

---

## Reaching an internal LB

This guide assumes `internet-facing`, but this section covers the case where you choose
`internal` for security requirements.

### Confusing behavior: DNS resolves but you cannot reach it

An internal NLB's DNS name **resolves successfully even from outside the company**. What
comes back, however, is a private IP inside the VPC.

```bash
$ dig +short k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com
10.0.11.3      # ← a private IP inside the VPC
10.0.25.94
```

This is why "the name resolves but it will not connect". Since it is not a DNS failure, you
are kept waiting until the timeout.

### Connection options

| Method | Purpose | Notes |
| --- | --- | --- |
| **kubectl port-forward** | Smoke testing, single-person validation | The easiest. But it needs a constant connection, so it is not suited to rolling out to a team |
| **VPN** (Client VPN / Site-to-Site) | Everyday team use | The standard answer for production operation. Developers can use it transparently as long as they are on the VPN |
| **Bastion / Session Manager** | Investigation by operators | Puts an SSH port forward in between |
| **Switch to internet-facing** | The configuration in this guide | Protected by mTLS. The rationale is in [Step 4-4 of 02](02-passport-proxy.md#tls-handshake-error-is-normal) |

### Verification steps with port-forward

```bash
# Management plane (health checks, fetching the CA certificate)
kubectl -n passport port-forward deploy/passport-passport 8081:8081

# Data plane (to try connecting from the CLI)
kubectl -n passport port-forward svc/passport-passport 8443:8443
```

When you port-forward the data plane and use it from the CLI, the connection target becomes
`https://localhost:8443`. **No extra configuration is needed for this use** — the SAN of the
certificate generated by the runtime automatically includes `localhost` and `127.0.0.1`.

```text
IP Address:127.0.0.1
DNS:k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com   ← the dataplaneCertSANs value
DNS:localhost                                                      ← added automatically
DNS:passport-proxy                                                 ← added automatically
```

If you need to connect with a hostname that is not in the SAN, you can work around it with
the following.

- Specify the SNI explicitly with `passport setup --proxy-server-name <a hostname included in the SAN>`
- Skip the outer hostname verification with `passport request --insecure-proxy-hostname`
  (certificate chain verification continues)
