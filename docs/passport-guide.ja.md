# Passport セットアップ手順書（旧・統合版）

> ## ⚠️ このドキュメントは現行構成ではありません
>
> **現行の手順書は [`docs/README.md`](README.md) を起点とする 01〜04 です。**
> 新しく構築する場合はそちらを参照してください。
>
> | 項目 | 本ドキュメント（旧） | 現行の 01〜04 |
> | --- | --- | --- |
> | data plane (:8443) | `scheme: internal` | **`internet-facing`**（mTLS で保護） |
> | 管理プレーン (:8081) | ClusterIP + **port-forward** | **ALB + パス allowlist**（`/ca.pem`, `/issue-cert` のみ） |
> | ホスト名 | LB の DNS 名を直接使用 | **独自ドメイン**（`jp-passport-*.example.com`） |
> | 開発者の前提 | kubectl / EKS アクセス権が必要 | **不要**（CLI だけで完結） |
>
> 本ドキュメントは、**`internal` 構成を選ぶ場合の参考**として残しています。
> `port-forward` / VPN / 踏み台での到達方法は
> [トラブルシューティング](troubleshooting.md#internal-lb-にした場合の到達経路)にも
> 要約があります。
>
> なお、**片付け手順についてはこのドキュメントの記述は不十分です**
> （`helm uninstall` 漏れによる destroy 失敗が未記載）。
> [トラブルシューティング](troubleshooting.md#片付けdestroy-時)を参照してください。


> **このドキュメントの読み方**
>
> Passport の導入は **管理者の作業** と **開発者の作業** に分かれます。自分の役割の章だけ読めば完了します。
>
> - **管理者**（プラットフォーム/インフラ担当）→ [Part 1](#part-1-管理者の作業) を実施。1人が1回やれば済みます。
> - **開発者**（API を使う人）→ [Part 2](#part-2-開発者の作業) を実施。各自の Mac で行います。
>
> 管理者の作業が終わっていないと開発者の `passport setup` は完了しません。順序は Part 1 → Part 2 です。

---

## Passport とは何か（3分で把握する）

Passport は、API のシークレット（APIキー、トークン）を**開発者の手元に配らずに**使えるようにする仕組みです。

開発者のコードには実際のキーではなく **secret reference**（キーの「参照」）を書きます。リクエストは Passport Proxy を通り、Proxy が参照を本物のシークレットに解決して API に転送します。開発者は本物のキーを一度も見ません。

```
開発者のコード                Passport Proxy              実際の API
(secret reference)  ──────▶  参照を解決して       ──────▶  (本物のキーで
                              本物のキーを付与              認証される)
                                    │
                                    ▼
                              API トラフィックを
                              OTEL 形式でログ記録
```

この仕組みのために3つのコンポーネントを設定します。

| コンポーネント | 置く場所 | 誰が設定するか | 役割 |
| --- | --- | --- | --- |
| **Passport Proxy** | 自社の Kubernetes | 管理者 | トラフィックの中継とログ記録、シークレットの解決 |
| **Passport CLI** | 開発者の PC | 開発者 | 開発者側のデーモン。ローカルの通信を Proxy に向ける |
| **Namespaces** | Passport Cloud | 管理者 | どのエンドポイントに誰がアクセスできるかの定義 |

---

# Part 1: 管理者の作業

## 事前に用意するもの

このチャートは **fail-closed 設計**です。必須項目が未設定なら `helm install` の時点で止まるか、Pod が起動を拒否します。「とりあえず入れてみて後で直す」ができないので、先に揃えてください。

### 必ず用意するもの

| 必要なもの | 入手方法 | 無いとどうなるか |
| --- | --- | --- |
| **レジストリ認証情報** | Passport の Registry 設定画面で発行 | Proxy のイメージ・チャートが一切取得できない |
| **Kubernetes クラスタ** | 既存のものでよい | — |
| **Postman Team ID** | [確認方法](#step-4-1-postman-team-id-を確認する)参照 | **Pod が起動を拒否する**（`CHANGE-ME` のままでは動かない） |
| **CA 鍵 / reference 鍵** | 自分で生成（[Step 4-2](#step-4-2-ca-鍵と-reference-鍵の-secret-を作る)） | **Pod が起動を拒否する**。実鍵が無条件で要求される |
| **Proxy のホスト名** | LoadBalancer の DNS 名、または独自ドメイン | CLI の TLS ハンドシェイクが `ERR_TLS_CERT_ALT_NAME_INVALID` で失敗する |

必要なツール: Docker、kubectl、Helm

### 条件次第で用意するもの

以下は**デフォルトのまま動く**ので、検証段階では不要です。本番や特定機能を使うときだけ設定します。

| 項目 | デフォルト | 用意が必要になる条件 |
| --- | --- | --- |
| `audit.sink` | **`stdout`（有効）** | 本番。`stdout` だと Pod のログに流れるだけで永続化されないため、`s3` / `http` などに変更する |
| `bundle.jwksUrl` | **Postman の公開 JWKS が設定済み** | 通常は変更不要。公開エンドポイントなので認証情報もいらない |
| S3 バケット | — | Proxy Console (`console.enabled`) を使う場合のみ |
| Vault | `aws-secrets-manager` | 使うバックエンドに応じて変更（file / hashicorp / aws / gcp） |

> **公式手順との相違**
>
> 公式手順は `audit.sink` を「必須。未設定だと起動失敗」、`bundle.jwksUrl` を「必須」、S3 を「Console に必須」と書いていますが、実物の `values.yaml` では**前2つはデフォルト値が入っており、S3 は Console を使わなければ不要**です。
>
> 逆に公式手順に書かれていない **Team ID と CA 鍵 / reference 鍵が真の必須項目**です。この2つが未設定だと Pod が起動しません。

## Step 1. レジストリ認証情報を発行する

Passport の **Registry 設定** から認証情報を発行します。組織の管理者が一度発行すれば、チーム全員がそれを使えます。

発行したキーを環境変数に入れます。

```bash
export PASSPORT_REGISTRY_KEY='<発行されたキー>'
```

> **シークレットの取り扱い**
> このキーはレジストリへのアクセス権です。シェル履歴に残したくない場合は、コマンドの先頭に空白を入れるか、`read -s PASSPORT_REGISTRY_KEY` で入力してください。リポジトリにコミットしないよう注意してください。

## Step 2. Docker でイメージを取得する

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | docker login ociregistry.usepassport.ai --username passport --password-stdin
```

```bash
docker pull ociregistry.usepassport.ai/passport/passport-proxy:latest
```

取得したイメージ名とタグは、後で `values.yaml` に書くので控えておきます。

### Kubernetes に直接 pull させる場合

自社レジストリにミラーせず、クラスタから Passport レジストリを直接参照させる場合は pull secret を作ります。

```bash
kubectl create secret docker-registry passport-registry \
  --docker-server=ociregistry.usepassport.ai \
  --docker-username=passport \
  --docker-password="$PASSPORT_REGISTRY_KEY"
```

作成後、`values.yaml` からこの secret（`passport-registry`）を参照させます。

## Step 3. Helm チャートを取得して values を書き出す

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | helm registry login ociregistry.usepassport.ai --username passport --password-stdin
```

```bash
helm show values oci://ociregistry.usepassport.ai/passport/passport --version 0.6.0 > values.yaml
```

> インストール時と同じチャートから values を書き出しているので、デフォルト値とテンプレートが食い違う心配はありません。

## Step 4. values.yaml を設定する

書き出した `values.yaml` を編集します。**この Step が全体でもっとも詰まりやすい箇所**です。以下の順に進めてください。

### Step 4-1. Postman Team ID を確認する

`bundle.allowedTeamIds` に入れる値です。デフォルトは `"CHANGE-ME"` で、**このままだと Pod が起動を拒否します**（テナント境界の定義なので fail-closed）。

> **⚠️ ここで必要なのは WorkOS 形式の組織 ID (`org_...`) です**
>
> Postman には2系統の ID があり、**混同すると `/issue-cert` が 403 になります**。
>
> | ID | 例 | ここで使うか |
> | --- | --- | --- |
> | WorkOS 組織 ID | `org_01EXAMPLE000000000000000` | ✅ **これを設定する** |
> | Postman の数値 team ID | `13347347` | ❌ 使わない（Postman API `/me` が返すのはこちら） |
> | teamDomain | `acme-demo` | ❌ 使わない（URL に出る文字列） |
>
> 数値 ID を設定すると Pod は正常に起動しますが、CLI からの証明書発行時に次のエラーになります。
>
> ```text
> POST /issue-cert returned 403: bundle verification failed:
> teamId "org_01EXAMPLE..." is not authorized for this deployment;
> ensure this team ID is included in the proxy's PASSPORT_PROXY_ALLOWED_TEAM_IDS configuration
> ```

### 確認方法

**もっとも確実な方法は、CLI に実際の値を吐かせることです。**

```bash
passport login          # 未ログインなら先に実行
passport auth status
```

出力の `org` 行が設定すべき値です。

```text
subject     user_01M391ERCKN5QDJYNYT42BJ8H7
org         org_01EXAMPLE000000000000000     ← これを使う
issuer      https://auth-passport-api.postmanlabs.com/...
```

`passport setup --verbose` を実行すると、CLI が送る `teamId` が直接確認できます。

```text
user  you@example.com  (userId=user_01M391...  teamId=org_01EXAMPLE000000000000000)
```

```yaml
bundle:
  allowedTeamIds: "org_01EXAMPLE000000000000000"    # ← WorkOS 形式の組織 ID
```

複数チームを許可する場合はカンマ区切りで指定します。

### Step 4-2. CA 鍵と reference 鍵の Secret を作る

`keys.mode: existingSecret`（デフォルト）では、以下2つの鍵を含む K8s Secret が必要です。

- **CA 署名鍵** — MITM CA とユーザーごとの証明書を発行する
- **reference 鍵** — ACS が暗号化した vault reference を復号する RSA 秘密鍵

> values.yaml のコメントに「ephemeral（使い捨て）CA モードは**削除された**。実鍵が必須」と明記されています。省略できません。

```bash
umask 077
mkdir -p .keys
openssl genrsa -out .keys/ca-private-key 4096
openssl genrsa -out .keys/reference-private-key 4096

kubectl create secret generic passport-keys \
  --from-file=ca-private-key=.keys/ca-private-key \
  --from-file=reference-private-key=.keys/reference-private-key \
  -n passport
```

ファイル名（`ca-private-key` / `reference-private-key`）は `values.yaml` の `keys.caFileName` / `keys.referenceFileName` と一致させてください。上記はデフォルト値に合わせています。

> **鍵の取り扱い**
> 生成した鍵はリポジトリにコミットしないでください。Secret 登録後はローカルのファイルを削除するか、安全な場所に退避してください。
> 鍵長・アルゴリズムの要件は values.yaml に明記されていません。上記は RSA 4096 の例です。要件が不明な場合は Postman に確認してください。

### Step 4-3. イメージと pull secret を設定する

```bash
kubectl create secret docker-registry passport-registry \
  --docker-server=ociregistry.usepassport.ai \
  --docker-username=passport \
  --docker-password="$PASSPORT_REGISTRY_KEY" \
  -n passport
```

```yaml
image:
  repository: ociregistry.usepassport.ai/passport/passport-proxy
  tag: "v0.6.0"
  pullSecrets:
    - name: passport-registry    # ← "- passport-registry" ではなく "- name:" が必要
```

> **⚠️ もっともハマりやすい落とし穴**
>
> `pullSecrets` は**マップのリスト**で書きます。文字列のリストにすると `helm install` が次のエラーで失敗します。
>
> ```text
> .spec.template.spec.imagePullSecrets: element 0:
>   associative list with keys may not have non-map elements
> ```
>
> ```yaml
> # NG                          # OK
> pullSecrets:                  pullSecrets:
>   - passport-registry           - name: passport-registry
> ```
>
> **このエラーは `--dry-run` では検出できません**（server-side apply の時点で判明するため）。dry-run が通っても install が失敗しうる、という例です。

### Step 4-4. Service の公開方法を決める

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal    # ← internal 推奨
```

> **`scheme: internal` を推奨します。**
> Proxy はシークレットを解決する経路です。`internet-facing` にするとチャートが警告を出し、`profile=production` では拒否されます。
>
> ただし internal にすると**手元の PC から直接到達できません**。CLI での検証には `kubectl port-forward` か VPN / 踏み台が必要になります。

管理プレーン（8081）は `ClusterIP` のまま変更しないでください。平文 HTTP で内部限定の設計です。

### Step 4-5. その他の項目

| 項目 | 設定例 | 備考 |
| --- | --- | --- |
| `namespace.create` | `false` | 自分で `kubectl create namespace` した場合 |
| `vault.source` | `aws-secrets-manager` | 使うバックエンドに合わせる |
| `vault.aws.region` | `ap-northeast-1` | **デフォルトは `us-east-1`** なので要変更 |
| `audit.sink` | `stdout`（検証）/ `s3`（本番） | `stdout` は永続化されない |
| `proxy.dataplaneCertSANs` | **この時点では空のまま** | Step 5 で設定（理由は後述） |

## Step 5. Proxy をデプロイする

### なぜ2段階になるのか

`proxy.dataplaneCertSANs` には **CLI が接続するホスト名**を入れます。ここが実際の接続先と一致しないと、CLI の TLS ハンドシェイクが `ERR_TLS_CERT_ALT_NAME_INVALID` で失敗します。

LoadBalancer の DNS 名は**作ってみないと分からない**ため、次の順序になります。

```
1回目 install → LB が作られる → DNS 名を取得 → values に設定 → helm upgrade
                                                  （ここで CLI が接続可能になる）
```

独自ドメインを使う場合は先に DNS を決められるので、この往復は不要です。

### 5-1. レンダリングを検証する

実リソースを作らずにチャートが通るか確認します。

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport --dry-run
```

警告が出たら対処してください。`service.type=LoadBalancer` が internal でない場合はここで警告されます。

### 5-2. インストールする

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

> **install が失敗した場合**
> リリースが `failed` 状態で残るため、`helm install` をやり直せません（`cannot re-use a name that is still in use`）。
> `values.yaml` を修正して **`helm upgrade`** で適用するか、`helm uninstall passport -n passport` してからやり直してください。
> 状態確認: `helm status passport -n passport`

### 5-3. LoadBalancer の DNS 名を取得する

```bash
kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### 5-4. ホスト名を設定して再適用する

取得した DNS 名を2箇所に設定します。

```yaml
proxy:
  dataplaneCertSANs: "k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com"
  managementHost: "k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com"
```

```bash
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

### デプロイ後に記録しておくもの

| 項目 | 取得方法 | 用途 |
| --- | --- | --- |
| **Proxy URL** | LB の DNS 名 + `:8443` | 開発者への案内、Namespaces 設定 |
| **Management Host** | 同上 | 同上 |
| **公開鍵** | `GET /ca.pem`（[Step 6](#step-6-proxy-の動作を確認する)） | Namespaces の Access Proxy 登録 |
| **Vault の種別** | `values.yaml` の `vault.source` | Namespaces 設定 |

> この4つは Namespaces 設定（Step 7）で必要になります。

## Step 6. Proxy の動作を確認する

### 6-1. Pod とリリースの状態

```bash
kubectl -n passport get pods,svc
helm status passport -n passport
```

両 Pod が `1/1 Running` / `RESTARTS 0`、リリースが `STATUS: deployed` になっていれば成功です。

### 6-2. 起動ログを確認する

```bash
kubectl -n passport logs -l app.kubernetes.io/instance=passport --tail=30
```

ログは OTEL 形式の JSON なので読みにくいですが、以下が出ていれば正常です。

| ログ | 意味 |
| --- | --- |
| `passport: /issue-cert enabled` | jwksUrl と allowedTeamIds を読み込めた |
| `starting HTTPS proxy` (port 8443) | data plane が待ち受け開始 |
| `starting management server` (port 8081) | 管理プレーンが待ち受け開始 |

次の WARN は**設定次第で正常**です。該当機能を無効にしている場合は無視してよいものです。

```text
passport: revocation disabled (set PASSPORT_PROXY_REVOCATION_STORE, ...)
passport: console auth disabled (PASSPORT_PROXY_CONSOLE_USER and/or ... unset)
```

### 6-3. ヘルスチェックと公開鍵の取得

管理プレーンは `ClusterIP` なので、`port-forward` を経由します。

```bash
kubectl -n passport port-forward deploy/passport-passport 8081:8081
```

別のターミナルで:

```bash
curl -s localhost:8081/knockknock   # liveness → {"response":"Who is there?"}
curl -s localhost:8081/readyz       # readiness → 鍵のロード・リスナー・audit sink の準備状況
```

### 6-4. CA 証明書と「reference 鍵の公開鍵」を用意する

Step 7-2 の Access Proxy 登録で使う値を準備します。**ここが全体でもっとも間違えやすい箇所です。**

#### Access Proxy に登録するのは reference 鍵の公開鍵

Step 4-2 で2つの鍵を作りました。用途がまったく違います。

| 鍵 | 用途 | Access Proxy に登録するか |
| --- | --- | --- |
| `ca-private-key` | クライアント証明書の署名（MITM CA） | ❌ **登録しない** |
| **`reference-private-key`** | **`vaultKEK` の復号** | ✅ **この公開鍵を登録する** |

`values.yaml` のコメントが根拠です。

> **reference (KEK)** → RSA private half that decrypts the vault references ACS envelope-encrypts with the **tenant public key**

Passport Cloud (ACS) がテナント公開鍵で `vaultKEK` を envelope 暗号化し、Proxy が reference 秘密鍵で復号します。したがって登録するのは **reference 鍵の公開鍵**です。

```bash
openssl rsa -in .keys/reference-private-key -pubout -out passport-reference-pubkey.pem
```

> **⚠️ CA 鍵の公開鍵を登録すると、認可は通るのに復号で失敗します**
>
> ```text
> HTTP/1.1 502 Bad Gateway
> x-passport-proxy-error: decrypt-failed
> passport: failed to decrypt vault reference: <uuid>
> ```
>
> 403 ではなく **502 `decrypt-failed`** が出たら、この取り違えを疑ってください。
>
> **さらに厄介なのは、間違えると復旧が重いことです。**
> Access Proxy の公開鍵は登録後に変更できません（UI が Read-only）。作り直しが必要で、しかも **Access Proxy を作り直しただけでは既存の secret reference の `vaultKEK` は再暗号化されません**（値が完全に同一のまま残ります）。secret reference も作り直す必要があり、UI で個別削除できない場合は Namespace ごと作り直すことになります。
>
> **最初に正しい鍵を登録してください。**

#### 鍵の取り違えを検出する

modulus の指紋を比べれば、どの鍵を登録したか判別できます。

```bash
openssl rsa -in .keys/ca-private-key        -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -in .keys/reference-private-key -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -pubin -in passport-reference-pubkey.pem -noout -modulus | md5
```

3つ目が **2つ目（reference 鍵）と一致**していれば正しいです。1つ目と一致していたら CA 鍵を登録しようとしています。

#### CA 証明書も別途取得する

こちらは CLI 側が信頼するために使います（`passport ca install`）。Access Proxy には登録しません。

```bash
curl -s localhost:8081/ca.pem > passport-ca.pem
```

| ファイル | ヘッダー | 用途 |
| --- | --- | --- |
| `passport-ca.pem` | `-----BEGIN CERTIFICATE-----` | CLI が信頼する CA 証明書 |
| **`passport-reference-pubkey.pem`** | `-----BEGIN PUBLIC KEY-----` | **Access Proxy 登録に貼る値** |

> Access Proxy の公開鍵欄に証明書（`BEGIN CERTIFICATE`）を貼ると、そもそもバリデーションで弾かれます。
>
> ```text
> Enter a PEM-encoded public key or leave this field empty.
> ```
>
> ただし「`BEGIN PUBLIC KEY` なら何でも通る」ので、**CA 鍵から抽出した公開鍵は受理されてしまいます**。その結果が上記の 502 です。形式が正しいだけでは不十分で、中身が reference 鍵であることが必要です。

取得した証明書を検証します。

```bash
openssl x509 -in passport-ca.pem -noout -subject -dates
openssl x509 -in passport-ca.pem -noout -text | grep -A3 'Subject Alternative Name'
```

実際の出力例:

```text
subject= /CN=passport-proxy/O=Passport/OU=passport
notBefore=Jan  1 00:00:00 2025 GMT
notAfter=Jan  1 00:00:00 2030 GMT

X509v3 Subject Alternative Name:
    IP Address:127.0.0.1, DNS:k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com,
    DNS:localhost, DNS:passport-proxy
```

確認すべき点:

| 項目 | 期待値 |
| --- | --- |
| `CA:TRUE` | 自己署名の CA として生成されている |
| 鍵長 | Step 4-2 で生成した鍵と同じ（例: RSA 4096 bit） |
| **SAN** | `dataplaneCertSANs` に設定した名前が含まれている |
| 有効期限 | 5年（2025–2030） |

> **SAN は自動で補完されます**
> `dataplaneCertSANs` に指定した値に加えて、`localhost` / `127.0.0.1` / `passport-proxy` がランタイム側で付与されます。port-forward 経由での検証に追加設定は不要です。
>
> 独自ドメインを使う場合は、その名前が SAN に入っているかここで確認してください。

### API トラフィックのログについて

Proxy は API トラフィックを **OpenTelemetry (OTEL) 形式**で記録します。この記録は **Namespaces の設定なしでも動きます**。

実際にアクセスされているエンドポイントを把握してから Namespaces のリソースを定義したい場合は、ここで一度トラフィックを流し、OTEL ログをエクスポートしておくと、次の Step 7 でそのまま取り込めます。

## Step 7. Namespaces を設定する（Passport Cloud 側）

ここからはブラウザでの作業です。Namespaces は secret reference の発行・失効を有効にし、API エンドポイントをリソースにマッピングします。

### 7-1. Passport に登録する

[app.usepassport.ai](https://app.usepassport.ai) でメールアドレスを登録 → 確認コードを入力 → パスワードを設定。

### 7-2. Access Proxy を登録する

右上のアカウントメニューから **Team Settings** → **Access Proxies** → **Create Access Proxy**。

Step 5 / Step 6-4 で記録した以下を入力します。

| 入力欄 | 値 |
| --- | --- |
| Proxy URL | `https://<LB の DNS 名>:8443` |
| Management Host | `https://<LB の DNS 名>` |
| Proxy public key | **`passport-reference-pubkey.pem` の内容**（reference 鍵の公開鍵） |

> **⚠️ 公開鍵は登録後に変更できません（UI が Read-only）。**
> 間違えると Access Proxy の作り直し、さらに secret reference の作り直し（場合によっては Namespace ごと）が必要になります。
> [Step 6-4](#6-4-ca-証明書とreference-鍵の公開鍵を用意する) で指紋を照合し、**reference 鍵**であることを確認してから登録してください。
>
> - `passport-ca.pem`（`BEGIN CERTIFICATE`）→ バリデーションで弾かれる
> - CA 鍵から抽出した公開鍵 → **受理されるが、後で 502 `decrypt-failed` になる**

### 7-3. API リソースを設定する

Home ページで namespace を作成し、**Add Resources** を選択。追加方法は3通りあります。

| 方法 | 向いている場面 |
| --- | --- |
| **OTEL logs** | Step 6 でログをエクスポート済みの場合。実際に観測されたエンドポイントをそのままリソース化できる |
| **cURL** | 対象の API が分かっている場合。サンプルを自分のエンドポイントに合わせて調整する |
| **Manual** | エンドポイントを直接入力する |

> **パスはワイルドカードを使うのが実用的です。**
> `/anything/test` のような固定パスだと、そのパスにしかマッチしません。`/anything/*` のように登録しておくと柔軟に使えます。

#### secret reference を紐付ける

リソースを登録したら、**そのリソースに secret reference を紐付けます**。これをやらないと参照が使えません。

入力項目は3つです。

| 欄 | 入れる値 | 説明 |
| --- | --- | --- |
| **Secret Name** | `httpbin-token` など任意 | Passport Cloud 上の表示名。`{{vault:...}}` には使いません |
| **Vault Type** | `AWS` | `values.yaml` の `vault.source` と対応 |
| **vault key** | `passport/demo/httpbin-token` | **Secrets Manager のシークレット名**。Proxy が AWS に問い合わせるときのキー |

> `vault.aws.pathPrefix` を設定している場合、vault key はプレフィックスを除いた部分になります。空（デフォルト）なら完全なシークレット名をそのまま入れます。

### 7-4. 設定が反映されたか確認する

Namespace の設定は**証明書（bundle）に埋め込まれて**開発者に届きます。設定しただけでは有効になりません。

Namespace の UUID を URL から取得します。

```text
https://app.usepassport.ai/namespaces/00000000-1111-2222-3333-444444444444
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

CLI で証明書を再発行し、中身を確認します。

```bash
passport setup --namespace-id <Namespace UUID> --endpoint httpbin.org
openssl x509 -in ~/.passport/cert.pem -noout -text | grep -A1 '1.3.6.1.4.1.99999.1'
```

期待される出力:

```json
{"userId":"...","teamId":"...","bundleVersion":2,
 "allowedApiRefs":{"GET httpbin.org/anything/*":[
   {"secretReference":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "vaultType":"aws",
    "vaultKEK":"h9u3+hU3hSW5EgM8..."}]}}
```

| 確認項目 | 意味 |
| --- | --- |
| `allowedApiRefs` にリソースが出ている | リソース登録が反映された |
| `secretReference` に UUID が入っている | secret reference の紐付けが反映された |
| `vaultKEK` に値が入っている | 公開鍵で暗号化された鍵素材。Proxy が reference 鍵で復号する |

**`allowedApiRefs` が `{}` のままなら、`--namespace-id` を指定していないか、紐付けができていません。**

### 7-5. チームメンバーを招待する

Namespaces の設定が終わったらチームを招待します。開発者はサインイン後、必要なエンドポイントへのアクセスをリクエストできるようになります。

## Step 8. 開発者に案内する

開発者に必要なのは、基本的には **Passport Cloud のチーム招待** だけです。CLI は `passport login` 時に Proxy のエンドポイントを自動解決するため、通常 URL を手渡す必要はありません。

ただし自動解決できない環境（閉域、独自ホスト名など）では手動指定が必要になるため、以下を併せて案内できるようにしておくと確実です。

```
Management Host: https://<management_url>
Proxy URL:       https://<proxy_url>:8443
```

開発者には、CLI インストール後に **`passport daemon install` の実行**を必ず案内してください。これを入れないと、開発者は毎回 `export HTTPS_PROXY=...` を打つ必要があります。

---

# Part 2: 開発者の作業

> **前提**: Postman アカウントがあり、Passport Cloud のチームに招待されていること。
>
> Proxy の URL は通常 `passport login` 後に自動で解決されるため、**管理者から URL を受け取る必要はありません**。自動解決できない環境の場合のみ、管理者から Proxy URL を受け取ってください（[Step 3 の補足](#proxy-の-url-が自動解決されない場合)参照）。

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

### インストールを確認する

```bash
passport --version
```

実際の出力例（`/usr/local/bin/passport` にインストールされます）:

```
0.6.0-canary-260921-212749
```

> **注意**: 公式手順には `passport version` と書かれていますが、**正しくは `passport --version`（または `-v`）** です。

## Step 2. 現在の状態を確認する（任意）

インストール直後は何も設定されていません。確認すると以下のようになります。

```bash
passport auth status      # → not logged in — run `passport login`
passport daemon status    # → Passport daemon: not running
passport ca status        # → no Passport CA certificate at ~/.passport/ca.pem
```

この状態からセットアップを始めます。各コマンドは後でトラブルシューティングにも使えます。

## Step 3. ログインする

```bash
passport login
```

> **重要**: `passport login` は**デフォルトでセットアップまで自動実行します**。つまり通常はこれ1コマンドで完了し、Step 4 は不要です。
>
> 自動セットアップを止めたい場合は `--no-setup` を付けてください。

よく使うオプション:

| オプション | 用途 |
| --- | --- |
| `--with-api-key <apikey>` | ブラウザを使わず API キーで認証する（CI 向け） |
| `--region eu` | EU リージョンで認証する |
| `--no-setup` | ログイン後の自動セットアップをスキップする |
| `--verbose` | エラーの詳細を表示する |

> `--alias` オプションは**廃止予定**です。新規に使わないでください。

ログインできたか確認します。

```bash
passport auth status
```

## Step 4. セットアップする（必要な場合のみ）

Step 3 で自動実行されているため、**通常このステップは不要です**。以下の場合のみ実行します。

- `--no-setup` を付けてログインした
- 対象エンドポイントを指定したい
- Proxy の URL を手動で指定する必要がある

### まず接続先を確認する

**`--verbose` を付けると、どのエンドポイントにどの理由で接続するかが全部出ます。** 意図しない Proxy に向いていないか、先に確認してください。

```bash
passport setup --verbose
```

```text
managementHost = automation-testing-secure-proxy.postmanlabs.com
  ✓ macOS managed plist        ← used
  · --management-url           (skipped, higher source matched)
  · PASSPORT_MGMT_HOST         (skipped, higher source matched)
  · passport-service discovery (skipped, higher source matched)
```

### ⚠️ エンドポイント解決の優先順位

上の出力が示す通り、**優先順位は以下の通りで、MDM プロファイルがコマンドライン引数より強い**です。

| 優先 | ソース | 備考 |
| --- | --- | --- |
| 1 | **macOS managed plist (MDM)** | **`--proxy-url` を指定しても上書きされる** |
| 2 | `--management-url` / `--proxy-url` | コマンドライン引数 |
| 3 | `PASSPORT_MGMT_HOST` / `PASSPORT_PROXY_HOST` | 環境変数 |
| 4 | passport-service discovery | 自動解決 |

MDM 管理された Mac では、`/Library/Managed Preferences/com.postman.passport.plist` に `ManagementURL` と `ProxyURL` が入っています。

```bash
defaults read /Library/Managed\ Preferences/com.postman.passport
```

```text
{
    ManagementURL = "https://mgmt.example.com";
    ProxyURL = "https://proxy.example.com:8443";
    RoutingPolicy = { Mode = "forward-all"; Strict = 1; ... };
}
```

**自前の Proxy で検証したいのに MDM 設定が入っている場合**、引数では切り替えられません。IT 管理者に該当プロファイルの削除・変更を依頼するか、MDM 管理外の環境で検証してください。

### 基本形（エンドポイントを指定）

```bash
passport setup --endpoint api.stripe.com
```

### ⚠️ secret reference を使うなら `--namespace-id` が必須

**`--endpoint` だけでは参照の権限が証明書に乗りません。** Namespace を明示する必要があります。

```bash
passport setup --namespace-id <Namespace UUID> --endpoint httpbin.org
```

Namespace UUID は Passport Cloud の URL から取得します。

```text
https://app.usepassport.ai/namespaces/00000000-1111-2222-3333-444444444444
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

指定できたか確認します。

```bash
passport whoami
```

```text
allowedApiRefs
  GET httpbin.org/anything/*
```

**`allowedApiRefs  (none)` のままなら権限が乗っていません。** `--namespace-id` を付け忘れているか、管理者側の紐付けが未完了です。

生の内容を見るとより詳しく分かります。

```bash
openssl x509 -in ~/.passport/cert.pem -noout -text | grep -A1 '1.3.6.1.4.1.99999.1'
```

```json
{"allowedApiRefs":{"GET httpbin.org/anything/*":[
  {"secretReference":"aaaaaaaa-...","vaultType":"aws","vaultKEK":"h9u3+hU3..."}]}}
```

`allowedApiRefs` が `{}` なら権限なし、リソースはあるが配列が `[]` なら secret reference が未紐付けです。

### Proxy の URL が自動解決されない場合

管理者から受け取った URL を指定します（MDM 設定がない場合のみ有効）。

```bash
passport setup --proxy-url https://my-proxy.example.com:8443
```

管理用と data-plane で host が異なる場合:

```bash
passport setup \
  --management-url https://mgmt.example.com \
  --proxy-url https://proxy.example.com:8443
```

> `--management-url` を省略すると `--proxy-url` と同じ値が使われます。

### 主なオプション

| オプション | 用途 |
| --- | --- |
| `--endpoint <hostname>` | 証明書を使う対象ホスト（例: `api.stripe.com`） |
| `--ttl <seconds>` | 証明書の有効期間。**デフォルト 3600 秒（1時間）** |
| **`--namespace-id <id>`** | Namespace UUID。**secret reference を使うなら必須**（後述） |
| `--no-daemon` | デーモンを起動せず `HTTPS_PROXY` も設定しない（CI / headless 向け） |
| `--verbose` | エンドポイント解決の優先順位を全表示（`PASSPORT_DEBUG=1` でも有効） |

### 終了コードの意味

`passport setup` は結果によって終了コードが変わります。**CI で使う場合はとくに重要です。**

| コード | 意味 | 対処 |
| --- | --- | --- |
| `0` | 完全成功（証明書 + デーモン稼働） | — |
| `1` | 失敗（証明書の取得に失敗） | `--verbose` で原因を確認する |
| `2` | **部分成功**（証明書は取得できたがデーモンの起動に失敗） | `passport daemon status` で確認する |

> コード `2` は「成功」ではありません。証明書はあるがデーモンが動いていないため、透過的なルーティングは機能しません。

## Step 5. セットアップを確認する

```bash
passport whoami          # 証明書内の identity を表示
passport daemon status   # デーモンの稼働状態、証明書の有効期限、upstream への到達性
passport ca status       # OS の信頼ストアに CA が入っているか
```

`passport daemon status` は3つをまとめて確認できるため、**最初に見るべきコマンド**です。

## Step 6. Passport 経由の通信を確認する

### 6-1. まず素のリクエストで疎通を確認する

secret reference を使う前に、Proxy を通れることを確かめます。

```bash
passport request https://httpbin.org/get --show-headers
```

応答の `origin` が **Proxy が動いているネットワークの外向き IP**（AWS なら NAT Gateway の IP）になっていれば、確かに Proxy を経由しています。

```bash
# AWS の場合、NAT Gateway の IP と一致するか照合できる
aws ec2 describe-nat-gateways --region <region> \
  --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp'
```

### 6-2. secret reference を使う

**`{{vault:...}}` に書くのは Passport が発行した UUID です。** Secrets Manager のキー名ではありません。

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
> 解決後のパスが秘密の値そのものになるため、Namespace 側に事前登録できません（パスが一致せず弾かれます）。ヘッダーかボディに入れるのが実用的です。

### 6-3. エラーの切り分け

エラーコードで原因が分かります。

| 応答 | `x-passport-proxy-error` | 原因 |
| --- | --- | --- |
| **403** | `unauthorized` | 参照が許可されていない。管理者が Namespace でリソースと secret を紐付けているか、`--namespace-id` を指定したか確認 |
| **502** | `decrypt-failed` | Access Proxy に登録された公開鍵が **reference 鍵ではない**。管理者側の設定ミス |
| **200** | — | 成功 |

管理者は Proxy の監査ログで確認できます。

```bash
kubectl -n <ns> logs -l app.kubernetes.io/instance=passport --tail=100
```

成功時は解決した参照が記録されます。

```text
[INFO] passport: MITM
  path=/anything/test user=user_01M391...
  secretReferences=[aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee]
  vaultTypes={aaaaaaaa-...: aws-secrets-manager}
```

失敗時は理由が入ります。

```text
[WARN] passport: MITM resolve error
  reason=unauthorized refs=[...]
```

> **replica が複数ある場合、リクエストを処理した1台にしかログが出ません。** 全 Pod を確認してください。

### `passport request` の主なオプション

| オプション | 用途 |
| --- | --- |
| `-X, --method <method>` | HTTP メソッド（デフォルト `GET`） |
| `-H, --header <header...>` | 追加ヘッダー。複数指定可 |
| `-d, --data <body>` | リクエストボディ |
| `--show-headers` | レスポンスのステータスとヘッダーも表示 |
| `--insecure-proxy-hostname` | 外側 TLS のホスト名検証をスキップ（証明書チェーンの検証は継続） |

## 日常的な運用

### デーモンの管理

```bash
passport daemon status      # 状態確認
passport daemon start       # 起動
passport daemon stop        # 停止
passport daemon restart     # 再起動
passport daemon logs -f     # ログを追う
```

**Mac を再起動しても自動で立ち上がるようにする**には、LaunchAgent を入れます。

```bash
passport daemon install
```

> これを入れると `export HTTPS_PROXY=...` を毎回打つ必要がなくなります。CLI のヘルプにも "Devs never type `export` again." とあります。**開発者には実質必須**です。

### ログの確認

```bash
passport logs                          # 全ログを時系列でマージ
passport logs --source connections     # 通信記録のみ
passport logs --source events          # デーモンのライフサイクルイベントのみ
passport logs -f --level warn          # warn 以上をストリーム
passport logs --json                   # JSON 形式で出力
```

ログが増えすぎた場合はローテートします。

```bash
passport logs:clear
```

### OS の信頼ストア

OS の信頼ストアを使うツール（ブラウザ、一部の言語ランタイムなど）から Passport 経由の通信を行う場合、CA を信頼させる必要があります。

```bash
passport ca install      # システムキーチェーンに登録（管理者権限が必要）
passport ca status       # 登録状態の確認
passport ca uninstall    # 削除
```

### TUI ダッシュボード

引数なしで実行すると TUI ダッシュボードが起動します。

```bash
passport
```

表示をカスタマイズするオプション:

| オプション | 用途 |
| --- | --- |
| `--theme <name>` | `passport` / `matrix` / `nord` / `mocha` |
| `--no-animation` | モーションエフェクトを無効化 |
| `--ascii` | ASCII のみで描画（unicode/braille を使わない） |
| `--color <value>` | `auto` / `on` / `off` |
| `--silent` | 出力を抑制 |

## Step 7. アクセスをリクエストする

Passport Cloud にサインインし、必要なエンドポイントへのアクセスをリクエストします。管理者の承認後、secret reference が使えるようになります。

## アンインストール

```bash
passport daemon uninstall    # デーモンの自動起動と管理環境を削除
passport ca uninstall        # CA を信頼ストアから削除
passport logout              # 保存された Postman API キーを削除
```

その後、提供されているアンインストールスクリプトで CLI 本体を削除します。

---

# IT / MDM による一括展開（管理者向け）

中央管理された Mac に配る場合の流れです。

1. Passport Proxy のエンドポイントを含む Mac プロファイルを配布する
2. （必要に応じて）アンインストールスクリプトで既存のインストールを削除する
3. Passport CLI の `.pkg` をインストールする（Apple シリコン / Intel を出し分ける）
4. post-install スクリプトを実行して Passport デーモンを起動する

---

# 完了の確認

次の4つすべてが満たされていればセットアップ完了です。

- [ ] Proxy が稼働し、API トラフィックを記録している
- [ ] 対象の開発者の PC に CLI がインストールされている
- [ ] Passport Cloud で Namespaces が設定されている
- [ ] secret reference を発行でき、secret を解決できる

---

# internal LB にした場合の到達経路

`scheme: internal` を選ぶとセキュリティ上は望ましい一方、**手元の PC から Proxy に直接接続できません**。開発者の CLI をどう繋ぐかを設計する必要があります。

## 紛らわしい挙動: DNS は引けるが到達できない

internal NLB の DNS 名は**社外からでも名前解決に成功します**。ただし返ってくるのは VPC 内のプライベート IP です。

```bash
$ nslookup k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com
Address: 10.0.11.3      # ← VPC 内のプライベート IP
Address: 10.0.25.94
```

「名前は引けるのに繋がらない」のはこのためです。DNS の失敗ではないので、タイムアウトまで待たされます。

### 接続方法の選択肢

| 方法 | 用途 | 備考 |
| --- | --- | --- |
| **kubectl port-forward** | 動作確認、1人での検証 | もっとも手軽。ただし常時接続が必要で、チーム展開には向かない |
| **VPN**（Client VPN / Site-to-Site） | チームでの常用 | 本番運用の標準的な解。開発者は VPN 接続さえすれば透過的に使える |
| **踏み台 / Session Manager** | 運用担当者の調査用 | SSH ポートフォワードを挟む |
| **internet-facing に変更** | 非推奨 | mTLS はかかるがエンドポイントが公開される。チャートも警告を出す |

### port-forward での確認手順

```bash
# 管理プレーン（ヘルスチェック、CA 証明書の取得）
kubectl -n passport port-forward deploy/passport-passport 8081:8081

# data plane（CLI からの接続を試す場合）
kubectl -n passport port-forward svc/passport-passport 8443:8443
```

data plane を port-forward して CLI から使う場合、接続先は `https://localhost:8443` になります。**この用途では追加設定は要りません** — ランタイムが生成する証明書の SAN に `localhost` と `127.0.0.1` が自動で含まれるためです。

実際に発行された CA 証明書の SAN:

```text
IP Address:127.0.0.1
DNS:k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com   ← dataplaneCertSANs の値
DNS:localhost                                                      ← 自動付与
DNS:passport-proxy                                                 ← 自動付与
```

`dataplaneCertSANs` に指定した値に加えて、`localhost` / `127.0.0.1` / `passport-proxy` がランタイム側で付与されます。したがって port-forward 経由（`localhost:8443`）でもホスト名検証は通ります。

> **確認方法**
>
> ```bash
> curl -s localhost:8081/ca.pem > passport-ca.pem
> openssl x509 -in passport-ca.pem -noout -text | grep -A3 'Subject Alternative Name'
> ```
>
> 独自ドメインを使う場合は、その名前が SAN に入っているかをこの方法で確認してください。入っていなければ `dataplaneCertSANs` に追加して `helm upgrade` します。

SAN にないホスト名で接続する必要がある場合は、以下で回避できます。

- `passport setup --proxy-server-name <SAN に含まれるホスト名>` で SNI を明示する
- `passport request --insecure-proxy-hostname` で外側のホスト名検証をスキップする（証明書チェーンの検証は継続される）

---

# つまずきやすいポイント

実際に遭遇したもの（★）と、設定から予想されるものを併記します。

## インストール時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| ★ `imagePullSecrets: element 0: associative list with keys may not have non-map elements` | `image.pullSecrets` を文字列のリストで書いた | `- name: passport-registry` 形式に直す。**`--dry-run` では検出できない** |
| ★ `cannot re-use a name that is still in use` | 前回の install が失敗してリリースが残っている | `helm upgrade` で適用するか `helm uninstall` してやり直す。状態は `helm status` で確認 |
| ★ `helm list -a` が `unknown shorthand flag` | helm 4.x でフラグが変更された | `helm list` または `helm status <release> -n <ns>` を使う |
| チャートのレンダリングが失敗する | `bundle.allowedTeamIds` が `CHANGE-ME` のまま | 自分の Team ID（数値）を設定する |
| `service.type=LoadBalancer ... may provision a PUBLIC LB` の警告 | internal 用の annotation がない | `aws-load-balancer-scheme: internal` を付ける |

### 起動時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| Pod が起動しない | CA 鍵 / reference 鍵の Secret がない | 鍵を生成して Secret を作る（[Step 4-2](#step-4-2-ca-鍵と-reference-鍵の-secret-を作る)）。実鍵は無条件で必須 |
| Pod が起動しない | `bundle.allowedTeamIds` が空 | `jwksUrl` が設定済みで `allowedTeamIds` が空だと起動を拒否する仕様 |
| ★ `revocation disabled` の WARN | `revocation.enabled: false` | 機能を使わないなら**正常**。無視してよい |
| ★ `console auth disabled` の WARN | `console.enabled: false` | 同上。Console を使う場合のみ `user` と `passwordHash` を設定 |

### 接続時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `ERR_TLS_CERT_ALT_NAME_INVALID` | `dataplaneCertSANs` が接続先ホスト名と不一致 | LB の DNS 名を正しく設定して `helm upgrade`。port-forward 経由なら上記セクション参照 |
| ★ DNS は引けるが接続がタイムアウトする | internal LB に VPC 外から接続しようとしている | port-forward / VPN / 踏み台を使う |
| イメージ・チャートが取得できない | `PASSPORT_REGISTRY_KEY` が未発行または誤り | Registry 設定で認証情報を再確認する |
| 開発者の `passport setup` が完了しない | Passport Cloud のチーム招待が未送付 | 招待を確認。URL は通常自動解決されるので URL 未共有は原因になりにくい |
| ★ Access Proxy 登録で `Enter a PEM-encoded public key or leave this field empty.` | 公開鍵の欄に証明書（`BEGIN CERTIFICATE`）を貼った | reference 鍵の公開鍵を抽出して貼る（下記参照） |
| ★ **502 `decrypt-failed`** / `failed to decrypt vault reference` | Access Proxy に **CA 鍵**の公開鍵を登録した（正しくは reference 鍵） | Access Proxy を作り直し、**secret reference も作り直す**。公開鍵は変更不可 |
| ★ **403 `unauthorized`** / `not authorized for vault refs` | `--namespace-id` 未指定、または Namespace で secret が未紐付け | `passport setup --namespace-id <UUID>`。`whoami` の `allowedApiRefs` で確認 |
| ★ `{{vault:...}}` が解決されない | Secrets Manager のキー名を書いている | **Passport 発行の UUID** を書く。証明書の `secretReference` で確認 |
| ★ `error: missing required argument '"'"'url'"'"'` | `passport request` で URL をオプションの後ろに書いた | URL を第1引数に置く |
| Namespaces でリソースが一致しない | Manual 登録時のパスが不一致 | **パスまで完全一致**が必要。OTEL ログからの取り込みを推奨 |

---

<!--
【このドキュメントのステータス】

■ 全体: エンドツーエンドで検証完了（2026-10-13）
   環境: EKS eks-api-dev / ap-northeast-1 / account 123456789012
         chart passport-0.6.0 / image passport-proxy:v0.6.0 / helm 4.2.0
         CLI 0.6.0-canary-260921-212749 / macOS arm64
   release passport revision 5 = deployed / Pod 2/2 Running
   NLB (internal): k8s-passport-passport-21627f43cc-...elb.ap-northeast-1.amazonaws.com:8443

   ★vault 解決まで成功した:
     passport request https://httpbin.org/anything/test \
       -H 'Authorization: Bearer {{vault:9d21398d-8562-40df-9958-9ad0e24a562d}}'
     → 200 OK
       "Authorization": "Bearer passport-demo-token-not-a-real-credential"
       "origin": "16.76.114.120"  ← 自前 EKS の NAT GW と一致
     監査ログ:
       secretReferences=[9d21398d-...]
       vaultTypes={9d21398d-...: aws-secrets-manager}
     = IRSA → Secrets Manager → 解決 → 転送 の全経路が機能している

■ 検証した構成
   Namespace UUID  : e188fe3a-ed6b-400c-be5c-42de42154d57
   secretReference : 9d21398d-8562-40df-9958-9ad0e24a562d
   vault key (AWS) : passport/demo/httpbin-token
   リソース        : GET httpbin.org/anything/*
   IRSA ロール     : arn:aws:iam::123456789012:role/eks-api-dev-passport-proxy
                     （terraform/passport.tf で管理）

■ 実機で判明した落とし穴（本文に反映済み）
   1. image.pullSecrets は "- name: xxx" 形式。文字列リストだと server-side apply で失敗。
      --dry-run では検出できない
   2. install 失敗後はリリースが failed で残り install をやり直せない → upgrade で復旧
   3. dataplaneCertSANs は LB 作成後しか分からない → 2段階インストール
      SAN には localhost / 127.0.0.1 / passport-proxy が自動付与される
      （クラスタ内の Service DNS 名は入らない）
   4. helm 4.x では helm list -a / --all が使えない
   5. allowedTeamIds は WorkOS 形式の org_... （Postman API の数値 ID ではない）
      数値 ID でも Pod は起動するので /issue-cert の 403 まで気づけない
   6. vault.aws.region のデフォルトは us-east-1
   7. IRSA は helm upgrade だけでは効かない。Pod 再作成が必要
      （webhook が Pod 作成時のみ env を注入するため）
      kubectl -n passport rollout restart deploy/passport-passport
   8. ★Access Proxy に登録するのは reference 鍵の公開鍵（CA 鍵ではない）
      CA 鍵を登録すると 502 decrypt-failed。しかも公開鍵は変更不可（UI が Read-only）
      → Access Proxy 作り直し + secret reference 作り直しが必要
      （Access Proxy だけ作り直しても vaultKEK は再暗号化されない）
   9. ★--namespace-id が必須。--endpoint だけでは allowedApiRefs が空
   10. ★{{vault:...}} には Passport 発行の UUID を書く（Secrets Manager のキー名ではない）
   11. MDM プロファイル (macOS managed plist) が --proxy-url / 環境変数より優先される
   12. 証明書の TTL は実測 300 秒。ただし passport request が自動更新する
   13. passport request は URL を第1引数に置く必要がある
   14. replica 複数時はリクエストを処理した 1 台にしかログが出ない
   15. passport version は誤り。正しくは passport --version

■ 公式手順との相違（本書は実機に合わせている）
   - audit.sink / bundle.jwksUrl は「必須」ではなくデフォルト値あり
   - S3 は Console を使わなければ不要
   - 公式に未記載の真の必須項目: allowedTeamIds / CA・reference 鍵 / dataplaneCertSANs
   - login が setup を自動実行するので2ステップ必須ではない
   - 公式に未記載の重要コマンド: daemon install / ca install / request / logs
   - アンインストールは daemon uninstall → ca uninstall → logout が先

■ 未検証
   - passport ca install（OS 信頼ストアへの登録。trusted no のまま）
   - passport daemon install（LaunchAgent での自動起動）
   - Windows 環境（Part 2 の Windows セクション）
   - OTEL ログからの Namespace リソース取り込み（手動登録で代替した）
   - Step 7-5 のチーム招待フロー
   - Proxy Console（console.enabled=false のまま）
-->
