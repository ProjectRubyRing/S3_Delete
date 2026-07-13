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
`REQUIRED_EXTERNAL=(mode prefix)` に列挙。未指定なら usage を表示して終了する。
毎回同じ prefix でよいなら `prefix` を外し `CFG_DEFAULT_PREFIX` を使う。

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
