#!/bin/bash
###############################################################################
# s3_delete_helper.sh
#
# 概要:
#   本体スクリプト s3_select_delete.sh を「毎回大量の引数を打たずに」呼び出す
#   ためのラッピング(ヘルパ)シェル。
#
#   環境ごとに固定となるパラメータ(アカウントID・バケット・プロファイル・
#   リージョン・スイッチバック設定・common.sh 等)を本ファイル上部の
#   「設定(CONFIG)」セクションへ既定値として持たせ、実行のたびに変わる
#   パラメータ(mode / prefix など)だけをコマンドラインで受け取る。
#
# 設計上の重要ポイント:
#   1) 本体は「子プロセスとして実行(exec)」する。
#        本体は末尾で exit し、set -Eeuo pipefail と trap を張っており、
#        「source される」設計ではない。source すると set/trap/exit が本ヘルパへ
#        漏れて壊れる。子プロセス実行なら本体内部の
#        `source "${SWITCHBACK_SCRIPT}"`(スイッチロール制御)は本体プロセス内で
#        実行され、その後の aws 呼び出しへ正しく反映される。
#   2) 本体スクリプトのパスは「本ヘルパ自身の位置(BASH_SOURCE)」から解決する。
#        CWD(カレントディレクトリ)に依存しないため、ヘルパを別ディレクトリに
#        置いても本体を確実に見つけられる。
#   3) source されるスクリプト(switchback-script / common-sh)は「絶対パス」で
#        本体へ渡す。スラッシュを含むパスの source は CWD 相対で解決されるため、
#        ディレクトリを分けても source が壊れないよう絶対パス化する。
#
# 対応環境: RHEL 9 / bash / aws cli v2 / jq
###############################################################################

set -Eeuo pipefail

HELPER_NAME="$(basename "$0")"

#==============================================================================
# パス解決(CWD 非依存)
#   - 本ヘルパ自身の実体ディレクトリを基準に、本体スクリプトの場所を決める。
#   - シンボリックリンク経由でも実体を辿れるよう readlink -f を優先利用する。
#==============================================================================
_resolve_self_dir() {
    local src="${BASH_SOURCE[0]}"
    local real=""
    if real="$(readlink -f "${src}" 2>/dev/null)" && [[ -n "${real}" ]]; then
        dirname "${real}"
    else
        # readlink -f 非対応環境向けフォールバック
        cd "$(dirname "${src}")" >/dev/null 2>&1 && pwd
    fi
}

HELPER_DIR="$(_resolve_self_dir)"
# ヘルパは <PROJECT_ROOT>/helpers/ に置く想定。1つ上が本体の置き場。
PROJECT_ROOT="$(cd "${HELPER_DIR}/.." >/dev/null 2>&1 && pwd)"

#==============================================================================
# 相対パス→絶対パス変換
#   - 設定で相対パスを書いた場合は PROJECT_ROOT を基準に絶対化する。
#   - source される側(switchback / common)へ渡すパスは必ずこれで絶対化する。
#==============================================================================
resolve_path() {
    local p="${1:-}"
    [[ -z "${p}" ]] && { printf ''; return 0; }
    case "${p}" in
        /*) : ;;                        # 既に絶対パス
        *)  p="${PROJECT_ROOT}/${p}" ;; # 相対パスは PROJECT_ROOT 基準で絶対化
    esac
    # 実体があれば正規化(なければそのまま返す=本体側でエラー処理させる)
    if [[ -e "${p}" ]] && command -v readlink >/dev/null 2>&1; then
        readlink -f "${p}" 2>/dev/null || printf '%s' "${p}"
    else
        printf '%s' "${p}"
    fi
}

#==============================================================================
# ============== 設定(CONFIG): ここを環境に合わせて編集する ==============
#   - 環境ごとに固定のパラメータの既定値を定義する。
#   - 「補助パラメータは自由に追加してよい」。必要なら変数を増やし、
#     後段の build_main_args() で本体オプションへ反映すること。
#   - 相対パスは PROJECT_ROOT(このリポジトリのルート)基準で解釈される。
#==============================================================================

# --- 本体スクリプト(通常は変更不要。別名にした場合のみ調整) ---
MAIN_SCRIPT="${PROJECT_ROOT}/s3_select_delete.sh"

# --- 対象 AWS 環境(★環境固有: 要編集) ---
CFG_ACCOUNT_ID=""            # 例: "123456789012"(12桁)
CFG_BUCKET=""               # 例: "example-bucket"

# --- AWS CLI プロファイル / リージョン(不要なら空のまま) ---
CFG_PROFILE=""              # 例: "my-profile"
CFG_REGION=""               # 例: "ap-northeast-1"

# --- スイッチバック(権限不足時のロール切替)設定 ---
#     CFG_SWITCHBACK_SCRIPT は相対/絶対どちらでも良い(自動で絶対パス化して
#     本体へ渡すため、source がディレクトリ差異で壊れない)。
CFG_SWITCHBACK_MODE="exit"                 # exit | auto
CFG_SWITCHBACK_SCRIPT=""                   # 例: "switchback.sh" や "/opt/company/aws/switchback.sh"
CFG_SWITCHBACK_ARGS=()                     # source へ渡す追加引数(必要なら列挙)

# --- 共通スクリプト(任意で source する common.sh)。相対/絶対どちらでも可 ---
CFG_COMMON_SH=""                           # 例: "common.sh"

# --- ログ出力先(空なら本体はログファイルを作らない) ---
CFG_LOG_FILE=""                            # 例: "/var/log/s3_delete/helper.log"

#==============================================================================
# 「外から必ず指定させる」パラメータの定義
#   - ここに列挙したものは、コマンドラインでの指定が無いと usage を出して終了する。
#   - 既定は mode と prefix(実行のたびに変わり、安全上も明示させたい)。
#   - prefix を毎回同じにしたい等で必須から外す場合は "prefix" を削るだけでよい
#     (その場合は下の CFG_DEFAULT_PREFIX を使う)。
#==============================================================================
REQUIRED_EXTERNAL=(mode prefix)
CFG_DEFAULT_PREFIX=""       # prefix を必須から外した場合の既定 prefix

#==============================================================================
# =========================== 設定ここまで ===========================
#==============================================================================

# コマンドラインで受け取る可変パラメータ(初期値)
OPT_MODE=""
OPT_PREFIX=""
OPT_PREFIX_SET="false"      # prefix が明示指定されたか(空文字指定と未指定を区別)
OPT_DRY_RUN="false"
OPT_ALLOW_ROOT="false"
OPT_DEBUG="false"
EXTERNAL_CONFIG=""          # --config で読み込む外部設定ファイル
PASSTHROUGH=()              # `--` 以降、本体へそのまま渡す追加引数

#==============================================================================
# 使用方法
#==============================================================================
usage() {
    cat <<EOF
使用方法:
  ${HELPER_NAME} --mode <directory|file> --prefix <PREFIX> [オプション] [-- <本体へ渡す追加引数...>]

このヘルパは本体 s3_select_delete.sh を、環境固定パラメータを補いながら呼び出します。
環境固定パラメータ(アカウントID/バケット/プロファイル/リージョン/スイッチバック等)は
本ファイル上部の「設定(CONFIG)」セクション、または --config の外部設定ファイルで指定します。

必須(コマンドラインで指定が必要):
$(printf '  %s\n' "${REQUIRED_EXTERNAL[@]/#/--}")

主なオプション:
  -m, --mode <directory|file>  処理モード(directory=配下再帰削除 / file=1ファイル削除)
  -p, --prefix <PREFIX>        一覧開始プレフィックス(例: work/)
  -n, --dry-run                ドライラン(実削除しない)
      --allow-root             空プレフィックス(バケット直下全体)の再帰削除を許可
      --debug                  DEBUG ログ有効化
      --config <FILE>          外部設定ファイルを読み込む(CONFIG 変数を上書き)
  -h, --help                   この使用方法を表示
  --                           これ以降の引数は本体 s3_select_delete.sh へそのまま渡す

現在の設定(CONFIG)値:
  MAIN_SCRIPT        : ${MAIN_SCRIPT}
  CFG_ACCOUNT_ID     : ${CFG_ACCOUNT_ID:-(未設定)}
  CFG_BUCKET         : ${CFG_BUCKET:-(未設定)}
  CFG_PROFILE        : ${CFG_PROFILE:-(未設定)}
  CFG_REGION         : ${CFG_REGION:-(未設定)}
  CFG_SWITCHBACK_MODE: ${CFG_SWITCHBACK_MODE}
  CFG_SWITCHBACK_SCR : ${CFG_SWITCHBACK_SCRIPT:-(未設定)}
  CFG_COMMON_SH      : ${CFG_COMMON_SH:-(未設定)}
  CFG_LOG_FILE       : ${CFG_LOG_FILE:-(未設定)}

例:
  # ディレクトリモード(環境固定値は CONFIG から補完)
  ${HELPER_NAME} --mode directory --prefix work/

  # ファイルモード + ドライラン
  ${HELPER_NAME} --mode file --prefix work/ --dry-run

  # 外部設定ファイルで環境を切り替え、本体の未対応オプションも直接渡す
  ${HELPER_NAME} --config ./env/prod.conf --mode directory --prefix logs/ -- --log-file /tmp/x.log
EOF
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    usage >&2
    exit 1
}

#==============================================================================
# 外部設定ファイルの読み込み(任意)
#   - CONFIG 変数(CFG_*, MAIN_SCRIPT, REQUIRED_EXTERNAL 等)を上書きできる。
#   - source するのはこのヘルパ自身のプロセス内で完結する設定値のみ。
#==============================================================================
load_external_config() {
    [[ -z "${EXTERNAL_CONFIG}" ]] && return 0
    local cfg="${EXTERNAL_CONFIG}"
    [[ "${cfg}" == /* ]] || cfg="${PWD}/${cfg}"
    [[ -f "${cfg}" ]] || die "設定ファイルが見つかりません: ${EXTERNAL_CONFIG}"
    [[ -r "${cfg}" ]] || die "設定ファイルを読み取れません: ${EXTERNAL_CONFIG}"
    # shellcheck disable=SC1090
    source "${cfg}"
    # source により set が変わる可能性があるため再設定
    set -Eeuo pipefail
}

#==============================================================================
# 引数解析(ヘルパ用)
#==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)      OPT_MODE="${2:-}"; shift 2 ;;
            -p|--prefix)    OPT_PREFIX="${2:-}"; OPT_PREFIX_SET="true"; shift 2 ;;
            -n|--dry-run)   OPT_DRY_RUN="true"; shift ;;
            --allow-root)   OPT_ALLOW_ROOT="true"; shift ;;
            --debug)        OPT_DEBUG="true"; shift ;;
            --config)       EXTERNAL_CONFIG="${2:-}"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            --)             shift; PASSTHROUGH=("$@"); break ;;
            -*)             die "不明なオプション: $1" ;;
            *)              die "不正な引数: $1" ;;
        esac
    done
}

#==============================================================================
# 必須(外部指定)パラメータの検証
#   - REQUIRED_EXTERNAL に列挙された項目が指定済みかを確認する。
#==============================================================================
validate_required_external() {
    local key
    for key in "${REQUIRED_EXTERNAL[@]}"; do
        case "${key}" in
            mode)
                [[ -n "${OPT_MODE}" ]] || die "--mode は必須です。"
                ;;
            prefix)
                [[ "${OPT_PREFIX_SET}" == "true" ]] || die "--prefix は必須です。"
                ;;
            *)
                die "REQUIRED_EXTERNAL に未知のキーがあります(CONFIG を確認): ${key}"
                ;;
        esac
    done

    # prefix を必須から外している場合は既定 prefix を採用
    if [[ "${OPT_PREFIX_SET}" != "true" ]]; then
        OPT_PREFIX="${CFG_DEFAULT_PREFIX}"
    fi
}

#==============================================================================
# CONFIG 由来の必須値(環境固定値)の検証
#   - 本体で必須の account-id / bucket が CONFIG 未設定だと分かりにくいので、
#     ヘルパ側で先に分かりやすいメッセージを出す。
#==============================================================================
validate_config() {
    [[ -f "${MAIN_SCRIPT}" ]] || die "本体スクリプトが見つかりません: ${MAIN_SCRIPT}（CONFIG の MAIN_SCRIPT を確認）"
    [[ -r "${MAIN_SCRIPT}" ]] || die "本体スクリプトを読み取れません: ${MAIN_SCRIPT}"
    [[ -n "${CFG_ACCOUNT_ID}" ]] || die "CFG_ACCOUNT_ID が未設定です（CONFIG または --config で設定してください）。"
    [[ -n "${CFG_BUCKET}" ]]     || die "CFG_BUCKET が未設定です（CONFIG または --config で設定してください）。"
    if [[ "${CFG_SWITCHBACK_MODE}" == "auto" && -z "${CFG_SWITCHBACK_SCRIPT}" ]]; then
        die "CFG_SWITCHBACK_MODE=auto の場合は CFG_SWITCHBACK_SCRIPT が必須です。"
    fi
}

#==============================================================================
# 本体へ渡す引数配列の組み立て
#   - CONFIG(環境固定) + コマンドライン(可変) + PASSTHROUGH を統合する。
#   - source される switchback-script / common-sh は絶対パス化して渡す。
#==============================================================================
build_main_args() {
    MAIN_ARGS=(
        --account-id "${CFG_ACCOUNT_ID}"
        --bucket     "${CFG_BUCKET}"
        --mode       "${OPT_MODE}"
        --prefix     "${OPT_PREFIX}"
    )

    [[ -n "${CFG_PROFILE}" ]] && MAIN_ARGS+=(--profile "${CFG_PROFILE}")
    [[ -n "${CFG_REGION}" ]]  && MAIN_ARGS+=(--region  "${CFG_REGION}")

    MAIN_ARGS+=(--switchback-mode "${CFG_SWITCHBACK_MODE}")

    # ★ source される側は絶対パスで渡す(CWD/ディレクトリ差異で source が壊れない)
    if [[ -n "${CFG_SWITCHBACK_SCRIPT}" ]]; then
        local sb_abs
        sb_abs="$(resolve_path "${CFG_SWITCHBACK_SCRIPT}")"
        MAIN_ARGS+=(--switchback-script "${sb_abs}")
    fi
    # switchback へ渡す追加引数(設定されていれば)
    if [[ "${#CFG_SWITCHBACK_ARGS[@]}" -gt 0 ]]; then
        local a
        for a in "${CFG_SWITCHBACK_ARGS[@]}"; do
            MAIN_ARGS+=(--switchback-arg "${a}")
        done
    fi

    if [[ -n "${CFG_COMMON_SH}" ]]; then
        local common_abs
        common_abs="$(resolve_path "${CFG_COMMON_SH}")"
        MAIN_ARGS+=(--common-sh "${common_abs}")
    fi

    [[ -n "${CFG_LOG_FILE}" ]]         && MAIN_ARGS+=(--log-file "${CFG_LOG_FILE}")
    [[ "${OPT_DRY_RUN}" == "true" ]]   && MAIN_ARGS+=(--dry-run)
    [[ "${OPT_ALLOW_ROOT}" == "true" ]] && MAIN_ARGS+=(--allow-root)
    [[ "${OPT_DEBUG}" == "true" ]]     && MAIN_ARGS+=(--debug)

    # `--` 以降にユーザが直接渡した追加引数(自由拡張)
    if [[ "${#PASSTHROUGH[@]}" -gt 0 ]]; then
        MAIN_ARGS+=("${PASSTHROUGH[@]}")
    fi
}

#==============================================================================
# メイン
#==============================================================================
main() {
    parse_args "$@"
    load_external_config
    validate_required_external
    validate_config
    build_main_args

    if [[ "${OPT_DEBUG}" == "true" ]]; then
        printf '[DEBUG] 実行: bash %s' "${MAIN_SCRIPT}" >&2
        printf ' %q' "${MAIN_ARGS[@]}" >&2
        printf '\n' >&2
    fi

    # 本体は「子プロセスとして実行」する(source ではない)。
    #   - exec で置き換えることで、対話プロンプト用の標準入力(tty)と終了コードを
    #     そのまま引き継ぐ。本体内部の switchback の source は本体プロセス内で動く。
    exec bash "${MAIN_SCRIPT}" "${MAIN_ARGS[@]}"
}

main "$@"
