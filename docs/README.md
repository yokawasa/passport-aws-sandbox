# Passport on AWS — Setup Guide

Build [Postman Passport](https://usepassport.ai) on AWS (EKS) from nothing, through to a
developer resolving secret references.

Based on a configuration validated end to end in this repository. **The proxy and the
management plane are both reached over their own domain names — no `kubectl port-forward`.**

> ## 🚧 The English guide is not written yet
>
> Only this index exists in English so far. **The complete guide is available in Japanese:**
>
> → **[docs/ja/README.md](ja/README.md)**
>
> The pages listed below link to the Japanese versions until their translations land.
> Commands, YAML and output samples in those pages are language-independent, so they are
> usable as-is.

## Documents

| # | Document | Audience | Contents |
| --- | --- | --- | --- |
| 01 | [Infrastructure](ja/01-infrastructure.md) 🇯🇵 | Admin | Build VPC / EKS / IRSA / Secrets Manager with Terraform; issue the ACM certificate |
| 02 | [Deploying the Passport Proxy](ja/02-passport-proxy.md) 🇯🇵 | Admin | Generate keys, configure `values.yaml`, deploy with Helm |
| 03 | [DNS and public exposure](ja/03-dns-and-exposure.md) 🇯🇵 | Admin | Add Route53 records, fix the hostnames, verify connectivity, configure Namespaces |
| 04 | [Developer setup](ja/04-developer-setup.md) 🇯🇵 | Developer | Install the CLI and use secret references |
| — | [Troubleshooting](ja/troubleshooting.md) 🇯🇵 | Everyone | Problems actually hit while building this |

**01–03 are done once by an administrator. 04 is done by each developer on their own
machine.** A developer's `passport login` will not complete until 01–03 are finished.

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

## Verified environment

This guide was validated end to end against:

| Item | Value |
| --- | --- |
| EKS cluster | Amazon EKS 1.33 / ap-northeast-1 (named `<project>-<environment>`, `passport-sandbox-dev` by default) |
| Helm chart | `passport-0.6.0` |
| Image | `passport-proxy:v0.6.0` |
| CLI | `0.7.2` / macOS arm64 |
