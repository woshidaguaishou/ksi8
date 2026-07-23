DataSync導入要件説明資料

Slide 1：データ連携要件とDataSyncによる実現方針

結論

DCからインターネット経由でS3へデータを転送する要件に対し、DataSyncでどのように解決するかを整理します。

要件と解決方針

転送経路

要件・課題

DCからAWS S3へ、VPN/DXを前提とせずインターネット経由で転送する。

DataSyncによる対応

DataSync AgentがPublic service endpointへHTTPSでアウトバウンド接続し、AWS DataSyncへデータを送信する。

設計上の扱い

採用

転送元

要件・課題

DC内のファイルサーバ/NAS上に出力される連携ファイルを対象とする。

DataSyncによる対応

Source LocationとしてNFSまたはSMBを定義し、Agentがローカルネットワーク経由で読み取る。

設計上の扱い

要確認（NFS/SMB）

転送先

要件・課題

AWS側ではS3バケットへ蓄積し、後続処理・AI連携基盤から参照可能にする。

DataSyncによる対応

Destination LocationとしてS3バケット／Prefixを指定し、DataSyncサービスがIAM RoleをAssumeして書き込む。

設計上の扱い

採用

運用性

要件・課題

定期実行、差分転送、失敗検知、再実行、転送結果の確認が必要。

DataSyncによる対応

Taskにより差分転送・スケジュール実行・帯域制御・CloudWatch Logs連携・検証を設定する。

設計上の扱い

採用

セキュリティ

要件・課題

インターネット経由でもデータ保護、AWS側アクセス制御、保管時暗号化が必要。

DataSyncによる対応

Agent〜AWS間はTLS、S3アクセスはDataSync用IAM Role、S3はSSE-S3またはSSE-KMSで暗号化する。

設計上の扱い

採用

論理構成

DC
↓
ファイルサーバ/NAS
↓
DataSync Agent
↓
Internet（HTTPS 443）
↓
AWS DataSync Public Endpoint
↓
Amazon S3（Bucket/Prefix）

※ AWS側からDCへ入る通信は不要。AgentがDC側からAWSへアウトバウンド送信する構成。

参考：AWS DataSync User Guide（Public service endpoint、Network requirements、S3 location、Task scheduling）

---

Slide 2：AWS DataSync 導入要件

導入要件

DataSyncを導入するために、DC側・AWS側・運用側で事前に満たすべき条件を整理します。

導入に必要な構成・設定

Agent配置

導入要件

DC内にDataSync Agent VMを配置する。

具体的な設定・確認内容

VMware / KVM / Hyper-V等にAgentイメージを導入。ファイルサーバ/NASへ到達でき、かつインターネット出口へ到達できるネットワークに配置する。

備考

固定IPを推奨。S3やVPC内に置く構成ではない。

Agentリソース

導入要件

転送規模に応じたvCPU・メモリ・ディスクを確保する。

具体的な設定・確認内容

Basic：4 vCPU / 32GB RAM / 80GB Disk。
Enhanced：8 vCPU / 32GB RAM / 80GB Disk。
Basicで2,000万超のファイル等を扱う場合は64GB RAMを検討。

備考

転送対象数・データ量により最終決定。

Source接続

導入要件

Agentから転送元ストレージへアクセス可能にする。

具体的な設定・確認内容

SMBの場合：TCP 445、認証ユーザー、共有名、権限。
NFSの場合：TCP 2049、Export設定、Agent IP許可。

備考

プロトコル、パス、権限は要確認。

AWS接続

導入要件

AgentからAWS DataSync Public Endpointへ接続可能にする。

具体的な設定・確認内容

Agent → AWS：TCP 443（HTTPS）を許可。
DNS名前解決、NTP同期を許可。
Agentアクティベーション時のみ管理端末 → Agent：TCP 80を使用。

備考

VPN/DX/VPC Endpointは不要。

S3権限

導入要件

DataSyncがS3へ書き込むためのIAM Roleを準備する。

具体的な設定・確認内容

S3 LocationにDataSync用IAM Roleを指定。必要に応じてS3 Bucket Policy、KMS Key Policyを調整する。

備考

aws:SourceVpce制限がある場合は例外設定が必要。

運用設定

導入要件

スケジュール、帯域、ログ、検証方式を定義する。

具体的な設定・確認内容

Taskで差分転送、スケジュール、帯域制限、データ検証、CloudWatch Logs出力を設定する。

備考

最短スケジュール間隔は1時間。

参考：AWS DataSync User Guide（Agent requirements、Network requirements、Configuring transfers with Amazon S3、SMB/NFS location）

---

Slide 3：AWS DataSync 制約事項・確認事項

インターネット経由でDCからS3へ転送する構成における制約、リスク、未確定事項を整理します。

制約事項

通信経路

制約・注意点

Public Endpoint利用時はAgent〜DataSync間の通信がインターネット経由となる。

対応方針

TLS通信を前提としつつ、FWで宛先FQDN・TCP443を制御する。

リアルタイム性

制約・注意点

DataSyncはタスク実行型の転送であり、リアルタイムストリーミング用途ではない。スケジュール実行の最短間隔は1時間。

対応方針

準リアルタイム要件がある場合は、別方式との比較が必要。

帯域影響

制約・注意点

転送量が大きい場合、DCのインターネット出口帯域やファイルサーバ負荷に影響する可能性がある。

対応方針

帯域制限、実行時間帯、初回転送と差分転送の分離を設計する。

S3制限

制約・注意点

S3 Bucket Policyで特定VPC Endpointのみ許可している場合、DataSyncからの書き込みが拒否される可能性がある。

対応方針

DataSync用IAM Roleを許可するBucket Policy例外を設ける。

メタデータ

制約・注意点

NFS/SMBの権限・所有者・タイムスタンプ等は、S3オブジェクトのメタデータとしての扱いになるため確認が必要。

対応方針

PoCでファイル形式、権限、文字コード、更新判定を確認する。

費用

制約・注意点

DataSync転送料、S3リクエスト、S3保管、KMS、CloudWatch Logs等の費用が発生する。

対応方針

データ量・ファイル数・実行頻度を確定後に概算する。

未確定・確認事項

転送元

確認内容

サーバ名、IP、共有パス、NFS/SMB、認証方式、権限

設計への影響

Location設定、FW設定

データ仕様

確認内容

ファイル形式、文字コード、命名規則、ディレクトリ構成

設計への影響

S3 Prefix、後続処理

転送規模

確認内容

初回データ量、日次増分、ファイル数、最大ファイルサイズ

設計への影響

Agentリソース、帯域、費用

転送頻度

確認内容

日次/時間単位/手動、実行時間帯、締め時間

設計への影響

スケジュール、RPO

エラー運用

確認内容

失敗時の通知先、再実行手順、リカバリ責任者

設計への影響

CloudWatch、運用手順

S3設計

確認内容

Bucket、Prefix、暗号化方式、Lifecycle、Versioning、Bucket Policy

設計への影響

セキュリティ、保管費用

運用責任

確認内容

Agent VMの管理者、AWS側Task管理者、障害一次切り分け

設計への影響

運用体制、保守範囲

参考：AWS DataSync User Guide（Task scheduling、Data verification、Metadata handling、S3 request cost considerations）
