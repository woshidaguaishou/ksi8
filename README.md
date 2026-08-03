有，而且可以用AWS官方文档直接支撑。不过建议把原文稍微修正，尤其是 Proxy／Firewall的TTL并不是AWS统一规定，需要向MELCO TOP或网络负责人确认。

1. S3 Multipart Upload本身没有固定TTL

AWS官方说明：

Multipart Upload开始后，Amazon S3会保留已经上传的Part，直到上传被完成或中止。

也就是说，AWS不会因为“上传了几个小时”就自动让Upload ID失效。只有以下情况才会结束：

* 执行CompleteMultipartUpload
* 执行AbortMultipartUpload
* 配置了AbortIncompleteMultipartUpload Lifecycle规则，由S3在指定天数后清理

官方文档：

* Uploading and copying objects using multipart upload⁠￼
* Aborting a multipart upload⁠￼
* Lifecycleで未完了Multipart Uploadを削除する設定⁠￼

因此可以写：

S3のマルチパートアップロード自体には、標準で固定された有効期限はありません。Amazon S3は、アップロードが完了または中止されるまで、アップロード済みのパートを保持します。
ただし、AbortIncompleteMultipartUploadを設定したLifecycleルールが存在する場合は、指定日数経過後に未完了アップロードが削除されます。

⸻

2. STS临时凭证存在有效期

AssumeRole取得的临时凭证有效期可以设置为：

* 最短15分钟
* 最长取决于IAM Role的Maximum Session Duration
* Role的最大Session Duration可设置为1～12小时

官方文档：

* AssumeRole API – DurationSeconds⁠￼
* AWS CLI assume-role⁠￼

可以写：

STSの一時認証情報には有効期限があります。AssumeRoleのセッション期間は15分以上で設定でき、IAMロール側の最大セッション期間は1時間から12時間の範囲で設定されます。
転送中に認証情報が失効し、認証情報を更新できない場合、後続のUploadPartやCompleteMultipartUpload等のAPIリクエストが失敗する可能性があります。

注意，不是说已上传的Part会被删除，而是凭证过期后，后续API请求无法继续认证。

⸻

3. IAM Identity Center也有Session Duration

IAM Identity Center的AWS账号访问Session：

* 默认1小时
* 最短1小时
* 最长12小时

官方文档：

* Set session duration for AWS accounts⁠￼
* AWS CLIでIAM Identity Center認証を設定する⁠￼

建议写得严谨一点：

IAM Identity Centerを利用する場合、AWSアカウントセッションには設定された有効期間があります。Permission Setのセッション期間はデフォルト1時間で、1時間から12時間の範囲で設定できます。
AWS CLIが認証情報を更新できない状態でセッションが終了した場合、後続のS3 APIリクエストが失敗する可能性があります。

不要直接写成：

SSO到期后正在传输的数据必定立即中断。

因为AWS CLI的SSO Token Provider配置和缓存状态会影响凭证能否刷新。

⸻

4. Presigned URL有明确有效期

AWS官方说明：

* Presigned URL有设定的到期时间
* 使用临时凭证生成时，即便URL设置了更长时间，也会在底层临时凭证到期时提前失效

官方文档：

* Download and upload objects with presigned URLs⁠￼
* Presigned URL best practices⁠￼

可写成：

署名付きURLには有効期限があります。また、一時認証情報を使用して署名付きURLを生成した場合、URLにより長い有効期間を設定していても、元となる一時認証情報の失効時点でURLも利用できなくなります。

⸻

5. Proxy／Firewall超时的依据

AWS官方只能证明AWS CLI支持通过HTTP_PROXY和HTTPS_PROXY使用Proxy。

官方文档：

* Using an HTTP proxy for the AWS CLI⁠￼

但是：

Proxy连接空闲时间、最长连接时间、认证Session有效期、Firewall Session Timeout，并没有AWS统一值。

这些取决于：

* MELCO TOP的Proxy产品和配置
* 公司Firewall策略
* TLS Inspection设置
* Proxy认证方式
* 网络设备Session Timeout

所以正式资料里应写成：

Proxy／Firewallの通信セッションタイムアウトはAWS側の共通仕様ではなく、MELCO TOPおよび社内ネットワーク機器の設定に依存するため、ネットワーク管理者への確認が必要です。

建议最终使用的日文

S3のマルチパートアップロード自体には、標準で固定されたセッション有効期限はありません。Amazon S3は、アップロードが完了または中止されるまで、アップロード済みのパートを保持します。ただし、AbortIncompleteMultipartUploadを指定したLifecycleルールが設定されている場合は、指定日数経過後に未完了アップロードが削除されます。

一方、STSの一時認証情報、IAM Identity CenterのAWSアカウントセッション、および署名付きURLには有効期限があります。転送中に認証情報が失効し、AWS CLIが認証情報を更新できない場合、後続のS3 APIリクエストが失敗する可能性があります。

また、Proxy／FirewallのセッションタイムアウトはAWSの共通仕様ではなく、MELCO TOPおよび社内ネットワーク機器の設定に依存します。そのため、想定転送時間および再試行時間を考慮し、認証情報の有効期間とネットワーク機器のタイムアウト設定を確認する必要があります。

这个版本的逻辑和官方依据是对得上的。



你说的第一点成立，第二点需要改一下表述。

结论

100GB并不是AWS CLI不能处理的规模。aws s3 cp或aws s3 sync在文件超过阈值时会自动使用Multipart Upload。因此，更准确的风险不是“100GB容易上传失败”，而是：

传输时间较长，受线路中断、Proxy超时、认证凭证到期、终端异常等影响；一旦高阶AWS CLI命令整体失败，单个大文件不能从已经完成的分片位置继续，通常需要重新上传该文件。

AWS官方明确说明，aws s3高阶命令会自动执行Multipart Upload，但失败后不能恢复同一次上传。

“上传会话TTL”并不准确

S3 Multipart Upload本身默认没有固定TTL。Multipart Upload创建后，会一直存在，直到：

* 上传完成；
* 主动Abort；
* Bucket Lifecycle规则到期后自动Abort。

因此，不能直接写成“由于AWS上传会话TTL限制，100GB上传可能超时”。AWS官方说明，Multipart Upload初始化后默认没有过期时间。

真正可能过期的是下面这些东西。

可能过期的对象	影响
STS／AssumeRole临时凭证	过期后，后续UploadPart等请求会认证失败
IAM Identity Center登录会话	会话过期后CLI可能无法继续请求
Presigned URL	到期后不能继续使用该URL上传
Proxy／Firewall连接会话	长时间传输可能被中间设备断开
S3 Lifecycle的Incomplete Multipart规则	超过指定天数后，未完成Multipart Upload可能被清除

AssumeRole会话通常可设置为15分钟至角色允许的最大时长，角色最大Session Duration可配置为1至12小时；Role Chaining最长通常只有1小时。

还要区分“总共100GB”和“单个文件100GB”

总共100GB，由大量文件组成

使用：

aws s3 sync /data/export/ s3://bucket/prefix/

这种方式相对可行。即使中途失败，重新执行sync时，已经成功上传且未变化的文件通常会被跳过，主要重传尚未完成的文件。

单个文件就是100GB

使用：

aws s3 cp huge-file.dat s3://bucket/prefix/

AWS CLI会自动Multipart Upload，但高阶aws s3 cp命令失败后，不能继续使用原来的上传进度。重新执行时，通常需要重新上传整个文件。

所以对单个100GB文件而言，你提出的风险是合理的，只是应该写成：

AWS CLI高阶命令虽然会自动执行Multipart Upload，但不支持失败后的断点续传，因此长时间传输中发生网络中断或认证凭证失效时，可能需要重新上传整个文件。

可以直接给客户的日文说明

风险说明

AWS CLIによる100GB規模のアップロード自体は技術的に可能であり、大容量ファイルについてはAWS CLIが自動的にマルチパートアップロードを実行します。
一方、aws s3 cpやaws s3 sync等の高レベルコマンドでは、単一ファイルのアップロード処理が途中で失敗した場合、同一マルチパートアップロードを途中から再開できません。そのため、ネットワーク切断、Proxyのタイムアウト、端末停止、認証情報の有効期限切れ等が発生した場合、対象ファイルを最初から再転送する可能性があります。

TTL部分的修正版

S3のマルチパートアップロード自体には、標準状態で固定のセッション有効期限はありません。アップロードは完了またはAbortされるまで保持されます。
ただし、STSの一時認証情報、IAM Identity Centerのログインセッション、署名付きURL、Proxy／Firewallの通信セッションには有効期限またはタイムアウトが存在するため、想定転送時間より十分長い有効期間を設定する必要があります。

采用条件

AWS CLI／バッチ方式を採用する場合は、以下を実装条件とします。

・AWS CLI v2を使用する
・aws s3 syncまたはaws s3 cpをバッチ化する
・終了コード判定および自動再試行を実装する
・転送前後のログと通知を保存する
・一時認証情報の有効期間を最大転送時間および再試行時間より長く設定する
・チェックサムによるデータ整合性検証を有効化する
・未完了マルチパートアップロードを削除するS3 Lifecycle Ruleを設定する
・単一大容量ファイルについては、必要に応じて低レベルMultipart Upload APIまたはSDKによる再開機能を検討する

AWS CLI v2は上传时默认计算Checksum，S3也会在服务端验证，不一致时不会保存对象。

客观判断

如果是很多文件合计100GB、每天或每周执行一次，AWS CLI＋batch＋sync完全可以作为正式方案。

如果是单个100GB文件频繁上传，而且网络不稳定，普通aws s3 cp的恢复能力不足。这时应该选择以下之一：

1. 使用低级Multipart Upload API／SDK，保存Upload ID和已完成Part，实现真正断点续传；
2. 将数据拆分为多个可独立重传的文件；
3. 重新考虑DataSync。

所以你向客户提出风险是正确的，但建议把“上传会话TTL限制”改成：

临时认证凭证和网络中间设备存在有效期／超时风险，而S3 Multipart Upload本身默认没有固定TTL。

