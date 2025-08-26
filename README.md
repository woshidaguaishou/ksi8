了解しました 👍
先ほどの費用一覧（Excel）に加えて、日本のお客様向けに提出できる **「AWS 演習環境構築計画書（日本語版）」** を下記のように整理しました。

---

# AWS 演習環境構築計画書（案）

## 1. 目的

本演習は、AWS を活用したクラウドインフラの基礎設計・構築・監視・運用に関する知識を実践的に習得することを目的とする。
特に、**外部アクセス経路**と**運用管理経路**の 2 系統を設計・検証し、セキュリティと可観測性を重視した構成を体験する。

---

## 2. アーキテクチャ概要

### 経路① 外部アクセス（ユーザ向け）

```
インターネット → API Gateway → Lambda → ALB → Private Subnet EC2 (Apache)
```

* API Gateway がインターネットからの入口
* Lambda が疑似的に「ユーザのブラウザアクセス」を再現し、ALB にリクエスト
* ALB がプライベートサブネット内の EC2 (Apache) へ転送
* Web ページの表示を確認

### 経路② 運用アクセス（管理者向け）

```
AWS Management Console → SSM Session Manager → Bastion（EC2） → 別 VPC 内の EC2
```

* Session Manager を用いて踏み台 EC2 へログイン（SSH 不要、公開 IP 不要）
* 踏み台 EC2 から Transit Gateway 経由で別 VPC 内の EC2 へアクセス
* 運用者が安全に管理可能

---

## 3. 利用サービス一覧

* **ネットワーク**: VPC, サブネット, Transit Gateway, NAT Gateway, VPC Endpoint (SSM)
* **コンピュート**: EC2（Apache サーバ / Bastion サーバ）
* **ロードバランサ**: ALB
* **API 管理**: API Gateway, Lambda
* **運用管理**: Systems Manager (Session Manager), IAM, CloudWatch, AWS Config

---

## 4. 監視・セキュリティ

* **CloudWatch**：Lambda 実行ログ、ALB アクセスログ、EC2 メトリクスを収集
* **AWS Config**：すべてのリソース構成変更を記録し、ルールによる準拠性チェックを実施
* **IAM ロール**：最小権限ポリシーを付与し、運用アカウントを制御
* **SSM + VPC Endpoint**：インターネットを経由せずに EC2 へアクセス

---

## 5. 学習効果

| 観点         | 学習できる内容                         |
| ---------- | ------------------------------- |
| ネットワーク設計   | VPC 分割、ルーティング、TGW 接続            |
| Web サービス構築 | ALB 経由の EC2 サービス公開              |
| 運用管理       | Session Manager による非公開環境アクセス    |
| 監視         | CloudWatch / Config による可視化      |
| セキュリティ     | SSH 廃止、最小権限 IAM、Config ルールによる監査 |
| コスト意識      | 各サービスの課金単位を理解する                 |

---

## 6. 利用料金モデル（課金方式）

※詳細は別添「課金方式一覧表（Excel）」を参照

| サービス         | 主な課金方式                          |
| ------------ | ------------------------------- |
| EC2          | インスタンスタイプ × 稼働時間、EBS 容量、データ送信量  |
| ALB          | 稼働時間、LCU（リクエスト/接続/帯域幅）          |
| API Gateway  | リクエスト数（100万件/月 無料枠あり）           |
| Lambda       | リクエスト数、実行時間（GB-秒）               |
| TGW          | 接続数（時間）、データ転送量（GB）              |
| NAT GW       | 稼働時間、処理データ量                     |
| VPC Endpoint | エンドポイント稼働時間、データ転送量              |
| SSM          | 利用無料（ログ転送は CloudWatch/S3 に従量課金） |
| CloudWatch   | メトリクス、ログ保存/転送、ダッシュボード           |
| AWS Config   | リソース記録数、ルール数                    |
| IAM          | 無料                              |

---

📂 料金公式リンク一覧（日本語）

* [EC2 料金](https://aws.amazon.com/jp/ec2/pricing/)
* [EBS 料金](https://aws.amazon.com/jp/ebs/pricing/)
* [ALB 料金](https://aws.amazon.com/jp/elasticloadbalancing/pricing/)
* [API Gateway 料金](https://aws.amazon.com/jp/api-gateway/pricing/)
* [Lambda 料金](https://aws.amazon.com/jp/lambda/pricing/)
* [Transit Gateway 料金](https://aws.amazon.com/jp/transit-gateway/pricing/)
* [NAT Gateway 料金](https://aws.amazon.com/jp/vpc/pricing/)
* [VPC Endpoint 料金](https://aws.amazon.com/jp/vpc/pricing/)
* [SSM 料金](https://aws.amazon.com/jp/systems-manager/pricing/)
* [CloudWatch 料金](https://aws.amazon.com/jp/cloudwatch/pricing/)
* [Config 料金](https://aws.amazon.com/jp/config/pricing/)
* [IAM 料金](https://aws.amazon.com/jp/iam/pricing/)

---



サービス	課金項目	公式ドキュメントリンク
EC2（仮想サーバ/Bastion・Apache）	"・インスタンス稼働料金（タイプ × 秒単位）
・EBSストレージ（GB/月）
・データ送信（インターネット宛、GB単位）"	https://aws.amazon.com/jp/ec2/pricing/
EBS（ブロックストレージ）	"・ストレージ容量（GB/月）
・IOPS/スループット課金（ボリュームタイプによる）"	https://aws.amazon.com/jp/ebs/pricing/
ALB（アプリケーションロードバランサ）	"・稼働時間（時間単位）
・LCU使用量（リクエスト数、接続数、帯域幅、いずれか最大値で計算）"	https://aws.amazon.com/jp/elasticloadbalancing/pricing/
API Gateway（HTTP API）	・リクエスト数（100万件/月まで無料、その後従量課金）	https://aws.amazon.com/jp/api-gateway/pricing/
Lambda（関数実行）	"・リクエスト数（100万件/月まで無料）
・実行時間（メモリ割当 × 実行時間、GB-秒単位）"	https://aws.amazon.com/jp/lambda/pricing/
Transit Gateway（TGW）	"・VPCアタッチメント数（時間単位）
・データ転送量（GB単位）"	https://aws.amazon.com/jp/transit-gateway/pricing/
NAT Gateway	"・稼働時間（時間単位）
・処理データ量（GB単位）"	https://aws.amazon.com/jp/vpc/pricing/
VPC Endpoint（SSM関連: ssm/ssmmessages/ec2messages）	"・エンドポイント稼働料金（AZごと、時間単位）
・データ転送量（地域によって従量課金）"	https://aws.amazon.com/jp/vpc/pricing/
SSM（Session Manager）	"・セッション利用自体は無料
・ログ転送（CloudWatch/S3）で別途課金"	https://aws.amazon.com/jp/systems-manager/pricing/
CloudWatch	"・メトリクス（基本無料、カスタムは従量課金）
・ログ保存（GB/月）
・ログ転送/書き込み（GB単位）
・ダッシュボード（3つ無料、追加は課金）"	https://aws.amazon.com/jp/cloudwatch/pricing/
AWS Config	"・リソース記録（対象リソース数 × 回数）
・Configルール（マネージドルール/カスタムルール）"	https://aws.amazon.com/jp/config/pricing/
IAM	・無料（ユーザー、ロール、ポリシー管理）	https://aws.amazon.com/jp/iam/pricing/<img width="2006" height="626" alt="image" src="https://github.com/user-attachments/assets/5cde3303-1f67-42f5-b39f-ba406c49f1b4" />



要望に合わせて **Word ドキュメント** を生成しましょうか？

