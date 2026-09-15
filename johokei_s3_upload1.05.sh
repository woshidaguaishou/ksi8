#!/bin/bash

# ============================================================
# 情報系データ S3転送バッチ
#
# 処理概要：
#   稲沢中継サーバに格納された情報系データを、
#   AWS CLIを使用してデータ利活用基盤のAmazon S3へ転送する。
#
# 転送先Bucket：
#   datautl-prd-gdp-apne1-s3-bucket-johokei-raw
#
# 実行方式：
#   手動実行
#
# 実行例：
#   /bin/bash johokei_s3_upload.sh
#
# 正常時：
#   ・S3への転送成功後、稲沢中継サーバ上の元ファイルを削除する。
#
# 異常時：
#   ・最大3回までRetryする。
#   ・最終的に失敗した場合、元ファイルは削除しない。
#   ・エラーログを出力する。
#
# 二重起動：
#   ・flockを使用して同時実行を禁止する。
#
# 暗号化：
#   ・S3側はSSE-KMSを使用する。
#   ・KMS Key確定後、必要に応じてKMS_KEY_IDへARNを設定する。
#   ・Bucket Default Encryptionを使用する場合は空欄でもよい。
#
# 前提条件：
#   ・Linux Server
#   ・AWS CLI v2がインストールされていること
#   ・AWS CLIの認証設定が完了していること
#   ・対象S3 BucketへのIAM権限が設定されていること
#   ・対象KMS Keyへの必要なIAM/KMS権限が設定されていること
#   ・AWS S3へHTTPS(TCP/443)で通信可能であること
#
# 注意：
#   Access Key / Secret Access Keyなどの認証情報は、
#   本スクリプト内には記載しない。
#
# ============================================================


# ============================================================
# ① AWS側設定
# ============================================================

# 【確定】
# 情報系データ格納先S3 Bucket
S3_BUCKET="s3://datautl-prd-gdp-apne1-s3-bucket-johokei-raw"


# 【IAM/KMS設計確定後に設定】
#
# SSE-KMSで明示的にKMS Keyを指定する場合に設定する。
#
# 例：
# KMS_KEY_ID="arn:aws:kms:ap-northeast-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#
# Bucket側のDefault Encryptionとして対象SSE-KMS Keyが設定済みで、
# Bucket Policy等で明示指定が要求されない場合は空欄でもよい。
#
KMS_KEY_ID=""


# ============================================================
# ② 実機環境設定
# ★ 実機担当者が環境に合わせて設定する
# ============================================================

# 【実機担当設定】
# 稲沢中継サーバ上の情報系データ格納Root Directory
#
# 例：
# /data/johokei
#
SOURCE_ROOT="/PLEASE/SET/SOURCE/DIRECTORY"


# 【実機担当設定】
# 転送対象ファイルPattern
#
# CSVのみ：
# *.csv
#
FILE_PATTERN="*.csv"


# ============================================================
# ③ Script設定
# 原則変更不要
# ============================================================

# Script自身が配置されているDirectory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)


# Local Directory → S3 Prefix対応表
PREFIX_MAP="${SCRIPT_DIR}/prefix_map.conf"


# LogはScript配置Directory配下のlogへ保存する
LOG_DIR="${SCRIPT_DIR}/log"


# 最大転送試行回数
MAX_RETRY=3


# Retry間隔（秒）
RETRY_INTERVAL=60


# 二重起動防止Lock File
LOCK_FILE="/tmp/johokei_s3_upload.lock"


# 対象ファイルが存在しない場合、
# "*.csv"という文字列自体を対象としない
shopt -s nullglob


# ============================================================
# ④ 初期処理
# ============================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')


# Log Directory作成
mkdir -p "${LOG_DIR}"


# 今回のLog File
LOG_FILE="${LOG_DIR}/johokei_s3_upload_${TIMESTAMP}.log"


# ------------------------------------------------------------
# Log出力Function
# ------------------------------------------------------------

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "${LOG_FILE}"
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
# ⑥ バッチ開始
# ============================================================

log "=================================================="
log "Batch started."
log "SOURCE_ROOT : ${SOURCE_ROOT}"
log "S3_BUCKET   : ${S3_BUCKET}"
log "PREFIX_MAP  : ${PREFIX_MAP}"

if [ -n "${KMS_KEY_ID}" ]; then
    log "SSE-KMS     : Explicit KMS Key"
else
    log "SSE-KMS     : S3 Bucket Default Encryption"
fi

log "=================================================="


# ============================================================
# ⑦ 事前チェック
# ============================================================


# ------------------------------------------------------------
# AWS CLI確認
# ------------------------------------------------------------

if ! command -v aws > /dev/null 2>&1; then

    log "ERROR: AWS CLI is not installed."

    exit 1
fi


# ------------------------------------------------------------
# AWS認証確認
#
# IAM設定そのものはAWS側で実施する。
# ここではAWS CLIが有効なAWS Identityを取得できることのみ確認する。
# ------------------------------------------------------------

if ! aws sts get-caller-identity \
    >> "${LOG_FILE}" 2>&1; then

    log "ERROR: AWS authentication failed."

    exit 1
fi


# ------------------------------------------------------------
# Source Directory確認
# ------------------------------------------------------------

if [ ! -d "${SOURCE_ROOT}" ]; then

    log "ERROR: Source directory does not exist: ${SOURCE_ROOT}"

    exit 1
fi


# ------------------------------------------------------------
# Prefix Mapping File確認
# ------------------------------------------------------------

if [ ! -f "${PREFIX_MAP}" ]; then

    log "ERROR: Prefix mapping file does not exist: ${PREFIX_MAP}"

    exit 1
fi


# ============================================================
# ⑧ AWS CLI共通Option作成
# ============================================================

AWS_CP_OPTIONS=(
    --only-show-errors
)


# KMS Key ARNが明示設定されている場合のみ、
# AWS CLIからSSE-KMS Keyを明示指定する。
if [ -n "${KMS_KEY_ID}" ]; then

    AWS_CP_OPTIONS+=(
        --sse aws:kms
        --sse-kms-key-id "${KMS_KEY_ID}"
    )

fi


# ============================================================
# ⑨ 件数初期化
# ============================================================

TARGET_COUNT=0
SUCCESS_COUNT=0
ERROR_COUNT=0


# ============================================================
# ⑩ Prefix Mapping単位でS3転送
#
# prefix_map.conf Format：
#
# LOCAL_SUBDIR|S3_PREFIX
#
# 例：
#
# P01060_AG|P01060_AG
# P01060_AH|P01060_AH
#
# ============================================================

while IFS='|' read -r LOCAL_SUBDIR S3_PREFIX
do

    # Windows改行コード除去
    LOCAL_SUBDIR="${LOCAL_SUBDIR//$'\r'/}"
    S3_PREFIX="${S3_PREFIX//$'\r'/}"


    # 空行Skip
    [ -z "${LOCAL_SUBDIR}" ] && continue


    # コメント行Skip
    case "${LOCAL_SUBDIR}" in
        \#*)
            continue
            ;;
    esac


    # S3 Prefix未設定の場合はError
    if [ -z "${S3_PREFIX}" ]; then

        log "ERROR: S3 Prefix is not defined for ${LOCAL_SUBDIR}"

        ERROR_COUNT=$((ERROR_COUNT + 1))

        continue
    fi


    # --------------------------------------------------------
    # Local/S3 Path生成
    # --------------------------------------------------------

    LOCAL_DIR="${SOURCE_ROOT}/${LOCAL_SUBDIR}"

    S3_URI="${S3_BUCKET}/${S3_PREFIX}/"


    log "--------------------------------------------------"
    log "Transfer target"
    log "Local : ${LOCAL_DIR}"
    log "S3    : ${S3_URI}"


    # --------------------------------------------------------
    # Local Directory不存在
    # --------------------------------------------------------

    if [ ! -d "${LOCAL_DIR}" ]; then

        log "WARNING: Local directory does not exist: ${LOCAL_DIR}"

        continue
    fi


    # ========================================================
    # 対象File取得
    # ========================================================

    FILES=( "${LOCAL_DIR}"/${FILE_PATTERN} )


    if [ ${#FILES[@]} -eq 0 ]; then

        log "No target files: ${LOCAL_DIR}"

        continue
    fi


    # ========================================================
    # File単位転送
    # ========================================================

    for FILE in "${FILES[@]}"
    do

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
            # S3 Upload
            #
            # KMS_KEY_ID設定済みの場合：
            #
            # aws s3 cp FILE S3_URI \
            #   --sse aws:kms \
            #   --sse-kms-key-id KMS_KEY_ID
            #
            # KMS_KEY_ID未設定の場合：
            #
            # Bucket側Default Encryptionを使用する。
            # ------------------------------------------------

            aws s3 cp \
                "${FILE}" \
                "${S3_URI}${FILE_NAME}" \
                "${AWS_CP_OPTIONS[@]}" \
                >> "${LOG_FILE}" 2>&1


            AWS_EXIT_CODE=$?


            # ------------------------------------------------
            # Upload成功
            # ------------------------------------------------

            if [ ${AWS_EXIT_CODE} -eq 0 ]; then

                UPLOAD_SUCCESS=1

                log "Upload success: ${FILE_NAME}"

                break
            fi


            # ------------------------------------------------
            # Upload失敗
            # ------------------------------------------------

            log "WARNING: Upload failed: ${FILE_NAME}, ExitCode=${AWS_EXIT_CODE}"


            ATTEMPT=$((ATTEMPT + 1))


            if [ ${ATTEMPT} -le ${MAX_RETRY} ]; then

                log "Retry after ${RETRY_INTERVAL} seconds."

                sleep ${RETRY_INTERVAL}

            fi

        done


        # ====================================================
        # ⑪ 転送結果処理
        # ====================================================

        if [ ${UPLOAD_SUCCESS} -eq 1 ]; then


            # ------------------------------------------------
            # S3転送成功後のみ、
            # 稲沢中継サーバ上の元Fileを削除する。
            # ------------------------------------------------

            rm -f "${FILE}"


            if [ $? -eq 0 ]; then

                log "Local file deleted: ${FILE}"

                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

            else

                # S3転送成功、Local削除失敗
                log "ERROR: Local file deletion failed: ${FILE}"

                ERROR_COUNT=$((ERROR_COUNT + 1))

            fi


        else

            # ------------------------------------------------
            # S3転送失敗
            #
            # 稲沢中継サーバ上のFileは削除しない。
            # ------------------------------------------------

            log "ERROR: Upload failed after ${MAX_RETRY} attempts: ${FILE_NAME}"

            log "Local file retained: ${FILE}"

            ERROR_COUNT=$((ERROR_COUNT + 1))

        fi

    done


done < "${PREFIX_MAP}"


# ============================================================
# ⑫ 実行結果
# ============================================================

log "=================================================="
log "Target files  : ${TARGET_COUNT}"
log "Success files : ${SUCCESS_COUNT}"
log "Error files   : ${ERROR_COUNT}"


if [ ${TARGET_COUNT} -eq 0 ]; then

    log "No upload target files."
fi


# ------------------------------------------------------------
# 異常終了
# ------------------------------------------------------------

if [ ${ERROR_COUNT} -gt 0 ]; then

    log "Batch finished with errors."
    log "=================================================="

    exit 1
fi


# ------------------------------------------------------------
# 正常終了
# ------------------------------------------------------------

log "Batch finished successfully."
log "=================================================="

exit 0
