# Passport on AWS — セットアップ手順書

[Postman Passport](https://usepassport.ai) を AWS (EKS) 上にゼロから構築し、開発者が
secret reference を使って API を叩けるようになるまでの手順書です。

このリポジトリで実際に検証した構成をもとにしています。**ポートフォワードを使わず、
Proxy と管理プレーンの両方に独自ドメインで外部からアクセスする構成**です。

## 全体の流れ

```
┌─ 01-infrastructure.md ──────────────────────────────┐
│  Terraform: VPC / EKS / IRSA / Secrets Manager       │   管理者
│  AWS CLI  : ACM 証明書の発行（DNS 検証）             │   40〜60分
└──────────────────────┬──────────────────────────────┘
                       │  EKS クラスタ・IRSA ロール ARN・証明書 ARN
                       ▼
┌─ 02-passport-proxy.md ──────────────────────────────┐
│  Helm: Passport Proxy をデプロイ                     │   管理者
│  鍵の生成、values.yaml の設定、NLB + ALB の作成      │   30〜45分
└──────────────────────┬──────────────────────────────┘
                       │  NLB / ALB の DNS 名
                       ▼
┌─ 03-dns-and-exposure.md ────────────────────────────┐
│  Route53: CNAME を切る → SAN を確定 → helm upgrade   │   管理者
│  疎通確認、Passport Cloud の Namespaces 設定         │   30〜40分
└──────────────────────┬──────────────────────────────┘
                       │  Proxy URL / Management Host / 公開鍵
                       ▼
┌─ 04-developer-setup.md ─────────────────────────────┐
│  Passport CLI のインストールと設定、通信確認         │   開発者
│                                                      │   10〜15分
└──────────────────────────────────────────────────────┘
```

**01〜03 は管理者が1回だけ実施します。04 は開発者が各自の PC で実施します。**
01〜03 が終わっていないと開発者の `passport setup` は完了しません。

## ドキュメント一覧

| # | ドキュメント | 対象 | 内容 |
| --- | --- | --- | --- |
| 01 | [インフラ構築](01-infrastructure.md) | 管理者 | Terraform で VPC / EKS / IRSA / Secrets Manager を作る。ACM 証明書を発行する |
| 02 | [Passport Proxy のデプロイ](02-passport-proxy.md) | 管理者 | 鍵を生成し、Helm で Proxy をデプロイする |
| 03 | [DNS と外部公開](03-dns-and-exposure.md) | 管理者 | Route53 にレコードを切り、ホスト名を確定して疎通確認する。Namespaces を設定する |
| 04 | [開発者向けセットアップ](04-developer-setup.md) | 開発者 | CLI をインストールし、secret reference 経由で API を叩く |
| — | [トラブルシューティング](troubleshooting.md) | 全員 | 実機で遭遇した落とし穴の一覧 |

## この構成の設計方針

### なぜ外部公開するのか

検証のたびに `kubectl port-forward` を張るのは、チームに展開する構成として現実的では
ありません。そこで **data plane (:8443) と管理プレーン (:8081) を、性質に応じて
非対称に公開**します。

| プレーン | ポート | 公開方法 | 根拠 |
| --- | --- | --- | --- |
| **data plane** | 8443 | NLB (`internet-facing`) | **mTLS 必須**。Passport CA が署名したクライアント証明書がないと TLS ハンドシェイクで切られる。インターネットに晒された mTLS ゲートウェイは Passport の設計前提 |
| **管理プレーン** | 8081 | ALB + **パス allowlist** (`/ca.pem`, `/issue-cert` のみ) | 平文 HTTP で、`/metrics` や管理 API と同居している。ALB で TLS 終端し、必要な2パスだけ通す |

> **⚠️ 管理プレーンを LoadBalancer で公開してはいけません。**
>
> :8081 には公開したい `/ca.pem` `/issue-cert` と、公開したくない `/metrics`
> `/revocation` 管理 API・Console UI が**同じポートに同居**しています。
> LoadBalancer にすると全部まとめて出てしまい、しかも平文 HTTP です。
> 必ず Ingress のパス allowlist を使ってください。

### data plane に ACM 証明書を使わない理由

NLB は L4 パススルーで、**クライアント証明書を終端させずに Pod まで届ける必要がある**
ためです。TLS は Proxy 自身が終端します。ACM 証明書が必要なのは管理プレーン側の
ALB だけです。

## この手順書で作るホスト名

**本手順書のコマンド・設定例はすべてダミー値で書かれています。**
自分の環境の値に読み替えてください。

ドメインは `example.com`（Route53 のパブリックホストゾーン）を例とし、ホスト名は
用途が分かるよう **`passport-proxy`**（data plane）と **`passport-mgmt`**（管理プレーン）
で統一しています。

| 役割 | ホスト名（例） | 向き先 | 用途 |
| --- | --- | --- | --- |
| **Proxy URL** | `passport-proxy.example.com` | NLB (:8443) | data plane。CLI が mTLS で接続する |
| **Management URL** | `passport-mgmt.example.com` | ALB (:443) | 管理プレーン。`/ca.pem` と `/issue-cert` のみ |

### 読み替えが必要なダミー値の一覧

| 本書の表記 | 意味 | 自分の値の確認方法 |
| --- | --- | --- |
| `example.com` | 所有するドメイン | Route53 のパブリックホストゾーン |
| `passport-proxy` / `passport-mgmt` | ホスト名（サブドメイン） | 任意。チーム名などを足して衝突を避ける（下記） |
| `Z0123456789ABCDEFGHIJ` | ホストゾーン ID | `aws route53 list-hosted-zones` |
| `my-aws-profile` | AWS CLI のプロファイル名 | `aws configure list-profiles` |
| `123456789012` | AWS アカウント ID | `aws sts get-caller-identity` |
| `org_01EXAMPLE000000000000000` | Postman Team ID | Team Settings → Team Info（`org_` で始まる値） |
| `00000000-1111-2222-3333-444444444444` | Namespace UUID | Passport Cloud の Namespace URL |
| `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` | secret reference UUID | Namespace で secret を紐付けた際に発行される |
| `ap-northeast-1` | リージョン | 任意のリージョンに読み替え可 |

> **ホスト名の衝突に注意**
>
> 共用のゾーンでは `passport-proxy` / `passport-mgmt` が既に使われていることが
> あります。その場合はチームや地域の識別子を足して衝突を避けてください
> （例: `jp-passport-proxy`、`passport-proxy-team-a`）。
> **ゾーン内の既存の命名慣習（接頭辞か接尾辞か）に合わせる**と、運用上わかりやすく
> なります。

## 前提知識とツール

Docker / Kubernetes / Helm / YAML / プライベートレジストリを一通り扱えることを前提と
しています。

必要なツール:

| ツール | 用途 | バージョン |
| --- | --- | --- |
| Terraform | インフラ構築 | >= 1.5.7（1.10 以上推奨） |
| AWS CLI v2 | ACM / Route53 / EKS | — |
| kubectl | Kubernetes 操作 | — |
| Helm | Proxy のデプロイ | 4.x で検証 |
| Docker | イメージの取得 | — |
| openssl | 鍵の生成と検証 | — |

## 検証済み環境

本手順書は以下の環境でエンドツーエンドに検証しています。

| 項目 | 値 |
| --- | --- |
| EKS クラスタ | Amazon EKS 1.33 / ap-northeast-1（クラスタ名は `<project>-<environment>`。既定では `passport-sandbox-dev`） |
| Helm チャート | `passport-0.6.0` |
| イメージ | `passport-proxy:v0.6.0` |
| CLI | `0.6.0-canary-260921-212749` / macOS arm64 |

> **ポートフォワード構成からの移行について**
>
> 以前の構成（`scheme: internal` + port-forward）から移行する場合、**LB の scheme は
> immutable なので `helm upgrade` では切り替わりません**。Service の delete + 再作成が
> 必要です。手順は [03-dns-and-exposure.md](03-dns-and-exposure.md#既存の-internal-nlb-から移行する場合) を参照してください。
