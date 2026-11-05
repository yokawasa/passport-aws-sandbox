# トラブルシューティング

実際に遭遇したもの（★）と、設定から予想されるものを併記しています。

- [片付け・destroy 時](#片付けdestroy-時)
- [インストール時](#インストール時)
- [起動時](#起動時)
- [接続時](#接続時)
- [外部公開まわり](#外部公開まわり)
- [internal LB にした場合の到達経路](#internal-lb-にした場合の到達経路)

---

## 片付け・destroy 時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| ★ **`DependencyViolation: The subnet 'subnet-xxxx' has dependencies and cannot be deleted`** | LB (ALB/NLB) が残り、ENI が subnet を掴んでいる | [LB と ENI の復旧手順](#destroy-が-dependencyviolation-で失敗する) |
| ★ **`DependencyViolation: The vpc 'vpc-xxxx' has dependencies and cannot be deleted`** | LB 付随のセキュリティグループ (`k8s-...`) が残っている | [SG の復旧手順](#vpc-の-dependencyviolation-残存セキュリティグループ) |
| ★ `No valid credential sources found` / `InvalidGrantException` | AWS SSO のトークン期限切れ | `aws sso login --profile <profile>` で再ログイン。**`aws sts get-caller-identity` が通っても Terraform は失敗しうる**（下記参照） |
| ★ `error asking for approval: EOF` | 非対話環境で `terraform destroy` を実行した | `terraform -chdir=terraform destroy -auto-approve`（**先に `plan -destroy` で対象を確認すること**） |

> **⚠️ 今回の実例では、片付けは2段階で失敗しました。**
> まず **subnet** が LB の ENI で止まり、それを解決すると次に **VPC** が SG で止まりました。
> どちらも原因は同じ「AWS Load Balancer Controller が作ったリソースは Terraform 管理外」
> です。LB 本体を消しても**付随する SG は残る**ので、続けて確認してください。

### destroy が DependencyViolation で失敗する

**原因**: ALB / NLB は **Terraform の管理対象外**です。AWS Load Balancer Controller が
`Ingress` や `type: LoadBalancer` の Service を見て作成するため、`terraform destroy` は
削除しようとしません。残ったまま destroy すると、LB の ENI が private subnet を掴んだ
ままになり subnet を削除できません。

```text
Error: deleting EC2 Subnet (subnet-0a331fca695911125): operation error EC2: DeleteSubnet,
  api error DependencyViolation: The subnet 'subnet-0a331fca695911125' has dependencies
  and cannot be deleted.
```

**とくに `helm uninstall passport` の消し忘れが典型例です。** データプレーンの NLB と
管理プレーンの ALB はどちらも Helm 管理下にあります。

#### 残骸を特定する

```bash
# どの ENI が掴んでいるか
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=subnet-id,Values=subnet-xxxx \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Status:Status,Type:InterfaceType}' \
  --output table
```

`Description` が `ELB net/k8s-passport-passport-.../...`、`InterfaceType` が
`network_load_balancer` なら、Passport の NLB が原因です。

#### 復旧手順

> **EKS クラスタが既に destroy されている場合、Service を削除して自動で消させる道は
> 塞がっています**（コントローラも一緒に消えているため）。AWS 側から直接削除します。

```bash
VPC_ID=<失敗したときの VPC ID>

# 1. 残っている LB を特定
aws elbv2 describe-load-balancers --region ap-northeast-1 \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].{Name:LoadBalancerName,ARN:LoadBalancerArn}" \
  --output table

# 2. 削除して、完全に消えるまで待つ
ARN=<上で得た ARN>
aws elbv2 delete-load-balancer --region ap-northeast-1 --load-balancer-arn "$ARN"
aws elbv2 wait load-balancers-deleted --region ap-northeast-1 --load-balancer-arns "$ARN"

# 3. ENI が解放されたことを確認（0 になるまで待つ）
aws ec2 describe-network-interfaces --region ap-northeast-1 \
  --filters Name=vpc-id,Values=$VPC_ID --query 'length(NetworkInterfaces)' --output text

# 4. destroy を再実行
make tf-destroy
```

> **⚠️ ステップ3 で ENI が消えるまで待ってください。**
> `delete-load-balancer` の API が返っても、ENI の解放には**さらに数十秒〜数分**の
> ラグがあります。焦って destroy を再実行すると同じエラーになります。
> （実測では `wait` 完了後さらに約30秒で解放されました。）

#### 再発防止

destroy 前に `make destroy-check` を実行してください。VPC 内に LB が残っていれば
exit 1 で止まります。

```bash
helm uninstall passport -n passport   # ← 忘れやすい
make destroy-check                    # 「(なし)」になるまで待つ
make tf-destroy
```

### VPC の DependencyViolation: 残存セキュリティグループ

subnet の問題を解決した後、今度は VPC の削除で止まることがあります。

```text
Error: deleting EC2 VPC (vpc-xxxx): operation error EC2: DeleteVpc,
  api error DependencyViolation: The vpc 'vpc-xxxx' has dependencies and cannot be deleted.
```

**原因**: AWS Load Balancer Controller は LB 本体だけでなく、付随するセキュリティ
グループも作成します。**LB を手動削除しても SG は自動では消えません**（通常は
コントローラがクリーンアップしますが、EKS クラスタが先に消えているとそれが走りません）。
VPC は non-default な SG が残っていると削除できません。

#### 残っている SG を特定する

```bash
VPC_ID=<失敗したときの VPC ID>

aws ec2 describe-security-groups --region ap-northeast-1 \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[?GroupName!=`default`].{ID:GroupId,Name:GroupName,Desc:Description}' \
  --output table
```

実例（`k8s-` プレフィックスが目印）:

```text
sg-06827cbb3ea3d87fa  k8s-traffic-eksapidev-329d1fe766   [k8s] Shared Backend SecurityGroup for LoadBalancer
sg-0d9f17e3b9364e10a  k8s-passport-passport-166f3ee611   [k8s] Managed SecurityGroup for LoadBalancer
```

`k8s-passport-passport-*` が Passport Proxy の NLB 用、`k8s-traffic-*` が管理プレーンの
ALB 用です。

#### 削除する

```bash
aws ec2 delete-security-group --region ap-northeast-1 --group-id <SG-ID>
```

> **SG の削除は即時反映**です。ENI のような待ち時間はありません。
>
> **相互参照がある場合は削除順序に注意**してください。他の SG から参照されていると
> `DependencyViolation` になります。事前に確認する場合:
>
> ```bash
> aws ec2 describe-security-groups --region ap-northeast-1 \
>   --filters Name=vpc-id,Values=$VPC_ID \
>   --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='<SG-ID>']]].GroupId" \
>   --output text
> ```

#### VPC 以外の依存も確認する

SG を消しても VPC が削除できない場合、他の依存が残っています。一括で確認します。

```bash
VPC_ID=<VPC ID>; R=ap-northeast-1
aws ec2 describe-network-interfaces --region $R --filters Name=vpc-id,Values=$VPC_ID --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
aws ec2 describe-internet-gateways  --region $R --filters Name=attachment.vpc-id,Values=$VPC_ID --query 'InternetGateways[].InternetGatewayId' --output text
aws ec2 describe-nat-gateways       --region $R --filter Name=vpc-id,Values=$VPC_ID --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text
aws ec2 describe-vpc-endpoints      --region $R --filters Name=vpc-id,Values=$VPC_ID --query 'VpcEndpoints[].VpcEndpointId' --output text
aws ec2 describe-instances          --region $R --filters Name=vpc-id,Values=$VPC_ID Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
```

すべて空なら VPC は削除できます。

#### 片付け完了の確認

```bash
# VPC が消えたか（InvalidVpcID.NotFound が返れば OK）
aws ec2 describe-vpcs --region ap-northeast-1 --vpc-ids $VPC_ID 2>&1 | grep -o 'InvalidVpcID.NotFound'

# 課金が続くリソースが残っていないか
aws eks list-clusters --region ap-northeast-1 --query 'clusters' --output text
aws ec2 describe-nat-gateways --region ap-northeast-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region ap-northeast-1 --query 'Addresses[?AssociationId==null].PublicIp' --output text
```

> **他プロジェクトのリソースと取り違えないでください。** 同一アカウントに別の VPC が
> ある場合、上のコマンドはそれらも拾います。`VpcId` でフィルタして自分の VPC の
> ものか確認してから削除してください。

### AWS SSO のトークン期限切れ

**紛らわしい点: `aws sts get-caller-identity` が成功しても Terraform は失敗します。**

```text
Error: No valid credential sources found
Error: failed to refresh cached credentials, refresh cached SSO token failed,
  unable to refresh SSO token, ... InvalidGrantException
```

AWS CLI は取得済みのロール認証情報をキャッシュしていて、それがまだ有効なら通ります。
一方 Terraform の SDK は **SSO トークンのリフレッシュを試みる**ため、トークン本体が
期限切れだと失敗します。

```bash
# トークンの期限を確認する
for f in ~/.aws/sso/cache/*.json; do
  python3 -c "import json;d=json.load(open('$f'));print(d.get('expiresAt','-'),d.get('startUrl','-'))" 2>/dev/null
done
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

```bash
# 再ログイン（ブラウザが開きます）
aws sso login --profile my-aws-profile
```

---

## インストール時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| ★ `imagePullSecrets: element 0: associative list with keys may not have non-map elements` | `image.pullSecrets` を文字列のリストで書いた | `- name: passport-registry` 形式に直す。**`--dry-run` では検出できない** |
| ★ `cannot reuse a name that is still in use` | **リリースが既に存在する状態で `helm install` を実行した。** 前回が成功 (`deployed`) でも失敗 (`failed`) でも同じ | **2回目以降は `helm upgrade`**（迷うなら `helm upgrade --install`）。状態は `helm list -n passport` で確認。やり直すなら `helm uninstall` |
| ★ `helm list -a` が `unknown shorthand flag` | helm 4.x でフラグが変更された | `helm list` または `helm status <release> -n <ns>` を使う |
| チャートのレンダリングが失敗する | `bundle.allowedTeamIds` が未設定 | 自分の Team ID（`org_...`）を設定する |
| `service.type=LoadBalancer ... may provision a PUBLIC LB` の警告 | `internet-facing` を選んでいる | 本手順書では**意図した構成**なので想定どおり。`internal` にしたい場合は annotation を変更 |

## 起動時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| Pod が起動しない | CA 鍵 / reference 鍵の Secret がない | 鍵を生成して Secret を作る。実鍵は無条件で必須 |
| Pod が起動しない | `bundle.allowedTeamIds` が空 | `jwksUrl` が設定済みで `allowedTeamIds` が空だと起動を拒否する仕様 |
| ★ `revocation disabled` の WARN | `revocation.enabled: false` | 機能を使わないなら**正常**。無視してよい |
| ★ `console auth disabled` の WARN | `console.enabled: false` | 同上。Console を使う場合のみ `user` と `passwordHash` を設定 |
| ★ **`startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set`** → CrashLoopBackOff | `bundle.requireBundleClaims: true` にしたが `audience` / `issuer` が未設定 | 3点セットで設定するか、`requireBundleClaims: false` に戻す（[下記](#requirebundleclaims-で-pod-が起動しない)） |
| ★ `http: TLS handshake error from 10.x.x.x: EOF` がログに流れ続ける | NLB のヘルスチェックがクライアント証明書なしで :8443 を叩いている | **mTLS 必須なので正常**。Pod が `1/1 Running` なら無視してよい。[減らす方法](02-passport-proxy.md#tls-handshake-error-は正常) |
| ★ 起動ログが見つからない（`--tail` がヘルスチェックで埋まる） | 起動ログは先頭の数行だが、`TLS handshake error` が数秒おきに追記され数千行になる | `--tail` を使わず `logs "$POD" \| grep -v "TLS handshake error" \| head` で先頭から読む（[手順](02-passport-proxy.md#5-4-起動ログを確認する)） |
| ★ Secrets Manager の解決が失敗する | IRSA が効いていない | **`helm upgrade` だけでは効かない。** webhook が Pod 作成時のみ env を注入するため `kubectl -n passport rollout restart deploy/passport-passport` が必要 |

### requireBundleClaims で Pod が起動しない

```text
startup failed: config: PASSPORT_PROXY_REQUIRE_BUNDLE_CLAIMS requires both
  PASSPORT_PROXY_BUNDLE_AUDIENCE and PASSPORT_PROXY_BUNDLE_ISSUER to be set
```

**原因**: `bundle.requireBundleClaims` を有効にするには `bundle.audience` と
`bundle.issuer` の**両方**が必要です。片方だけだと fail-closed で起動を拒否します。

**チャートの `values.yaml` にこの依存関係は記載されていません。** 両方とも
"optional" とコメントされているだけで、制約はバイナリ側にのみ存在します。

```bash
# 実際に注入された env を確認する
kubectl -n passport get deploy passport-passport -o json | \
  python3 -c "import json,sys; [print(e['name'],'=',e.get('value')) \
    for e in json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['env'] \
    if 'BUNDLE' in e['name'] or 'CLAIMS' in e['name']]"
```

**対処**: 検証段階では無効に戻すのが簡単です。

```yaml
bundle:
  requireBundleClaims: false
```

```bash
helm upgrade passport oci://ociregistry.usepassport.ai/passport/passport \
  --version 0.6.0 -f values.yaml -n passport
```

無効でも JWKS の署名検証と `allowedTeamIds` によるテナント固定は独立して効きます。

有効化したい場合は `issuer` に bundle JWT の `iss` クレームを設定しますが、**その値は
実際に発行された bundle をデコードしないと確認できません**。推測値を入れると Pod は
起動するのに `/issue-cert` が 403 を返すため、原因の特定が難しくなります。

## 接続時

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `ERR_TLS_CERT_ALT_NAME_INVALID` | `dataplaneCertSANs` が接続先ホスト名と不一致 | FQDN を設定して `helm upgrade` → Pod 再起動。SAN は `openssl s_client` で確認 |
| ★ DNS は引けるが接続がタイムアウトする | internal LB に VPC 外から接続しようとしている | [下記参照](#internal-lb-にした場合の到達経路) |
| イメージ・チャートが取得できない | `PASSPORT_REGISTRY_KEY` が未発行または誤り | Registry 設定で認証情報を再確認する |
| ★ Access Proxy 登録で `Enter a PEM-encoded public key or leave this field empty.` | 公開鍵の欄に証明書（`BEGIN CERTIFICATE`）を貼った | reference 鍵の公開鍵を抽出して貼る |
| ★ **502 `decrypt-failed`** / `failed to decrypt vault reference` | Access Proxy に **CA 鍵**の公開鍵を登録した（正しくは reference 鍵） | Access Proxy を作り直し、**secret reference も作り直す**。公開鍵は変更不可 |
| ★ **403 `unauthorized`** / `not authorized for vault refs` | `--namespace-id` 未指定、または Namespace で secret が未紐付け | `passport setup --namespace-id <UUID>`。`whoami` の `allowedApiRefs` で確認 |
| ★ `{{vault:...}}` が解決されない | Secrets Manager のキー名を書いている | **Passport 発行の UUID** を書く。証明書の `secretReference` で確認 |
| ★ `error: missing required argument 'url'` | `passport request` で URL をオプションの後ろに書いた | URL を第1引数に置く |
| ★ `daemon install` 後も `HTTPS_PROXY` が効かない | 既存のターミナルには反映されない | 新しいターミナルを開く |
| ★ MDM 設定が引数を上書きする | macOS managed plist が最優先 | IT 管理者にプロファイルの更新を依頼する |
| Namespaces でリソースが一致しない | Manual 登録時のパスが不一致 | **パスまで完全一致**が必要。OTEL ログからの取り込みを推奨 |
| ★ ログが出ない | replica 複数時はリクエストを処理した1台にしか出ない | 全 Pod のログを確認する |

## 外部公開まわり

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `scheme` を変えても反映されない | **LB の scheme は immutable** | Service を delete してから `helm upgrade` で再作成。DNS 名が変わる |
| `dig` で `10.x.x.x` が返る | `internal` のまま | annotation を `internet-facing` に変更し、Service を作り直す |
| ACM 証明書が `PENDING_VALIDATION` のまま | 検証用 CNAME が引けない | `dig +short <validation-name> CNAME` で確認。`Name` の末尾のドットまで完全一致させる |
| `/metrics` や `/console` に外部から到達できてしまう | `ingress.paths` を広げすぎた | `/ca.pem` と `/issue-cert` のみに戻す |
| Ingress に ADDRESS が付かない | ALB のプロビジョニング待ち、または subnet タグ不足 | 2〜3分待つ。`kubernetes.io/role/elb` タグを確認 |
| ★ `kubectl get ingress passport` が `NotFound` | **Ingress 名はリリース名と違う。** 実際は `<release>-<chart>-setup`（既定で `passport-passport-setup`） | 名前ではなくラベルで選ぶ: `kubectl -n passport get ingress -l app.kubernetes.io/instance=passport -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'` |

---

## internal LB にした場合の到達経路

本手順書は `internet-facing` を前提にしていますが、セキュリティ要件で `internal` を
選んだ場合の情報です。

### 紛らわしい挙動: DNS は引けるが到達できない

internal NLB の DNS 名は**社外からでも名前解決に成功します**。ただし返ってくるのは
VPC 内のプライベート IP です。

```bash
$ dig +short k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com
10.0.11.3      # ← VPC 内のプライベート IP
10.0.25.94
```

「名前は引けるのに繋がらない」のはこのためです。DNS の失敗ではないので、タイムアウト
まで待たされます。

### 接続方法の選択肢

| 方法 | 用途 | 備考 |
| --- | --- | --- |
| **kubectl port-forward** | 動作確認、1人での検証 | もっとも手軽。ただし常時接続が必要でチーム展開には向かない |
| **VPN**（Client VPN / Site-to-Site） | チームでの常用 | 本番運用の標準的な解。開発者は VPN 接続さえすれば透過的に使える |
| **踏み台 / Session Manager** | 運用担当者の調査用 | SSH ポートフォワードを挟む |
| **internet-facing に変更** | 本手順書の構成 | mTLS で保護される。[02 の Step 4-4](02-passport-proxy.md#step-4-4-data-plane-を外部公開する設定にする) に根拠を記載 |

### port-forward での確認手順

```bash
# 管理プレーン（ヘルスチェック、CA 証明書の取得）
kubectl -n passport port-forward deploy/passport-passport 8081:8081

# data plane（CLI からの接続を試す場合）
kubectl -n passport port-forward svc/passport-passport 8443:8443
```

data plane を port-forward して CLI から使う場合、接続先は `https://localhost:8443` に
なります。**この用途では追加設定は要りません** — ランタイムが生成する証明書の SAN に
`localhost` と `127.0.0.1` が自動で含まれるためです。

```text
IP Address:127.0.0.1
DNS:k8s-passport-passport-xxxx.elb.ap-northeast-1.amazonaws.com   ← dataplaneCertSANs の値
DNS:localhost                                                      ← 自動付与
DNS:passport-proxy                                                 ← 自動付与
```

SAN にないホスト名で接続する必要がある場合は、以下で回避できます。

- `passport setup --proxy-server-name <SAN に含まれるホスト名>` で SNI を明示する
- `passport request --insecure-proxy-hostname` で外側のホスト名検証をスキップする
  （証明書チェーンの検証は継続される）
