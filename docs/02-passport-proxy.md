# 02. Passport Proxy のデプロイ

> **対象**: 管理者（プラットフォーム / インフラ担当）
> **所要時間**: 30〜45分
> **前のステップ**: [01. インフラ構築](01-infrastructure.md)
> **次のステップ**: [03. DNS と外部公開](03-dns-and-exposure.md)

Passport Proxy のイメージとチャートを取得し、鍵を生成して、Helm でデプロイします。

## Passport とは何か（3分で把握する）

Passport は、API のシークレット（API キー、トークン）を**開発者の手元に配らずに**使える
ようにする仕組みです。

開発者のコードには実際のキーではなく **secret reference**（キーの「参照」）を書きます。
リクエストは Passport Proxy を通り、Proxy が参照を本物のシークレットに解決して API に
転送します。開発者は本物のキーを一度も見ません。

```
開発者のコード                Passport Proxy              実際の API
(secret reference)  ──────▶  参照を解決して       ──────▶  (本物のキーで
                              本物のキーを付与              認証される)
                                    │
                                    ▼
                              API トラフィックを
                              OTEL 形式でログ記録
```

| コンポーネント | 置く場所 | 誰が設定するか | 役割 |
| --- | --- | --- | --- |
| **Passport Proxy** | 自社の Kubernetes | 管理者（02〜03） | トラフィックの中継とログ記録、シークレットの解決 |
| **Passport CLI** | 開発者の PC | 開発者（04） | 開発者側のデーモン。ローカルの通信を Proxy に向ける |
| **Namespaces** | Passport Cloud | 管理者（03） | どのエンドポイントに誰がアクセスできるかの定義 |

---

## 事前に用意するもの

このチャートは **fail-closed 設計**です。必須項目が未設定なら `helm install` の時点で
止まるか、Pod が起動を拒否します。「とりあえず入れてみて後で直す」ができないので、先に
揃えてください。

### 必ず用意するもの

| 必要なもの | 入手方法 | 無いとどうなるか |
| --- | --- | --- |
| **レジストリ認証情報** | Passport の Registry 設定画面で発行 | イメージ・チャートが一切取得できない |
| **Postman Team ID** | [Step 4-1](#step-4-1-postman-team-id-を確認する) | **Pod が起動を拒否する** |
| **CA 鍵 / reference 鍵** | 自分で生成（[Step 4-2](#step-4-2-ca-鍵と-reference-鍵の-secret-を作る)） | **Pod が起動を拒否する**。実鍵が無条件で要求される |
| **IRSA ロール ARN** | 01 の `terraform output` | Secrets Manager の解決が失敗する |
| **ACM 証明書 ARN** | 01 の Step 6 | 管理プレーンの Ingress が TLS 終端できない |

### 条件次第で用意するもの

以下は**デフォルトのまま動く**ので、検証段階では不要です。

| 項目 | デフォルト | 用意が必要になる条件 |
| --- | --- | --- |
| `audit.sink` | **`stdout`（有効）** | 本番。`stdout` は Pod のログに流れるだけで永続化されない |
| `bundle.jwksUrl` | **Postman の公開 JWKS が設定済み** | 通常は変更不要。公開エンドポイントなので認証情報も不要 |
| S3 バケット | — | Proxy Console (`console.enabled`) を使う場合のみ |

> **公式手順との相違**
>
> 公式手順は `audit.sink` と `bundle.jwksUrl` を「必須。未設定だと起動失敗」と書いて
> いますが、実物の `values.yaml` では**デフォルト値が入っています**。
> 逆に公式手順に書かれていない **Team ID と CA 鍵 / reference 鍵が真の必須項目**です。

---

## Step 1. レジストリ認証情報を発行する

Passport の **Registry 設定**から認証情報を発行します。組織の管理者が一度発行すれば、
チーム全員が使えます。

```bash
read -s PASSPORT_REGISTRY_KEY
export PASSPORT_REGISTRY_KEY
```

> **シークレットの取り扱い**
> このキーはレジストリへのアクセス権です。上記のように `read -s` で入力すればシェル
> 履歴に残りません。リポジトリにコミットしないよう注意してください。

## Step 2. namespace と pull secret を作る

01 の `passport_namespace` と**必ず一致**させてください（デフォルト `passport`）。

```bash
kubectl create namespace passport

kubectl create secret docker-registry passport-registry \
  --docker-server=ociregistry.usepassport.ai \
  --docker-username=passport \
  --docker-password="$PASSPORT_REGISTRY_KEY" \
  -n passport
```

イメージを手元で確認したい場合（任意）:

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | docker login ociregistry.usepassport.ai \
  --username passport --password-stdin
docker pull ociregistry.usepassport.ai/passport/passport-proxy:v0.6.0
```

## Step 3. Helm チャートを取得して values を書き出す

```bash
printf '%s' "$PASSPORT_REGISTRY_KEY" | helm registry login ociregistry.usepassport.ai \
  --username passport --password-stdin

helm show values oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 > values.yaml
```

> インストール時と同じチャートから values を書き出しているので、デフォルト値と
> テンプレートが食い違う心配はありません。

## Step 4. values.yaml を設定する

**この Step が全体でもっとも詰まりやすい箇所**です。以下の順に進めてください。

### Step 4-1. Postman Team ID を設定する

`values.yaml` に設定します。

```yaml
bundle:
  allowedTeamIds: "org_01EXAMPLE000000000000000"
```

> **⚠️ WorkOS 形式の `org_...` です。Postman API が返す数値 ID ではありません。**
>
> 数値 ID を入れても **Pod は正常に起動してしまう**ため、開発者が
> `passport setup` を実行して `/issue-cert` が 403 を返すまで間違いに気づけません。
> Team Settings → Team Info で `org_` で始まる値を確認してください。

### Step 4-2. CA 鍵と reference 鍵の Secret を作る

`keys.mode: existingSecret`（デフォルト）では、以下2つの鍵を含む K8s Secret が必要です。

- **CA 署名鍵** — MITM CA とユーザーごとのクライアント証明書を発行する
- **reference 鍵** — Passport Cloud が暗号化した vault reference を復号する RSA 秘密鍵

> 使い捨て（ephemeral）CA モードは**ランタイムから削除されました**。実鍵が必須で、
> 省略できません。

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

ファイル名は `values.yaml` の `keys.caFileName` / `keys.referenceFileName` と一致させ
ます（上記はデフォルト値に合わせています）。

> **鍵の取り扱い**
> 生成した鍵はリポジトリにコミットしないでください。`.keys/` は `.gitignore` に
> 入れてください。**reference 鍵は 03 の Access Proxy 登録で公開鍵を抽出するのに
> 必要なので、Secret 登録後も安全な場所に保管してください**（紛失すると Access Proxy
> の作り直しが必要になります）。

### Step 4-3. イメージと pull secret を設定する

```yaml
image:
  repository: ociregistry.usepassport.ai/passport/passport-proxy
  tag: "v0.6.0"
  pullSecrets:
    - name: passport-registry    # ← "- passport-registry" ではなく "- name:" が必要
```

> **⚠️ もっともハマりやすい落とし穴**
>
> `pullSecrets` は**マップのリスト**で書きます。文字列のリストにすると `helm install`
> が次のエラーで失敗します。
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
> **このエラーは `--dry-run` では検出できません**（server-side apply の時点で判明する
> ため）。dry-run が通っても install が失敗しうる、という例です。

### Step 4-4. data plane を外部公開する設定にする

**本手順書は `internet-facing` を選びます。** ポートフォワードなしでチームに展開する
ためです。

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
  mgmt:
    annotations: {}     # 管理プレーンは ClusterIP のまま。変更しない
```

> **⚠️ LB の scheme は immutable です。**
>
> **最初の `helm install` の時点で決めてください。** 後から `internal` ↔
> `internet-facing` を切り替えようとしても `helm upgrade` では反映されず、Service の
> delete + 再作成が必要になります（DNS 名も変わります）。

#### `internet-facing` はセキュリティ的に妥当か

data plane については**妥当**です。根拠:

| 防御層 | 内容 |
| --- | --- |
| **mTLS 必須** | Passport CA が署名したクライアント証明書がないと TLS ハンドシェイクで切断される。認証なしで中に入れない |
| **証明書の発行経路が限定** | 証明書は Postman の access bundle（ES256/JWKS 検証）を提示した正規ユーザーにしか発行されない |
| **テナント固定** | `bundle.allowedTeamIds` で自組織に限定 |
| **短命な証明書** | TTL は実測 300 秒程度 |
| **秘密が経路に乗らない** | 実際の API クレデンシャルは vault 参照として解決されるため、平文の秘密がクライアント側を通らない |

チャートのデフォルトが `internal` なのは defense-in-depth であって、公開が設計上の
誤りというわけではありません。

> **`internal` を選ぶ場合**
>
> セキュリティ要件で VPC 内に閉じる必要がある場合は `internal` のままにします。
> その場合、開発者の CLI を繋ぐために **VPN / 踏み台 / port-forward のいずれか**が
> 必要です。本手順書の 03 以降は `internet-facing` 前提で書かれているので、
> [トラブルシューティング](troubleshooting.md#internal-lb-にした場合の到達経路)を
> 参照してください。

### Step 4-5. 管理プレーンを Ingress で公開する

管理プレーン (:8081) は **LoadBalancer にしてはいけません**。チャートが用意している
`ingress` ブロック（パス allowlist）を使います。

```yaml
ingress:
  enabled: true
  className: alb
  host: passport-mgmt.example.com
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-1:123456789012:certificate/xxxx
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /readyz
    alb.ingress.kubernetes.io/group.name: passport-mgmt
  paths:                 # ← 公開するのはこの2つだけ
    - /ca.pem
    - /issue-cert
  tls: []                # ALB が TLS 終端するので不要（nginx の場合のみ設定）
```

`certificate-arn` には 01 の Step 6 で発行した ARN を入れます。

> **⚠️ `paths` を広げないでください。**
>
> :8081 には `/ca.pem` `/issue-cert`（公開したい）と、`/metrics` `/revocation` 管理 API・
> Console UI（**公開したくない**）が同居しています。`paths` を `/` にすると全部
> 公開されます。
>
> 現状 `console.enabled: false` / `revocation.adminTokenSecretRef` 未設定で fail-closed
> になっていますが、これは「鍵がかかっている」のではなく「**機能がまだ登録されて
> いないだけ**」です。将来これらを有効化した瞬間に露出します。
>
> mgmt Service は `type` に関わらず ClusterIP のままなので、この2パス以外は外部から
> 到達できません。

> **`/metrics` を Prometheus で取りたい場合**は Ingress に足すのではなく、
> `metrics.serviceMonitor.enabled: true` を使ってクラスタ内から scrape してください。

### Step 4-6. IRSA とその他の項目

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/passport-sandbox-dev-passport-proxy

vault:
  source: aws-secrets-manager
  aws:
    region: ap-northeast-1      # ← デフォルトは us-east-1。要変更

namespace:
  create: false                 # Step 2 で kubectl create namespace 済み
```

| 項目 | 設定例 | 備考 |
| --- | --- | --- |
| `serviceAccount.annotations` | 01 の `passport_proxy_irsa_role_arn` | これが無いと Secrets Manager の解決が失敗する |
| `vault.aws.region` | `ap-northeast-1` | **デフォルトは `us-east-1`** なので要変更 |
| `namespace.create` | `false` | Step 2 で作成済みのため |
| `audit.sink` | `stdout`（検証）/ `s3`（本番） | `stdout` は永続化されない |
| `proxy.dataplaneCertSANs` | **この時点では空のまま** | 03 で設定（理由は後述） |
| `proxy.managementHost` | **この時点では空のまま** | 同上 |

### Step 4-7. 外部公開するなら併せて有効化を検討する（任意）

**ここは未検証の項目を含みます。** 検証段階ではデフォルトのまま進め、必要になった
時点で1つずつ有効化して Pod が起動するか確認することを推奨します。

```yaml
rateLimit:
  enabled: true                 # /issue-cert への総当たり対策
  perToken: { rps: 10, burst: 20 }

audit:
  sink: s3                      # stdout は Pod 再起動で消える
  s3: { bucket: "my-audit-bucket", region: "ap-northeast-1", prefix: passport-audit }
```

> **⚠️ `bundle.requireBundleClaims` は3点セットでないと Pod が起動しません。**
>
> 有効にするなら `audience` と `issuer` の**両方**を併せて設定する必要があります。
> 片方だけ、あるいは両方欠けていると fail-closed で起動を拒否します。
>
> ```text
> startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both
>   PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set
> ```
>
> **チャートの `values.yaml` にこの依存関係は書かれていません。** `issuer` /
> `audience` はどちらも "optional" とだけコメントされており、制約はバイナリ側にのみ
> 存在します。
>
> さらに `issuer` に入れるべき値（bundle JWT の `iss` クレーム）は、**実際に発行された
> bundle をデコードしないと確認できません**。推測値を入れると Pod は起動するものの
> `/issue-cert` が 403 を返すため、気づくのが遅れます（Team ID の取り違えと同じ失敗
> パターン）。
>
> **検証段階では `requireBundleClaims: false`（デフォルト）のままを推奨します。**
> 無効でも JWKS の署名検証と `allowedTeamIds` によるテナント固定は独立して効いており、
> この設定は「クレームの存在を追加で強制する」ものです。
>
> 有効化する場合は、先にデフォルト設定で `passport login` を通し、取得した bundle の
> `iss` を確認してから設定してください。

> **`networkPolicy.enabled: true` は検証段階では見送りを推奨します。**
> `values.yaml` のコメントにある通り、ポート単位の all-or-nothing な NetworkPolicy が
> `/issue-cert` を黙って壊した経緯があります。有効にする場合は
> `ingress.mgmt.from` に setup クライアントと Prometheus を必ず列挙してください。

---

## Step 5. Proxy をデプロイする

### なぜ2段階になるのか

`proxy.dataplaneCertSANs` には **CLI が接続するホスト名**を入れます。ここが実際の
接続先と一致しないと、CLI の TLS ハンドシェイクが `ERR_TLS_CERT_ALT_NAME_INVALID` で
失敗します。

独自ドメインを使う場合、**CNAME の向き先である LB の DNS 名は作ってみないと分からない**
ため、次の順序になります。

```
02: install → NLB / ALB が作られる → DNS 名を取得
                                       │
03:                                    ▼
    Route53 に CNAME を切る → values に FQDN を設定 → helm upgrade
                                                      （CLI が接続可能になる）
```

### 5-1. レンダリングを検証する

実リソースを作らずにチャートが通るか確認します。

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport --dry-run=client
```

`internet-facing` を選んでいるため、**public LB に関する警告が出るのは想定どおり**です
（Step 4-4 の根拠で許容しています）。それ以外のエラーがあれば対処してください。

### 5-2. インストールする

```bash
helm install passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

> **install が失敗した場合**
> リリースが `failed` 状態で残るため `helm install` をやり直せません
> （`cannot re-use a name that is still in use`）。
> `values.yaml` を修正して **`helm upgrade`** で適用するか、
> `helm uninstall passport -n passport` してからやり直してください。
> 状態確認: `helm status passport -n passport`

### 5-3. Pod とリリースの状態を確認する

```bash
kubectl -n passport get pods,svc,ingress
helm status passport -n passport
```

両 Pod が `1/1 Running` / `RESTARTS 0`、リリースが `STATUS: deployed` になっていれば
成功です。

> **⚠️ `helm status` が `deployed` でも Pod が起動しているとは限りません。**
>
> このチャートは fail-closed 設計で、設定の不整合はインストール時ではなく
> **Pod の起動時**に判明します。`CrashLoopBackOff` になっていたら、まずログで
> 理由を見てください。
>
> ```bash
> kubectl -n passport get pods
> kubectl -n passport logs -l app.kubernetes.io/instance=passport --tail=20
>
> # 再起動済みで現在のログが空な場合は、落ちた側のコンテナを見る
> kubectl -n passport logs <pod-name> --previous --tail=20
> ```
>
> `startup failed: config: ...` で始まる1行が出ていれば、それが原因です。
> よくあるものは [トラブルシューティング](troubleshooting.md#起動時)を参照してください。

```text
NAME                         TYPE           EXTERNAL-IP                              PORT(S)
svc/passport-passport        LoadBalancer   k8s-passport-....elb.amazonaws.com        8443:xxxxx/TCP
svc/passport-passport-mgmt   ClusterIP      <none>                                    8081/TCP

NAME                   CLASS   HOSTS                                 ADDRESS
ingress/passport       alb     passport-mgmt.example.com  k8s-passport-....elb.amazonaws.com
```

**`passport-passport-mgmt` が `ClusterIP` のままであること**を必ず確認してください。

### 5-4. 起動ログを確認する

> **⚠️ `--tail` を使わないでください。**
>
> 起動ログは**最初の数行**に出ます。一方 NLB のヘルスチェックが数秒おきに
> `TLS handshake error` を吐き続けるため（[後述](#tls-handshake-error-は正常)）、
> 数分後には数千行まで膨らみます。`--tail=30` ではヘルスチェックのノイズしか
> 見えません。

ノイズを除いて先頭から読みます。

```bash
POD=$(kubectl -n passport get pods -l app.kubernetes.io/instance=passport \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n passport logs "$POD" | grep -v "TLS handshake error" | head -10
```

ログは OTEL 形式の JSON で読みにくいので、要点だけ抜き出すなら:

```bash
kubectl -n passport logs "$POD" | grep -v "TLS handshake error" \
  | python3 -c 'import json,sys
for l in sys.stdin:
    try: d = json.loads(l)
    except ValueError: continue
    print(d["SeverityText"].ljust(5), d["Body"]["Value"])'
```

```text
WARN  passport: revocation disabled (set PASSPORT_PROXY_REVOCATION_STORE, ...)
INFO  passport: rate limiting enabled (in-memory per-pod)
WARN  passport: console auth disabled (PASSPORT_PROXY_CONSOLE_USER and/or ... unset)
INFO  passport: /issue-cert enabled
INFO  passport: managed bootstrap disabled; /issue-cert requires a valid bundle
INFO  starting management server
INFO  starting HTTPS proxy
```

以下の3つが出ていれば正常です。

| ログ | 意味 |
| --- | --- |
| `passport: /issue-cert enabled` | jwksUrl と allowedTeamIds を読み込めた |
| `starting HTTPS proxy` (port 8443) | data plane が待ち受け開始 |
| `starting management server` (port 8081) | 管理プレーンが待ち受け開始 |

次の WARN は**設定次第で正常**です。該当機能を無効にしているなら無視してください。

```text
passport: revocation disabled (set PASSPORT_PROXY_REVOCATION_STORE, ...)
passport: console auth disabled (PASSPORT_PROXY_CONSOLE_USER and/or ... unset)
passport: managed bootstrap disabled; /issue-cert requires a valid bundle
```

#### `TLS handshake error` は正常

```text
2026/11/05 08:03:21 http: TLS handshake error from 10.0.138.89:51114: EOF
```

**NLB のヘルスチェックがクライアント証明書なしで :8443 を叩いている**ため出ます。
data plane は mTLS 必須なので、証明書を持たない接続が切られるのは設計どおりです。
送信元 IP が VPC 内のプライベート IP（`10.x.x.x`）であることで確認できます。

Pod が `1/1 Running` なら無視してください。**ログが埋まるのが邪魔な場合**は、
ヘルスチェックを管理プレーン側に向けると減らせます。

```yaml
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "8081"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: http
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /readyz
```

> この annotation は未検証です。適用するなら Pod の起動と NLB のターゲットが
> `healthy` のままであることを確認してください。

### 5-5. LB の DNS 名を取得する

03 で Route53 の CNAME に使います。

```bash
# data plane (NLB)
kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

# 管理プレーン (ALB)
kubectl -n passport get ingress passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

ALB のプロビジョニングには **2〜3分**かかります。空で返る場合は少し待ってから再実行して
ください。

---

## 完了の確認

- [ ] 両 Pod が `1/1 Running`
- [ ] `helm status` が `deployed`
- [ ] `passport-passport` が LoadBalancer で EXTERNAL-IP を持つ
- [ ] **`passport-passport-mgmt` が ClusterIP のまま**
- [ ] Ingress に ADDRESS が付いている
- [ ] 起動ログに `/issue-cert enabled` がある

記録しておく値:

| 項目 | 取得方法 |
| --- | --- |
| **NLB の DNS 名** | `kubectl -n passport get svc passport-passport -o jsonpath='{...}'` |
| **ALB の DNS 名** | `kubectl -n passport get ingress passport -o jsonpath='{...}'` |

→ [03. DNS と外部公開](03-dns-and-exposure.md) へ進む
