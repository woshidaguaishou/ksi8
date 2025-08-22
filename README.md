以下の点についてご確認をお願いいたします。Aurora 移行時の容量見積もりに必要です。

FRA／アーカイブログ／REDO／一時表領域／UNDO を含んでいますか？
　Aurora ではこれらは同じ形で存在しないため、含まれるかどうかで実際の必要容量が変わります。

OS ディスク／アプリケーションファイル／イメージ／システムバックアップ を含んでいますか？
　Aurora ではこれらは対象外となります。

表示されている 1.245 TB は、
　- データファイル＋インデックスの総量 を示していますか？
　- それとも バックアップ圧縮ファイルのサイズ ですか？（圧縮サイズは Aurora 上の実データ量と一致しません）


https://docs.aws.amazon.com/ja_jp/AmazonRDS/latest/AuroraUserGuide/Aurora.Managing.Performance.Storage.html
https://docs.aws.amazon.com/ja_jp/AmazonRDS/latest/AuroraUserGuide/Aurora.Managing.Backups.html
