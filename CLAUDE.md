# CLAUDE.md

Postman Passport の動作検証用 AWS サンドボックス。EKS + ALB + Secrets Manager + IRSA を
Terraform で立て、Passport Proxy がシークレットを解決できることを確認する。

## 規約

- **コミットメッセージは英語で書く。**
- **ドキュメントは英語がデフォルト。** `docs/` 直下が英語、`docs/ja/` が日本語。
  ルートは `README.md`（英語）と `README.ja.md`。ファイル名は言語間で揃える
  （`docs/ja/` 内の相互リンクがそのまま使えるため）。
- `project` / `environment` から全リソース名が決まる（`locals.tf` の `local.name`）。
  既定は `passport-sandbox-dev`。変更すると全リソースが作り直しになる。
- 手順書に実値を書かない。ホスト名は `passport-proxy.example.com` /
  `passport-mgmt.example.com`、アカウント ID は `123456789012` のようなダミーを使う。
  読み替え表は `docs/README.md` にある。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| `terraform/` | VPC / EKS / ALB Controller / Passport 用 IRSA |
| `docs/` | Passport セットアップ手順書（英語。01〜04 + troubleshooting） |
| `docs/ja/` | 同・日本語版。**現時点ではこちらが原本** |
| `assets/` | アーキテクチャ図（`architecture.drawio` が原本、PNG は drawio CLI で書き出し） |

## 落とし穴

- **ALB / NLB とその SG は Terraform 管理外。** AWS Load Balancer Controller が
  `Ingress` / `type: LoadBalancer` の Service を見て作る。残したまま destroy すると
  subnet → VPC の順に `DependencyViolation` で失敗する。
  片付けは `helm uninstall passport -n passport` → `make destroy-check` →
  `make tf-destroy` の順。削除は非同期なので待つこと。
- **IRSA は `helm upgrade` だけでは効かない。** webhook が Pod 作成時のみ env を
  注入するため、`kubectl -n passport rollout restart deploy/passport-passport` が要る。
- AWS CLI は `AWS_PROFILE` の指定が要る。SSO 期限切れ時、`aws sts get-caller-identity`
  が通っても Terraform は失敗する（`aws sso login` で解消）。

詳細は `docs/troubleshooting.md`。
