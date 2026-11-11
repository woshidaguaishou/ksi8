#!/usr/bin/env bash
# 情報系データ連携 - 稲沢中継サーバ -> S3(raw)
# 変更点: _COMPLETEをバケット直下(バッチ単位)ではなく、S3 Prefix(テーブル)単位に出力
# 入力: johokei_sftp_pull.shから渡される STAGING_ROOT
# 前提: STAGING_ROOT/.PULL_COMPLETE は全SFTP取得終了後に前段Shellが作成する。
#       このShellは、S3段階でテーブル単位に処理を継続する。

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/transfer_map.conf"
LOG_DIR="${SCRIPT_DIR}/log"

# === 実機環境に合わせて確認・変更する箇所 ===
S3_BUCKET="s3://datautl-prd-gdp-apne1-s3-bucket-johokei-raw"
AWS_PROFILE_NAME="johokei-s3-upload"
AWS_REGION="ap-northeast-1"
KMS_KEY_ID=""  # バケットのデフォルトSSE-KMSを使用する場合は空欄
# =========================================

MAX_RETRIES=3
RETRY_WAIT_SECONDS=60

usage() {
  printf 'Usage: %s <STAGING_ROOT>\n' "$0" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
STAGING_ROOT="${1%/}"
[[ -d "$STAGING_ROOT" ]] || { printf 'ERROR: staging directory does not exist: %s\n' "$STAGING_ROOT" >&2; exit 2; }
[[ -f "$STAGING_ROOT/.PULL_COMPLETE" ]] || {
  printf 'ERROR: .PULL_COMPLETE is missing. SFTP pull has not completed.\n' >&2
  exit 2
}
[[ -f "$CONF_FILE" ]] || { printf 'ERROR: transfer_map.conf is missing.\n' >&2; exit 2; }
command -v aws >/dev/null 2>&1 || { printf 'ERROR: aws CLI not found.\n' >&2; exit 2; }
command -v flock >/dev/null 2>&1 || { printf 'ERROR: flock not found.\n' >&2; exit 2; }
mkdir -p -- "$LOG_DIR" || exit 2
LOG_FILE="${LOG_DIR}/johokei_s3_upload_$(date '+%Y%m%d_%H%M%S')_$$.log"
exec > >(tee -a "$LOG_FILE") 2>&1

exec 9>/tmp/johokei_s3_upload.lock
if ! flock -n 9; then
  echo "ERROR: another S3 upload process is already running"
  exit 1
fi

# 前段SFTP成功後の再実行で、処理済みテーブルの再アップロード/Glue再起動を避ける。
# 全テーブル正常終了後に削除するため、失敗時は残す。
DONE_DIR="${STAGING_ROOT}/.S3_TABLE_DONE"
mkdir -p -- "$DONE_DIR" || exit 2
[[ -w "$DONE_DIR" ]] || { echo "ERROR: cannot write progress directory: $DONE_DIR"; exit 2; }

AWS=(aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION")
SSE_ARGS=()
if [[ -n "$KMS_KEY_ID" ]]; then
  SSE_ARGS=(--sse aws:kms --sse-kms-key-id "$KMS_KEY_ID")
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

run_retry() {
  local attempt
  for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    if "${AWS[@]}" "$@"; then
      return 0
    fi
    log "WARN: AWS CLI failed (attempt ${attempt}/${MAX_RETRIES}): $*"
    if (( attempt < MAX_RETRIES )); then
      sleep "$RETRY_WAIT_SECONDS"
    fi
  done
  return 1
}

# 先に設定を読み込んで検証し、誤ったPrefixへの削除を防止する。
PREFIXES=()
FILE_PREFIXES=()
LINE_NUMS=()
declare -A SEEN_PREFIX=()
line_no=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_no+=1))
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" == \#* || "$line" == ENABLE\|* ]] && continue
  IFS='|' read -r enable source_user source_host source_port remote_dir file_prefix s3_prefix extra <<< "$line"
  [[ "$enable" == "N" ]] && continue
  if [[ "$enable" != "Y" || -n "${extra:-}" || -z "$file_prefix" || -z "$s3_prefix" ]]; then
    log "ERROR: invalid mapping on line $line_no"
    exit 2
  fi
  # 末尾/の有無は吸収。Bucketルートや相対移動パスへの誤削除を防止する。
  s3_prefix="${s3_prefix%/}"
  if [[ ! "$s3_prefix" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ || "$s3_prefix" == *..* || "$s3_prefix" == *//* || "$s3_prefix" == */_COMPLETE ]]; then
    log "ERROR: unsafe S3_PREFIX on line $line_no: $s3_prefix"
    exit 2
  fi
  if [[ "$file_prefix" == *'/'* || "$file_prefix" == *'*'* || "$file_prefix" == *'?'* || "$file_prefix" == *'['* || "$file_prefix" == *']'* || "$file_prefix" == *'|'* ]]; then
    log "ERROR: invalid FILE_NAME_PREFIX on line $line_no"
    exit 2
  fi
  if [[ -n "${SEEN_PREFIX[$s3_prefix]+x}" ]]; then
    log "ERROR: duplicate S3_PREFIX in enabled mappings: $s3_prefix"
    exit 2
  fi
  SEEN_PREFIX[$s3_prefix]=1
  PREFIXES+=("$s3_prefix")
  FILE_PREFIXES+=("$file_prefix")
  LINE_NUMS+=("$line_no")
done < "$CONF_FILE"

if (( ${#PREFIXES[@]} == 0 )); then
  log "ERROR: no enabled table found in transfer_map.conf"
  exit 2
fi

log "START S3 upload tables=${#PREFIXES[@]}, bucket=$S3_BUCKET, profile=$AWS_PROFILE_NAME"

# 旧仕様のバケット直下マーカーが残っていた場合、誤検知を避けるため削除。
if ! run_retry s3 rm "${S3_BUCKET}/_COMPLETE" --only-show-errors; then
  log "ERROR: unable to remove legacy bucket-root _COMPLETE"
  exit 1
fi

# 0Byteの_COMPLETE用一時ファイル。
COMPLETE_FILE="$(mktemp)" || exit 2
trap 'rm -f -- "$COMPLETE_FILE"' EXIT
: > "$COMPLETE_FILE"

failed=0
succeeded=0
skipped=0

for ((idx=0; idx<${#PREFIXES[@]}; idx++)); do
  s3_prefix="${PREFIXES[idx]}"
  file_prefix="${FILE_PREFIXES[idx]}"
  local_dir="${STAGING_ROOT}/${s3_prefix}"
  target="${S3_BUCKET}/${s3_prefix}"
  # 同一バッチの再実行を識別するローカル進捗ファイル。
  state_name="${s3_prefix//\//__}.done"
  done_file="${DONE_DIR}/${state_name}"

  if [[ -f "$done_file" ]]; then
    log "SKIP (already completed this batch): $s3_prefix"
    ((skipped+=1))
    continue
  fi

  log "START TABLE: $s3_prefix (mapping line ${LINE_NUMS[idx]})"

  # 前回の_COMPLETEが残っていると今回失敗時の完了判定に使われてしまう。
  if ! run_retry s3 rm "${target}/_COMPLETE" --only-show-errors; then
    log "ERROR: cannot clear old marker: ${target}/_COMPLETE"
    ((failed+=1))
    continue
  fi

  # nullglobにより対象ファイルが無い場合は空配列になる。
  shopt -s nullglob
  files=("${local_dir}/${file_prefix}"_*.csv.gz)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    log "ERROR: no matching file in $local_dir for ${file_prefix}_*.csv.gz"
    ((failed+=1))
    continue
  fi

  # 旧形式と同様、対象Prefix内の旧csv.gzを削除する。初期ロードの.csvは触らない。
  if ! run_retry s3 rm "${target}/" --recursive --exclude '*' --include '*.csv.gz' --only-show-errors; then
    log "ERROR: failed to delete old csv.gz in $s3_prefix"
    ((failed+=1))
    continue
  fi

  table_ok=1
  for src in "${files[@]}"; do
    name="$(basename -- "$src")"
    log "UPLOAD: ${name} -> ${target}/${name}"
    if ! run_retry s3 cp "$src" "${target}/${name}" "${SSE_ARGS[@]}" --only-show-errors; then
      log "ERROR: upload failed: $s3_prefix/$name"
      table_ok=0
      break
    fi
  done

  if (( table_ok == 0 )); then
    log "ERROR: table incomplete, no _COMPLETE: $s3_prefix"
    ((failed+=1))
    continue
  fi

  # このPrefix内のすべてのファイルが正常アップロードされた場合のみ出力。
  if ! run_retry s3 cp "$COMPLETE_FILE" "${target}/_COMPLETE" "${SSE_ARGS[@]}" --only-show-errors; then
    log "ERROR: marker upload failed: $s3_prefix"
    ((failed+=1))
    continue
  fi

  # 完了後の再実行時にGlueが二重起動しないよう、処理済み状態を保持する。
  if ! printf '%s\n' "$(date '+%F %T')" > "${done_file}.tmp" || ! mv -f -- "${done_file}.tmp" "$done_file"; then
    log "ERROR: unable to save local completion state: $s3_prefix"
    ((failed+=1))
    continue
  fi

  # 従来仕様: S3転送完了済みの中継ファイルは削除。
  for src in "${files[@]}"; do
    if ! rm -f -- "$src"; then
      log "WARN: cannot delete staging file after successful upload: $src"
    fi
  done
  ((succeeded+=1))
  log "DONE TABLE: ${target}/_COMPLETE"
done

log "RESULT: succeeded=$succeeded, skipped=$skipped, failed=$failed"
if (( failed > 0 )); then
  log "ERROR: some tables failed. Completed tables remain usable; pending tables can be retried."
  log "RETRY: bash ${SCRIPT_DIR}/johokei_s3_upload.sh ${STAGING_ROOT}"
  exit 1
fi

# 全テーブルが終了した時のみ前段との引継ぎマーカーと進捗状態を削除。
rm -f -- "${STAGING_ROOT}/.PULL_COMPLETE" || { log "ERROR: cannot remove .PULL_COMPLETE"; exit 1; }
for prefix in "${PREFIXES[@]}"; do
  rm -f -- "${DONE_DIR}/${prefix//\//__}.done" || { log "ERROR: cannot remove progress marker for $prefix"; exit 1; }
done
rmdir -- "$DONE_DIR" 2>/dev/null || true
log "SUCCESS: all enabled tables completed (per-prefix _COMPLETE)."
exit 0
