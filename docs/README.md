# Passport on AWS — Setup Guide

Build [Postman Passport](https://usepassport.ai) on AWS (EKS) from nothing, through to a
developer resolving secret references.

Based on a configuration validated end to end in this repository. **The proxy and the
management plane are both reached over their own domain names — no `kubectl port-forward`.**

> 日本語版: [ja/README.md](ja/README.md)
> Both languages are kept in sync — if you change one, change the other.

## The sequence

```
┌─ 01-infrastructure.md ───────────────────────────────┐
│  Terraform: VPC / EKS / IRSA / Secrets Manager       │ admin
│  AWS CLI  : issue the ACM certificate (DNS validated)│
└──────────────────────┬───────────────────────────────┘
                       │  EKS cluster, IRSA role ARN, certificate ARN
                       ▼
┌─ 02-passport-proxy.md ───────────────────────────────┐
│  Helm: deploy the Passport Proxy                     │ admin
│  Generate keys, set values.yaml, create NLB + ALB    │
└──────────────────────┬───────────────────────────────┘
                       │  NLB / ALB DNS names
                       ▼
┌─ 03-dns-and-exposure.md ─────────────────────────────┐
│  Route53: add CNAMEs, fix the SAN, helm upgrade      │ admin
│  Verify connectivity, configure Passport Namespaces  │
└──────────────────────┬───────────────────────────────┘
                       │  Proxy URL / Management Host / public key
                       ▼
┌─ 04-developer-setup.md ──────────────────────────────┐
│  Install and configure the Passport CLI, verify      │ developer
│                                                      │
└──────────────────────────────────────────────────────┘
```

**01-03 are done once, by an administrator. 04 is done by each developer on their own
machine.** A developer's `passport login` will not complete until 01-03 are finished.

## Documents

| # | Document | Audience | Contents |
| --- | --- | --- | --- |
| 01 | [Infrastructure](01-infrastructure.md) | Admin | Build VPC / EKS / IRSA / Secrets Manager with Terraform; issue the ACM certificate |
| 02 | [Deploying the Passport Proxy](02-passport-proxy.md) | Admin | Generate keys, configure `values.yaml`, deploy with Helm |
| 03 | [DNS and public exposure](03-dns-and-exposure.md) | Admin | Add Route53 records, fix the hostnames, verify connectivity, configure Namespaces |
| 04 | [Developer setup](04-developer-setup.md) | Developer | Install the CLI and use secret references |
| — | [Troubleshooting](troubleshooting.md) | Everyone | Problems actually hit while building this |

## How this is exposed

Validating by hand with `kubectl port-forward` every time does not scale to a team, so the
two planes are **exposed asymmetrically, according to what each one is**.

| Plane | Port | How it is exposed | Why |
| --- | --- | --- | --- |
| **Data plane** | 8443 | NLB (`internet-facing`) | **mTLS is mandatory** — without a client certificate signed by the Passport CA the TLS handshake is dropped. An internet-facing mTLS gateway is what Passport is designed around |
| **Management plane** | 8081 | ALB with a **path allowlist** (`/ca.pem`, `/issue-cert` only) | Plain HTTP, sharing a port with `/metrics` and the admin API. The ALB terminates TLS and forwards only those two paths |

> **⚠️ Never expose the management plane with a LoadBalancer.**
>
> Port 8081 serves `/ca.pem` and `/issue-cert` (which you want public) alongside
> `/metrics`, the `/revocation` admin API and the console UI (which you do not) — all on
> **the same port**, over plain HTTP. Use the Ingress path allowlist instead.

### Why the data plane needs no ACM certificate

The NLB passes L4 through so the **client certificate reaches the pod unterminated**; the
proxy itself terminates TLS. Only the management plane's ALB needs an ACM certificate.

## Placeholder values

**Every command and config sample uses dummy values.** Substitute your own.

The domain is `example.com` (a Route53 public hosted zone), and the hostnames state their
role: **`passport-proxy`** (data plane) and **`passport-mgmt`** (management plane).

| Role | Hostname (example) | Points at | Purpose |
| --- | --- | --- | --- |
| **Proxy URL** | `passport-proxy.example.com` | NLB (:8443) | Data plane; the CLI connects here over mTLS |
| **Management URL** | `passport-mgmt.example.com` | ALB (:443) | Management plane; `/ca.pem` and `/issue-cert` only |

### What to substitute

| In this guide | Meaning | How to find yours |
| --- | --- | --- |
| `example.com` | A domain you own | A Route53 public hosted zone |
| `passport-proxy` / `passport-mgmt` | Hostnames (subdomains) | Your choice; prefix with a team name to avoid collisions (below) |
| `Z0123456789ABCDEFGHIJ` | Hosted zone ID | `aws route53 list-hosted-zones` |
| `my-aws-profile` | AWS CLI profile name | `aws configure list-profiles` |
| `123456789012` | AWS account ID | `aws sts get-caller-identity` |
| `org_01EXAMPLE000000000000000` | Postman team ID | Team Settings → Team Info (starts with `org_`) |
| `00000000-1111-2222-3333-444444444444` | Namespace UUID | The namespace URL in Passport Cloud |
| `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` | Secret reference UUID | Issued when you attach a secret in a namespace |
| `ap-northeast-1` | Region | Any region works |

> **Watch for hostname collisions.** On a shared zone `passport-proxy` / `passport-mgmt`
> may already be taken. Add a team or region identifier (`jp-passport-proxy`,
> `passport-proxy-team-a`) and **follow whatever naming convention the zone already uses**
> — prefix or suffix.

## Assumed knowledge and tooling

Assumes working familiarity with Docker, Kubernetes, Helm, YAML and private registries.

| Tool | Purpose | Version |
| --- | --- | --- |
| Terraform | Building infrastructure | >= 1.5.7 (1.10+ recommended) |
| AWS CLI v2 | ACM / Route53 / EKS | — |
| kubectl | Operating Kubernetes | — |
| Helm | Deploying the proxy | Verified with 4.x |
| Docker | Pulling the image | — |
| openssl | Generating and inspecting keys | — |

You also need permission to create VPC / EKS / IAM / ELB resources in the target account.

## Setup

### 1. Create the S3 bucket for tfstate

```bash
make bootstrap TFSTATE_BUCKET=my-tfstate-bucket-1234 REGION=ap-northeast-1
```

### 2. Prepare variables, then init / apply

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit as needed. Restrict endpoint_public_access_cidrs to the IP you run kubectl
# from — it defaults to 0.0.0.0/0.

make tf-init TFSTATE_BUCKET=my-tfstate-bucket-1234
make tf-plan
make tf-apply
```

Creating the VPC, EKS cluster, node group and ALB Controller takes roughly 15–20 minutes.

### 3. Update kubeconfig

```bash
make kubeconfig
kubectl get nodes
```

### 4. Deploy the Passport Proxy

Everything from here is Passport configuration, covered in [`docs/`](.).

| Document | Contents |
| --- | --- |
| [01 Infrastructure](01-infrastructure.md)  | Steps 1–3 above in detail, plus issuing the ACM certificate for the management plane |
| [02 Deploying the proxy](02-passport-proxy.md) | Generating keys, configuring `values.yaml`, deploying with Helm |
| [03 DNS and exposure](03-dns-and-exposure.md) | Route53 records, connectivity checks, configuring Namespaces |
| [04 Developer setup](04-developer-setup.md) | Developer CLI setup and using secret references |

> 🇯🇵 [日本語セットアップガイド](ja/README.md)
>  
> Commands, YAML and output samples are language-independent and usable as-is.

The target API is deliberately absent from this repository. Register an external endpoint
such as `httpbin.org` as a namespace resource and validate against that.

## Teardown

**Delete the load balancers before running `terraform destroy`.**

```bash
# 1. If the Passport Proxy is installed, uninstall it (this removes the NLB and ALB)
helm uninstall passport -n passport

# 2. Confirm no load balancers or security groups remain in the VPC (exits 1 if any do)
make destroy-check

# 3. Destroy
make tf-destroy
```

> **⚠️ The ALB / NLB are outside Terraform's management.**
>
> The AWS Load Balancer Controller creates them from `Ingress` and `type: LoadBalancer`
> Services, so `terraform destroy` never tries to delete them. Leave them in place and the
> load balancer ENIs keep holding the private subnets, failing with:
>
> ```text
> Error: deleting EC2 Subnet (subnet-xxxx): ... api error DependencyViolation:
>   The subnet 'subnet-xxxx' has dependencies and cannot be deleted.
> ```
>
> **Forgetting `helm uninstall passport` is the common case.** Both the NLB and the ALB are
> managed by that release.
>
> **Deleting a load balancer leaves its security group (`k8s-...`) behind**, and the VPC
> deletion then fails the same way. `make destroy-check` looks for both.
>
> **Deletion is asynchronous.** After `helm uninstall` returns, the controller needs
> **1–3 minutes** to remove the load balancers and release the ENIs. Wait until
> `make destroy-check` reports none before destroying.

### When destroy fails with DependencyViolation

If the EKS cluster is already gone, so is the controller, and deleting the Service can no
longer clean up for you. Remove the resources through the AWS API instead.

```bash
VPC_ID=<the VPC ID from the error>

# 1. Find the remaining load balancers
aws elbv2 describe-load-balancers --region ap-northeast-1 \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].{Name:LoadBalancerName,ARN:LoadBalancerArn}" --output table

# 2. Delete and wait for them to disappear
aws elbv2 delete-load-balancer --region ap-northeast-1 --load-balancer-arn <ARN>
aws elbv2 wait load-balancers-deleted --region ap-northeast-1 --load-balancer-arns <ARN>

# 3. Confirm the ENIs were released (wait for 0 — this lags the delete API by minutes)
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'length(NetworkInterfaces)' --output text

# 4. Re-run destroy
make tf-destroy
```

The load balancers' security groups (`k8s-...`) can also survive. If destroy then stops on
a security group, delete it by hand once the ENIs are released.

## Verified environment

This guide was validated end to end against:

| Item | Value |
| --- | --- |
| EKS cluster | Amazon EKS 1.33 / ap-northeast-1 (named `<project>-<environment>`, `passport-sandbox-dev` by default) |
| Helm chart | `passport-0.6.0` |
| Image | `passport-proxy:v0.6.0` |
| CLI | `0.7.2` / macOS arm64 |
