第一张图的优先度①，本质是：

根据已经收到的ヒアリング结果，对Excel中每一种网络构成选择推荐方案，并说明为什么推荐、什么条件下不能用。

结合你现在的表格，以及“数据量以100GB为基准”的前提，我建议按下面定。

推荐方案总表

网络构成	推荐方案	推荐结论	备注
①-1 东京大楼→东京DC	パターン①：Falcon网传输	条件性采用	只有一条候选，具体上传协议仍要确认
①-2 Internet	パターン③：AWS DataSync	推荐	适合100GB级、定期、自动化传输
①-2 VPN／DX	パターン②：AWS DataSync	推荐	通过私网端点进行托管式文件传输
②-1＋②-2 稲沢→MELCO TOP→AWS	パターン①：AWS CLI	推荐	现有路径明确经过HTTP／HTTPS Proxy
③-1 稲沢→Megcloud共享S3	パターン①：S3 Interface Endpoint	推荐	利用既有闭域连接直接写入共享S3
③-2 Megcloud稲沢→Data Lake	パターン③：S3 Replication	原则推荐	如必须严格控制执行时间，则改选パターン②
④ Megcloud MiLai→Data Lake	パターン③：S3 Replication	原则推荐	与③-2相同
⑤ Data Lake→各Site	现有Lambda方案需修正	不建议Lambda搬运100GB文件	Lambda只做通知／控制，文件直接从S3传输

⸻

①-1 东京大楼→东京DC

推荐

パターン①：社内専用Falcon網を経由して東京DCへ転送

这是当前唯一候选方案，因此可以继续采用，但它还不能算“设计完成”。

目前只能确认：

東京ビルのオンプレデータ
→ Falcon社内専用網
→ 東京DC

Falcon网只是网络路径，不负责文件传输。必须继续确认：

* 东京DC的接收端是什么：文件服务器、SFTP服务器、API还是业务系统
* SMB、SFTP、HTTPS或专用传输软件中的哪一种
* 是东京大楼主动Push，还是东京DC主动Pull
* 东京DC是否临时保存数据
* 失败重试及传输完成判定

Excel可写

推奨：パターン①。ただし、Falcon網はネットワーク経路のみであり、東京DC側の受信先、転送プロトコル、認証方式、実行契機については要確認。

⸻

①-2 Internet：东京DC→AWS

推荐

パターン③：AWS DataSync Agentからインターネット経由でDataSyncサービスへ接続し、S3へ転送

正确路径应写成：

東京DC内のNFS／SMBファイルサーバー
→ 東京DC内DataSync Agent
→ HTTPS／Internet
→ AWS DataSync公共服务端点
→ Amazon S3 Data Lake

注意，不是DataSync服务直接从AWS端“进入东京DC取文件”，而是：

东京DC内部的DataSync Agent读取本地NFS／SMB，再主动向AWS发送。

推荐理由

DataSync专门用于本地文件／对象存储与AWS存储之间的数据移动，支持NFS和SMB。它可以只传输变化的数据，并提供完整性校验、带宽限制、任务报告和CloudWatch日志，比手工上传或单纯CLI脚本更适合100GB级的定期生产传输。

三个方案比较：

项目	パターン① 手动	パターン② CLI	パターン③ DataSync
100GB传输	不适合	可以	适合
自动执行	差	需要自制脚本	支持
差分传输	人工判断	sync可以，但需维护	支持
完整性校验	人工	需自行设计	支持Checksum验证
重试和监控	人工	自行开发	托管任务／日志
初期构筑	最少	较少	需要Agent
长期运维	高	中	低

例外

数据只是一次性上传，或者极低频率传输时，パターン② AWS CLI可能比部署DataSync Agent更经济。

Excel可写

推奨：パターン③（AWS DataSync）。100GB規模の定期的なデータ連携を前提とした場合、差分転送、整合性検証、再実行、帯域制御、監視をマネージド機能として利用でき、手動アップロードおよびCLIスクリプトと比較して運用負荷を低減できるため。

官方文档：

* What is AWS DataSync?⁠￼
* DataSync SMB Location⁠￼
* DataSync NFS Location⁠￼
* DataSync数据完整性验证⁠￼

⸻

①-2 VPN／Direct Connect：东京DC→AWS

推荐

パターン②：DataSync Agent＋DataSync VPC Service Endpoint

正确路径：

東京DC内NFS／SMB
→ DataSync Agent
→ VPNまたはDirect Connect
→ DataSync VPC Service Endpoint
→ AWS DataSync
→ S3 Data Lake

DataSync支持通过AWS PrivateLink提供的VPC服务端点进行通信，这种情况下Agent与DataSync服务之间的通信保留在VPC／AWS私网路径内。

为什么不推荐パターン① Lambda Pull

Lambda不是批量文件传输服务。单次运行最长15分钟，对大文件传输而言，超时、重试、断点续传、幂等和错误恢复都需要自行实现。

为什么不把パターン③作为第一推荐

パターン③：

本地AWS CLI
→ VPN／DX
→ S3 Interface Endpoint
→ S3

技术上完全可行，而且S3 Interface Endpoint确实可以从本地通过VPN或DX访问。

但是它只是提供私网S3 API连接：

* 脚本调度需要自行设计
* 重试和失败恢复需要自行设计
* 传输结果报告需要自行设计
* 完整性校验和告警需要自行设计

所以：

* 长期、定期、100GB级：パターン② DataSync
* 少量、简单、已有可靠批处理：パターン③ CLI＋S3 Interface Endpoint

另外，不能把S3 Gateway Endpoint用于本地直连；Gateway Endpoint不接受来自本地网络、对等VPC或TGW的访问，本地接入必须使用Interface Endpoint。

Excel可写

推奨：パターン②（AWS DataSync）。オンプレミス側にDataSync Agentを配置し、VPNまたはDirect Connect経由でDataSync VPCサービスエンドポイントへ接続する。100GB規模の定期転送に必要となる差分転送、再実行、検証、監視をマネージド化できるため。

官方文档：

* Choosing a DataSync service endpoint⁠￼
* AWS PrivateLink for Amazon S3⁠￼
* S3 Gateway Endpoint限制⁠￼

⸻

②-1＋②-2 稲沢→MELCO TOP→S3

推荐

パターン①：稲沢側AWS CLIからMELCO TOP Proxy経由でS3へ直接アップロード

整体路径要合并理解：

稲沢オンプレデータ
→ AWS CLI／批处理
→ MELIT／MELCO社内网
→ MELCO TOP Forward Proxy
→ Internet
→ S3公共服务端点
→ S3 Data Lake

其中：

* ②-1：稲沢→MELCO TOP
* ②-2：MELCO TOP→Internet→AWS S3
* 数据方向：稲沢侧主动Push
* MELCO TOP：HTTP／HTTPS代理出口，不是数据保存位置

推荐理由

AWS CLI官方支持通过HTTP_PROXY和HTTPS_PROXY环境变量使用代理服务器，因此和现有MELCO TOP Proxy架构的匹配度最高。

AWS CLI的aws s3 cp和aws s3 sync可以直接把本地文件上传到S3；大型对象上传会使用Multipart Upload，传输失败时只需重传失败部分。

示例：

export HTTPS_PROXY=http://melco-top-proxy.example:8080
aws s3 sync /data/export/ \
  s3://data-lake-bucket/inazawa/ \
  --only-show-errors

不过生产上不能只写这一行命令，还要增加：

* 返回码判断
* 重试次数和间隔
* 上传完成日志
* CloudWatch或现有监控系统告警
* 文件上传前后的Checksum
* 上传完成文件的移动／归档
* 重复上传防止
* 临时IAM凭证管理

Excel可写

推奨：パターン①（AWS CLI）。MELCO TOPがHTTP／HTTPS Proxyとして構成されており、AWS CLIはProxy設定を正式にサポートしているため、既存ネットワーク構成を変更せずS3へ直接アップロードできる。転送処理はバッチ化し、再試行、結果ログ、整合性確認を実装する。

官方文档：

* AWS CLI使用HTTP Proxy⁠￼
* AWS CLI S3高级命令⁠￼
* S3 Multipart Upload⁠￼

⸻

③-1 稲沢→Megcloud共享S3

推荐

パターン①：S3 Interface VPC Endpoint経由でMegcloud共有S3へアップロード

路径：

稲沢オンプレ
→ 社内専用MELCO网
→ Megcloud VPC
→ S3 Interface VPC Endpoint
→ Megcloud共有S3

推荐理由

这是当前唯一候选，而且符合“稲沢到Megcloud之间闭域化”的设计目标。S3 Interface Endpoint具有VPC内私有IP，并支持从本地通过VPN或Direct Connect访问。

但这里必须追加一个设计前提：

MELCO内网与Megcloud VPC之间必须已经存在VPN、Direct Connect或其他可路由的私网连接。

仅创建Interface Endpoint，不会自动让稲沢本地网络连到VPC。

还要确认：

* 本地DNS如何解析S3 Endpoint
* 是否指定--endpoint-url
* Endpoint Security Group
* Bucket Policy中的aws:SourceVpce
* 路由和Firewall TCP 443
* IAM认证和KMS权限

Excel可写

推奨：パターン①。稲沢オンプレミスからMegcloud VPC内のS3 Interface VPC Endpointを経由し、共有用S3へデータを格納することで、インターネットを経由しない閉域通信を実現できるため。

⸻

③-2 Megcloud稲沢→Data Lake

原则推荐

パターン③：Amazon S3 Replication

路径：

Megcloud（稲沢）共有S3
→ Amazon S3 Replication
→ データ利活用基盤S3

为什么比Lambda A／B更适合

源和目标都已经是S3，因此从架构上说，优先使用S3原生复制服务比自己开发Lambda搬运程序更合理：

* 不需要Lambda代码
* 不需要自行实现重试和幂等
* 不受Lambda 15分钟限制
* 支持跨AWS账号复制
* 自动复制新对象及对象更新
* 可以保留对象元数据

S3 Live Replication是自动、异步的S3 Bucket间复制，支持同账号和跨账号。

前提和缺点

* 源、目标Bucket都必须启用Versioning。
* 默认是异步复制
* Live Replication主要复制规则生效后的新对象；既存对象需要S3 Batch Replication。
* 跨账号需要IAM Role、目标Bucket Policy和KMS权限。
* 两边都会保留数据，但源Bucket可以通过Lifecycle控制保存期限
* 对复制时间有明确SLA要求时，可评估S3 Replication Time Control。

什么时候改选パターン②

满足以下任一条件时，可以将パターン② 基盘侧Pull作为推荐：

* Megcloud已经把パターン②定义为标准服务
* 不允许在Megcloud源Bucket开启Versioning
* 必须由数据利用基盘控制具体执行时刻
* 数据取得成功后必须立即删除源文件
* 需要基于业务条件选择文件，而不是简单按Prefix／Tag复制

不过这时建议在现有表格中追加EventBridge／SQS等事件通知设计，否则“基盘侧Lambda检测跨账号S3文件”如何实现并不完整。

Excel可写

推奨：原則パターン③（Amazon S3 Replication）。送信元・送信先がともにS3であるため、Lambdaによる独自転送処理を実装せず、S3のマネージド機能でクロスアカウント転送、再試行、継続的な同期を実現できる。実行時刻の厳密な制御または送信元削除が必要な場合はパターン②を採用する。

官方文档：

* S3 Replication概述⁠￼
* 跨账号S3 Replication⁠￼
* Replication要求⁠￼
* S3 Replication Time Control⁠￼

⸻

④ Megcloud MiLai→Data Lake

推荐

与③-2相同，原則パターン③：Amazon S3 Replication

因为其技术结构相同：

Megcloud（MiLai）共有S3
→ 跨账号S3 Replication
→ データ利活用基盤S3

推荐依据、限制和替代条件与③-2相同。

为了减少运维差异，③-2与④最好采用同一种方式，不建议稲沢用Lambda、MiLai用Replication，否则权限、监控、故障处理和成本模型会分成两套。

Excel可写

推奨：パターン③。Megcloud（稲沢）と同一方式に統一し、クロスアカウントS3 Replicationを利用することで、実装および運用方式を標準化する。

⸻

⑤ Data Lake→各Site

当前方案不能直接按原样推荐

表中写的是：

S3 Data Lake
→ Lambda
→ NAT Gateway
→ Internet
→ 各Site

如果Lambda只是：

* 调用外部API
* 发送文件到达通知
* 生成URL
* 传输少量JSON或控制信息

那么这个方案可以。

但如果按你们当前的100GB基准，不能让Lambda作为100GB文件的数据中继。Lambda单次执行最长15分钟，而且调用负载和本地临时存储都有配额，作为大型文件传输主体会产生明显的超时、重试和断点恢复风险。

建议修正

各Site能够主动下载

S3 Data Lake
→ Lambda生成Presigned URL并通知
→ 各Site直接通过HTTPS从S3下载

Presigned URL可以在不修改Bucket Policy的情况下，授予对特定S3对象的限时访问权限。

各Site要求SFTP Push

S3 Data Lake
→ AWS Transfer Family SFTP Connector
→ 外部Site的SFTP服务器

AWS Transfer Family SFTP Connector专门支持从S3向外部合作方的SFTP服务器发送文件，并提供凭证、日志和托管传输功能。

Excel可写

現行パターン①は条件付き採用。Lambdaは連携制御、通知または署名付きURLの発行に限定し、100GB規模のファイル本体をLambda経由で中継しない。各サイトがHTTPSで取得可能な場合はS3署名付きURL、SFTPが必要な場合はAWS Transfer Family SFTP Connectorを推奨する。

官方文档：

* Lambda Quotas⁠￼
* S3 Presigned URL⁠￼
* Transfer Family SFTP Connector⁠￼

⸻

可以直接向负责人提交的日文结论

各ネットワーク構成に対する推奨パターンを以下の通り整理しました。

・①-1：パターン①を継続。ただし、東京DC側受信先および転送プロトコルは要確認。
・①-2（インターネット）：パターン③ AWS DataSyncを推奨。
・①-2（VPN／Direct Connect）：パターン② AWS DataSync＋VPCサービスエンドポイントを推奨。
・②-1／②-2：パターン① AWS CLIによるMELCO TOP Proxy経由のS3アップロードを推奨。
・③-1：パターン① S3 Interface VPC Endpoint経由のMegcloud共有S3格納を推奨。
・③-2／④：原則パターン③ Amazon S3 Replicationを推奨。厳密な実行時刻制御や送信元削除が必要な場合はパターン②を採用。
・⑤：Lambdaは制御処理のみに利用し、大容量ファイル本体は署名付きURLまたはAWS Transfer Family SFTP Connectorにより転送する構成へ見直す。

選定基準は、100GB規模のデータ転送に対する信頼性、再実行性、整合性検証、運用負荷、独自プログラムの保守範囲、およびネットワーク制約です。
