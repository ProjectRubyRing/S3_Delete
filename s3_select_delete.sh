#!/bin/bash
###############################################################################
# s3_select_delete.sh
#
# 概要:
#   指定したAWSアカウント / S3バケットを対象に、ディレクトリ(プレフィックス)
#   またはファイル(オブジェクト)を一覧表示し、利用者が番号で選択した対象を
#   安全に削除するRHEL 9対応の対話型Bashスクリプト。
#
#   - AWS認証状態の確認 (aws sts get-caller-identity)
#   - 対象アカウントIDとの一致確認
#   - S3操作権限の事前確認
#   - 権限不足時のスイッチバック(警告終了 / 自動source)
#   - 誤削除防止(DELETE入力、ルート削除禁止、ドライラン)
#   - ログ / エラー処理 / 一時ファイルクリーンアップ
#
#   ※ 本スクリプトは "aws login --remote" を自動実行しない。
#      未認証時は当該コマンドの実行を利用者へ案内するのみ。
#
# 対応環境: RHEL 9 / bash / aws cli v2 / jq
###############################################################################

set -Eeuo pipefail

#==============================================================================
# 終了コード定義
#==============================================================================
readonly EXIT_SUCCESS=0            # 正常終了
readonly EXIT_USAGE=1              # 引数不正
readonly EXIT_MISSING_CMD=2        # 必須コマンド不足
readonly EXIT_NOT_AUTHENTICATED=3  # AWS未認証 / 期限切れ
readonly EXIT_ACCOUNT_MISMATCH=4   # AWSアカウント不一致
readonly EXIT_NO_PERMISSION=5      # AWS権限不足
readonly EXIT_SWITCHBACK_FAILED=6  # スイッチバック失敗
readonly EXIT_LIST_FAILED=7        # 一覧取得失敗
readonly EXIT_DELETE_FAILED=8      # 削除失敗
readonly EXIT_USER_CANCEL=9        # 利用者によるキャンセル

#==============================================================================
# グローバル変数(既定値)
#==============================================================================
SCRIPT_NAME="$(basename "$0")"

TARGET_ACCOUNT_ID=""       # --account-id  対象AWSアカウントID(12桁)
BUCKET_NAME=""             # --bucket      対象S3バケット名
MODE=""                    # --mode        directory | file
PREFIX=""                  # --prefix      一覧開始プレフィックス
AWS_PROFILE_NAME=""        # --profile     AWS CLIプロファイル(省略可)
AWS_REGION_NAME=""         # --region      AWSリージョン(省略可)
SWITCHBACK_MODE="exit"     # --switchback-mode  exit | auto
SWITCHBACK_SCRIPT=""       # --switchback-script  sourceするスクリプトのパス
SWITCHBACK_ARGS=()         # --switchback-arg  sourceへ渡す追加引数(複数可)
DRY_RUN="false"            # --dry-run     ドライラン
ALLOW_ROOT="false"         # --allow-root  空プレフィックス(ルート)削除を許可
DEBUG_ENABLED="false"      # --debug       DEBUGログ有効化
LOG_FILE=""                # --log-file    ログファイルパス(省略可)
COMMON_SH=""               # --common-sh   共通スクリプトのパス(任意)

# 一時ファイル(trapでクリーンアップ)
TMP_DIR=""

# 一覧・選択の受け渡し用配列
declare -a LIST_ITEMS=()   # 表示・選択対象(プレフィックス or キー)

#==============================================================================
# ログ出力
#   - 日時付きで標準エラーへ出力(標準出力は一覧など機能出力に使う)
#   - ログファイル指定時は追記
#   - 秘密情報(トークン・認証情報)は出力しない
#==============================================================================
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
    local line="[${ts}] [${level}] ${msg}"
    # ログはすべて標準エラーへ(機能的な標準出力と混ざらないようにする)
    printf '%s\n' "${line}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { [[ "${DEBUG_ENABLED}" == "true" ]] && _log "DEBUG" "$@" || true; }

#==============================================================================
# エラーハンドリング / クリーンアップ
#==============================================================================
cleanup() {
    # 一時ファイルの削除
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}" 2>/dev/null || true
        log_debug "一時ディレクトリを削除しました: ${TMP_DIR}"
    fi
}

on_error() {
    # set -e / pipefail による予期せぬ異常終了時のログ
    local exit_code="$1"
    local line_no="$2"
    log_error "予期せぬエラーが発生しました (行: ${line_no}, 終了コード: ${exit_code})"
}

# ERR: 予期せぬ失敗をログ / EXIT: 常にクリーンアップ
trap 'on_error "$?" "${LINENO}"' ERR
trap 'cleanup' EXIT

#==============================================================================
# 使用方法表示
#==============================================================================
usage() {
    cat <<EOF
使用方法:
  ${SCRIPT_NAME} --account-id <ID> --bucket <BUCKET> --mode <directory|file> [オプション]

必須パラメータ:
  --account-id <ID>            対象AWSアカウントID(12桁の数字)
  --bucket <BUCKET>            対象S3バケット名(スラッシュを含めない)
  --mode <directory|file>      処理モード
                                 directory : プレフィックス(ディレクトリ相当)を選択し配下を再帰削除
                                 file      : ファイル(オブジェクト)を1件選択し削除
                               (別名: -m)

任意パラメータ:
  --prefix <PREFIX>            一覧表示を開始するS3プレフィックス(例: work/)
                               先頭の "/" は自動で除去する。未指定時は空(ルート)。
  --profile <NAME>             AWS CLIプロファイル名(不要な環境では省略可)
  --region <REGION>            AWSリージョン(S3で明示不要なら省略可)
  --switchback-mode <MODE>     権限不足時の動作: exit(警告終了) | auto(自動source)
                               既定: exit
  --switchback-script <PATH>   自動スイッチバック時にsourceするスクリプトのパス
  --switchback-arg <ARG>       sourceするスクリプトへ渡す追加引数(複数指定可)
  --dry-run                    ドライラン(実際には削除せず対象のみ表示)
  --allow-root                 空プレフィックス(バケット直下全体)の再帰削除を許可
                               ※ 既定では危険操作として禁止
  --log-file <PATH>            ログファイルの出力先パス
  --debug                      DEBUGログを有効化
  --common-sh <PATH>           共通スクリプト(common.sh)を任意でsource
  -h, --help                   この使用方法を表示

コマンド例:
  # ディレクトリモード / 権限不足時は警告終了
  ${SCRIPT_NAME} --account-id 123456789012 --bucket example-bucket \\
      --prefix work/ --mode directory --switchback-mode exit

  # ファイルモード / 権限不足時は自動スイッチバック
  ${SCRIPT_NAME} --account-id 123456789012 --bucket example-bucket \\
      --prefix work/ --mode file --switchback-mode auto \\
      --switchback-script /opt/company/aws/switchback.sh

  # ドライラン
  ${SCRIPT_NAME} --account-id 123456789012 --bucket example-bucket \\
      --prefix work/ --mode directory --dry-run

前提:
  実行前に "aws login --remote" 等で認証を完了しておくこと。
  本スクリプトは認証コマンドを自動実行しない。

終了コード:
  ${EXIT_SUCCESS}=正常  ${EXIT_USAGE}=引数不正  ${EXIT_MISSING_CMD}=コマンド不足
  ${EXIT_NOT_AUTHENTICATED}=未認証  ${EXIT_ACCOUNT_MISMATCH}=アカウント不一致
  ${EXIT_NO_PERMISSION}=権限不足  ${EXIT_SWITCHBACK_FAILED}=スイッチバック失敗
  ${EXIT_LIST_FAILED}=一覧取得失敗  ${EXIT_DELETE_FAILED}=削除失敗  ${EXIT_USER_CANCEL}=キャンセル
EOF
}

# 使用方法を表示して異常終了する補助
die_usage() {
    local msg="$1"
    log_error "${msg}"
    usage >&2
    exit "${EXIT_USAGE}"
}

#==============================================================================
# 引数解析
#==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --account-id)        TARGET_ACCOUNT_ID="${2:-}"; shift 2 ;;
            --bucket)            BUCKET_NAME="${2:-}"; shift 2 ;;
            -m|--mode)           MODE="${2:-}"; shift 2 ;;
            --prefix)            PREFIX="${2:-}"; shift 2 ;;
            --profile)           AWS_PROFILE_NAME="${2:-}"; shift 2 ;;
            --region)            AWS_REGION_NAME="${2:-}"; shift 2 ;;
            --switchback-mode)   SWITCHBACK_MODE="${2:-}"; shift 2 ;;
            --switchback-script) SWITCHBACK_SCRIPT="${2:-}"; shift 2 ;;
            --switchback-arg)    SWITCHBACK_ARGS+=("${2:-}"); shift 2 ;;
            --dry-run)           DRY_RUN="true"; shift ;;
            --allow-root)        ALLOW_ROOT="true"; shift ;;
            --log-file)          LOG_FILE="${2:-}"; shift 2 ;;
            --debug)             DEBUG_ENABLED="true"; shift ;;
            --common-sh)         COMMON_SH="${2:-}"; shift 2 ;;
            -h|--help)           usage; exit "${EXIT_SUCCESS}" ;;
            --)                  shift; break ;;
            -*)                  die_usage "不明なオプション: $1" ;;
            *)                   die_usage "不正な引数: $1" ;;
        esac
    done
}

#==============================================================================
# 必須コマンド存在確認
#==============================================================================
check_required_commands() {
    local missing=0
    local cmd
    for cmd in aws jq date mktemp; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "必須コマンドが見つかりません: ${cmd}"
            missing=1
        fi
    done
    if [[ "${missing}" -ne 0 ]]; then
        log_error "AWS CLI と jq を含む必須コマンドをインストールしてください。"
        exit "${EXIT_MISSING_CMD}"
    fi
    log_debug "必須コマンドの存在を確認しました。"
}

#==============================================================================
# パラメータ検証
#==============================================================================
validate_params() {
    # --- 必須チェック ---
    [[ -n "${TARGET_ACCOUNT_ID}" ]] || die_usage "--account-id は必須です。"
    [[ -n "${BUCKET_NAME}" ]]       || die_usage "--bucket は必須です。"
    [[ -n "${MODE}" ]]              || die_usage "--mode は必須です。"

    # --- アカウントID: 12桁の数字 ---
    if [[ ! "${TARGET_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
        die_usage "--account-id は12桁の数字で指定してください: ${TARGET_ACCOUNT_ID}"
    fi

    # --- モード検証 ---
    if [[ "${MODE}" != "directory" && "${MODE}" != "file" ]]; then
        die_usage "--mode は directory または file を指定してください: ${MODE}"
    fi

    # --- バケット名: スラッシュ / S3 URI混在の禁止 ---
    if [[ "${BUCKET_NAME}" == s3://* ]]; then
        die_usage "--bucket にはバケット名のみを指定してください(s3:// は不要): ${BUCKET_NAME}"
    fi
    if [[ "${BUCKET_NAME}" == */* ]]; then
        die_usage "--bucket にスラッシュを含めないでください: ${BUCKET_NAME}"
    fi

    # --- プレフィックス正規化: 先頭スラッシュ除去 ---
    #     S3のキーは先頭 "/" を持たない運用に統一する。
    while [[ "${PREFIX}" == /* ]]; do
        PREFIX="${PREFIX#/}"
    done

    # --- ".." をローカルパスとして解釈しない(誤解防止の警告) ---
    #     S3キーとしての ".." はローカルの親ディレクトリ意味を持たないため、
    #     混入している場合は誤りの可能性が高い。
    if [[ "${PREFIX}" == *".."* ]]; then
        die_usage "--prefix に '..' を含めないでください(S3キーはローカルパスではありません): ${PREFIX}"
    fi

    # --- スイッチバックモード検証 ---
    if [[ "${SWITCHBACK_MODE}" != "exit" && "${SWITCHBACK_MODE}" != "auto" ]]; then
        die_usage "--switchback-mode は exit または auto を指定してください: ${SWITCHBACK_MODE}"
    fi
    if [[ "${SWITCHBACK_MODE}" == "auto" && -z "${SWITCHBACK_SCRIPT}" ]]; then
        die_usage "--switchback-mode auto の場合は --switchback-script が必須です。"
    fi

    # --- ディレクトリモードでの空プレフィックス(ルート)保護 ---
    if [[ "${MODE}" == "directory" && -z "${PREFIX}" && "${ALLOW_ROOT}" != "true" ]]; then
        die_usage "空プレフィックス(バケット直下全体)の再帰削除は既定で禁止です。意図的に行う場合のみ --allow-root を指定してください。"
    fi

    log_info "引数検証: OK (account=${TARGET_ACCOUNT_ID}, bucket=${BUCKET_NAME}, mode=${MODE}, prefix='${PREFIX}', dry_run=${DRY_RUN}, switchback=${SWITCHBACK_MODE})"
}

#==============================================================================
# common.sh の任意読み込み
#   - 存在 / 読み取り / source失敗を検証
#   - CodeCommit専用処理は取り込まない(本スクリプトには不要)
#==============================================================================
load_common_sh() {
    [[ -z "${COMMON_SH}" ]] && return 0
    if [[ ! -e "${COMMON_SH}" ]]; then
        log_error "common.sh が存在しません: ${COMMON_SH}"
        exit "${EXIT_USAGE}"
    fi
    if [[ ! -f "${COMMON_SH}" ]]; then
        log_error "common.sh が通常ファイルではありません: ${COMMON_SH}"
        exit "${EXIT_USAGE}"
    fi
    if [[ ! -r "${COMMON_SH}" ]]; then
        log_error "common.sh を読み取れません: ${COMMON_SH}"
        exit "${EXIT_USAGE}"
    fi
    log_info "common.sh を読み込みます: ${COMMON_SH}"
    # shellcheck disable=SC1090
    if ! source "${COMMON_SH}"; then
        log_error "common.sh のsourceに失敗しました: ${COMMON_SH}"
        exit "${EXIT_USAGE}"
    fi
    # sourceにより set オプションが変更される可能性があるため再設定
    set -Eeuo pipefail
    log_info "common.sh の読み込みが完了しました。"
}

#==============================================================================
# AWS CLI共通オプション生成(配列で管理)
#==============================================================================
build_aws_opts() {
    AWS_OPTS=()
    [[ -n "${AWS_PROFILE_NAME}" ]] && AWS_OPTS+=(--profile "${AWS_PROFILE_NAME}")
    [[ -n "${AWS_REGION_NAME}" ]]  && AWS_OPTS+=(--region "${AWS_REGION_NAME}")
    # 出力はスクリプトが解釈しやすいようにjson固定
    AWS_OPTS+=(--output json)
    log_debug "AWS共通オプション: ${AWS_OPTS[*]}"
}

#==============================================================================
# AWS CLIエラー種別判定
#   - 標準エラー文字列とAWSエラーコードから種別を推定
#   - set -e に影響されない箇所から呼び出す
#   戻り値(標準出力): 判定種別文字列
#     UNAUTHENTICATED / ACCESS_DENIED / NO_SUCH_BUCKET / NETWORK /
#     CONFIG / OTHER
#==============================================================================
classify_aws_error() {
    local err_text="$1"
    # 秘密情報が含まれないよう、判定にはエラーコード語のみを使用する
    if grep -Eq 'ExpiredToken|InvalidClientTokenId|InvalidToken|TokenRefreshRequired|SignatureDoesNotMatch|AuthFailure|credentials|Unable to locate credentials' <<<"${err_text}"; then
        printf 'UNAUTHENTICATED\n'; return 0
    fi
    if grep -Eq 'AccessDenied|UnauthorizedOperation|Forbidden|not authorized' <<<"${err_text}"; then
        printf 'ACCESS_DENIED\n'; return 0
    fi
    if grep -Eq 'NoSuchBucket|does not exist|Not Found|404' <<<"${err_text}"; then
        printf 'NO_SUCH_BUCKET\n'; return 0
    fi
    if grep -Eq 'Could not connect|Connection was closed|Network|EndpointConnectionError|Name or service not known|Temporary failure in name resolution' <<<"${err_text}"; then
        printf 'NETWORK\n'; return 0
    fi
    if grep -Eq 'You must specify a region|Unable to parse config|ProfileNotFound|The config profile|ConfigParseError' <<<"${err_text}"; then
        printf 'CONFIG\n'; return 0
    fi
    printf 'OTHER\n'
}

#==============================================================================
# AWS認証確認 + アカウントID取得 + 照合
#   - aws sts get-caller-identity の成否で判定
#   - Account値を取得し、対象アカウントIDと照合
#==============================================================================
verify_authentication() {
    local out_file="${TMP_DIR}/sts_out.json"
    local err_file="${TMP_DIR}/sts_err.txt"
    local rc=0

    log_info "AWS認証状態を確認します..."

    # set -e の即時終了を避けて終了コードを取得する
    set +e
    aws "${AWS_OPTS[@]}" sts get-caller-identity >"${out_file}" 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        local err_text kind
        err_text="$(cat "${err_file}" 2>/dev/null || true)"
        kind="$(classify_aws_error "${err_text}")"
        # 調査用の詳細はDEBUGへ(利用者向けは簡潔に)
        log_debug "sts get-caller-identity エラー詳細: ${err_text}"

        case "${kind}" in
            NETWORK)
                log_error "AWSへ接続できませんでした。ネットワークまたは名前解決を確認してください。"
                ;;
            CONFIG)
                log_error "AWS CLI設定に問題があります。プロファイル/リージョン設定を確認してください。"
                ;;
            *)
                # 未認証・期限切れ・その他はまとめて認証案内
                cat >&2 <<'MSG'
AWS認証が確認できませんでした。
事前に aws login --remote を実行して認証を完了してから、再度このスクリプトを実行してください。
MSG
                ;;
        esac
        exit "${EXIT_NOT_AUTHENTICATED}"
    fi

    # Account値の取得(jqで安全に抽出)
    local actual_account
    actual_account="$(jq -r '.Account // empty' "${out_file}")"
    if [[ ! "${actual_account}" =~ ^[0-9]{12}$ ]]; then
        log_error "取得したAWSアカウントIDが不正です(12桁数字ではありません)。"
        exit "${EXIT_NOT_AUTHENTICATED}"
    fi
    log_info "AWS認証OK(現在のアカウント: ${actual_account})"

    # 対象アカウントIDとの照合
    if [[ "${actual_account}" != "${TARGET_ACCOUNT_ID}" ]]; then
        log_error "AWSアカウント不一致: 認証中=${actual_account} / 指定=${TARGET_ACCOUNT_ID}"
        log_error "対象アカウントと異なるため処理を中止します。"
        exit "${EXIT_ACCOUNT_MISMATCH}"
    fi
    log_info "アカウントID照合OK(${TARGET_ACCOUNT_ID})"
}

#==============================================================================
# S3操作権限確認(読み取り系: ListBucket相当)
#   - list-objects-v2 を1件だけ試行して権限とバケット存在を確認
#   戻り値: 0=OK / 1=権限不足 / それ以外はexit(認証・存在エラー等)
#==============================================================================
check_s3_permission() {
    local err_file="${TMP_DIR}/s3perm_err.txt"
    local rc=0

    log_info "S3一覧取得権限(ListBucket相当)を確認します..."

    set +e
    aws "${AWS_OPTS[@]}" s3api list-objects-v2 \
        --bucket "${BUCKET_NAME}" \
        --prefix "${PREFIX}" \
        --max-items 1 \
        >/dev/null 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -eq 0 ]]; then
        log_info "S3一覧取得権限OK。"
        return 0
    fi

    local err_text kind
    err_text="$(cat "${err_file}" 2>/dev/null || true)"
    kind="$(classify_aws_error "${err_text}")"
    log_debug "list-objects-v2 エラー詳細: ${err_text}"

    case "${kind}" in
        UNAUTHENTICATED)
            # 認証エラーはスイッチバックより先に再認証を案内
            cat >&2 <<'MSG'
AWS認証が確認できませんでした(期限切れの可能性)。
事前に aws login --remote を実行して認証を完了してから、再度このスクリプトを実行してください。
MSG
            exit "${EXIT_NOT_AUTHENTICATED}"
            ;;
        NO_SUCH_BUCKET)
            # バケット不存在とアクセス拒否はAWSの情報秘匿仕様で区別できない場合がある
            log_error "バケットが存在しないか、アクセスできません: ${BUCKET_NAME}"
            log_error "(AWS仕様により「不存在」と「アクセス拒否」は区別できない場合があります)"
            exit "${EXIT_LIST_FAILED}"
            ;;
        NETWORK)
            log_error "AWSへ接続できませんでした。ネットワークまたは名前解決を確認してください。"
            exit "${EXIT_LIST_FAILED}"
            ;;
        ACCESS_DENIED)
            log_warn "S3操作権限が不足しています(AccessDenied)。"
            return 1
            ;;
        *)
            log_warn "S3権限確認で判定不能なエラーが発生しました。権限不足として扱います。"
            return 1
            ;;
    esac
}

#==============================================================================
# スイッチバック実行
#   - exit  : 案内して異常終了
#   - auto  : 指定スクリプトをsourceし、現シェルで権限切替
#==============================================================================
run_switchback() {
    if [[ "${SWITCHBACK_MODE}" == "exit" ]]; then
        log_error "現在の認証状態ではAWS操作(S3)に必要な権限が不足しています。"
        if [[ -n "${SWITCHBACK_SCRIPT}" ]]; then
            log_error "権限を切り替えるには、次のスイッチバックスクリプトを実行してください: ${SWITCHBACK_SCRIPT}"
        else
            log_error "権限を切り替えるためのスイッチバック手順を実施してから再実行してください。"
        fi
        exit "${EXIT_NO_PERMISSION}"
    fi

    # --- auto モード ---
    log_info "自動スイッチバックを開始します: ${SWITCHBACK_SCRIPT}"

    # sourceする外部シェルの安全確認
    if [[ ! -e "${SWITCHBACK_SCRIPT}" ]]; then
        log_error "スイッチバックスクリプトが存在しません: ${SWITCHBACK_SCRIPT}"
        exit "${EXIT_SWITCHBACK_FAILED}"
    fi
    # 通常ファイルであること(設計判断: シンボリックリンクは既定で拒否する)
    if [[ -L "${SWITCHBACK_SCRIPT}" ]]; then
        log_error "スイッチバックスクリプトがシンボリックリンクです。安全のため拒否します: ${SWITCHBACK_SCRIPT}"
        exit "${EXIT_SWITCHBACK_FAILED}"
    fi
    if [[ ! -f "${SWITCHBACK_SCRIPT}" ]]; then
        log_error "スイッチバックスクリプトが通常ファイルではありません: ${SWITCHBACK_SCRIPT}"
        exit "${EXIT_SWITCHBACK_FAILED}"
    fi
    if [[ ! -r "${SWITCHBACK_SCRIPT}" ]]; then
        log_error "スイッチバックスクリプトを読み取れません: ${SWITCHBACK_SCRIPT}"
        exit "${EXIT_SWITCHBACK_FAILED}"
    fi

    # 注意:
    #   外部シェルは source で現在のプロセス内に読み込まれる。
    #   このため外部シェルが exit を実行すると、本スクリプトごと終了する。
    #   また外部シェルがカレントディレクトリや set オプションを変更する可能性がある。
    #   認証情報を現シェルへ反映させるため、サブシェルではなく source を使用する。
    log_info "source を実行します(外部シェルの標準出力/標準エラーはそのまま表示します)。"

    local rc=0
    set +e
    # shellcheck disable=SC1090
    source "${SWITCHBACK_SCRIPT}" "${SWITCHBACK_ARGS[@]+"${SWITCHBACK_ARGS[@]}"}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log_error "スイッチバックスクリプトのsource実行に失敗しました(終了コード: ${rc}): ${SWITCHBACK_SCRIPT}"
        exit "${EXIT_SWITCHBACK_FAILED}"
    fi

    # source後に set オプションが変更されている可能性があるため再設定
    set -Eeuo pipefail
    log_info "スイッチバックスクリプトのsourceが完了しました。再検証を行います。"
}

#==============================================================================
# スイッチバック後の再検証
#   - 認証確認 / アカウント照合 / S3権限確認 を再実行
#   - 無限ループを避けるため、ここで失敗したら再試行せず終了
#==============================================================================
revalidate_after_switchback() {
    # 共通オプションはプロファイル等が変わらない前提だが、念のため再生成
    build_aws_opts
    verify_authentication
    if ! check_s3_permission; then
        log_error "スイッチバック後もS3操作権限が不足しています。再試行せず終了します。"
        exit "${EXIT_NO_PERMISSION}"
    fi
    log_info "スイッチバック後の再検証OK。"
}

#==============================================================================
# ディレクトリ一覧取得(プレフィックス相当)
#   - list-objects-v2 + Delimiter "/" で直下のCommonPrefixesを取得
#   - 末尾スラッシュのみの空ディレクトリ表現も対象に含める
#   - ページネーション対応(--no-paginate を使わず全件取得)
#==============================================================================
list_directories() {
    local out_file="${TMP_DIR}/dir_list.json"
    local err_file="${TMP_DIR}/dir_err.txt"
    local rc=0

    log_info "ディレクトリ一覧を取得します(prefix='${PREFIX}')..."

    set +e
    # AWS CLIは既定でページネーションし全ページを結合出力する
    aws "${AWS_OPTS[@]}" s3api list-objects-v2 \
        --bucket "${BUCKET_NAME}" \
        --prefix "${PREFIX}" \
        --delimiter "/" \
        >"${out_file}" 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log_error "ディレクトリ一覧の取得に失敗しました。"
        log_debug "list-objects-v2(dir) エラー詳細: $(cat "${err_file}" 2>/dev/null || true)"
        exit "${EXIT_LIST_FAILED}"
    fi

    # CommonPrefixes(サブディレクトリ) と、指定prefix直下の空ディレクトリ表現(末尾/のキー)を統合
    # jqでNUL区切り出力し、mapfileで安全に配列化(空白・記号・日本語対応)
    LIST_ITEMS=()
    local tmp_items="${TMP_DIR}/dir_items.nul"
    jq -rj '
        ( (.CommonPrefixes // []) | .[].Prefix ),
        ( (.Contents // []) | .[].Key | select(endswith("/")) )
        | . + " "
    ' "${out_file}" > "${tmp_items}"

    # 重複除去しつつ配列化(prefix自身のキーが末尾/で来る場合を考慮)
    local -A seen=()
    local item
    while IFS= read -r -d '' item; do
        [[ -z "${item}" ]] && continue
        # 指定prefixそのもの(自ディレクトリ)は選択対象から除外
        [[ "${item}" == "${PREFIX}" ]] && continue
        if [[ -z "${seen[${item}]:-}" ]]; then
            seen[${item}]=1
            LIST_ITEMS+=("${item}")
        fi
    done < "${tmp_items}"

    log_info "ディレクトリ ${#LIST_ITEMS[@]} 件を取得しました。"
}

#==============================================================================
# ファイル一覧取得(オブジェクト)
#   - list-objects-v2 でprefix配下のキーを取得
#   - 末尾スラッシュ(ディレクトリ表現)は除外
#   - ページネーション対応 / jqでNUL区切り安全処理
#==============================================================================
list_files() {
    local out_file="${TMP_DIR}/file_list.json"
    local err_file="${TMP_DIR}/file_err.txt"
    local rc=0

    log_info "ファイル一覧を取得します(prefix='${PREFIX}')..."

    set +e
    aws "${AWS_OPTS[@]}" s3api list-objects-v2 \
        --bucket "${BUCKET_NAME}" \
        --prefix "${PREFIX}" \
        >"${out_file}" 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log_error "ファイル一覧の取得に失敗しました。"
        log_debug "list-objects-v2(file) エラー詳細: $(cat "${err_file}" 2>/dev/null || true)"
        exit "${EXIT_LIST_FAILED}"
    fi

    LIST_ITEMS=()
    local tmp_items="${TMP_DIR}/file_items.nul"
    # 末尾 "/" のキー(ディレクトリ表現)は除外し、ファイルのみを対象にする
    jq -rj '
        (.Contents // [])
        | .[].Key
        | select(endswith("/") | not)
        | . + " "
    ' "${out_file}" > "${tmp_items}"

    local item
    while IFS= read -r -d '' item; do
        [[ -z "${item}" ]] && continue
        LIST_ITEMS+=("${item}")
    done < "${tmp_items}"

    log_info "ファイル ${#LIST_ITEMS[@]} 件を取得しました。"
}

#==============================================================================
# 選択番号受付(対話)
#   - 番号付きで一覧表示し、1件選択させる
#   - q / 空入力でキャンセル
#   - 整数・範囲を検証
#   - 非対話環境(標準入力なし)は安全のため削除せず終了
#   戻り値(標準出力): 選択された1-based番号
#==============================================================================
prompt_selection() {
    local count="${#LIST_ITEMS[@]}"

    if [[ "${count}" -eq 0 ]]; then
        log_info "対象が0件のため、削除処理を行わず終了します。"
        exit "${EXIT_SUCCESS}"
    fi

    # 非対話環境では削除させない
    if [[ ! -t 0 ]]; then
        log_error "非対話環境(標準入力が端末ではない)のため、安全のため削除せず終了します。"
        exit "${EXIT_USER_CANCEL}"
    fi

    # 一覧表示(利用者向けなので標準エラーへ。プロンプトと同じストリームに揃える)
    {
        printf '\n=== 削除対象候補(%s モード) ===\n' "${MODE}"
        local i
        for i in "${!LIST_ITEMS[@]}"; do
            printf '  [%d] %s\n' "$((i + 1))" "${LIST_ITEMS[$i]}"
        done
        printf '\n削除する番号を入力してください(1-%d)。q または 空入力でキャンセル。\n' "${count}"
    } >&2

    local input
    printf '選択> ' >&2
    IFS= read -r input || input=""

    # キャンセル判定
    if [[ -z "${input}" || "${input}" == "q" || "${input}" == "Q" ]]; then
        log_info "利用者によりキャンセルされました。"
        exit "${EXIT_USER_CANCEL}"
    fi

    # 整数検証
    if [[ ! "${input}" =~ ^[0-9]+$ ]]; then
        log_error "整数以外が入力されました: ${input}"
        exit "${EXIT_USAGE}"
    fi

    # 範囲検証
    if (( input < 1 || input > count )); then
        log_error "範囲外の番号が入力されました: ${input}(有効範囲: 1-${count})"
        exit "${EXIT_USAGE}"
    fi

    printf '%s\n' "${input}"
}

#==============================================================================
# 削除対象確認(DELETE入力)
#   - 対象情報を明示表示し、明示文字列 "DELETE" の入力を要求
#   引数: $1=対象S3キー/プレフィックス $2=種別(directory|file)
#   戻り値: 0=確認OK / それ以外はexit
#==============================================================================
confirm_deletion() {
    local target="$1"
    local kind="$2"
    local s3_uri="s3://${BUCKET_NAME}/${target}"

    {
        printf '\n================ 削除内容の確認 ================\n'
        printf '  AWSアカウントID : %s\n' "${TARGET_ACCOUNT_ID}"
        printf '  バケット名       : %s\n' "${BUCKET_NAME}"
        printf '  モード           : %s\n' "${kind}"
        printf '  対象S3 URI       : %s\n' "${s3_uri}"
        if [[ "${kind}" == "directory" ]]; then
            printf '  削除方式         : 配下の全オブジェクトを再帰的に削除\n'
        else
            printf '  削除方式         : 対象1ファイルのみ削除\n'
        fi
        if [[ "${DRY_RUN}" == "true" ]]; then
            printf '  ドライラン       : 有効(実削除は行いません)\n'
        fi
        printf '===============================================\n'
    } >&2

    if [[ "${DRY_RUN}" == "true" ]]; then
        # ドライランでは確認入力を省略し、削除予定のみ提示
        log_info "ドライランのため確認入力をスキップします。"
        return 0
    fi

    printf '本当に削除する場合は DELETE と入力してください> ' >&2
    local answer
    IFS= read -r answer || answer=""
    if [[ "${answer}" != "DELETE" ]]; then
        log_info "確認文字列が一致しませんでした。削除を中止して正常終了します。"
        exit "${EXIT_SUCCESS}"
    fi
    log_info "削除確認OK(DELETE入力を受領)。"
    return 0
}

#==============================================================================
# ディレクトリ削除(再帰)
#   - aws s3 rm --recursive を使用(ドライランは --dryrun)
#   - 空プレフィックス(ルート)は既定で禁止
#   引数: $1=対象プレフィックス
#==============================================================================
delete_directory() {
    local target_prefix="$1"

    # 二重チェック: 空プレフィックスの再帰削除を禁止
    if [[ -z "${target_prefix}" && "${ALLOW_ROOT}" != "true" ]]; then
        log_error "空プレフィックスの再帰削除は禁止です(--allow-root 未指定)。"
        exit "${EXIT_DELETE_FAILED}"
    fi

    local s3_uri="s3://${BUCKET_NAME}/${target_prefix}"
    local err_file="${TMP_DIR}/del_dir_err.txt"
    local rc=0

    # aws s3 rm はプロファイル/リージョンを個別に受け取る(--output jsonは付けない)
    local s3_opts=()
    [[ -n "${AWS_PROFILE_NAME}" ]] && s3_opts+=(--profile "${AWS_PROFILE_NAME}")
    [[ -n "${AWS_REGION_NAME}" ]]  && s3_opts+=(--region "${AWS_REGION_NAME}")

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "ドライラン: 以下のプレフィックス配下が削除対象です: ${s3_uri}"
        set +e
        aws "${s3_opts[@]}" s3 rm "${s3_uri}" --recursive --dryrun 2>"${err_file}"
        rc=$?
        set -e
        if [[ "${rc}" -ne 0 ]]; then
            log_error "ドライラン(一覧)に失敗しました。"
            log_debug "s3 rm --dryrun エラー詳細: $(cat "${err_file}" 2>/dev/null || true)"
            exit "${EXIT_DELETE_FAILED}"
        fi
        log_info "ドライラン完了(実削除は行っていません)。"
        return 0
    fi

    log_info "再帰削除を開始します: ${s3_uri}(大量オブジェクト時は時間がかかる場合があります)"
    set +e
    aws "${s3_opts[@]}" s3 rm "${s3_uri}" --recursive 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log_error "ディレクトリの再帰削除に失敗しました: ${s3_uri}"
        log_debug "s3 rm エラー詳細: $(cat "${err_file}" 2>/dev/null || true)"
        exit "${EXIT_DELETE_FAILED}"
    fi
    log_info "再帰削除が完了しました: ${s3_uri}"
    log_warn "バージョニング有効バケットの場合、削除は削除マーカー作成となり過去バージョンは残ります。"
}

#==============================================================================
# ファイル削除(単一)
#   - delete-object を使用
#   引数: $1=対象キー
#==============================================================================
delete_file() {
    local object_key="$1"
    local s3_uri="s3://${BUCKET_NAME}/${object_key}"
    local err_file="${TMP_DIR}/del_file_err.txt"
    local rc=0

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "ドライラン: 以下のファイルが削除対象です: ${s3_uri}"
        log_info "ドライラン完了(実削除は行っていません)。"
        return 0
    fi

    log_info "ファイルを削除します: ${s3_uri}"
    set +e
    aws "${AWS_OPTS[@]}" s3api delete-object \
        --bucket "${BUCKET_NAME}" \
        --key "${object_key}" \
        >/dev/null 2>"${err_file}"
    rc=$?
    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log_error "ファイル削除に失敗しました: ${s3_uri}"
        log_debug "delete-object エラー詳細: $(cat "${err_file}" 2>/dev/null || true)"
        exit "${EXIT_DELETE_FAILED}"
    fi
    log_info "ファイル削除が完了しました: ${s3_uri}"
    log_warn "バージョニング有効バケットの場合、削除は削除マーカー作成となり過去バージョンは残ります。"
}

#==============================================================================
# メイン処理
#==============================================================================
main() {
    parse_args "$@"

    # 一時ディレクトリ作成(ログ関数より前でも良いが、trapは設定済み)
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/s3_select_delete.XXXXXX")"
    log_debug "一時ディレクトリ: ${TMP_DIR}"

    # ログファイル初期化(指定時)
    if [[ -n "${LOG_FILE}" ]]; then
        if ! : > "${LOG_FILE}" 2>/dev/null && [[ ! -w "${LOG_FILE}" ]]; then
            # 追記できるかだけ確認(既存への追記も許容)
            log_warn "ログファイルに書き込めない可能性があります: ${LOG_FILE}"
        fi
    fi

    log_info "===== ${SCRIPT_NAME} 実行開始 ====="

    load_common_sh
    check_required_commands
    validate_params
    build_aws_opts

    # 認証 → アカウント照合
    verify_authentication

    # S3権限確認 → 不足時はスイッチバック → 再検証
    if ! check_s3_permission; then
        run_switchback
        revalidate_after_switchback
    fi

    # モード別: 一覧 → 選択 → 確認 → 削除
    local selected_index selected_item
    case "${MODE}" in
        directory)
            list_directories
            selected_index="$(prompt_selection)"
            selected_item="${LIST_ITEMS[$((selected_index - 1))]}"
            log_info "選択されたディレクトリ: ${selected_item}"
            confirm_deletion "${selected_item}" "directory"
            delete_directory "${selected_item}"
            ;;
        file)
            list_files
            selected_index="$(prompt_selection)"
            selected_item="${LIST_ITEMS[$((selected_index - 1))]}"
            log_info "選択されたファイル: ${selected_item}"
            confirm_deletion "${selected_item}" "file"
            delete_file "${selected_item}"
            ;;
        *)
            die_usage "内部エラー: 不正なモード ${MODE}"
            ;;
    esac

    log_info "===== ${SCRIPT_NAME} 正常終了 ====="
    exit "${EXIT_SUCCESS}"
}

main "$@"
