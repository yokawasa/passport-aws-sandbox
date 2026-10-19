# ---------------------------------------------------------------------------
# Passport Proxy 用の IRSA と検証用シークレット
#
# Passport Proxy は {{vault:...}} 参照をリクエストごとに解決するため、
# AWS Secrets Manager への読み取り権限を IRSA で受け取る。
# Proxy 本体は Helm チャート (ociregistry.usepassport.ai) でデプロイするので、
# ここで管理するのは IAM と Secrets Manager 側のリソースのみ。
#
# ServiceAccount は Helm が作るため、作成された SA 名に対して信頼関係を張る。
# ---------------------------------------------------------------------------

module "passport_proxy_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name = "${local.name}-passport-proxy"

  role_policy_arns = {
    secrets = aws_iam_policy.passport_secrets_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Helm チャートの既定名 (<release>-<chart>)。release 名を変えたら要修正。
      namespace_service_accounts = ["${var.passport_namespace}:passport-passport"]
    }
  }

  tags = local.tags
}

# Proxy が解決を許可されるシークレットの範囲。
# prefix で絞り、Proxy が無関係なシークレットを読めないようにする。
resource "aws_iam_policy" "passport_secrets_read" {
  name        = "${local.name}-passport-secrets-read"
  description = "Allow Passport Proxy to resolve secrets under the ${var.passport_secret_prefix} prefix"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadPassportManagedSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.passport_secret_prefix}*"
      },
      {
        # GetSecretValue だけでは KMS CMK で暗号化されたシークレットを
        # 復号できないため、Secrets Manager 経由の復号を許可する。
        Sid      = "DecryptViaSecretsManager"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = local.tags
}

# ---------------------------------------------------------------------------
# 検証用シークレット
#
# secret reference の解決を動作確認するためのダミー値。
# 実値は Terraform の state に残るため、本番の認証情報をここに書かないこと。
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "demo" {
  count = var.passport_create_demo_secret ? 1 : 0

  name        = "${var.passport_secret_prefix}demo/httpbin-token"
  description = "Dummy token for verifying Passport secret reference resolution"

  # 検証用なので削除を即時にして作り直しを容易にする
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "demo" {
  count = var.passport_create_demo_secret ? 1 : 0

  secret_id     = aws_secretsmanager_secret.demo[0].id
  secret_string = "passport-demo-token-not-a-real-credential"
}
