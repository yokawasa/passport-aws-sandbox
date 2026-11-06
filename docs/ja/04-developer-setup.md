# 04. 開発者向けセットアップ

> **対象**: 開発者（API を使う人）
> **所要時間**: 10〜15分
> **前提**: 管理者が [01](01-infrastructure.md)〜[03](03-dns-and-exposure.md) を完了していること

Passport CLI をインストールし、secret reference を使って API を叩けるようにします。

> **ポートフォワードは不要です。**
> 以前の構成では `kubectl port-forward` が必要でしたが、Proxy と管理プレーンは独自
> ドメインで公開されているため CLI から直接接続できます。**kubectl や EKS への
> アクセス権も必要ありません。**

## 事前に必要なもの

**この手順書以外に受け取るものはありません。** 接続先の URL も Namespace ID も、
`passport login` が自動で解決します。

必要なのは次の2つだけです。

- Postman アカウント（Passport Cloud のチームに招待されていること）
- CLI をインストールできる権限（macOS なら管理者パスワード）

---

## Step 1. Passport CLI をインストールする

### macOS

Apple シリコンか Intel かで取得するファイルが変わります。まず自分の Mac を確認します。

```bash
uname -m
```

- `arm64` → Apple シリコン
- `x86_64` → Intel

```bash
# インストールするバージョン（管理者に確認。本書は 0.7.2 で検証）
PASSPORT_VERSION=0.7.2

# Apple シリコンなら osx_arm64、Intel なら osx_64
ARCH=$([ "$(uname -m)" = arm64 ] && echo osx_arm64 || echo osx_64)

curl -fL -o ~/Downloads/passport.pkg \
  "https://dl-passport.pstmn.io/download/version/$PASSPORT_VERSION/$ARCH"
```

> リリースチャネルによっては URL に `?channel=canary` が必要です（例:
> `.../0.6.0-canary-260921-212749/osx_arm64?channel=canary`）。配布方法は
> 管理者に確認してください。

インストールします（管理者パスワードの入力を求められます）。

```bash
sudo installer -pkg ~/Downloads/passport.pkg -target /
```

### Windows (PowerShell)

```powershell
curl.exe -fL -o $env:USERPROFILE\Downloads\passport.msi "https://dl-passport.pstmn.io/download/version/0.7.2/win_64"
```

```powershell
msiexec /i $env:USERPROFILE\Downloads\passport.msi /quiet
```

> Windows 環境は未検証です（本リポジトリでの動作確認は macOS arm64 のみ）。

### インストールを確認する

```bash
passport --version
```

```text
0.7.2
```

## Step 2. 現在の状態を確認する（任意）

インストール直後は何も設定されていません。

```bash
passport auth status      # → not logged in — run `passport login`
passport daemon status    # → Passport daemon: not running
passport ca status        # → no Passport CA certificate at ~/.passport/ca.pem
```

各コマンドは後でトラブルシューティングにも使えます。

## Step 3. ログインする

```bash
passport login
```

> **`passport login` はデフォルトでセットアップまで自動実行します。**
> 自動セットアップを止めたい場合は `--no-setup` を付けてください。

| オプション | 用途 |
| --- | --- |
| `--with-api-key <apikey>` | ブラウザを使わず API キーで認証する（CI 向け） |
| `--region eu` | EU リージョンで認証する |
| `--no-setup` | ログイン後の自動セットアップをスキップする |
| `--verbose` | エラーの詳細を表示する |

```bash
passport auth status
```

## Step 4. 権限が乗ったか確認する

secret reference を使う権限は、クライアント証明書に焼き込まれます。**乗っていなくても
`login` 自体は成功してしまう**ため、必ず確認してください。

```bash
passport whoami
```

出力例

```text
Passport identity:
  userId       user_01EXAMPLE...
  teamId       org_01EXAMPLE...
  allowedApiRefs
    GET httpbin.org/anything/*
      - httpbin-token  (aws)  →  {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}

  notBefore    2026-01-01T00:00:00.000Z
  notAfter     2026-01-01T00:05:00.000Z  (valid for 85s)
```

**`allowedApiRefs` にリソースが出ていれば完了です。** Step 5 へ進んでください。

> **そのまま使える `{{vault:...}}` が表示されます。** Step 5 で使う参照はここから
> コピーできるので、UUID を別途調べる必要はありません。

`allowedApiRefs` が `(none)` のまま、あるいは接続できない場合は
[トラブルシューティング](troubleshooting.md#開発者のセットアップ)を参照してください。

JSON で見たい場合（CLI 0.7.0 以降）:

```bash
passport whoami --json
```

```json
{"mode":"user","userId":"user_01EXAMPLE...","teamId":"org_01EXAMPLE...",
 "email":"you@example.com","allowedApiRefs":{"GET httpbin.org/anything/*":[
   {"secretReference":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "name":"httpbin-token","vaultType":"aws"}]},
 "notBefore":"...","notAfter":"...","validity":"VALID"}
```

**`validity` が `EXPIRED` なら** `passport refresh` で再発行してください
（TTL は最大 300 秒）。

## Step 5. Passport 経由の通信を確認する

### 5-1. まず素のリクエストで疎通を確認する

```bash
passport request https://httpbin.org/get --show-headers
```

応答の `origin` が **Proxy が動いているネットワークの外向き IP**（AWS なら NAT Gatewayの IP）になっていれば、確かに Proxy を経由しています。

```bash
# 管理者が照合する場合
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp'
```

### 5-2. secret reference を使う

**`{{vault:...}}` に書くのは Passport が発行した UUID です。**
Secrets Manager のキー名ではありません。

| 書く場所 | 値 |
| --- | --- |
| Namespace の **vault key** 欄（管理者が設定） | `passport/demo/httpbin-token`（Secrets Manager のキー名） |
| **`{{vault:...}}`**（開発者が書く） | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee`（Passport 発行の UUID） |

使える参照は Step 4 の `passport whoami` にそのままの形で出ています。

```text
  allowedApiRefs
    GET httpbin.org/anything/*
      - httpbin-token  (aws)  →  {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}
```

秘密はヘッダーに入れるのが実用的です。

```bash
passport request https://httpbin.org/anything/test \
  --show-headers \
  -H 'Authorization: Bearer {{vault:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}}'
```

成功すると、**送った参照ではなく解決後の実値**が相手に届きます。

```json
{
  "headers": {
    "Authorization": "Bearer passport-demo-token-not-a-real-credential"
  },
  "origin": "16.76.114.120",
  "url": "https://httpbin.org/anything/test"
}
```

> **URL は第1引数に置いてください。**
> オプションより後ろに書くと `error: missing required argument 'url'` になります。
>
> **`{{vault:...}}` はヘッダー / ボディ / URL / クエリパラメータのいずれにも書けます**
> （CLI のヘルプに明記されています）。ただしパスに埋める場合、**解決後のパスが
> リソース定義と一致する必要がある**点に注意してください。秘密の値そのものがパスに
> 入るとワイルドカード（`/anything/*` など）でしか一致させられません。
> ヘッダーに入れるのがもっとも確実です。

### 5-3. エラーの切り分け

| 応答 | `x-passport-proxy-error` | 原因 |
| --- | --- | --- |
| **403** | `unauthorized` | 参照が許可されていない。`--namespace-id` を指定したか、管理者が Namespace でリソースと secret を紐付けているか確認 |
| **502** | `decrypt-failed` | Access Proxy に登録された公開鍵が **reference 鍵ではない**。管理者側の設定ミス |
| **200** | — | 成功 |

### `passport request` の主なオプション

| オプション | 用途 |
| --- | --- |
| `-X, --method <method>` | HTTP メソッド（デフォルト `GET`） |
| `-H, --header <header...>` | 追加ヘッダー。複数指定可 |
| `-d, --data <body>` | リクエストボディ |
| `--show-headers` | レスポンスのステータスとヘッダーも表示 |
| `--insecure-proxy-hostname` | 外側 TLS のホスト名検証をスキップ（証明書チェーンの検証は継続） |

---

## Step 6. アクセスをリクエストする

Passport Cloud にサインインし、必要なエンドポイントへのアクセスをリクエストします。
管理者の承認後、secret reference が使えるようになります。

---

## 日常的な運用

### デーモンの管理

```bash
passport daemon status      # 状態確認
passport daemon start       # 起動
passport daemon stop        # 停止
passport daemon restart     # 再起動
passport daemon logs -f     # ログを追う
```

**Mac を再起動しても自動で立ち上がるようにする**には LaunchAgent を入れます。

```bash
passport daemon install
```

> これを入れると `export HTTPS_PROXY=...` を毎回打つ必要がなくなります。
> **開発者には実質必須**です。
>
> **⚠️ `daemon install` 直後、既に開いているターミナルでは `HTTPS_PROXY` が効きません。**
> 新しいターミナルを開いてください。

### 証明書の再発行

証明書の TTL は最大 300 秒です。期限切れは `whoami` の `validity` で分かります。

```bash
passport refresh          # 証明書を再発行（デーモンには触らない）
passport refresh --ttl 300
```

> `passport request` は自動で更新するため、通常このコマンドは不要です。
> `whoami` が `EXPIRED` のときや、管理者が Namespace のリソースを変更した直後に使います。

### ログの確認

```bash
passport logs                          # 全ログを時系列でマージ
passport logs --source connections     # 通信記録のみ
passport logs --source events          # デーモンのライフサイクルイベントのみ
passport logs -f --level warn          # warn 以上をストリーム
passport logs --json                   # JSON 形式で出力
passport logs:clear                    # ローテート
```

### OS の信頼ストア

OS の信頼ストアを使うツール（ブラウザ、一部の言語ランタイムなど）から Passport 経由の
通信を行う場合、CA を信頼させる必要があります。

```bash
passport ca install      # システムキーチェーンに登録（管理者権限が必要）
passport ca status       # 登録状態の確認
passport ca uninstall    # 削除
```

> `passport ca install` は未検証です（`trusted no` のまま動作確認しています）。

### TUI ダッシュボード

```bash
passport
```

| オプション | 用途 |
| --- | --- |
| `--theme <name>` | `passport` / `matrix` / `nord` / `mocha` |
| `--no-animation` | モーションエフェクトを無効化 |
| `--ascii` | ASCII のみで描画 |
| `--color <value>` | `auto` / `on` / `off` |

## 完了の確認

- [ ] `passport --version` が表示される
- [ ] `passport auth status` がログイン済み
- [ ] `passport whoami` の `allowedApiRefs` にリソースが出る
- [ ] `passport request` で `origin` が Proxy の外向き IP になる
- [ ] `{{vault:...}}` が実値に解決される

## アンインストール

```bash
passport daemon uninstall    # デーモンの自動起動と管理環境を削除
passport ca uninstall        # CA を信頼ストアから削除
passport logout              # 保存された Postman API キーを削除
```

その後、提供されているアンインストールスクリプトで CLI 本体を削除します。

---

困ったときは [トラブルシューティング](troubleshooting.md) を参照してください。
