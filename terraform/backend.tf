# tfstate は S3 に保存する。
# バケットは terraform/bootstrap で先に作成しておくこと。
#
# 初期化例:
#   terraform init \
#     -backend-config="bucket=<your-tfstate-bucket>" \
#     -backend-config="key=passport-sandbox/dev/terraform.tfstate" \
#     -backend-config="region=ap-northeast-1"
#
# S3 ネイティブのロック (use_lockfile) を使うため DynamoDB テーブルは不要。
# Terraform 1.10 未満の場合は dynamodb_table を指定すること。
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
