#!/bin/bash

# ============================================================
# 情報系データ S3転送バッチ
#
# 処理概要：
#   稲沢中継サーバに格納された情報系データを、
#   AWS CLIを使用してデータ利活用基盤のAmazon S3へ転送する。
#
#   転送先S3：
#   datautl-prd-gdp-apne1-s3-bucket-johokei-raw
#
#   転送先Prefixについては prefix_map.conf に定義する。
#
# 正常時：
#   ・S3への転送が成功したファイルは、
#     稲沢中継サーバ上から削除する。
#
# 異常時：
#   ・最大3回までRetryする。
#   ・最終的に失敗した場合、元ファイルは削除しない。
#   ・エラーログを出力する。
#
# 二重起動：
#   ・flockを使用し、同時実行を禁止する。
#
# 前提条件：
#   ・Linux Server
#   ・AWS CLI v2がインストール済みであること
#   ・AWS CLIの認証設定が完了していること
#   ・対象S3 BucketへのPutObject権限があること
#   ・AWS S3へHTTPS(TCP/443)で通信可能であること
#
# 定期実行：
#   ・cronにて設定する。
#   ・具体的な実行時刻は実機構築時に設定する。
# ============================================================


# ============================================================
# ① 設定値
# ============================================================


# 【確定】
# 情報系データ格納先S3 Bucket
S3_BUCKET="s3://datautl-prd-gdp-apne1-s3-bucket-johokei-raw"


# 【実機担当入力】
# 稲沢中継サーバ上の情報系データ格納ルートディレクトリ
#
# 設定例：
# /data/johokei
#
SOURCE_ROOT="/PLEASE/SET/SOURCE/DIRECTORY"


# 【実機担当入力】
# Prefix対応表
#
# 各ローカルディレクトリとS3 Prefixの対応を記載する。
PREFIX_MAP="/opt/scripts/prefix_map.conf"


# 【必要に応じて変更】
# 転送対象ファイル
#
# 現時点ではCSVを想定
FILE_PATTERN="*.csv"


# 【設計値】
# 最大転送試行回数
MAX_RETRY=3


# 【設計値】
# Retry間隔（秒）
RETRY_INTERVAL=60


# 【実機担当入力】
# ログ保存ディレクトリ
LOG_DIR="/var/log/johokei-s3-upload"


# 【原則変更不要】
# 二重起動防止Lock File
LOCK_FILE="/tmp/johokei_s3_upload.lock"



# ============================================================
# ② 初期処理
# ============================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/johokei_s3_upload_${TIMESTAMP}.log"


# ------------------------------------------------------------
# Log出力用Function
# ------------------------------------------------------------

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "${LOG_FILE}"
}



# ============================================================
# ③ 二重起動防止
# ============================================================

exec 200>"${LOCK_FILE}"

flock -n 200

if [ $? -ne 0 ]; then
    log "ERROR: Batch is already running."
    exit 2
fi



# ============================================================
# ④ バッチ開始
# ============================================================

log "=================================================="
log "Batch started."
log "SOURCE_ROOT : ${SOURCE_ROOT}"
log "S3_BUCKET   : ${S3_BUCKET}"
log "PREFIX_MAP  : ${PREFIX_MAP}"
log "=================================================="



# ============================================================
# ⑤ 事前チェック
# ============================================================


# AWS CLI確認
if ! command -v aws > /dev/null 2>&1; then

    log "ERROR: AWS CLI is not installed."

    exit 1
fi


# 転送元ルートディレクトリ確認
if [ ! -d "${SOURCE_ROOT}" ]; then

    log "ERROR: Source directory does not exist: ${SOURCE_ROOT}"

    exit 1
fi


# Prefix Mapping File確認
if [ ! -f "${PREFIX_MAP}" ]; then

    log "ERROR: Prefix mapping file does not exist: ${PREFIX_MAP}"

    exit 1
fi



# ============================================================
# ⑥ 転送件数初期化
# ============================================================

TARGET_COUNT=0
SUCCESS_COUNT=0
ERROR_COUNT=0



# ============================================================
# ⑦ Prefix Mapping単位でS3転送
#
# prefix_map.conf形式：
#
# ローカルディレクトリ|S3プレフィックス
#
# 例：
# P01060_AG|P01060_AG
# P01060_AH|P01060_AH
#
# ============================================================

while IFS='|' read -r LOCAL_SUBDIR S3_PREFIX
do

    # 空行をSkip
    [ -z "${LOCAL_SUBDIR}" ] && continue


    # コメント行をSkip
    case "${LOCAL_SUBDIR}" in
        \#*)
            continue
            ;;
    esac


    LOCAL_DIR="${SOURCE_ROOT}/${LOCAL_SUBDIR}"

    S3_URI="${S3_BUCKET}/${S3_PREFIX}/"


    log "--------------------------------------------------"
    log "Transfer target"
    log "Local : ${LOCAL_DIR}"
    log "S3    : ${S3_URI}"


    # --------------------------------------------------------
    # ローカルディレクトリが存在しない場合
    # --------------------------------------------------------

    if [ ! -d "${LOCAL_DIR}" ]; then

        log "WARNING: Local directory does not exist: ${LOCAL_DIR}"

        continue
    fi


    # --------------------------------------------------------
    # 対象ファイルを1ファイルずつ処理
    # --------------------------------------------------------

    for FILE in "${LOCAL_DIR}"/${FILE_PATTERN}
    do

        # ファイルが存在しない場合
        if [ ! -f "${FILE}" ]; then
            continue
        fi


        TARGET_COUNT=$((TARGET_COUNT + 1))

        FILE_NAME=$(basename "${FILE}")


        log "Upload start: ${FILE_NAME}"


        UPLOAD_SUCCESS=0

        ATTEMPT=1


        # ====================================================
        # Retry処理
        # ====================================================

        while [ ${ATTEMPT} -le ${MAX_RETRY} ]
        do

            log "Upload attempt ${ATTEMPT}/${MAX_RETRY}: ${FILE_NAME}"


            # ------------------------------------------------
            # S3へファイル転送
            # ------------------------------------------------

            aws s3 cp \
                "${FILE}" \
                "${S3_URI}${FILE_NAME}" \
                --only-show-errors \
                >> "${LOG_FILE}" 2>&1


            AWS_EXIT_CODE=$?


            # ------------------------------------------------
            # 正常終了
            # ------------------------------------------------

            if [ ${AWS_EXIT_CODE} -eq 0 ]; then

                UPLOAD_SUCCESS=1

                log "Upload success: ${FILE_NAME}"

                break
            fi


            # ------------------------------------------------
            # 異常終了
            # ------------------------------------------------

            log "WARNING: Upload failed: ${FILE_NAME}, ExitCode=${AWS_EXIT_CODE}"


            ATTEMPT=$((ATTEMPT + 1))


            if [ ${ATTEMPT} -le ${MAX_RETRY} ]; then

                log "Retry after ${RETRY_INTERVAL} seconds."

                sleep ${RETRY_INTERVAL}

            fi

        done



        # ====================================================
        # ⑧ 転送結果処理
        # ====================================================


        # ----------------------------------------------------
        # S3転送成功
        # ----------------------------------------------------

        if [ ${UPLOAD_SUCCESS} -eq 1 ]; then


            # S3転送成功後のみ
            # 稲沢中継サーバ上の元ファイルを削除する
            rm -f "${FILE}"


            if [ $? -eq 0 ]; then

                log "Local file deleted: ${FILE_NAME}"

                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

            else

                # S3転送は成功したが、
                # 中継サーバ上のファイル削除に失敗
                log "ERROR: Local file deletion failed: ${FILE}"

                ERROR_COUNT=$((ERROR_COUNT + 1))

            fi


        # ----------------------------------------------------
        # S3転送失敗
        # ----------------------------------------------------

        else

            # 転送失敗時は元ファイルを削除しない
            log "ERROR: Upload failed after ${MAX_RETRY} attempts: ${FILE_NAME}"

            log "Local file retained: ${FILE}"

            ERROR_COUNT=$((ERROR_COUNT + 1))

        fi

    done


done < "${PREFIX_MAP}"



# ============================================================
# ⑨ 実行結果
# ============================================================

log "=================================================="
log "Target files  : ${TARGET_COUNT}"
log "Success files : ${SUCCESS_COUNT}"
log "Error files   : ${ERROR_COUNT}"


# 転送対象なし
if [ ${TARGET_COUNT} -eq 0 ]; then

    log "No upload target files."

fi


# 1件以上エラーあり
if [ ${ERROR_COUNT} -gt 0 ]; then

    log "Batch finished with errors."
    log "=================================================="

    exit 1
fi


# 正常終了
log "Batch finished successfully."
log "=================================================="

exit 0
