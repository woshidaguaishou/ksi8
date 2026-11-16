# CloudTrail 詳細設計

## 1. 基本設計からの引継ぎ

CloudTrailの詳細設計は、「4.4 監査・ログ 基本設計書」に記載された既存監査ログの継続利用方針に基づく。

| 出典 | 基本設計の記載内容 | 詳細設計への反映 |
|---|---|---|
| 1.3 前提・制約（監査ログの取得設定） | CloudTrailによる監査ログを既存の組織証跡で取得し、ログアカウントのS3へ集約する | 本番・開発・MVP環境に適用済みのOrganization Trailを継続利用し、管理イベントをログアカウントの既存S3バケットへ配信する |
| 4.1 ログ管理の全体方針「データ利活用基盤のログ設計との差分」 | 監査ログ（CloudTrail・Config）は既存基盤の設計に準拠し、本基盤固有の差分は設けない | AIエージェント基盤で作成する個別リソース向けのTrail及びEvent Selectorは追加しない |
| 5.1 レイヤー別の取得ログ一覧「基盤共通」 | CloudTrailは既存で取得済みとし、既存設定を継続利用する | 既存Trail、Event Selector、S3配信先、KMS暗号化及びログファイル整合性検証を継続利用し、新規構築・設定変更は行わない |

## 2. 調査・比較対象

### 2.1 対象環境

| 環境 | AWSアカウント | 用途 |
|---|---|---|
| 本番環境 | `182066453934` | 正式基盤の設計・継続利用判定対象 |
| 開発環境 | `035611741483` | 正式基盤の設計・継続利用判定対象 |
| MVP環境 | `049145893238` | 既存設定の適用状況及びログ配信確認対象。構築・変更対象外 |

対象リージョンは `ap-northeast-1` とする。

### 2.2 共通基盤アカウント及び組織情報

| 項目 | 値 | 備考 |
|---|---|---|
| Organization ID | `o-jjrd939pt4` | 対象3アカウントで同一値を確認 |
| Trail管理アカウント | `841162687537` | Trail ARNに含まれるAccount ID |
| ログアカウント | `079604065232` | CloudTrailログ集約S3及びKMS Keyの管理アカウント |

> Trail管理アカウントとログアカウントは別アカウントである。業務アカウントからログ集約S3への直接参照は許可せず、ログ参照権限を付与されたログアカウントから確認する。

## 3. 環境別設定比較

| 項目 | 本番環境 | 開発環境 | MVP環境 | 差分・判定 |
|---|---|---|---|---|
| Organization ID | `o-jjrd939pt4` | 同左 | 同左 | なし |
| Trail名 | `datautl-prd-log-cloudtrail-001` | 同左 | 同左 | なし |
| Trail ARN | `arn:aws:cloudtrail:ap-northeast-1:841162687537:trail/datautl-prd-log-cloudtrail-001` | 同左 | 同左 | なし |
| Trail種別 | Organization Trail | 同左 | 同左 | なし |
| Home Region | `ap-northeast-1` | 同左 | 同左 | なし |
| 記録状態 | 有効（`IsLogging = true`） | 同左 | 同左 | なし |
| Multi-Region Trail | 有効 | 同左 | 同左 | なし |
| Global Service Events | 有効 | 同左 | 同左 | なし |
| Event Selector | Advanced Event Selector | 同左 | 同左 | なし |
| Event Category | `Management` | 同左 | 同左 | なし |
| Management Events | Read／Writeを含む全管理イベント | 同左 | 同左 | なし |
| Data Events | 取得対象外 | 同左 | 同左 | なし |
| Insights | 無効 | 同左 | 同左 | なし |
| S3配信先 | `datautl-prd-log-apne1-s3-bucket-cloudtrail` | 同左 | 同左 | なし |
| S3 Key Prefix | なし | 同左 | 同左 | なし |
| 暗号化 | SSE-KMS | 同左 | 同左 | なし |
| KMS Key ARN | `arn:aws:kms:ap-northeast-1:079604065232:key/47e55b65-6537-4fe7-b785-91f290cd19a7` | 同左 | 同左 | なし |
| Log File Validation | 有効 | 同左 | 同左 | なし |
| CloudWatch Logs連携 | なし | 同左 | 同左 | なし |
| SNS連携 | なし | 同左 | 同左 | なし |
| 最新ログ配信 | 成功 | 成功 | 成功 | なし |
| 最新Digest配信 | 成功 | 成功 | 成功 | なし |
| ログアカウントS3実ファイル | 出力確認済み | 出力確認済み | 出力確認済み | なし |

> **補足1：** `CloudWatchLogsLogGroupArn = None` 及び `SnsTopicARN = None` は、CloudWatch Logs及びSNSへの配信を構成していないことを示す。S3へのログ配信は正常であるため、異常とは扱わない。

> **補足2：** Event Selectorは `eventCategory = Management` のみを条件としており、`readOnly`、`eventSource`、`eventName` 等の追加制限はない。このため、Read／Writeを含む全管理イベントを取得する。Data Eventsは対象外とする。

## 4. 設計内容

### 4.1 正式基盤の設計値

基本設計に定められた既存監査ログの継続利用方針を正式基盤の設計基準とする。本番環境及び開発環境の実機調査により、既存CloudTrail設定が当該設計基準と一致していることを確認済みである。

正式基盤では、以下の設定を継続利用する。

- Organization Trail `datautl-prd-log-cloudtrail-001` を利用する
- Multi-Region Trailを有効とする
- Global Service Eventsを取得する
- Read／Writeを含む全Management Eventsを取得する
- ログファイルはログアカウントの既存S3バケットへ集約する
- ログファイルはSSE-KMSで暗号化する
- Log File Validationを有効とする
- CloudWatch Logs及びSNSへの追加配信は行わない
- 保存期間及びライフサイクルは既存ログアカウント側の管理方針を継続利用し、本対応では変更しない

### 4.2 AIエージェント基盤の新規リソース

CloudTrailのManagement EventsはAWSアカウント内の管理API操作を記録するため、AIエージェント基盤で新規作成するAWSリソースについても、既存Organization Trailの記録対象へ自動的に含まれる。

個別のリソース名、リソースID及びARNをTrailへ追加する設定は行わない。また、本基盤専用の個別Trail及びEvent Selectorは作成しない。

S3オブジェクト操作、Lambda Invoke等のData Eventsは既存Organization Trailの取得対象外である。これらの実行・アクセス履歴は、S3アクセスログ、Lambda実行ログ、AgentCore Runtimeログ、Vended Logs、CloudFrontログ及びWAFログ等、各サービスのログ設計により取得する。

### 4.3 MVP環境の扱い

MVP環境は本対応による構築・変更対象外であるが、本番・開発環境と同一のOrganization Trailが適用されていることを確認済みである。

また、MVP環境のManagement EventsがログアカウントS3へ継続的に配信されていることを実ファイルにより確認済みである。このため、MVP環境に対する個別Trailの追加及び設定変更は行わない。

### 4.4 ログアカウント連携

対象3環境のCloudTrailログは、ログアカウント `079604065232` の以下の既存S3バケットへ集約する。

`datautl-prd-log-apne1-s3-bucket-cloudtrail`

Organization Trailのログ格納Prefixは以下とする。

```text
AWSLogs/o-jjrd939pt4/<Account-ID>/CloudTrail/<Region>/<YYYY>/<MM>/<DD>/
```

実機調査により、以下の3アカウントについて、2026年11月16日時点で `ap-northeast-1` のCloudTrailログファイルが継続的に出力されていることを確認済みである。

- `182066453934`（本番）
- `035611741483`（開発）
- `049145893238`（MVP）

また、各環境の `get-trail-status` において、以下を確認済みである。

- `IsLogging = true`
- `LatestDeliveryAttemptSucceeded` が更新されている
- `LatestDeliveryError` が出力されていない
- `LatestDigestDeliveryTime` が更新されている

このため、以下の追加対応は行わない。

- Trailの新規作成
- Event Selectorの変更
- 配信先S3バケットの変更
- CloudWatch Logs連携の追加
- SNS Topicの追加
- S3 Bucket Policyの変更
- KMS Key及びKey Policyの変更
- ログアカウント連携方式の変更

### 4.5 暗号化及びログファイル整合性

CloudTrailログは、ログアカウントが管理する以下のKMS Keyにより暗号化する。

`arn:aws:kms:ap-northeast-1:079604065232:key/47e55b65-6537-4fe7-b785-91f290cd19a7`

Log File Validationは有効であり、`LatestDigestDeliveryTime` が継続的に更新されていることを確認済みである。既存の暗号化設定及びログファイル整合性検証を継続利用し、本対応による変更は行わない。

## 5. 構築・変更対象

| 対象 | 対応 |
|---|---|
| Organization Trail | 新規作成・変更なし |
| Multi-Region設定 | 変更なし |
| Global Service Events | 変更なし |
| Event Selector | 変更なし |
| Data Events | 新規追加なし |
| Insights | 新規追加なし |
| S3配信先 | 変更なし |
| KMS暗号化 | 変更なし |
| Log File Validation | 変更なし |
| CloudWatch Logs連携 | 新規追加なし |
| SNS連携 | 新規追加なし |
| S3 Bucket Policy | 変更なし |
| KMS Key Policy | 変更なし |
| IaC | 本対応による変更なし |

## 6. 実機確認方法

以下のAWS CLIコマンドにより、各環境の設定及び動作状態を確認する。

### 6.1 各対象アカウントでの確認

```bash
aws sts get-caller-identity

aws organizations describe-organization \
  --query "Organization.Id" \
  --output text

aws cloudtrail describe-trails \
  --include-shadow-trails \
  --region ap-northeast-1

aws cloudtrail get-trail-status \
  --name "arn:aws:cloudtrail:ap-northeast-1:841162687537:trail/datautl-prd-log-cloudtrail-001" \
  --region ap-northeast-1

aws cloudtrail get-event-selectors \
  --trail-name "arn:aws:cloudtrail:ap-northeast-1:841162687537:trail/datautl-prd-log-cloudtrail-001" \
  --region ap-northeast-1
```

### 6.2 ログアカウントでのS3実ファイル確認

ログアカウント `079604065232` へ切り替え、以下を実行する。

```bash
aws sts get-caller-identity

aws s3 ls s3://datautl-prd-log-apne1-s3-bucket-cloudtrail/AWSLogs/o-jjrd939pt4/182066453934/CloudTrail/ap-northeast-1/<YYYY>/<MM>/<DD>/

aws s3 ls s3://datautl-prd-log-apne1-s3-bucket-cloudtrail/AWSLogs/o-jjrd939pt4/035611741483/CloudTrail/ap-northeast-1/<YYYY>/<MM>/<DD>/

aws s3 ls s3://datautl-prd-log-apne1-s3-bucket-cloudtrail/AWSLogs/o-jjrd939pt4/049145893238/CloudTrail/ap-northeast-1/<YYYY>/<MM>/<DD>/
```

確認基準は以下とする。

| 確認項目 | 正常判定 |
|---|---|
| Organization ID | `o-jjrd939pt4` |
| Organization Trail | `IsOrganizationTrail = true` |
| Trail稼働状態 | `IsLogging = true` |
| Multi-Region | `IsMultiRegionTrail = true` |
| Global Service Events | `IncludeGlobalServiceEvents = true` |
| Management Events | Advanced Event Selectorの `eventCategory = Management` |
| S3配信先 | `datautl-prd-log-apne1-s3-bucket-cloudtrail` |
| ログ暗号化 | 既存KMS Keyが設定されていること |
| Log File Validation | `LogFileValidationEnabled = true` |
| ログ配信 | `LatestDeliveryAttemptSucceeded` が更新され、`LatestDeliveryError` がないこと |
| Digest配信 | `LatestDigestDeliveryTime` が更新されていること |
| S3実ファイル | 対象3アカウントの当日または直近日付の `.json.gz` ファイルが存在すること |

## 7. 詳細設計結論

本番・開発・MVPの3環境について、Organization Trailの適用状況、Event Selector、稼働状態、ログアカウント連携及びS3実ファイルを確認した。

対象3アカウントは同一のAWS Organization（`o-jjrd939pt4`）に所属し、同一のOrganization Trail `datautl-prd-log-cloudtrail-001` が適用されている。TrailはMulti-Region及びGlobal Service Eventsを有効とし、Read／Writeを含む全Management Eventsを取得している。

全環境でTrailは正常稼働しており、CloudTrailログはログアカウント `079604065232` の既存S3バケットへ正常に配信されている。2026年11月16日の実機調査において、対象3アカウントのCloudTrailログファイルが継続的に出力されていることを確認した。また、SSE-KMSによる暗号化及びLog File Validationが有効であり、Digest配信も正常である。

以上により、CloudTrailについては、AIエージェント基盤で追加する個別リソース向けのTrail、Event Selector、ログ配信設定及びログアカウント連携の追加・変更は不要とする。

**最終判定：既存設定を継続利用し、新規構築・設定変更なし。**
