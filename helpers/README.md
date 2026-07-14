# helpers/ — s3_select_delete.sh 用ラッパ(ヘルパ)

本体 `s3_select_delete.sh` は引数が多いため、環境ごとに固定のパラメータを
既定値として持たせ、実行時に変わる引数だけを渡せるようにするラッパ群を置くディレクトリ。

## s3_delete_helper.sh

### 使い方(最短)
```bash
# 1) 本ファイル上部の「設定(CONFIG)」セクションを環境に合わせて編集
#    (最低限 CFG_ACCOUNT_ID と CFG_BUCKET)
# 2) 実行(可変パラメータだけ渡す)
./helpers/s3_delete_helper.sh --mode directory --prefix work/
./helpers/s3_delete_helper.sh --mode file --prefix work/ --dry-run
./helpers/s3_delete_helper.sh --help
```

### 設定の与え方
- **CONFIG セクション**: ヘルパ本体上部を直接編集。補助パラメータは自由に追加可
  (変数を足し、`build_main_args()` で本体オプションへ反映する)。
- **外部設定ファイル**: `--config ./env/prod.conf` で CONFIG 変数を上書き。
  環境ごとに設定ファイルを分ければ、1つのヘルパで複数環境を切り替えられる。

### 「必ず外から指定させる」パラメータ
`REQUIRED_EXTERNAL=(mode)` に列挙。未指定なら usage を表示して終了する。
毎回 `prefix` も明示させたい場合は `REQUIRED_EXTERNAL` に `prefix` を加える。

### `--prefix` を省略したとき(削除対象候補の一覧表示)
`--prefix` は必須ではない。省略した場合、本体は起動せず、ヘルパ自身が
バケットルート直下を一覧し、削除対象となる候補を表示して終了する(削除は行わない)。

- `--mode directory`: 直下のサブディレクトリ(`CommonPrefixes`)+ 空ディレクトリ表現
- `--mode file`: 直下のファイル(末尾 `/` を除くキー)

```bash
# バケットルート直下の候補を確認 → 表示された候補から --prefix を選んで再実行
./helpers/s3_delete_helper.sh --mode directory
./helpers/s3_delete_helper.sh --mode directory --prefix work/
```

一覧取得には `aws` CLI と `jq` が必要(プロファイル/リージョンは `CFG_PROFILE` /
`CFG_REGION` を使用)。毎回同じ prefix でよい場合は `CFG_DEFAULT_PREFIX` を設定すると、
候補一覧ではなくその既定 prefix で本体を実行する。

### 本体へ直接引数を渡したいとき
`--` 以降はそのまま本体へ渡る:
```bash
./helpers/s3_delete_helper.sh --mode file --prefix work/ -- --log-file /tmp/x.log
```

## 設計メモ(なぜこの作りか)

- **本体は「子プロセスとして実行(exec)」する。** 本体は末尾で `exit` し、
  `set -Eeuo pipefail` と `trap` を張っており "source される" 設計ではない。
  子プロセス実行なら、本体内部の `source "${SWITCHBACK_SCRIPT}"`(スイッチロール
  制御)は本体プロセス内で実行され、その後の `aws` 呼び出しへ正しく反映される。
  ヘルパ側から `source` すると set/trap/exit がヘルパへ漏れて壊れる。
- **本体パスはヘルパ自身の位置(`BASH_SOURCE`)から解決。** CWD 非依存なので、
  ヘルパを別ディレクトリに置いても本体を確実に見つけられる。
- **`source` される側(switchback-script / common-sh)は絶対パスで本体へ渡す。**
  スラッシュ付きパスの `source` は CWD 相対で解決されるため、ディレクトリを
  分けても壊れないよう `resolve_path()` で絶対パス化している。
