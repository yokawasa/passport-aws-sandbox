# 01. Infrastructure setup

> **Audience**: administrators (platform / infrastructure)
> **Time required**: 40-60 minutes (15-20 minutes for the Terraform apply)
> **Previous step**: none (start here)
> **Next step**: [02. Deploying the Passport Proxy](02-passport-proxy.md)

Build the VPC / EKS / IRSA / Secrets Manager with Terraform, and issue the ACM certificate
for the Passport Proxy's management plane (:8081).

## What this step creates

| Resource | How it is created | Purpose |
| --- | --- | --- |
| VPC / public and private subnets / NAT GW | Terraform | Network foundation |
| EKS cluster / Managed Node Group | Terraform | Runtime for the Proxy and the API |
| AWS Load Balancer Controller | Terraform (`helm_release`) | Creates ALBs automatically from Ingress |
| IRSA role for the Passport Proxy | Terraform | Permission for the Proxy to read Secrets Manager |
| Test secret | Terraform (optional) | For verifying secret reference behavior |
| **ACM certificate** | **AWS CLI (manual)** | TLS termination for the management-plane ALB |

> **ALB / NLB are not created by Terraform.** The AWS Load Balancer Controller on EKS
> creates and updates them based on `Ingress` / `Service`. That means **the LB DNS names
> are not known until 02 or later**. This ordering dependency is why the guide is split
> into three stages.

---

## Step 1. Create the S3 bucket for tfstate

```bash
make bootstrap TFSTATE_BUCKET=my-tfstate-bucket-1234 REGION=ap-northeast-1
```

The bucket name must be globally unique.

## Step 2. Prepare the variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

All variables are already listed in `terraform.tfvars.example`, so you do not need to add
any values. However, **you must change the following to match your own environment**.

> **⚠️ `endpoint_public_access_cidrs` is commented out.**
> Apply it as-is and the variable's default of `0.0.0.0/0` takes effect, **publishing the
> EKS API to the entire internet.** Uncomment the line and replace it with your own global IP.
>
> ```bash
> curl -s https://checkip.amazonaws.com   # Check your own global IP
> ```

| Variable | Value in example | Notes |
| --- | --- | --- |
| `endpoint_public_access_cidrs` | unset | **Must be changed. This is the public range for the EKS API that `kubectl` talks to, and is unrelated to Passport's :8443 / :8081.** The default is unset, and in that case the variable's default value is `0.0.0.0/0`, so it is exposed to the whole world. If your source IP changes, you must apply again |
| `passport_namespace` | `passport` | **Must match the `-n` used at Helm install time.** If they differ, the IRSA trust relationship does not hold and Secrets Manager resolution fails |
| `passport_secret_prefix` | `passport/` | Only secrets under this prefix are readable by the Proxy. Prevents access to unrelated secrets |
| `passport_create_demo_secret` | `true` | Creates a dummy token for testing. **The actual value remains in tfstate, so do not put production credentials in it.** Set it to `false` if you do not need it (the variable's default value is also `false`) |

## Step 3. init / apply

```bash
make tf-init TFSTATE_BUCKET=my-tfstate-bucket-1234
make tf-plan
make tf-apply
```

Creating the VPC, EKS, node group, and ALB Controller takes **15-20 minutes**.

## Step 4. Update kubeconfig and verify connectivity

```bash
make kubeconfig
kubectl get nodes
```

Success is when the nodes become `Ready`.

```bash
# Whether the ALB Controller is running (required to create Ingress in 02 and later)
kubectl -n kube-system get deploy aws-load-balancer-controller

# Whether the IngressClass "alb" exists
kubectl get ingressclass
```

## Step 5. Record the output values

They are used in 02 and later.

```bash
terraform -chdir=terraform output
```

| Output | Purpose |
| --- | --- |
| **`passport_proxy_irsa_role_arn`** | **Set it in `serviceAccount.annotations` in `values.yaml`** |
| `passport_demo_secret_name` | Bind it to a secret reference under Namespaces |
| `cluster_name` | Updating kubeconfig |

```bash
# To fetch them individually
terraform -chdir=terraform output -raw passport_proxy_irsa_role_arn
```

---

## Step 6. Issue the ACM certificate for the management plane (:8081)

The Passport Proxy's management plane (:8081) terminates TLS at the ALB, so it needs an
ACM certificate. **Issue it in the same region as the ALB (ap-northeast-1)**.

> **The data plane (NLB) does not need a certificate.** The client certificate has to reach
> the Pod without being terminated, via L4 passthrough, because the Proxy itself terminates
> TLS.

### 6-1. Check the zone ID

```bash
export AWS_PROFILE=my-aws-profile   # Match your environment
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ               # example.com
export MGMT_FQDN=passport-mgmt.example.com

aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --query 'HostedZone.Name'
```

If `"example.com."` comes back, it is the right zone.

### 6-2. Request the certificate

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name "$MGMT_FQDN" \
  --validation-method DNS \
  --region ap-northeast-1 \
  --query CertificateArn --output text)

echo "$CERT_ARN"
```

Record this ARN, since it is used in the `values.yaml` in 02.

### 6-3. Get the DNS validation record

Right after the request, the validation information may not have been generated yet. If it
comes back empty, wait a few seconds and run it again.

```bash
aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region ap-northeast-1 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

```json
{
    "Name": "_abc123....passport-mgmt.example.com.",
    "Type": "CNAME",
    "Value": "_def456....acm-validations.aws."
}
```

### 6-4. Put the validation record into Route53

Create the CNAME using the values above.

```bash
VALIDATION_NAME=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
  --region ap-northeast-1 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text)
VALIDATION_VALUE=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
  --region ap-northeast-1 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text)

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$VALIDATION_NAME\",
        \"Type\": \"CNAME\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"$VALIDATION_VALUE\"}]
      }
    }]
  }"
```

### 6-5. Wait for issuance

```bash
aws acm wait certificate-validated \
  --certificate-arn "$CERT_ARN" --region ap-northeast-1

aws acm describe-certificate --certificate-arn "$CERT_ARN" \
  --region ap-northeast-1 --query 'Certificate.Status'
```

It is done once it becomes `"ISSUED"`. Issuance normally takes **a few minutes**.

> **If it stays at `PENDING_VALIDATION` and does not progress**
>
> ```bash
> # Check whether the validation record resolves correctly
> dig +short "$VALIDATION_NAME" CNAME
> ```
>
> If it does not resolve, the record creation in 6-4 failed. Check that it matches exactly,
> including the trailing dot in `Name`.

---

## Completion check

Before moving on, confirm that all of the following hold.

- [ ] Nodes are `Ready` in `kubectl get nodes`
- [ ] `alb` is present in `kubectl get ingressclass`
- [ ] `terraform output passport_proxy_irsa_role_arn` returns a value
- [ ] The ACM certificate is `ISSUED`

Values to record:

| Item | Example |
| --- | --- |
| IRSA role ARN | `arn:aws:iam::<account-id>:role/passport-sandbox-dev-passport-proxy` |
| ACM certificate ARN | `arn:aws:acm:ap-northeast-1:123456789012:certificate/xxxx` |
| Hosted zone ID | `Z0123456789ABCDEFGHIJ` |
| Test secret name | `passport/demo/httpbin-token` |

→ Continue to [02. Deploying the Passport Proxy](02-passport-proxy.md)

---

## Teardown

Destroy **only after deleting the load balancers first**. It fails if you do not follow the
order.

```bash
# 1. Uninstall the Passport Proxy (the NLB and ALB go away)
helm uninstall passport -n passport

# 2. Confirm no LB / SG remain in the VPC (exit 1 if any remain)
make destroy-check

# 3. destroy
make tf-destroy
```

> **⚠️ ALB / NLB are outside Terraform's management.**
>
> Because the AWS Load Balancer Controller creates them based on `Ingress` / `type:
> LoadBalancer` Services, `terraform destroy` does not try to delete them. If you destroy
> with them still in place, the LB ENIs keep holding the private subnets and it fails with
> the following error.
>
> ```text
> Error: deleting EC2 Subnet (subnet-xxxx): ... api error DependencyViolation:
>   The subnet 'subnet-xxxx' has dependencies and cannot be deleted.
> ```
>
> **Be especially careful not to forget `helm uninstall passport`.**
> Both the data-plane NLB and the management-plane ALB are under Helm's management, so if
> you do not uninstall, both remain.
>
> **Deletion is asynchronous.** It takes **1-3 minutes** for the controller to actually
> delete the LBs and release the ENIs. Wait until `make destroy-check` returns "(none)".
>
> **Even after the LBs are gone, the security groups that come with them (`k8s-...`)
> remain.** In that case, the VPC deletion then fails with the same `DependencyViolation`.
> `make destroy-check` checks both the LBs and the SGs.

For the recovery procedure when it fails, see
[Troubleshooting](troubleshooting.md#destroy-fails-with-dependencyviolation).

### Deleting the manually created resources

The ACM certificate and the Route53 records are outside Terraform's management, so delete
them manually.

```bash
# ACM certificate
aws acm delete-certificate --certificate-arn "$CERT_ARN" --region ap-northeast-1

# Route53 records (the validation CNAME and the passport-* CNAMEs)
# Delete them with Action: DELETE in change-resource-record-sets
# Note: DELETE requires Name / Type / TTL / ResourceRecords to match the creation exactly
```
