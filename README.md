AWS CLI 直接送付と API Gateway → Lambda → S3 の構成はどちらも技術的には可能ですが、次の点をご確認ください。

AWS CLI 直接送付の場合：
相手 S3 バケットポリシーで当方の ARN を許可するか、事前に発行された署名付きURL（presigned URL）を利用する必要があります。現在の方針では ARN 記載は難しいため、署名付き URLの利用が現実的ですね。。。

API Gateway → Lambda → S3（REST転送）の場合：
直接ファイルを通す場合は API Gateway のサイズ制限（10MB程度）や Lambda 実行時間制限により、大容量ファイルは非推奨です。
実運用では Lambda で署名付き URL を発行し、HULFT からその URL に直接 PUT アップロードする方式が安全かつ制限回避できます。

この方式であれば、バケットは Public Access Block を維持しながら、ARN 情報を開示せずに送付可能です。
