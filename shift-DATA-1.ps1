# ============================================================
# オンプレWindows Server → Amazon S3 ファイル転送バッチ
#
# 処理概要：
#   指定されたローカルディレクトリ内のCSVファイルを
#   AWS CLIを使用してAmazon S3へアップロードする。
#
#   正常終了したファイルはArchiveフォルダへ移動する。
#   転送失敗時は最大3回までリトライし、
#   最終的に失敗した場合は元ファイルを残す。
#
# 前提条件：
#   ・AWS CLI v2がインストールされていること
#   ・aws.exeにPATHが設定されていること
#   ・S3へアクセス可能なAWS認証設定がされていること
#   ・HTTPS（TCP/443）でAWSへ通信できること
#
# 定期実行：
#   Windows Task Schedulerから毎日02:00に実行する想定
# ============================================================



# ============================================================
# ① 設定値
# ★ 基本的には、このエリアだけ環境に合わせて変更する
# ============================================================

# 【要修改】
# S3へ転送するファイルが配置されるフォルダ
#
# 例：
# C:\data\export
$SourceDir = "C:\data\export"


# 【要修改】
# S3転送成功後のファイル保存先
#
# 例：
# C:\data\archive
$ArchiveDir = "C:\data\archive"


# 【要修改】
# バッチ実行ログ保存先
#
# 例：
# C:\data\log
$LogDir = "C:\data\log"


# 【要修改：S3設計完成後】
# 転送先S3 Bucket / Prefix
#
# 例：
# s3://project-prod-data/raw/onprem/systemA
#
# ※最後に "/" を付けなくてもよい
$S3BaseUri = "s3://YOUR-BUCKET/raw/onprem/systemA"


# 【必要に応じて修改】
# 転送対象ファイル
#
# CSV：
# *.csv
#
# 全ファイルの場合：
# *
$FilePattern = "*.csv"


# 【必要に応じて修改】
# 最大リトライ回数
$MaxRetry = 3


# 【必要に応じて修改】
# リトライするまでの待機時間（秒）
#
# 60 = 1分
$RetryInterval = 60



# ============================================================
# ② 初期処理
# ここから下は原則として変更不要
# ============================================================

# 現在の日付をYYYY/MM/DD形式で取得する
#
# S3 Prefixとして使用する
#
# 例：
# 2026/08/27
$Date = Get-Date -Format "yyyy/MM/dd"


# 現在日時を取得する
#
# ログファイル名に使用する
#
# 例：
# 20260827_020000
$TimeStamp = Get-Date -Format "yyyyMMdd_HHmmss"


# 最終的なS3転送先を生成する
#
# 例：
# s3://bucket/raw/onprem/systemA/2026/08/27/
$S3Uri = "$S3BaseUri/$Date/"


# 今回の実行ログファイル名を作成する
#
# 例：
# C:\data\log\s3_upload_20260827_020000.log
$LogFile = "$LogDir\s3_upload_$TimeStamp.log"


# Archiveフォルダが存在しない場合は作成する
New-Item `
    -ItemType Directory `
    -Force `
    -Path $ArchiveDir |
    Out-Null


# Logフォルダが存在しない場合は作成する
New-Item `
    -ItemType Directory `
    -Force `
    -Path $LogDir |
    Out-Null



# ============================================================
# ③ バッチ開始ログ
# ============================================================

# 区切り線をログへ出力
"==================================================" |
    Out-File $LogFile -Append


# バッチ開始日時をログへ出力
"$(Get-Date) Upload batch started." |
    Out-File $LogFile -Append


# 転送元フォルダをログへ出力
"Source : $SourceDir" |
    Out-File $LogFile -Append


# 転送先S3をログへ出力
"Target : $S3Uri" |
    Out-File $LogFile -Append


# 区切り線をログへ出力
"==================================================" |
    Out-File $LogFile -Append



# ============================================================
# ④ 転送対象ファイル取得
# ============================================================

# SourceDirから対象ファイル一覧を取得する
#
# 例：
# C:\data\export\*.csv
$Files = Get-ChildItem `
    -Path $SourceDir `
    -Filter $FilePattern `
    -File


# 転送失敗ファイル数
$ErrorCount = 0



# ============================================================
# ⑤ ファイル転送処理
# ============================================================

# 対象ファイルを1ファイルずつ処理する
foreach ($File in $Files) {


    # 転送開始ログ
    "$(Get-Date) Upload start: $($File.Name)" |
        Out-File $LogFile -Append


    # ファイル転送成功フラグ
    #
    # false = 未成功
    # true  = 成功
    $Success = $false


    # 最大リトライ回数まで転送処理を実行する
    for (
        $Retry = 1;
        $Retry -le $MaxRetry;
        $Retry++
    ) {


        # ----------------------------------------------------
        # AWS CLIを使用してS3へファイルを転送する
        #
        # 実際には以下のようなコマンドになる
        #
        # aws s3 cp `
        #   C:\data\export\data.csv `
        #   s3://bucket/raw/onprem/systemA/2026/08/27/data.csv
        #
        # AWS CLIの標準出力・エラー出力はログへ保存する
        # ----------------------------------------------------

        aws s3 cp `
            $File.FullName `
            "$S3Uri$($File.Name)" `
            *>> $LogFile


        # AWS CLIの終了コードを確認する
        #
        # 0 = 正常終了
        # 0以外 = 異常終了
        if ($LASTEXITCODE -eq 0) {


            # S3転送成功ログ
            "$(Get-Date) Upload success: $($File.Name)" |
                Out-File $LogFile -Append


            # 正常転送したファイルをArchiveへ移動
            Move-Item `
                $File.FullName `
                $ArchiveDir


            # Archive移動ログ
            "$(Get-Date) Archived: $($File.Name)" |
                Out-File $LogFile -Append


            # 転送成功フラグをtrueに変更
            $Success = $true


            # Retryループを終了
            break

        }
        else {


            # 転送失敗ログ
            "$(Get-Date) Upload failed: $($File.Name) Retry=$Retry" |
                Out-File $LogFile -Append


            # 最大リトライ回数に達していない場合のみ待機
            if ($Retry -lt $MaxRetry) {


                # 指定秒数待ってから再試行する
                Start-Sleep `
                    -Seconds $RetryInterval

            }

        }

    }


    # 最大回数実行しても成功しなかった場合
    if (-not $Success) {


        # エラーログを出力
        "$(Get-Date) ERROR: Upload failed after $MaxRetry retries: $($File.Name)" |
            Out-File $LogFile -Append


        # 元ファイルはSourceDirに残す
        # 削除・Archive移動はしない
        # 手動再実行可能な状態とする


        # エラー件数を1増やす
        $ErrorCount++

    }

}



# ============================================================
# ⑥ 対象ファイルなしの場合
# ============================================================

# 転送対象ファイルが存在しなかった場合
if ($Files.Count -eq 0) {


    # 対象ファイルなしとしてログへ記録
    "$(Get-Date) No upload target files." |
        Out-File $LogFile -Append

}



# ============================================================
# ⑦ 最終結果判定
# ============================================================

# 1件以上転送失敗している場合
if ($ErrorCount -gt 0) {


    # 異常終了ログ
    "$(Get-Date) Batch finished with errors." |
        Out-File $LogFile -Append


    # Exit Code 1で終了
    # Task Schedulerや監視ツール側で異常判定可能
    exit 1

}
else {


    # 正常終了ログ
    "$(Get-Date) Batch finished successfully." |
        Out-File $LogFile -Append


    # Exit Code 0で正常終了
    exit 0

}