# terraform-aws-eks-api

private subnet の **Amazon EKS** で動く FastAPI の API を、public subnet の **ALB** 経由で公開する最小構成のリファレンス実装です。インフラはすべて Terraform で記述し、既存の [terraform-aws-modules](https://github.com/terraform-aws-modules) を活用しています。

## アーキテクチャ

```
                     Internet
                        │
                        ▼
        ┌───────────────────────────────┐
        │  public subnet (AZ-a / AZ-c)  │
        │   ALB (internet-facing)       │  ← Ingress から自動作成
        │   NAT Gateway                 │
        └───────────────┬───────────────┘
                        │ target-type: ip
                        ▼
        ┌───────────────────────────────┐
        │  private subnet (AZ-a / AZ-c) │
        │   EKS Managed Node Group      │
        │     └ Pod: FastAPI :8000      │
        └───────────────────────────────┘
```

ポイント:

- **ALB は Terraform で直接作らない。** EKS 上の AWS Load Balancer Controller が `Ingress` リソースを見て ALB を作成・更新します。パスやリスナーの変更が Kubernetes 側で完結し、ターゲット登録も自動化されるためです。
- VPC モジュールの `public_subnet_tags` / `private_subnet_tags` に `kubernetes.io/role/elb` と `kubernetes.io/role/internal-elb` を付与しています。**このタグが無いとコントローラが subnet を見つけられず ALB が作られません。**
- ALB は `target-type: ip` で Pod IP に直接ルーティングします（NodePort を経由しない）。
- ノードと control plane の ENI は private subnet のみ。外向き通信は NAT Gateway 経由です。
- コントローラの IAM 権限は IRSA（OIDC + ServiceAccount）で付与しています。

## 使っている Terraform モジュール

| モジュール | バージョン | 用途 |
|---|---|---|
| `terraform-aws-modules/vpc/aws` | `~> 6.0` | VPC、public/private subnet、NAT GW、ELB 検出用タグ |
| `terraform-aws-modules/eks/aws` | `~> 21.0` | EKS クラスタ、Managed Node Group、アドオン、アクセスエントリ |
| `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks` | `~> 5.60` | ALB Controller 用の IRSA ロール（AWS 管理のポリシー相当を同梱） |
| `helm_release` (hashicorp/helm) | — | `aws-load-balancer-controller` chart のインストール |

ECR リポジトリのみリソースを直書きしています（モジュールを使うほどの設定量がないため）。

## ディレクトリ構成

```
.
├── terraform/
│   ├── bootstrap/        # tfstate 用 S3 バケット (state はローカル)
│   ├── versions.tf       # provider / terraform のバージョン制約
│   ├── backend.tf        # S3 backend (partial configuration)
│   ├── providers.tf      # aws / kubernetes / helm
│   ├── variables.tf
│   ├── locals.tf         # 命名規則、AZ、subnet CIDR 計算
│   ├── vpc.tf
│   ├── eks.tf
│   ├── ecr.tf
│   ├── alb_controller.tf # IRSA + helm_release + app namespace
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── app/                  # FastAPI サンプル API
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                  # Deployment / Service / Ingress
├── .github/workflows/    # fmt / validate / docker build
└── Makefile
```

## 前提

- Terraform >= 1.5.7（S3 ネイティブロック `use_lockfile` を使うため 1.10 以上推奨）
- AWS CLI v2、kubectl、Docker、Helm（Terraform 側で使うため CLI は任意）
- 対象アカウントに VPC / EKS / IAM / ELB を作成できる権限

## セットアップ

### 1. tfstate 用 S3 バケットを作る

```bash
make bootstrap TFSTATE_BUCKET=my-tfstate-bucket-1234 REGION=ap-northeast-1
```

### 2. 変数を用意して init / apply

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# 必要に応じて編集（endpoint_public_access_cidrs は自分の IP に絞るのを推奨）

make tf-init TFSTATE_BUCKET=my-tfstate-bucket-1234
make tf-plan
make tf-apply
```

VPC・EKS・ノードグループ・ALB Controller の作成で 15〜20 分程度かかります。

### 3. kubeconfig を更新

```bash
make kubeconfig
kubectl get nodes
```

### 4. API をビルドして ECR に push、デプロイ

```bash
make deploy
```

`make deploy` は ECR ログイン → `docker push` → マニフェスト適用（`IMAGE_PLACEHOLDER` を ECR URL に置換）→ rollout 待ちまで行います。

### 5. 動作確認

```bash
make url     # ALB の DNS 名
make smoke   # ALB 経由で GET /
```

ALB のプロビジョニングとヘルスチェック通過に 2〜3 分かかります。

```
GET /         -> {"message":"Hello from EKS","version":"0.1.0","hostname":"sample-api-..."}
GET /healthz  -> {"status":"ok"}
POST /echo    -> リクエストボディをそのまま返す
GET /docs     -> Swagger UI
```

## 片付け

```bash
make undeploy    # 先に Ingress を削除して ALB を消す
make tf-destroy
```

> `Ingress` を残したまま `terraform destroy` すると、コントローラが作った ALB とセキュリティグループが残って VPC の削除に失敗します。必ず `make undeploy` を先に実行してください。

## 本番向けに検討したいこと

- `single_nat_gateway = false` にして AZ ごとに NAT Gateway を配置（単一障害点の除去）
- `endpoint_public_access = false` + Session Manager / VPN 経由の運用
- ACM 証明書 + Route 53 で HTTPS 化（`k8s/ingress.yaml` のコメント部分を参照）
- ALB に WAF / Shield Advanced を適用
- HPA、PodDisruptionBudget、Cluster Autoscaler または Karpenter の導入
- VPC エンドポイント（ECR / S3 / CloudWatch Logs）で NAT 通信料を削減
- EKS コントロールプレーンのログ有効化とコンテナログの収集（Fluent Bit など）
- OIDC 連携した GitHub Actions からの `terraform plan` / `apply` 自動化

## ライセンス

MIT
