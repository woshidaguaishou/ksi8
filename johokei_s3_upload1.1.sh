#!/bin/bash

# ============================================================
# 情報系データ S3転送バッチ
#
# 【概要】
# 稲沢中継サーバに格納された情報系データを
# AWS CLIを使用してデータ利活用基盤S3へ転送する。
#
# 【処理】
# 1. Mapping File読込
# 2. 転送対象ファイル存在確認
# 3. 対象S3 Prefixの既存ファイル削除
# 4. 対象ファイルをS3へ転送
# 5. 転送成功後、中継サーバ上の元ファイル削除
# 6. 全Table正常終了後、_COMPLETEをS3へ格納
#
# 【異常時】
# ・S3 Uploadは最大3回Retry
# ・Upload失敗時は元ファイルを削除しない
# ・1件でも失敗した場合は_COMPLETEを作成しない
#
# 【実行方式】
# 手動実行
#
# 【認証】
# AWS CLI共通IAM Userを使用
# Access Key / Secret Access Keyは本Scriptに記載しない
#
# ============================================================

set -u


# ============================================================
# ① AWS設定
# ============================================================

# 【確定】
S3_BUCKET="s3://datautl-prd-gdp-apne1-s3-bucket-johokei-raw"


# 【IAM設定後に変更】
# AWS CLI Profile名
# Default Profileを使用する場合は空欄
AWS_PROFILE_NAME=""


# 【KMS設計確定後】
# Bucket Default Encryption(SSE-KMS)を利用する場合は空欄
#
# CLIからKMS Keyを明示指定する場合のみ
# KMS Key ARNを設定
#
# 例：
# KMS_KEY_ID="arn:aws:kms:ap-northeast-1:123456789012:key/xxxx"
KMS_KEY_ID=""


# ============================================================
# ② 実機環境設定
# ============================================================

# 【実機担当設定】
# 稲沢中継サーバ上の情報系データ格納Directory
#
# 例：
# SOURCE_DIR="/data/export"
#
SOURCE_DIR="/PLEASE/SET/SOURCE/DIRECTORY"


# ============================================================
# ③ Script設定
# ============================================================

# Script自身の配置Directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)


# Mapping File
FILE_MAP="${SCRIPT_DIR}/file_map.conf"


# Log Directory
LOG_DIR="${SCRIPT_DIR}/log"


# Retry回数
MAX_RETRY=3


# Retry間隔（秒）
RETRY_INTERVAL=60


# 二重起動防止File
LOCK_FILE="/tmp/johokei_s3_upload.lock"


# 対象ファイル無しの場合のglob対策
shopt -s nullglob


# ============================================================
# ④ Log初期化
# ============================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/johokei_s3_upload_${TIMESTAMP}.log"


log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "${LOG_FILE}"
}


# ============================================================
# ⑤ 二重起動防止
# ============================================================

exec 200>"${LOCK_FILE}"

if ! flock -n 200; then

    log "ERROR: Batch is already running."

    exit 2
fi


# ============================================================
# ⑥ AWS CLI Profile
# ============================================================

if [ -n "${AWS_PROFILE_NAME}" ]; then
    export AWS_PROFILE="${AWS_PROFILE_NAME}"
fi


# ============================================================
# ⑦ 開始
# ============================================================

log "=================================================="
log "情報系 S3 Upload Batch Start"
log "SOURCE_DIR : ${SOURCE_DIR}"
log "S3_BUCKET  : ${S3_BUCKET}"
log "FILE_MAP   : ${FILE_MAP}"
log "=================================================="


# ============================================================
# ⑧ 事前Check
# ============================================================

# AWS CLI
if ! command -v aws >/dev/null 2>&1; then

    log "ERROR: AWS CLI is not installed."

    exit 1
fi


# AWS認証
if ! aws sts get-caller-identity >>"${LOG_FILE}" 2>&1; then

    log "ERROR: AWS authentication failed."

    exit 1
fi


# Source Directory
if [ ! -d "${SOURCE_DIR}" ]; then

    log "ERROR: Source directory does not exist: ${SOURCE_DIR}"

    exit 1
fi


# Mapping File
if [ ! -f "${FILE_MAP}" ]; then

    log "ERROR: Mapping file does not exist: ${FILE_MAP}"

    exit 1
fi


# ============================================================
# ⑨ AWS CLI Option
# ============================================================

AWS_CP_OPTIONS=(
    --only-show-errors
)


# KMS KeyをCLIから明示指定する場合
if [ -n "${KMS_KEY_ID}" ]; then

    AWS_CP_OPTIONS+=(
        --sse aws:kms
        --sse-kms-key-id "${KMS_KEY_ID}"
    )

fi


# ============================================================
# ⑩ 件数
# ============================================================

TARGET_COUNT=0
SUCCESS_COUNT=0
ERROR_COUNT=0
TABLE_COUNT=0


# ============================================================
# ⑪ Mapping単位処理
# ============================================================

while IFS='|' read -r FILE_NAME_PREFIX S3_PREFIX
do

    # Windows CRLF対策
    FILE_NAME_PREFIX="${FILE_NAME_PREFIX//$'\r'/}"
    S3_PREFIX="${S3_PREFIX//$'\r'/}"


    # 空行
    [ -z "${FILE_NAME_PREFIX}" ] && continue


    # Comment
    case "${FILE_NAME_PREFIX}" in
        \#*)
            continue
            ;;
    esac


    # Mapping Check
    if [ -z "${S3_PREFIX}" ]; then

        log "ERROR: S3 Prefix is not defined: ${FILE_NAME_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # --------------------------------------------------------
    # 対象ファイル取得
    #
    # 例：
    #
    # AG_保守契約情報_001.csv.gz
    # AG_保守契約情報_002.csv.gz
    #
    # --------------------------------------------------------

    FILES=(
        "${SOURCE_DIR}/${FILE_NAME_PREFIX}_"*.csv.gz
    )


    # 当該TableのFileが無い場合は処理しない
    #
    # 重要：
    # Fileが無い状態でS3既存Fileを削除しないため、
    # S3削除より先に存在確認する。
    #
    if [ ${#FILES[@]} -eq 0 ]; then

        log "INFO: No target files: ${FILE_NAME_PREFIX}"

        continue
    fi


    TABLE_COUNT=$((TABLE_COUNT + 1))

    S3_URI="${S3_BUCKET}/${S3_PREFIX}/"


    log "--------------------------------------------------"
    log "Table       : ${FILE_NAME_PREFIX}"
    log "S3 Prefix   : ${S3_PREFIX}"
    log "File Count  : ${#FILES[@]}"


    # ========================================================
    # ⑫ S3既存File削除
    #
    # Customer Requirement:
    #
    # 新しい月次Fileを格納する前に、
    # 対象Prefix内の前月Fileを削除する。
    #
    # ========================================================

    log "Delete old S3 objects: ${S3_URI}"


    if ! aws s3 rm \
        "${S3_URI}" \
        --recursive \
        --only-show-errors \
        >>"${LOG_FILE}" 2>&1
    then

        log "ERROR: Failed to delete existing S3 objects: ${S3_URI}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        # 削除失敗時は新規FileをUploadしない
        continue
    fi


    log "Old S3 objects deleted."


    # ========================================================
    # ⑬ File単位Upload
    # ========================================================

    for FILE in "${FILES[@]}"
    do

        TARGET_COUNT=$((TARGET_COUNT + 1))

        FILE_NAME=$(basename "${FILE}")

        log "Upload Start : ${FILE_NAME}"
        log "Destination  : ${S3_URI}${FILE_NAME}"


        UPLOAD_SUCCESS=0
        ATTEMPT=1


        # ====================================================
        # Retry
        # ====================================================

        while [ ${ATTEMPT} -le ${MAX_RETRY} ]
        do

            log "Upload attempt ${ATTEMPT}/${MAX_RETRY}: ${FILE_NAME}"


            aws s3 cp \
                "${FILE}" \
                "${S3_URI}${FILE_NAME}" \
                "${AWS_CP_OPTIONS[@]}" \
                >>"${LOG_FILE}" 2>&1


            AWS_EXIT_CODE=$?


            if [ ${AWS_EXIT_CODE} -eq 0 ]; then

                UPLOAD_SUCCESS=1

                log "Upload Success: ${FILE_NAME}"

                break
            fi


            log "WARNING: Upload failed: ${FILE_NAME}, ExitCode=${AWS_EXIT_CODE}"

            ATTEMPT=$((ATTEMPT + 1))


            if [ ${ATTEMPT} -le ${MAX_RETRY} ]; then

                log "Retry after ${RETRY_INTERVAL} seconds."

                sleep "${RETRY_INTERVAL}"

            fi

        done


        # ====================================================
        # ⑭ Upload後処理
        # ====================================================

        if [ ${UPLOAD_SUCCESS} -eq 1 ]; then

            # S3 Upload成功後のみ
            # 中継サーバ上のFileを削除
            if rm -f "${FILE}"; then

                log "Local file deleted: ${FILE_NAME}"

                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

            else

                log "ERROR: Local file deletion failed: ${FILE_NAME}"

                ERROR_COUNT=$((ERROR_COUNT + 1))

            fi

        else

            # Upload失敗時は元File保持
            log "ERROR: Upload failed after ${MAX_RETRY} attempts: ${FILE_NAME}"

            log "Local file retained: ${FILE_NAME}"

            ERROR_COUNT=$((ERROR_COUNT + 1))

        fi

    done


done < "${FILE_MAP}"


# ============================================================
# ⑮ 結果判定
# ============================================================

log "=================================================="
log "Processed Tables : ${TABLE_COUNT}"
log "Target Files     : ${TARGET_COUNT}"
log "Success Files    : ${SUCCESS_COUNT}"
log "Error Files      : ${ERROR_COUNT}"
log "=================================================="


# 1件でもErrorがある場合
#
# _COMPLETEは作成しない
#
if [ ${ERROR_COUNT} -gt 0 ]; then

    log "ERROR: Batch finished with errors."
    log "_COMPLETE will NOT be created."

    exit 1
fi


# ============================================================
# ⑯ _COMPLETE作成
#
# 全TableのS3格納が正常終了したことを示すMarker。
#
# Localに一時的な0Byte Fileを作成し、
# Bucket RootへUploadする。
#
# ============================================================

COMPLETE_FILE="${SCRIPT_DIR}/_COMPLETE"

: > "${COMPLETE_FILE}"


log "Creating completion marker: _COMPLETE"


if aws s3 cp \
    "${COMPLETE_FILE}" \
    "${S3_BUCKET}/_COMPLETE" \
    "${AWS_CP_OPTIONS[@]}" \
    >>"${LOG_FILE}" 2>&1
then

    log "_COMPLETE uploaded successfully."

    rm -f "${COMPLETE_FILE}"

else

    log "ERROR: Failed to upload _COMPLETE."

    rm -f "${COMPLETE_FILE}"

    exit 1
fi


# ============================================================
# ⑰ 正常終了
# ============================================================

log "=================================================="
log "Batch finished successfully."
log "=================================================="

exit 0
