# 01. インフラ構築

> **対象**: 管理者（プラットフォーム / インフラ担当）
> **所要時間**: 40〜60分（Terraform の apply に 15〜20分）
> **前のステップ**: なし（ここから開始）
> **次のステップ**: [02. Passport Proxy のデプロイ](02-passport-proxy.md)

Passport Proxy用のベースインフラを構築します。Terraform で VPC / EKS / IRSA / Secrets Manager を作り、Passport Proxy の管理プレーン
(:8081) 用の ACM 証明書を発行します。

## このステップで作るもの

| リソース | 作成方法 | 用途 |
| --- | --- | --- |
| VPC / public・private subnet / NAT GW | Terraform | ネットワーク基盤 |
| EKS クラスタ / Managed Node Group | Terraform | Proxy と API の実行基盤 |
| AWS Load Balancer Controller | Terraform (`helm_release`) | Ingress から ALB を自動作成する |
| Passport Proxy 用 IRSA ロール | Terraform | Proxy が Secrets Manager を読むための権限 |
| 検証用シークレット | Terraform（任意） | secret reference の動作確認用 |
| **ACM 証明書** | **AWS CLI（手動）** | 管理プレーン ALB の TLS 終端 |

> **ALB / NLB は Terraform で作りません。** EKS 上の AWS Load Balancer Controller が
> `Ingress` / `Service` を見て作成・更新します。したがって **LB の DNS 名は
> 02 以降でしか分かりません**。この順序依存が手順書が3段階に分かれる理由です。

---

## Step 1. tfstate 用 S3 バケットを作る

```bash
make bootstrap TFSTATE_BUCKET=my-tfstate-bucket-1234 REGION=ap-northeast-1
```

バケット名は全世界で一意である必要があります。

## Step 2. 変数を用意する

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform.tfvars.example` には全変数が記載済みなので、値を書き足す必要はありません。
ただし以下は**必ず自分の環境の値に直してください**。

> **⚠️ `endpoint_public_access_cidrs` はコメントアウトされています。**
> そのまま apply すると変数の既定値 `0.0.0.0/0` が使われ、**EKS の API が全世界に
> 公開されます。** 行のコメントを外し、自分のグローバル IP に書き換えてください。
>
> ```bash
> curl -s https://checkip.amazonaws.com   # 自分のグローバル IP を確認
> ```

| 変数 | example の値 | 備考 |
| --- | --- | --- |
| `endpoint_public_access_cidrs` | 未指定 | **要変更。`kubectl` が叩く EKS API の公開範囲で、Passport の :8443 / :8081 とは無関係。** デフォルトが未指定で、その場合、変数の既定値が `0.0.0.0/0` なので、全世界公開になる。接続元 IP が変わったら再 apply が必要 |
| `passport_namespace` | `passport` | **Helm インストール時の `-n` と必ず一致させる。** ずれると IRSA の信頼関係が成立せず、Secrets Manager の解決が失敗する |
| `passport_secret_prefix` | `passport/` | このプレフィックス配下のシークレットだけ Proxy が読める。無関係なシークレットへのアクセスを防ぐ |
| `passport_create_demo_secret` | `true` | 検証用のダミートークンを作る。**実値が tfstate に残るので本番の認証情報は入れないこと。** 不要なら `false`（変数の既定値も `false`） |

## Step 3. init / apply

```bash
make tf-init TFSTATE_BUCKET=my-tfstate-bucket-1234
make tf-plan
make tf-apply
```

VPC・EKS・ノードグループ・ALB Controller の作成で **15〜20分**かかります。

## Step 4. kubeconfig を更新して疎通確認

```bash
make kubeconfig
kubectl get nodes
```

ノードが `Ready` になっていれば成功です。

```bash
# ALB Controller が動いているか（02 以降で Ingress を作るのに必須）
kubectl -n kube-system get deploy aws-load-balancer-controller

# IngressClass "alb" が存在するか
kubectl get ingressclass
```

## Step 5. 出力値を記録する

02 以降で使います。

```bash
terraform -chdir=terraform output
```

| 出力 | 用途 |
| --- | --- |
| **`passport_proxy_irsa_role_arn`** | **`values.yaml` の `serviceAccount.annotations` に設定する** |
| `passport_demo_secret_name` | Namespaces で secret reference に紐付ける |
| `cluster_name` | kubeconfig の更新 |

```bash
# 個別に取る場合
terraform -chdir=terraform output -raw passport_proxy_irsa_role_arn
```

---

## Step 6. 管理プレーン (:8081) 用の ACM 証明書を発行する

Passport Proxy の管理プレーン (:8081) は ALB で TLS 終端するため、ACM 証明書が必要です。
**ALB と同じリージョン (ap-northeast-1) に発行**します。

> **data plane (NLB) には証明書は不要です。** L4 パススルーでクライアント証明書を
> 終端させずに Pod まで届ける必要があり、TLS は Proxy 自身が終端するためです。

### 6-1. ゾーン ID を確認する

```bash
export AWS_PROFILE=my-aws-profile   # 環境に合わせる
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ               # example.com
export MGMT_FQDN=passport-mgmt.example.com

aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --query 'HostedZone.Name'
```

`"example.com."` が返れば正しいゾーンです。

### 6-2. 証明書をリクエストする

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name "$MGMT_FQDN" \
  --validation-method DNS \
  --region ap-northeast-1 \
  --query CertificateArn --output text)

echo "$CERT_ARN"
```

この ARN は 02 の `values.yaml` で使うので記録してください。

### 6-3. DNS 検証レコードを取得する

リクエスト直後は検証情報がまだ生成されていないことがあります。空で返ったら数秒おいて
再実行してください。

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

### 6-4. 検証レコードを Route53 に入れる

上の値を使って CNAME を作成します。

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

### 6-5. 発行を待つ

```bash
aws acm wait certificate-validated \
  --certificate-arn "$CERT_ARN" --region ap-northeast-1

aws acm describe-certificate --certificate-arn "$CERT_ARN" \
  --region ap-northeast-1 --query 'Certificate.Status'
```

`"ISSUED"` になれば完了です。通常 **数分**で発行されます。

> **`PENDING_VALIDATION` のまま進まない場合**
>
> ```bash
> # 検証レコードが正しく引けるか確認する
> dig +short "$VALIDATION_NAME" CNAME
> ```
>
> 引けない場合は 6-4 のレコード作成に失敗しています。`Name` の末尾のドットを含めて
> 完全一致しているか確認してください。

---

## 完了の確認

次に進む前に、以下がすべて満たされていることを確認してください。

- [ ] `kubectl get nodes` でノードが `Ready`
- [ ] `kubectl get ingressclass` に `alb` がある
- [ ] `terraform output passport_proxy_irsa_role_arn` が取れる
- [ ] ACM 証明書が `ISSUED`

記録しておく値:

| 項目 | 例 |
| --- | --- |
| IRSA ロール ARN | `arn:aws:iam::<account-id>:role/passport-sandbox-dev-passport-proxy` |
| ACM 証明書 ARN | `arn:aws:acm:ap-northeast-1:123456789012:certificate/xxxx` |
| ホストゾーン ID | `Z0123456789ABCDEFGHIJ` |
| 検証用シークレット名 | `passport/demo/httpbin-token` |

→ [02. Passport Proxy のデプロイ](02-passport-proxy.md) へ進む

---

## 片付け

**ロードバランサーを先に消してから** destroy します。順序を守らないと失敗します。

```bash
# 1. Passport Proxy をアンインストール (NLB と ALB が消える)
helm uninstall passport -n passport

# 2. VPC 内に LB / SG が残っていないことを確認 (残っていたら exit 1)
make destroy-check

# 3. destroy
make tf-destroy
```

> **⚠️ ALB / NLB は Terraform の管理対象外です。**
>
> これらは AWS Load Balancer Controller が `Ingress` / `type: LoadBalancer` の Service を
> 見て作成するため、`terraform destroy` は削除しようとしません。残したまま destroy すると、
> LB の ENI が private subnet を掴んだままになり、次のエラーで失敗します。
>
> ```text
> Error: deleting EC2 Subnet (subnet-xxxx): ... api error DependencyViolation:
>   The subnet 'subnet-xxxx' has dependencies and cannot be deleted.
> ```
>
> **とくに `helm uninstall passport` の消し忘れに注意してください。**
> データプレーンの NLB と管理プレーンの ALB はどちらも Helm 管理下にあるため、
> アンインストールしないと両方とも残ります。
>
> **削除は非同期です。** コントローラが実際に LB を消して ENI が解放されるまで
> **1〜3分**かかります。`make destroy-check` が「(なし)」を返すまで待ってください。
>
> **LB を消しても付随するセキュリティグループ (`k8s-...`) は残ります。**
> その場合は次に VPC の削除が同じ `DependencyViolation` で失敗します。
> `make destroy-check` は LB と SG の両方を確認します。

失敗した場合の復旧手順は
[トラブルシューティング](troubleshooting.md#destroy-が-dependencyviolation-で失敗する)を
参照してください。

### 手動で作ったリソースを消す

ACM 証明書と Route53 レコードは Terraform 管理外なので、手動で削除します。

```bash
# ACM 証明書
aws acm delete-certificate --certificate-arn "$CERT_ARN" --region ap-northeast-1

# Route53 レコード (検証用 CNAME と passport-* の CNAME)
# change-resource-record-sets の Action: DELETE で削除する
# ※ DELETE では Name / Type / TTL / ResourceRecords を作成時と完全一致させる必要がある
```
