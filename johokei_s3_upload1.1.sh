#!/bin/bash

# ============================================================
# 情報系データ S3転送バッチ
#
# 本Scriptは johokei_sftp_pull.sh の後続処理として実行する。
#
# .PULL_COMPLETE が存在しない場合は、
# S3転送を実施しない。
#
# ============================================================

set -u
shopt -s nullglob


# ============================================================
# ① 引数
# ============================================================

if [ $# -ne 1 ]; then

    echo "Usage:"
    echo "  $0 <STAGING_ROOT>"

    exit 1
fi


STAGING_ROOT="$1"


# ============================================================
# ② AWS設定
# ============================================================

S3_BUCKET="s3://datautl-prd-gdp-apne1-s3-bucket-johokei-raw"


# 【IAM/KMS設計確定後】
AWS_PROFILE_NAME=""

KMS_KEY_ID=""


# ============================================================
# ③ Script設定
# ============================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

TRANSFER_MAP="${SCRIPT_DIR}/transfer_map.conf"

LOG_DIR="${SCRIPT_DIR}/log"

mkdir -p "${LOG_DIR}"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

LOG_FILE="${LOG_DIR}/johokei_s3_upload_${TIMESTAMP}.log"

LOCK_FILE="/tmp/johokei_s3_upload.lock"

MAX_RETRY=3

RETRY_INTERVAL=60


log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "${LOG_FILE}"
}


# ============================================================
# ④ 二重起動防止
# ============================================================

exec 200>"${LOCK_FILE}"

if ! flock -n 200; then

    log "ERROR: S3 Upload Batch is already running."

    exit 2
fi


# ============================================================
# ⑤ 前段処理完了確認
#
# ここが2つのScriptの連携ポイント
# ============================================================

if [ ! -f "${STAGING_ROOT}/.PULL_COMPLETE" ]; then

    log "ERROR: .PULL_COMPLETE not found."
    log "SFTP Pull Batch has not completed successfully."

    exit 1
fi


# ============================================================
# ⑥ AWS Profile
# ============================================================

if [ -n "${AWS_PROFILE_NAME}" ]; then
    export AWS_PROFILE="${AWS_PROFILE_NAME}"
fi


# ============================================================
# ⑦ 事前Check
# ============================================================

if ! command -v aws >/dev/null 2>&1; then

    log "ERROR: AWS CLI is not installed."

    exit 1
fi


if ! aws sts get-caller-identity \
    >> "${LOG_FILE}" 2>&1; then

    log "ERROR: AWS authentication failed."

    exit 1
fi


if [ ! -f "${TRANSFER_MAP}" ]; then

    log "ERROR: transfer_map.conf not found."

    exit 1
fi


# ============================================================
# ⑧ AWS CLI Option
# ============================================================

AWS_CP_OPTIONS=(
    --only-show-errors
)


if [ -n "${KMS_KEY_ID}" ]; then

    AWS_CP_OPTIONS+=(
        --sse aws:kms
        --sse-kms-key-id "${KMS_KEY_ID}"
    )

fi


# ============================================================
# ⑨ 前回_COMPLETE削除
#
# 新しい転送処理中に前回の_COMPLETEが残らないようにする
# ============================================================

log "Removing previous _COMPLETE marker."


aws s3 rm \
    "${S3_BUCKET}/_COMPLETE" \
    --only-show-errors \
    >> "${LOG_FILE}" 2>&1


# ============================================================
# ⑩ 初期化
# ============================================================

ERROR_COUNT=0
TABLE_COUNT=0
FILE_COUNT=0


# ============================================================
# ⑪ Table単位処理
# ============================================================

while IFS='|' read -r \
    ENABLE \
    SOURCE_USER \
    SOURCE_HOST \
    SOURCE_PORT \
    REMOTE_DIR \
    FILE_NAME_PREFIX \
    S3_PREFIX
do

    ENABLE="${ENABLE//$'\r'/}"
    S3_PREFIX="${S3_PREFIX//$'\r'/}"


    [ -z "${ENABLE}" ] && continue


    case "${ENABLE}" in
        \#*)
            continue
            ;;
    esac


    [ "${ENABLE}" != "Y" ] && continue


    # Prefix安全Check
    if [[ ! "${S3_PREFIX}" =~ ^[A-Za-z0-9_-]+$ ]]; then

        log "ERROR: Invalid S3 Prefix: ${S3_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    LOCAL_DIR="${STAGING_ROOT}/${S3_PREFIX}"

    S3_URI="${S3_BUCKET}/${S3_PREFIX}/"


    FILES=(
        "${LOCAL_DIR}/${FILE_NAME_PREFIX}_"*.csv.gz
    )


    if [ ${#FILES[@]} -eq 0 ]; then

        log "ERROR: Target file not found: ${FILE_NAME_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    TABLE_COUNT=$((TABLE_COUNT + 1))


    log "--------------------------------------------------"
    log "Table      : ${FILE_NAME_PREFIX}"
    log "S3 Prefix  : ${S3_PREFIX}"
    log "File Count : ${#FILES[@]}"


    # ========================================================
    # S3旧File削除
    #
    # CSV.GZのみ削除
    #
    # 他のObjectを誤って削除しない
    # ========================================================

    log "Deleting previous files from: ${S3_URI}"


    if ! aws s3 rm \
        "${S3_URI}" \
        --recursive \
        --exclude "*" \
        --include "*.csv.gz" \
        --only-show-errors \
        >> "${LOG_FILE}" 2>&1
    then

        log "ERROR: Failed to delete previous S3 files."

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # ========================================================
    # 新File Upload
    # ========================================================

    TABLE_UPLOAD_SUCCESS=1


    for FILE in "${FILES[@]}"
    do

        FILE_NAME=$(basename "${FILE}")

        FILE_COUNT=$((FILE_COUNT + 1))

        ATTEMPT=1
        FILE_SUCCESS=0


        while [ ${ATTEMPT} -le ${MAX_RETRY} ]
        do

            log "Upload attempt ${ATTEMPT}/${MAX_RETRY}: ${FILE_NAME}"


            aws s3 cp \
                "${FILE}" \
                "${S3_URI}${FILE_NAME}" \
                "${AWS_CP_OPTIONS[@]}" \
                >> "${LOG_FILE}" 2>&1


            if [ $? -eq 0 ]; then

                FILE_SUCCESS=1

                log "Upload success: ${FILE_NAME}"

                break
            fi


            ATTEMPT=$((ATTEMPT + 1))


            if [ ${ATTEMPT} -le ${MAX_RETRY} ]; then

                sleep "${RETRY_INTERVAL}"

            fi

        done


        if [ ${FILE_SUCCESS} -ne 1 ]; then

            log "ERROR: Upload failed: ${FILE_NAME}"

            TABLE_UPLOAD_SUCCESS=0

            ERROR_COUNT=$((ERROR_COUNT + 1))

            break
        fi

    done


    # ========================================================
    # Table単位で全File成功した場合のみLocal File削除
    # ========================================================

    if [ ${TABLE_UPLOAD_SUCCESS} -eq 1 ]; then

        for FILE in "${FILES[@]}"
        do

            rm -f "${FILE}"

        done


        log "Local files deleted: ${S3_PREFIX}"

    else

        log "Local files retained: ${S3_PREFIX}"

    fi


done < "${TRANSFER_MAP}"


# ============================================================
# ⑫ Error判定
# ============================================================

if [ ${ERROR_COUNT} -gt 0 ]; then

    log "=================================================="
    log "ERROR: S3 Upload Batch failed."
    log "_COMPLETE will NOT be created."
    log ".PULL_COMPLETE will be retained."
    log "=================================================="

    exit 1
fi


# ============================================================
# ⑬ _COMPLETE
# ============================================================

COMPLETE_FILE="${STAGING_ROOT}/_COMPLETE"

: > "${COMPLETE_FILE}"


if ! aws s3 cp \
    "${COMPLETE_FILE}" \
    "${S3_BUCKET}/_COMPLETE" \
    "${AWS_CP_OPTIONS[@]}" \
    >> "${LOG_FILE}" 2>&1
then

    log "ERROR: Failed to upload _COMPLETE."

    rm -f "${COMPLETE_FILE}"

    exit 1
fi


rm -f "${COMPLETE_FILE}"


# ============================================================
# ⑭ Pull Marker削除
#
# 前段・後段すべて正常終了したことを意味する
# ============================================================

rm -f "${STAGING_ROOT}/.PULL_COMPLETE"


log "=================================================="
log "S3 Upload Batch completed successfully."
log "Processed Tables : ${TABLE_COUNT}"
log "Processed Files  : ${FILE_COUNT}"
log "_COMPLETE created."
log "=================================================="

exit 0
