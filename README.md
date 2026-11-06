# passport-aws-sandbox

An AWS sandbox for validating [Postman Passport](https://usepassport.ai). Confirming that
the Passport Proxy can actually resolve secrets takes a full AWS setup — EKS, ALB, Secrets
Manager, IAM (IRSA), networking — so this repository stands all of it up with Terraform.

The Passport Proxy runs on **Amazon EKS** in private subnets. Its data plane (:8443) is
exposed through an **NLB**, and the management plane's `/ca.pem` and `/issue-cert` through
an **ALB**. The target API is an external one such as `httpbin.org`, so it is not part of
this repository. All infrastructure is written in Terraform, building on the existing
[terraform-aws-modules](https://github.com/terraform-aws-modules).

> **The Passport setup guide lives in [`docs/`](docs/).**
> It walks from infrastructure to developer usage in four parts ([`docs/README.md`](docs/README.md)
> is the index). The proxy and management plane are reached over their own domain names
> rather than `kubectl port-forward`.
>
> 日本語版: [README.ja.md](README.ja.md) · [docs/ja/](docs/ja/)

## Architecture

```
                     Internet
                        │
         ┌──────────────┴──────────────┐
         │ NLB :8443        ALB :443   │  ← created from Service / Ingress
         │ (data plane)     (/ca.pem   │
         │                  /issue-cert)│
        ┌┴─────────────────────────────┴┐
        │  public subnet (AZ-a / AZ-c)  │
        │   NAT Gateway                 │
        └───────────────┬───────────────┘
                        │ target-type: ip
                        ▼
        ┌───────────────────────────────┐
        │  private subnet (AZ-a / AZ-c) │
        │   EKS Managed Node Group      │
        │     └ Pod: Passport Proxy     │
        │         :8443 / :8081         │
        └───────────────────────────────┘
```

Notes:

- **Terraform does not create the ALB / NLB directly.** The AWS Load Balancer Controller
  running on EKS creates and updates them from `Ingress` / `Service` resources, which keeps
  path and listener changes on the Kubernetes side and automates target registration.
- The VPC module tags subnets with `kubernetes.io/role/elb` and
  `kubernetes.io/role/internal-elb`. **Without these tags the controller cannot find the
  subnets and no load balancer is created.**
- `target-type: ip` routes straight to pod IPs, bypassing NodePort.
- Node and control plane ENIs live only in private subnets; egress goes through the NAT
  Gateway.
- The controller's IAM permissions come from IRSA (OIDC + ServiceAccount).

## Application architecture

How certificates and requests flow across the three boundaries: the developer's machine,
the Passport Proxy inside the customer VPC, and the target API it forwards to.

![Application architecture](assets/architecture.png)

The solid green line is the Passport flow verified end to end (against `httpbin.org`).
Developer code contains only a `{{vault:<UUID>}}` reference; the proxy resolves it against
Secrets Manager before forwarding, so **developers never receive the real credential**.
See the guides under [`docs/`](docs/) for details.

### Components and their step in the Passport flow

| Component | Steps | Role |
| --- | --- | --- |
| Passport backend (Cloud) | 1–3 | RFA approval, `/bundles/issue`, signing the JWT bundle. Has no file in this repository |
| `passport-passport-mgmt` (:8081) | 4 | Serves `POST /issue-cert`, issuing a client certificate carrying `allowedApiRefs` |
| Local daemon & `~/.passport/` | 4–5 | Stores the certificate and brokers the mTLS connection to the data plane via `HTTPS_PROXY` |
| `passport-passport` (:8443) | 5–7 | Accepts the mTLS connection, resolves references through Secrets Manager, forwards to the target API |
| Target API (external) | 7 | The forwarding destination — an external endpoint such as `httpbin.org`. Not part of this repository |

## Terraform modules used

| Module | Version | Purpose |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | `~> 6.0` | VPC, public/private subnets, NAT GW, ELB discovery tags |
| `terraform-aws-modules/eks/aws` | `~> 21.0` | EKS cluster, managed node group, addons, access entries |
| `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` | `~> 5.60` | IRSA role for the ALB Controller (bundles the AWS-managed policy equivalent) |
| `helm_release` (hashicorp/helm) | — | Installs the `aws-load-balancer-controller` chart |

## Repository layout

```
.
├── terraform/
│   ├── bootstrap/        # S3 bucket for tfstate (its own state stays local)
│   ├── versions.tf       # provider / terraform version constraints
│   ├── backend.tf        # S3 backend (partial configuration)
│   ├── providers.tf      # aws / helm
│   ├── variables.tf
│   ├── locals.tf         # naming, AZs, subnet CIDR math
│   ├── vpc.tf
│   ├── eks.tf
│   ├── alb_controller.tf # IRSA + helm_release (ALB Controller)
│   ├── passport.tf       # IRSA for the Passport Proxy + a demo secret
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── docs/                 # Passport setup guide (01–04 + troubleshooting)
│   └── ja/               # Japanese translation
├── assets/               # architecture diagram (drawio / png)
├── .github/workflows/    # terraform fmt / validate
└── Makefile
```

## Requirements

- Terraform >= 1.5.7 (1.10+ recommended, for the native S3 lock `use_lockfile`)
- AWS CLI v2, kubectl, Docker, Helm (the Helm CLI is optional — Terraform drives the chart)
- Permission to create VPC / EKS / IAM / ELB resources in the target account

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

Everything from here is Passport configuration, covered in [`docs/`](docs/).

| Document | Contents |
| --- | --- |
| [01 Infrastructure](docs/ja/01-infrastructure.md) 🇯🇵 | Steps 1–3 above in detail, plus issuing the ACM certificate for the management plane |
| [02 Deploying the proxy](docs/ja/02-passport-proxy.md) 🇯🇵 | Generating keys, configuring `values.yaml`, deploying with Helm |
| [03 DNS and exposure](docs/ja/03-dns-and-exposure.md) 🇯🇵 | Route53 records, connectivity checks, configuring Namespaces |
| [04 Developer setup](docs/ja/04-developer-setup.md) 🇯🇵 | Developer CLI setup and using secret references |

> 🇯🇵 **These guides are currently Japanese only.** The English translation is pending;
> [`docs/README.md`](docs/README.md) tracks the status. Commands, YAML and output samples
> are language-independent and usable as-is.

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

## Worth considering for production

- `single_nat_gateway = false`, placing a NAT Gateway per AZ to remove the single point of failure
- `endpoint_public_access = false`, reaching the cluster through Session Manager or a VPN
- WAF / Shield Advanced in front of the ALB
- HPA, PodDisruptionBudget, and Cluster Autoscaler or Karpenter
- VPC endpoints (S3 / CloudWatch Logs) to cut NAT traffic costs
- EKS control plane logging and container log collection (Fluent Bit or similar)
- `terraform plan` / `apply` from GitHub Actions via OIDC

## License

MIT
