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
export MGMT_HOST=passport-mgmt
export PROXY_HOST=passport-proxy

# 02 の Step 5-5 で取得した LB の DNS 名
NLB_DNS=$(kubectl -n passport get svc passport-passport \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_DNS=$(kubectl -n passport get ingress -l app.kubernetes.io/instance=passport \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

echo "NLB: $NLB_DNS"
echo "ALB: $ALB_DNS"
```

両方とも空でないことを確認してください。空の場合は LB のプロビジョニング待ちです。

> Ingress 名はリリース名と異なり **`passport-passport-setup`**（`<release>-<chart>-setup`）
> です。上ではラベルで選んでいるので名前に依存しません。

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
          \"Name\": \"$PROXY_HOST.$DOMAIN\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"$NLB_DNS\"}]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"$MGMT_HOST.$DOMAIN\",
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
dig +short $PROXY_HOST.$DOMAIN
dig +short $MGMT_HOST.$DOMAIN
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

### 3-3. ヘルスチェックを確認する

`/readyz` は外部に公開していないので、**Pod の `READY` 列で判断します**。

```bash
kubectl -n passport get pods -l app.kubernetes.io/instance=passport
```

```text
NAME                                 READY   STATUS    RESTARTS   AGE
passport-passport-5779ff65fb-b6t6f   1/1     Running   0          10m
passport-passport-5779ff65fb-m4rqp   1/1     Running   0          10m
```

**`READY` が `1/1` なら `/readyz` は合格しています。** kubelet が readiness probe で
10秒おきに `/readyz` を叩いており、失敗すると `0/1` に落ちるためです。probe の設定は
こう確認できます。

```bash
kubectl -n passport get deploy passport-passport \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'; echo
```

```text
{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"mgmt","scheme":"HTTP"},
 "initialDelaySeconds":3,"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}
```

`0/1` のままなら、probe の失敗理由が Events に出ます。

```bash
kubectl -n passport describe pod -l app.kubernetes.io/instance=passport | grep -A10 "^Events:"
```

> **⚠️ `kubectl exec` でコンテナ内から叩くことはできません。**
>
> イメージは distroless で、シェルも `curl` も `wget` も入っていません。
>
> ```text
> OCI runtime exec failed: exec failed: unable to start container process:
>   exec: "wget": executable file not found in $PATH
> ```
>
> `/readyz` の中身（どのチェックが落ちているか）を見たい場合は、一時的に別の Pod を
> 立ててクラスタ内から Service を叩きます。
>
> ```bash
> kubectl -n passport run curl-tmp --rm -it --restart=Never \
>   --image=curlimages/curl -- \
>   curl -s http://passport-passport-mgmt:8081/readyz
> ```
>
> ```json
> {"status":"ready","checks":[
>   {"name":"signing_key_loaded","ready":true},
>   {"name":"data_plane_listener_up","ready":true},
>   {"name":"audit_sink_initialized","ready":true},
>   {"name":"startup_complete","ready":true}]}
> ```
>
> `ready":false` のチェック名が、そのまま原因の切り分けに使えます
> （例: `signing_key_loaded` が false なら CA 鍵の Secret を疑う）。
> `--rm` を付けているので Pod は終了時に削除されます。

### 3-4. data plane の TLS と SAN を確認する

**ここが `ERR_TLS_CERT_ALT_NAME_INVALID` を事前に防ぐ最重要チェックです。**

```bash
export PROXY_FQDN=passport-proxy.example.com

openssl s_client -connect "$PROXY_FQDN:8443" -servername "$PROXY_FQDN" </dev/null 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
```

```text
            X509v3 Subject Alternative Name:
                IP Address:127.0.0.1, DNS:passport-proxy.example.com, DNS:localhost, DNS:passport-proxy
```

> **`openssl x509 -ext subjectAltName` のほうが簡潔ですが、macOS 標準の openssl
> （LibreSSL）には `-ext` がありません**（`unknown option -ext` になります）。
> `-text | grep` はどちらでも動くので、こちらを使っています。

**`DNS:passport-proxy.example.com` が含まれていることを確認してください。**

SAN に **LB の DNS 名（`k8s-passport-passport-....elb.amazonaws.com`）しか入っていない**
場合、Step 2 の `dataplaneCertSANs` がまだ反映されていません。`helm upgrade` と
Pod の再起動を実施してください。実際に注入されている値はこう確認できます。

```bash
kubectl -n passport get deploy passport-passport -o jsonpath=\
'{.spec.template.spec.containers[0].env[?(@.name=="PASSPORT_PROXY_DATAPLANE_CERT_SANS")].value}'; echo
```

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

> **補足**: Access Proxy は Passport の Proxy のことで、Passport Cloud UI 上での
> 呼び名です。画面では **Team Settings → Access Proxies** という名前なので、ここでは
> UI の表記に合わせています。

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

> **⚠️ 取り違えると復旧が重いので、最初に正しい鍵を登録してください。**
> 公開鍵は登録後に変更できず、Access Proxy と secret reference の作り直しになります。
> 症状と対処は [トラブルシューティング](troubleshooting.md#接続時)を参照してください。

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

[app.usepassport.ai](https://app.usepassport.ai) で登録します。メールアドレスを入力し、 確認コードを確認してパスワードを設定します。

### 5-2. Access Proxy を登録する

**Top Menu** > **Access Proxies** >
**Create Access Proxy** ボタンをクリックして、以下を入力します。

| 項目 | 入力する値 |
| --- | --- |
| **Proxy URL** | `https://passport-proxy.example.com:8443` |
| **Management Host** | `https://passport-mgmt.example.com` |
| **公開鍵** | `passport-reference-pubkey.pem` の中身（**reference 鍵**） |
| **Vault プロバイダー** | `aws-secrets-manager` |

### 5-3. API リソースを設定する

Homeで namespace を作成し、**Add Resources** を選択します。

追加方法は3通りあります。

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

**伝えるのは実質2つだけです。** ポートフォワードの手順も、接続先 URL も要りません。

| 項目 | 値 |
| --- | --- |
| 手順書 | [04-developer-setup.md](04-developer-setup.md) |
| Namespace ID | `<Namespace UUID>`（権限が乗らなかったときに使う） |

開発者側は基本これだけで完了します。

```bash
passport login          # setup まで自動実行される
passport whoami         # allowedApiRefs にリソースが出れば完了
```

> **URL を伝える必要はありません。** `passport login` 後に passport-service discovery が
> `managementUrl` / `proxyUrl` を自動解決し、`~/.passport/identity.json` に記録します。
> 開発者が URL を入力する場面はありません。

### 自動解決されない場合の参考値

開発者が接続できないときの切り分け用です。`passport setup --verbose` の出力と
見比べてください。

| 項目 | 値 |
| --- | --- |
| Management URL | `https://passport-mgmt.example.com` |
| Proxy URL | `https://passport-proxy.example.com:8443` |

明示する場合のコマンド:

```bash
passport setup \
  --management-url https://passport-mgmt.example.com \
  --proxy-url https://passport-proxy.example.com:8443 \
  --proxy-server-name passport-proxy.example.com \
  --namespace-id <Namespace UUID>
```

> **⚠️ MDM プロファイルがコマンドライン引数より優先されます。**
> 社内 Mac が MDM 管理下にある場合、配布している MDM プロファイルの
> `ManagementURL` / `ProxyURL` も新しいホスト名に更新しないと、**引数で指定しても
> 古い接続先が使われ続けます**。上の表の値と突き合わせて確認してください。詳細は
> [04-developer-setup.md](04-developer-setup.md#エンドポイント解決の優先順位)を
> 参照してください。

---

## 完了の確認

- [ ] `dig` で両ホスト名がグローバル IP に解決される
- [ ] 両 Pod が `READY 1/1`（= `/readyz` 合格）
- [ ] `curl $MGMT/ca.pem` が証明書を返す
- [ ] `curl $MGMT/metrics` が **404** を返す（allowlist が効いている）
- [ ] data plane の証明書 SAN に data plane の FQDN が含まれる
- [ ] Access Proxy に **reference 鍵**の公開鍵を登録した
- [ ] Namespace とリソース、secret reference を作成した

→ [04. 開発者向けセットアップ](04-developer-setup.md) へ進む
