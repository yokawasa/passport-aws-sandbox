# 04. 開発者向けセットアップ

> **対象**: 開発者（API を使う人）
> **所要時間**: 10〜15分
> **前提**: 管理者が [01](01-infrastructure.md)〜[03](03-dns-and-exposure.md) を完了していること

Passport CLI をインストールし、secret reference を使って API を叩けるようにします。

> **ポートフォワードは不要です。**
> 以前の構成では `kubectl port-forward` が必要でしたが、Proxy と管理プレーンは独自
> ドメインで公開されているため CLI から直接接続できます。**kubectl や EKS への
> アクセス権も必要ありません。**

## 管理者から受け取る情報

| 項目 | 値の例 |
| --- | --- |
| Management URL | `https://passport-mgmt.example.com` |
| Proxy URL | `https://passport-proxy.example.com:8443` |
| **Namespace ID** | `00000000-1111-2222-3333-444444444444` |

> URL は通常 `passport login` 後に**自動で解決される**ため、受け取らなくても済むことが
> 多いです。ただし **`--namespace-id` は secret reference を使うなら必須**なので、
> Namespace ID は必ず受け取ってください。

---

## Step 1. Passport CLI をインストールする

### macOS

Apple シリコンか Intel かで取得するファイルが変わります。まず自分の Mac を確認します。

```bash
uname -m
```

- `arm64` → Apple シリコン
- `x86_64` → Intel

**Apple シリコンの場合:**

```bash
curl -fL -o ~/Downloads/passport.pkg \
  "https://dl-passport.pstmn.io/download/version/0.6.0-canary-260921-212749/osx_arm64?channel=canary"
```

**Intel の場合:**

```bash
curl -fL -o ~/Downloads/passport.pkg \
  "https://dl-passport.pstmn.io/download/version/0.6.0-canary-260921-212749/osx_64?channel=canary"
```

インストールします（管理者パスワードの入力を求められます）。

```bash
sudo installer -pkg ~/Downloads/passport.pkg -target /
```

### Windows (PowerShell)

```powershell
curl.exe -fL -o $env:USERPROFILE\Downloads\passport.msi "https://dl-passport.pstmn.io/download/version/0.6.0-canary-260921-212749/win_64?channel=canary"
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
0.6.0-canary-260921-212749
```

> **注意**: 公式手順には `passport version` と書かれていますが、**正しくは
> `passport --version`（または `-v`）** です。

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

## Step 4. セットアップする

**secret reference を使うなら、このステップは必須です。**
Step 3 の自動セットアップでは `--namespace-id` が指定されないためです。

### まず接続先を確認する

**`--verbose` を付けると、どのエンドポイントにどの理由で接続するかが全部出ます。**
意図しない Proxy に向いていないか先に確認してください。

```bash
passport setup --verbose
```

```text
managementHost = passport-mgmt.example.com
  ✓ macOS managed plist        ← used
  · --management-url           (skipped, higher source matched)
  · PASSPORT_MGMT_HOST         (skipped, higher source matched)
  · passport-service discovery (skipped, higher source matched)
```

### ⚠️ エンドポイント解決の優先順位

上の出力が示す通り、**MDM プロファイルがコマンドライン引数より強い**です。

| 優先 | ソース | 備考 |
| --- | --- | --- |
| 1 | **macOS managed plist (MDM)** | **`--proxy-url` を指定しても上書きされる** |
| 2 | `--management-url` / `--proxy-url` | コマンドライン引数 |
| 3 | `PASSPORT_MGMT_HOST` / `PASSPORT_PROXY_HOST` | 環境変数 |
| 4 | passport-service discovery | 自動解決 |

```bash
defaults read /Library/Managed\ Preferences/com.postman.passport
```

```text
{
    ManagementURL = "https://passport-mgmt.example.com";
    ProxyURL = "https://passport-proxy.example.com:8443";
    RoutingPolicy = { Mode = "forward-all"; Strict = 1; ... };
}
```

**古いホスト名（または `localhost`）が入っている場合、引数では切り替えられません。**
IT 管理者にプロファイルの更新を依頼してください。

### セットアップを実行する

```bash
passport setup \
  --namespace-id <Namespace UUID> \
  --endpoint httpbin.org
```

URL が自動解決されない場合は明示します（MDM 設定がない場合のみ有効）。

```bash
passport setup \
  --management-url https://passport-mgmt.example.com \
  --proxy-url https://passport-proxy.example.com:8443 \
  --proxy-server-name passport-proxy.example.com \
  --namespace-id <Namespace UUID> \
  --endpoint httpbin.org
```

> `--management-url` を省略すると `--proxy-url` と同じ値が使われます。本構成では
> **管理プレーンと data plane でホスト名が異なる**ため、明示する場合は両方指定して
> ください。

### ⚠️ secret reference を使うなら `--namespace-id` が必須

**`--endpoint` だけでは参照の権限が証明書に乗りません。**

```bash
passport whoami
```

```text
allowedApiRefs
  GET httpbin.org/anything/*
```

**`allowedApiRefs  (none)` のままなら権限が乗っていません。** `--namespace-id` を
付け忘れているか、管理者側の紐付けが未完了です。

```bash
openssl x509 -in ~/.passport/cert.pem -noout -text | grep -A1 '1.3.6.1.4.1.99999.1'
```

```json
{"allowedApiRefs":{"GET httpbin.org/anything/*":[
  {"secretReference":"aaaaaaaa-...","vaultType":"aws","vaultKEK":"h9u3+hU3..."}]}}
```

`allowedApiRefs` が `{}` なら権限なし、リソースはあるが配列が `[]` なら secret
reference が未紐付けです。

### 主なオプション

| オプション | 用途 |
| --- | --- |
| `--endpoint <hostname>` | 証明書を使う対象ホスト（例: `api.stripe.com`） |
| `--ttl <seconds>` | 証明書の有効期間。デフォルト 3600 秒（**実測は 300 秒**） |
| **`--namespace-id <id>`** | Namespace UUID。**secret reference を使うなら必須** |
| `--proxy-server-name <host>` | SNI に使うホスト名。SAN 不一致の回避に使う |
| `--no-daemon` | デーモンを起動せず `HTTPS_PROXY` も設定しない（CI / headless 向け） |
| `--verbose` | エンドポイント解決の優先順位を全表示（`PASSPORT_DEBUG=1` でも有効） |

### 終了コードの意味

| コード | 意味 | 対処 |
| --- | --- | --- |
| `0` | 完全成功（証明書 + デーモン稼働） | — |
| `1` | 失敗（証明書の取得に失敗） | `--verbose` で原因を確認する |
| `2` | **部分成功**（証明書は取得できたがデーモンの起動に失敗） | `passport daemon status` で確認する |

> コード `2` は「成功」ではありません。証明書はあるがデーモンが動いていないため、
> 透過的なルーティングは機能しません。

## Step 5. セットアップを確認する

```bash
passport whoami          # 証明書内の identity を表示
passport daemon status   # デーモンの稼働状態、証明書の有効期限、upstream への到達性
passport ca status       # OS の信頼ストアに CA が入っているか
```

`passport daemon status` は3つをまとめて確認できるため、**最初に見るべきコマンド**です。

---

## Step 6. Passport 経由の通信を確認する

### 6-1. まず素のリクエストで疎通を確認する

```bash
passport request https://httpbin.org/get --show-headers
```

応答の `origin` が **Proxy が動いているネットワークの外向き IP**（AWS なら NAT Gateway
の IP）になっていれば、確かに Proxy を経由しています。

```bash
# 管理者が照合する場合
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp'
```

### 6-2. secret reference を使う

**`{{vault:...}}` に書くのは Passport が発行した UUID です。**
Secrets Manager のキー名ではありません。

| 書く場所 | 値 |
| --- | --- |
| Namespace の **vault key** 欄（管理者が設定） | `passport/demo/httpbin-token`（Secrets Manager のキー名） |
| **`{{vault:...}}`**（開発者が書く） | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee`（Passport 発行の UUID） |

UUID は証明書から確認できます。

```bash
openssl x509 -in ~/.passport/cert.pem -noout -text | grep -A1 '1.3.6.1.4.1.99999.1'
# → "secretReference":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
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
> **vault 参照をパスに埋めるのは避けてください。**
> 解決後のパスが秘密の値そのものになるため、Namespace 側に事前登録できません
> （パスが一致せず弾かれます）。ヘッダーかボディに入れてください。

### 6-3. エラーの切り分け

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

## Step 7. アクセスをリクエストする

Passport Cloud にサインインし、必要なエンドポイントへのアクセスをリクエストします。
管理者の承認後、secret reference が使えるようになります。

---

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
