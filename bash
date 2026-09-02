#!/bin/bash

# ============================================================
# オンプレサーバー → Amazon S3 ファイル転送バッチ
#
# 処理概要：
#   指定されたローカルディレクトリ内のCSVファイルを
#   AWS CLIを使用してAmazon S3へアップロードする。
#
#   正常終了したファイルはArchiveディレクトリへ移動する。
#   転送失敗時は最大3回までリトライし、
#   最終的に失敗した場合は元ファイルを残す。
#
# 前提条件：
#   ・AWS CLI v2がインストールされていること
#   ・AWS CLIからS3へアクセス可能な認証設定がされていること
#   ・HTTPS（TCP/443）でAWSへ通信できること
#
# 定期実行：
#   cronから毎日02:00に実行する想定
# ============================================================


# ============================================================
# ① 設定値
# ★ 基本的には、このエリアだけ環境に合わせて変更する
# ============================================================

# 【要修改】
# S3へ転送するファイルが配置されるローカルディレクトリ
# 例：/data/export
SOURCE_DIR="/data/export"


# 【要修改】
# S3への転送成功後にファイルを移動する保存先
# 例：/data/archive
ARCHIVE_DIR="/data/archive"


# 【要修改】
# バッチ実行ログを保存するディレクトリ
# 例：/var/log/s3-upload
LOG_DIR="/var/log/s3-upload"


# 【要修改：S3設計完成後】
# 転送先となるS3 Bucket / Prefix
#
# 例：
# s3://project-prod-data/raw/onprem/systemA
#
# ※最後に "/" を付けなくてもよい
S3_BASE_URI="s3://YOUR-BUCKET/raw/onprem/systemA"


# 【必要に応じて修改】
# 転送対象ファイルの拡張子・パターン
# CSVの場合は *.csv
FILE_PATTERN="*.csv"


# 【必要に応じて修改】
# S3転送失敗時の最大リトライ回数
MAX_RETRY=3


# 【必要に応じて修改】
# リトライするまでの待機時間（秒）
# 60 = 1分
RETRY_INTERVAL=60



# ============================================================
# ② 初期処理
# ここから下は原則として変更不要
# ============================================================

# 現在の日付を YYYY/MM/DD 形式で取得する
# S3のPrefixとして使用する
#
# 例：
# 2026/08/27
DATE=$(date '+%Y/%m/%d')


# 現在日時を取得する
# ログファイル名に使用する
#
# 例：
# 20260827_020000
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')


# S3の最終転送先を作成する
#
# 例：
# s3://bucket/raw/onprem/systemA/2026/08/27/
S3_URI="${S3_BASE_URI}/${DATE}/"


# 今回の実行ログファイル名を作成する
#
# 例：
# /var/log/s3-upload/s3_upload_20260827_020000.log
LOG_FILE="${LOG_DIR}/s3_upload_${TIMESTAMP}.log"


# Archiveディレクトリが存在しない場合は作成する
mkdir -p "${ARCHIVE_DIR}"


# Logディレクトリが存在しない場合は作成する
mkdir -p "${LOG_DIR}"



# ============================================================
# ③ バッチ開始ログ
# ============================================================

# 区切り線をログへ出力
echo "==================================================" >> "${LOG_FILE}"

# バッチ開始時刻をログへ出力
echo "$(date) Upload batch started." >> "${LOG_FILE}"

# 転送元ディレクトリをログへ出力
echo "Source : ${SOURCE_DIR}" >> "${LOG_FILE}"

# 転送先S3をログへ出力
echo "Target : ${S3_URI}" >> "${LOG_FILE}"

# 区切り線をログへ出力
echo "==================================================" >> "${LOG_FILE}"



# ============================================================
# ④ ファイル転送処理
# ============================================================

# 転送対象ファイルが存在したかを判定するための変数
# 0 = 対象なし
# 1 = 対象あり
FOUND_FILE=0


# 転送失敗したファイル数を記録する
ERROR_COUNT=0


# SOURCE_DIR内の対象ファイルを1ファイルずつ処理する
for FILE in ${SOURCE_DIR}/${FILE_PATTERN}
do

    # ファイルが存在しない場合は次へ進む
    if [ ! -f "${FILE}" ]; then
        continue
    fi


    # 転送対象ファイルが存在したことを記録
    FOUND_FILE=1


    # フルパスからファイル名だけを取得
    #
    # 例：
    # /data/export/data.csv
    # ↓
    # data.csv
    FILE_NAME=$(basename "${FILE}")


    # ファイル転送開始ログ
    echo "$(date) Upload start: ${FILE_NAME}" >> "${LOG_FILE}"


    # リトライ回数を1から開始する
    RETRY_COUNT=1


    # 最大リトライ回数まで転送を試行する
    while [ ${RETRY_COUNT} -le ${MAX_RETRY} ]
    do

        # ----------------------------------------------------
        # AWS CLIを使用してファイルをS3へ転送する
        #
        # 例：
        # aws s3 cp /data/export/data.csv \
        # s3://bucket/raw/onprem/systemA/2026/08/27/data.csv
        #
        # コマンドの標準出力・エラー出力はログへ保存する
        # ----------------------------------------------------
        aws s3 cp \
            "${FILE}" \
            "${S3_URI}${FILE_NAME}" \
            >> "${LOG_FILE}" 2>&1


        # 直前のAWS CLIコマンドの終了コードを確認する
        #
        # 0 = 正常終了
        # 0以外 = 異常終了
        if [ $? -eq 0 ]; then

            # 転送成功ログ
            echo "$(date) Upload success: ${FILE_NAME}" >> "${LOG_FILE}"


            # S3転送に成功したファイルをArchiveへ移動する
            mv "${FILE}" "${ARCHIVE_DIR}/"


            # Archive移動ログ
            echo "$(date) Archived: ${FILE_NAME}" >> "${LOG_FILE}"


            # 転送成功したためRetryループを終了する
            break

        else

            # 転送失敗ログ
            echo "$(date) Upload failed: ${FILE_NAME} Retry=${RETRY_COUNT}" \
                >> "${LOG_FILE}"


            # リトライ回数を1増やす
            RETRY_COUNT=$((RETRY_COUNT + 1))


            # 最大回数に達していなければ一定時間待機する
            if [ ${RETRY_COUNT} -le ${MAX_RETRY} ]; then
                sleep ${RETRY_INTERVAL}
            fi

        fi

    done


    # 最大回数リトライしても失敗した場合
    if [ ${RETRY_COUNT} -gt ${MAX_RETRY} ]; then

        # エラーログを出力
        echo "$(date) ERROR: Upload failed after ${MAX_RETRY} retries: ${FILE_NAME}" \
            >> "${LOG_FILE}"


        # 元ファイルは削除・移動せずSOURCE_DIRへ残す
        # 手動再実行可能な状態とする


        # エラー件数を1増やす
        ERROR_COUNT=$((ERROR_COUNT + 1))

    fi

done



# ============================================================
# ⑤ 実行結果判定
# ============================================================

# 転送対象ファイルが1件も存在しなかった場合
if [ ${FOUND_FILE} -eq 0 ]; then

    # 対象ファイルなしとしてログへ記録
    echo "$(date) No upload target files." >> "${LOG_FILE}"

fi


# 1ファイル以上転送に失敗している場合
if [ ${ERROR_COUNT} -gt 0 ]; then

    # バッチ異常終了ログ
    echo "$(date) Batch finished with errors." >> "${LOG_FILE}"


    # Exit Code 1で終了
    # 監視側から異常終了として判定可能
    exit 1

else

    # 全ファイル正常終了ログ
    echo "$(date) Batch finished successfully." >> "${LOG_FILE}"


    # Exit Code 0で正常終了
    exit 0

fi
