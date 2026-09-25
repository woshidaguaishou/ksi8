#!/bin/bash

# ============================================================
# 情報系データ SFTP取得バッチ
#
# 処理概要：
#   情報系データ元サーバからSFTPを使用して、
#   稲沢中継サーバへファイルを取得する。
#
#   全対象データの取得に成功した場合のみ、
#   johokei_s3_upload.sh を自動実行する。
#
# 処理フロー：
#
#   Source Server
#        ↓ SFTP
#   稲沢中継Server
#        ↓
#   .PULL_COMPLETE
#        ↓
#   johokei_s3_upload.sh
#        ↓
#   Amazon S3
#
# 正常時：
#   ・SFTP取得成功後、Source側ファイルを削除
#
# 異常時：
#   ・Source側ファイルは削除しない
#   ・S3転送バッチは起動しない
#
# 実行方式：
#   手動実行
#
# ============================================================

set -u
shopt -s nullglob


# ============================================================
# ① Script共通設定
# ============================================================

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

TRANSFER_MAP="${SCRIPT_DIR}/transfer_map.conf"

S3_UPLOAD_SCRIPT="${SCRIPT_DIR}/johokei_s3_upload.sh"


# 【実機担当設定】
#
# 稲沢中継サーバ上の作業Directory
#
# 最終的には例えば：
#
# /data/johokei/P01060_AG/
# /data/johokei/P01060_AH/
#
# のようにS3 Prefix単位で格納する。
#
STAGING_ROOT="/PLEASE/SET/STAGING/DIRECTORY"


# Log
LOG_DIR="${SCRIPT_DIR}/log"

mkdir -p "${LOG_DIR}"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

LOG_FILE="${LOG_DIR}/johokei_sftp_pull_${TIMESTAMP}.log"


# 二重起動防止
LOCK_FILE="/tmp/johokei_sftp_pull.lock"


log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "${LOG_FILE}"
}


# ============================================================
# ② 二重起動防止
# ============================================================

exec 200>"${LOCK_FILE}"

if ! flock -n 200; then

    log "ERROR: SFTP batch is already running."

    exit 2
fi


# ============================================================
# ③ 事前Check
# ============================================================

if ! command -v sftp >/dev/null 2>&1; then

    log "ERROR: sftp command is not installed."

    exit 1
fi


if [ ! -f "${TRANSFER_MAP}" ]; then

    log "ERROR: transfer_map.conf not found."

    exit 1
fi


if [ ! -f "${S3_UPLOAD_SCRIPT}" ]; then

    log "ERROR: S3 upload script not found."

    exit 1
fi


mkdir -p "${STAGING_ROOT}"


# 前回のPull完了Markerが残っている場合は削除しない。
#
# S3転送未完了の可能性があるため、
# 新しい取得処理を開始しない。
if [ -f "${STAGING_ROOT}/.PULL_COMPLETE" ]; then

    log "ERROR: Previous transfer data is still waiting for S3 upload."
    log "Please complete S3 upload first."

    exit 1
fi


# ============================================================
# ④ 初期化
# ============================================================

ERROR_COUNT=0
TARGET_COUNT=0
SUCCESS_COUNT=0


log "=================================================="
log "SFTP Pull Batch Start"
log "STAGING_ROOT : ${STAGING_ROOT}"
log "=================================================="


# ============================================================
# ⑤ Mapping単位で取得
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

    # CRLF除去
    ENABLE="${ENABLE//$'\r'/}"
    S3_PREFIX="${S3_PREFIX//$'\r'/}"


    # 空行
    [ -z "${ENABLE}" ] && continue


    # Comment
    case "${ENABLE}" in
        \#*)
            continue
            ;;
    esac


    # 無効行
    [ "${ENABLE}" != "Y" ] && continue


    TARGET_COUNT=$((TARGET_COUNT + 1))


    # 必須項目Check
    if [ -z "${SOURCE_USER}" ] ||
       [ -z "${SOURCE_HOST}" ] ||
       [ -z "${SOURCE_PORT}" ] ||
       [ -z "${REMOTE_DIR}" ] ||
       [ -z "${FILE_NAME_PREFIX}" ] ||
       [ -z "${S3_PREFIX}" ]; then

        log "ERROR: Invalid mapping entry."

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # Prefix安全Check
    #
    # 意図しないDirectory / S3 Pathを作らないため
    if [[ ! "${S3_PREFIX}" =~ ^[A-Za-z0-9_-]+$ ]]; then

        log "ERROR: Invalid S3 Prefix: ${S3_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # --------------------------------------------------------
    # 中継Server格納先
    # --------------------------------------------------------

    LOCAL_DIR="${STAGING_ROOT}/${S3_PREFIX}"

    mkdir -p "${LOCAL_DIR}"


    log "--------------------------------------------------"
    log "Source Host : ${SOURCE_HOST}"
    log "Remote Dir  : ${REMOTE_DIR}"
    log "File Prefix : ${FILE_NAME_PREFIX}"
    log "Local Dir   : ${LOCAL_DIR}"


    # ========================================================
    # SFTP取得
    #
    # 例：
    #
    # AG_保守契約情報_001.csv.gz
    # AG_保守契約情報_002.csv.gz
    #
    # ========================================================

    sftp \
        -q \
        -oBatchMode=yes \
        -P "${SOURCE_PORT}" \
        -b - \
        "${SOURCE_USER}@${SOURCE_HOST}" \
        >> "${LOG_FILE}" 2>&1 <<EOF
cd "${REMOTE_DIR}"
lcd "${LOCAL_DIR}"
get "${FILE_NAME_PREFIX}_"*.csv.gz
EOF


    SFTP_EXIT_CODE=$?


    if [ ${SFTP_EXIT_CODE} -ne 0 ]; then

        log "ERROR: SFTP download failed: ${FILE_NAME_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # ========================================================
    # Local File確認
    # ========================================================

    FILES=(
        "${LOCAL_DIR}/${FILE_NAME_PREFIX}_"*.csv.gz
    )


    if [ ${#FILES[@]} -eq 0 ]; then

        log "ERROR: Downloaded file not found: ${FILE_NAME_PREFIX}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    log "Download success: ${#FILES[@]} file(s)"


    # ========================================================
    # Source File削除
    #
    # 中継Serverへの取得成功確認後のみ実施
    # ========================================================

    DELETE_BATCH="${STAGING_ROOT}/.delete_${S3_PREFIX}_${TIMESTAMP}.txt"


    {
        echo "cd \"${REMOTE_DIR}\""

        for FILE in "${FILES[@]}"
        do

            FILE_NAME=$(basename "${FILE}")

            echo "rm \"${FILE_NAME}\""

        done

    } > "${DELETE_BATCH}"


    sftp \
        -q \
        -oBatchMode=yes \
        -P "${SOURCE_PORT}" \
        -b "${DELETE_BATCH}" \
        "${SOURCE_USER}@${SOURCE_HOST}" \
        >> "${LOG_FILE}" 2>&1


    DELETE_EXIT_CODE=$?


    rm -f "${DELETE_BATCH}"


    if [ ${DELETE_EXIT_CODE} -ne 0 ]; then

        log "ERROR: Source file deletion failed: ${FILE_NAME_PREFIX}"

        # Local Fileは残す
        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    log "Source files deleted successfully."

    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))


done < "${TRANSFER_MAP}"


# ============================================================
# ⑥ Pull結果判定
# ============================================================

log "=================================================="
log "Target Tables  : ${TARGET_COUNT}"
log "Success Tables : ${SUCCESS_COUNT}"
log "Error Tables   : ${ERROR_COUNT}"
log "=================================================="


# 1件でも失敗した場合
#
# S3 Uploadは開始しない
#
if [ ${ERROR_COUNT} -gt 0 ]; then

    log "ERROR: SFTP Pull Batch failed."
    log "S3 Upload Batch will NOT be started."

    exit 1
fi


# ============================================================
# ⑦ Pull完了Marker
# ============================================================

touch "${STAGING_ROOT}/.PULL_COMPLETE"


log "All source files were downloaded successfully."
log ".PULL_COMPLETE created."


# ============================================================
# ⑧ S3 Upload Script自動実行
# ============================================================

log "Starting S3 Upload Batch."


/bin/bash \
    "${S3_UPLOAD_SCRIPT}" \
    "${STAGING_ROOT}"


S3_EXIT_CODE=$?


# ============================================================
# ⑨ 最終結果
# ============================================================

if [ ${S3_EXIT_CODE} -ne 0 ]; then

    log "ERROR: S3 Upload Batch failed."
    log ".PULL_COMPLETE is retained for retry."

    exit 1
fi


log "S3 Upload Batch completed successfully."
log "=================================================="
log "All transfer processing completed successfully."
log "=================================================="

exit 0
