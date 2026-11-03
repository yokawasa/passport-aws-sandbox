# 03. DNS と外部公開

> **対象**: 管理者（プラットフォーム / インフラ担当）
> **所要時間**: 30〜40分
> **前のステップ**: [02. Passport Proxy のデプロイ](02-passport-proxy.md)
> **次のステップ**: [04. 開発者向けセットアップ](04-developer-setup.md)

Route53 に CNAME を切ってホスト名を確定させ、`helm upgrade` で証明書の SAN を更新し、
**ポートフォワードなしで**疎通確認します。最後に Passport Cloud の Namespaces を
設定します。

## このステップで作るもの

| 作るもの | 方法 | 用途 |
| --- | --- | --- |
| `passport-proxy` CNAME → NLB | AWS CLI（手動） | CLI が mTLS で接続する data plane |
| `passport-mgmt` CNAME → ALB | AWS CLI（手動） | `/ca.pem` と `/issue-cert` |
| 証明書の SAN 更新 | `helm upgrade` | TLS ハンドシェイクを通すため |
| Access Proxy / Namespace | Passport Cloud（UI） | secret reference の発行 |

---

## Step 1. Route53 に CNAME を切る

### 1-1. 変数を用意する

```bash
export AWS_PROFILE=my-aws-profile   # 環境に合わせる
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ               # example.com
export DOMAIN=example.com

# 02 の Step 5-5 で取得した LB の DNS 名
NLB_DNS=$(kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_DNS=$(kubectl -n passport get ingress passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "NLB: $NLB_DNS"
echo "ALB: $ALB_DNS"
```

両方とも空でないことを確認してください。空の場合は LB のプロビジョニング待ちです。

### 1-2. レコードを作成する

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Comment\": \"Passport (JP team) data plane and management plane\",
    \"Changes\": [
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"passport-proxy.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$NLB_DNS\"}]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"passport-mgmt.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$ALB_DNS\"}]
        }
      }
    ]
  }"
```

> **なぜ CNAME で安定させるのか**
>
> LB を作り直すと DNS 名が変わり、`dataplaneCertSANs` が合わなくなって CLI が
> `ERR_TLS_CERT_ALT_NAME_INVALID` で落ちます。**CNAME を挟んでおけば、LB を
> 作り直しても CNAME の向き先を変えるだけで済み、SAN と開発者への案内を変えずに
> 運用できます。**

### 1-3. 伝播を確認する

```bash
dig +short passport-proxy.$DOMAIN
dig +short passport-mgmt.$DOMAIN
```

CNAME の先のグローバル IP が返れば OK です。TTL 300 なので通常すぐ反映されます。

> **`internal` 構成との違い**
>
> `internal` NLB の場合、DNS は引けても返るのは VPC 内のプライベート IP（`10.x.x.x`）
> なので社外から到達できません。`internet-facing` ならグローバル IP が返ります。
> **`10.` で始まる IP が返ってきたら** `scheme` の設定を確認してください。

---

## Step 2. ホスト名を確定して helm upgrade

`values.yaml` の2箇所に、確定した FQDN を設定します。

```yaml
proxy:
  dataplaneCertSANs: "passport-proxy.example.com"
  managementHost: "passport-mgmt.example.com"
```

| 項目 | 設定する値 | 役割 |
| --- | --- | --- |
| `dataplaneCertSANs` | **data plane の FQDN** | Proxy が生成する TLS 証明書の SAN に入る。CLI の接続先と一致が必須 |
| `managementHost` | **管理プレーンの FQDN** | 発行されるクライアント証明書の CRL 配布点に入る |

```bash
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

### Pod を再起動する

```bash
kubectl -n passport rollout restart deploy/passport-passport
kubectl -n passport rollout status deploy/passport-passport
```

> **⚠️ IRSA は `helm upgrade` だけでは効きません。**
> EKS の webhook が **Pod 作成時にのみ**認証情報の環境変数を注入するためです。
> `serviceAccount.annotations` を変更・追加した場合は必ず Pod を再作成してください。
> これを忘れると Secrets Manager の解決が失敗します。

---

## Step 3. 疎通を確認する（ポートフォワードなし）

ここが以前の構成との最大の違いです。**`kubectl port-forward` は不要**になりました。

### 3-1. 管理プレーンに外部から到達できるか

```bash
export MGMT=https://passport-mgmt.example.com

# CA 証明書を取得できるか（公開しているパス）
curl -fsS "$MGMT/ca.pem" | head -1
```

```text
-----BEGIN CERTIFICATE-----
```

これが返れば、ALB → TLS 終端 → mgmt Service の経路が通っています。

### 3-2. 公開していないパスが遮断されているか

**この確認は必ず実施してください。** allowlist が効いていることの検証です。

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/metrics"
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/readyz"
curl -s -o /dev/null -w '%{http_code}\n' "$MGMT/console"
```

**いずれも `404`（ALB がルーティングしない）になるのが正しい状態**です。
`200` が返るパスがあれば `ingress.paths` を広げすぎています。

> `/readyz` は ALB のヘルスチェックには使われますが、`paths` に入れていないので
> 外部からは到達できません。これは意図した状態です。

### 3-3. 内部からヘルスチェックを確認する

`/readyz` は外部非公開なので、クラスタ内から確認します。

```bash
kubectl -n passport exec deploy/passport-passport -- \
  wget -qO- http://localhost:8081/readyz 2>/dev/null \
  || kubectl -n passport logs -l app.kubernetes.io/instance=passport --tail=5
```

> イメージは distroless で shell も curl も入っていないため、`exec` が使えない場合が
> あります。その場合は Pod の `READY` 状態（`kubectl get pods`）で判断してください。
> readiness probe が `/readyz` を叩いているので、`1/1 Running` なら合格しています。

### 3-4. data plane の TLS と SAN を確認する

**ここが `ERR_TLS_CERT_ALT_NAME_INVALID` を事前に防ぐ最重要チェックです。**

```bash
export PROXY_FQDN=passport-proxy.example.com

openssl s_client -connect "$PROXY_FQDN:8443" -servername "$PROXY_FQDN" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName
```

```text
subject=CN=passport-proxy, O=Passport, OU=passport
notBefore=...
notAfter=...
X509v3 Subject Alternative Name:
    IP Address:127.0.0.1, DNS:passport-proxy.example.com,
    DNS:localhost, DNS:passport-proxy
```

**`DNS:passport-proxy.example.com` が含まれていることを確認してください。**
含まれていなければ Step 2 の `dataplaneCertSANs` が反映されていません。

> **SAN は自動で補完されます**
> `dataplaneCertSANs` に指定した値に加えて、`localhost` / `127.0.0.1` /
> `passport-proxy` がランタイム側で付与されます（クラスタ内の Service DNS 名は
> 入りません）。

> **mTLS が効いていることの確認**
> クライアント証明書なしで接続すると、ハンドシェイク自体は進んでも CONNECT が
> 拒否されます。これが「公開してよい」根拠の中核なので、証明書なしで
> `curl -x https://$PROXY_FQDN:8443 https://httpbin.org/get` が通らないことを
> 確認しておくとよいでしょう。

---

## Step 4. Access Proxy 登録用の公開鍵を用意する

次の Step 5-2 で使う値を準備します。**ここが全体でもっとも間違えやすい箇所です。**

### 4-1. 登録するのは reference 鍵の公開鍵

02 の Step 4-2 で2つの鍵を作りました。用途がまったく違います。

| 鍵 | 用途 | Access Proxy に登録するか |
| --- | --- | --- |
| `ca-private-key` | クライアント証明書の署名（MITM CA） | ❌ **登録しない** |
| **`reference-private-key`** | **`vaultKEK` の復号** | ✅ **この公開鍵を登録する** |

`values.yaml` のコメントが根拠です。

> **reference (KEK)** → RSA private half that decrypts the vault references ACS
> envelope-encrypts with the **tenant public key**

Passport Cloud (ACS) がテナント公開鍵で `vaultKEK` を envelope 暗号化し、Proxy が
reference 秘密鍵で復号します。したがって登録するのは **reference 鍵の公開鍵**です。

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
> Access Proxy の公開鍵は登録後に変更できません（UI が Read-only）。作り直しが必要で、
> しかも **Access Proxy を作り直しただけでは既存の secret reference の `vaultKEK` は
> 再暗号化されません**。secret reference も作り直す必要があり、UI で個別削除できない
> 場合は Namespace ごと作り直すことになります。
>
> **最初に正しい鍵を登録してください。**

### 4-2. 鍵の取り違えを検出する

modulus の指紋を比べれば、どの鍵を抽出したか判別できます。

```bash
openssl rsa -in .keys/ca-private-key        -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -in .keys/reference-private-key -pubout | openssl rsa -pubin -noout -modulus | md5
openssl rsa -pubin -in passport-reference-pubkey.pem -noout -modulus | md5
```

3つ目が **2つ目（reference 鍵）と一致**していれば正しいです。1つ目と一致していたら
CA 鍵を抽出してしまっています。

### 4-3. CA 証明書も取得する

こちらは CLI 側が信頼するために使います。Access Proxy には登録しません。

```bash
curl -fsS "$MGMT/ca.pem" > passport-ca.pem
openssl x509 -in passport-ca.pem -noout -subject -dates
```

| ファイル | ヘッダー | 用途 |
| --- | --- | --- |
| `passport-ca.pem` | `-----BEGIN CERTIFICATE-----` | CLI が信頼する CA 証明書 |
| **`passport-reference-pubkey.pem`** | `-----BEGIN PUBLIC KEY-----` | **Access Proxy 登録に貼る値** |

> Access Proxy の公開鍵欄に証明書（`BEGIN CERTIFICATE`）を貼るとバリデーションで
> 弾かれます。
>
> ```text
> Enter a PEM-encoded public key or leave this field empty.
> ```
>
> ただし「`BEGIN PUBLIC KEY` なら何でも通る」ので、**CA 鍵から抽出した公開鍵は
> 受理されてしまいます**。その結果が 4-1 の 502 です。形式が正しいだけでは不十分で、
> 中身が reference 鍵であることが必要です。

---

## Step 5. Namespaces を設定する（Passport Cloud 側）

### 5-1. Passport に登録する

[app.usepassport.ai](https://app.usepassport.ai) で登録します。メールアドレスを入力し、
確認コードを確認してパスワードを設定します。

### 5-2. Access Proxy を登録する

**Team Settings**（右上のアカウントメニュー）→ **Access Proxies** →
**Create Access Proxy** を選択し、以下を入力します。

| 項目 | 入力する値 |
| --- | --- |
| **Proxy URL** | `https://passport-proxy.example.com:8443` |
| **Management Host** | `https://passport-mgmt.example.com` |
| **公開鍵** | `passport-reference-pubkey.pem` の中身（**reference 鍵**） |
| **Vault プロバイダー** | `aws-secrets-manager` |

> **独自ドメインを使う利点がここで効きます。** LB の DNS 名を直接登録していると、
> LB を作り直すたびに Access Proxy の登録内容を直す必要があります（しかも公開鍵は
> 変更不可なので作り直しになりがちです）。CNAME なら向き先を変えるだけで済みます。

### 5-3. API リソースを設定する

Home ページで namespace を作成し、**Add Resources** を選択します。追加方法は3通り
あります。

| 方法 | 内容 |
| --- | --- |
| **OTEL logs** | Proxy からエクスポートしたログを取り込み、観測されたエンドポイントをリソース化する（推奨） |
| **cURL** | 提供されるサンプルを起点に調整する |
| **Manual** | エンドポイントを直接追加する。**パスまで完全一致が必要** |

#### secret reference を紐付ける

リソースに対して secret reference を作成し、vault 側のキー名を指定します。
01 で `passport_create_demo_secret = true` にした場合、キー名は
`passport/demo/httpbin-token` です。

発行された **UUID** が secret reference の実体です。

> **⚠️ `{{vault:...}}` に書くのは Passport が発行した UUID です。**
> Secrets Manager のキー名（`passport/demo/httpbin-token`）ではありません。
> 取り違えると参照が解決されません。

### 5-4. 設定が反映されたか確認する

Namespace UUID は Passport Cloud の URL から取得します。

```text
https://app.usepassport.ai/namespaces/00000000-1111-2222-3333-444444444444
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

実際に反映されたかは、開発者側で `passport whoami` を実行して
`allowedApiRefs` にリソースが出るかで確認します（04 で実施）。

### 5-5. チームメンバーを招待する

Namespaces のセットアップが完了したら、チームを招待します。サインイン後、メンバーは
必要なエンドポイントへのアクセスをリクエストできます。

---

## Step 6. 開発者に案内する

開発者に以下を伝えます。**ポートフォワードの手順は不要になりました。**

| 項目 | 値 |
| --- | --- |
| Management URL | `https://passport-mgmt.example.com` |
| Proxy URL | `https://passport-proxy.example.com:8443` |
| Namespace ID | `<Namespace UUID>` |
| 手順書 | [04-developer-setup.md](04-developer-setup.md) |

開発者に渡す `passport setup` の例:

```bash
passport setup \
  --management-url https://passport-mgmt.example.com \
  --proxy-url https://passport-proxy.example.com:8443 \
  --proxy-server-name passport-proxy.example.com \
  --namespace-id <Namespace UUID> \
  --endpoint httpbin.org
```

> **⚠️ MDM プロファイルがコマンドライン引数より優先されます。**
> 社内 Mac が MDM 管理下にある場合、配布している MDM プロファイルの
> `ManagementURL` / `ProxyURL` も新しいホスト名に更新しないと、引数で指定しても
> 古い接続先が使われ続けます。詳細は
> [04-developer-setup.md](04-developer-setup.md#エンドポイント解決の優先順位)を
> 参照してください。

---

## 完了の確認

- [ ] `dig` で両ホスト名がグローバル IP に解決される
- [ ] `curl $MGMT/ca.pem` が証明書を返す
- [ ] `curl $MGMT/metrics` が **404** を返す（allowlist が効いている）
- [ ] data plane の証明書 SAN に data plane の FQDN が含まれる
- [ ] Access Proxy に **reference 鍵**の公開鍵を登録した
- [ ] Namespace とリソース、secret reference を作成した

→ [04. 開発者向けセットアップ](04-developer-setup.md) へ進む

---

## 既存の internal NLB から移行する場合

以前の構成（`scheme: internal` + port-forward）から移行する場合の手順です。

> **⚠️ LB の scheme は immutable です。`helm upgrade` では切り替わりません。**
> Service の delete + 再作成が必要で、**NLB の DNS 名が変わります**。

```bash
# 1. values.yaml を internet-facing に変更しておく（02 の Step 4-4）

# 2. Service を削除する（NLB も削除される）
kubectl -n passport delete svc passport-passport

# 3. upgrade で作り直す
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport

# 4. 新しい DNS 名を取得して Route53 の CNAME を貼り替える（Step 1）
kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

# 5. SAN を確認する（Step 3-4）
```

**CNAME を使っていれば、開発者への案内と Access Proxy の登録内容は変更不要です。**
向き先を貼り替えるだけで済みます。これが独自ドメインを挟む最大の利点です。

NLB の再作成には数分かかります。その間 data plane は停止するため、開発者に事前に
周知してください。
