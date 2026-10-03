# Aurora データ投入ツール

JMeter の性能テストの前後で、Aurora MySQL 8.4（互換 8.4.7）に対して次を行う。

- `mysqldump` 形式の論理バックアップ
- 指定テーブルの全件 CSV バックアップ
- テーブルデータの削除
- 指定 CSV の大量ロード
- スキーマに合わせた大量データの生成
- テスト後の後片付け

Windows 11 の PowerShell 5.1 がデータベース操作の実装である。RHEL 9.8 の bash / awk は同じテキストプランから CSV を生成し、`mysqldump` の引数を同じ順で出す。

パスワードはプランにも Excel にも書かない。`password_source` は `env:名前`、`file:パス`、`prompt` のいずれかにする。

## ファイル

| パス | 役割 |
| --- | --- |
| `tools/ps/Invoke-AuroraDataTool.ps1` | Windows の入口 |
| `tools/ps/Export-LoadPlan.ps1` | Excel からプランテキストを書く |
| `tools/bash/aurora-data-tool.sh` | RHEL の生成と dump 引数 |
| `tools/bash/aurora-gen.awk` | PowerShell と同じ乱数と CSV |
| `examples/orders.plan.txt` | サーバなしで生成できる例 |
| `examples/parity.plan.txt` | PowerShell と awk の一致確認用 |
| `docs/plan-format.md` | プランの書式 |

## Windows

MySQL 8.4 の `mysql.exe` と `mysqldump.exe` を PATH に置く。接続前にパスワードを環境変数へ入れる。

```powershell
$env:AURORA_PASSWORD = '...'
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action new-sample -Workbook examples\sample.xlsm
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action export-plan -Workbook examples\sample.xlsm -OutFile examples\app.plan.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action generate -Plan examples\orders.plan.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action ping -Plan examples\app.plan.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action prepare -Plan examples\app.plan.txt -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action cleanup -Plan examples\app.plan.txt -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ps\Invoke-AuroraDataTool.ps1 -Action self-test
```

`-PasswordEnv` または `-PasswordFile` でも渡せる。コマンドラインにパスワードは置かない。

動作は `ping`、`dump`、`export-csv`、`delete`、`load-csv`、`generate`、`generate-and-load`、`prepare`、`cleanup`、`inspect`、`export-plan`、`new-sample`、`self-test`。

`delete`、`load-csv`、`generate-and-load`、`prepare`、`cleanup` は、プランの `confirm=YES` と `-Execute` が揃うまでデータベースへ接続しない。削除を含む動作はさらに `allow_destructive=YES` が必要である。既定の `delete_mode` は `none`。CSV バックアップなしの削除は `allow_delete_without_backup=YES` がないと拒否する。

`prepare` は、ダンプ、CSV バックアップ、子テーブルから順の削除、親から順の生成とロード、行数確認の順で進む。`cleanup_mode` の既定は `restore-csv` で、テスト前の CSV を戻す。`delete-inserted` はマーカー列、または記録した主キーの範囲で削除する。`truncate` は表を空にする。

`inspect` はライブのスキーマを Excel に書く。実行時はライブの列でプランの生成設定を上書きし、プランにない列は `unknown_column_policy`（既定 `error`）に従う。

## Excel

`new-sample` または `inspect` がブックを作る。シートは「使い方」「接続」「ジョブ」「テーブル」「列」「外部キー」と、入力規則用の非表示「リスト」である。1 行目が日本語名、2 行目がプランのキー、データは 3 行目からである。灰色の列はスキーマ、黄色の列が生成設定である。

拡張子が `.xlsm` のとき、Excel を起動してボタン「処理設定ファイルを出力する」を埋め込む。ボタンは `Export-LoadPlan.ps1` を呼ぶ。この間だけ `HKCU\Software\Microsoft\Office\16.0\Excel\Security\AccessVBOM` を 1 にし、Excel を終了させてから元の値へ戻す。起動した Excel のプロセス ID だけを待ち、残っていればそのプロセスだけを止める。ほかの Excel は止めない。マクロの埋め込みに失敗した場合でも、同じエクスポーターを `-Action export-plan` で直接実行できる。`.xlsx` を作るだけなら、ブック生成関数の `-NoButton` と同じくマクロなしで足りる。

生成方法 `auto` は Excel に残し、実行時に型から決める。整数の `AUTO_INCREMENT` は明示的な一意値になる。生成列と geometry は `skip` になる。

## RHEL 9.8

```bash
bash tools/bash/aurora-data-tool.sh selftest
bash tools/bash/aurora-data-tool.sh generate --plan examples/orders.plan.txt --out ./out
bash tools/bash/aurora-data-tool.sh dumpargs --plan examples/orders.plan.txt --defaults /tmp/client.cnf --result /tmp/app.sql
```

`generate` はテーブルごとの CSV を書く。乱数は PowerShell と一致する（`LC_ALL=C`）。次は PowerShell 側の生成器を使う。

- 64 ビットを超える数値範囲
- 負の範囲
- `string_mode=unicode`
- ライブの参照プール（`reference_mode=list` と `prior`）
- ダンプの実行、削除、ロード、後片付け

awk の CSV は NUL と 0x1A も `\0` と `\Z` にエスケープする。awk の文字列に NUL を置けない処理系では、その文字を含むデータは PowerShell で生成する。

## データとダンプ

CSV 方言 `aurora1` は、UTF-8、BOM なし、LF、カンマ区切りである。NULL は引用しない `\N`。それ以外は二重引用符で囲み、`\`、`"`、改行、CR、NUL、0x1A をバックスラッシュでエスケープする。先頭行はヘッダである。バイナリは 16 進、geometry は WKB の 16 進で書き、INSERT では `UNHEX` と `ST_GeomFromWKB` に戻す。

既定のロードは複数行 INSERT である。`load_method=local-infile` は、すべての投入列がテキストで、式・生成列・除外列がないときだけ `LOAD DATA LOCAL` を使う。サーバの `local_infile` とクライアントの `--local-infile=1` が必要である。失敗したときは INSERT に戻る。

ダンプの引数は `--single-transaction`、`--quick`、`--skip-lock-tables`、`--no-tablespaces`、`--set-gtid-purged=OFF`、`--column-statistics=0`、`--default-character-set=utf8mb4`、`--hex-blob` である。`--master-data` は付けない。クライアントが `column-statistics` を知らない場合は、その指定だけ外して 1 回再実行する。`dump_scope=tables` のときはデータベース名を繰り返さない。

クライアント設定は一時ファイルに書き、ACL を絞り、処理の最後に内容を消してから削除する。

## 生成

`seed` とテーブル名から決まる乱数なので、同じプランは同じ CSV になる。列の戦略は `auto`、`skip`、`const`、`range`、`unique`、`random`、`choice`、`template`、`datetime`、`pattern`、`null`、`reference`、`expression`。

`{seq}` は列ごとの開始値に行番号かける刻みを足す。`{seq:4}` はゼロ埋め。`choice` の区切りは `|`。空文字は `$EMPTY$`、SQL の NULL は `$NULL$`。パターンは `#` 数字、`A` 大文字、`a` 小文字、`X` 英数字、`\` で次の文字をそのまま出す。

`reference_mode=virtual` は、親を消してから連番で入れ直すときの子の外部キーに使う。サーバ上の既存値を引くのは PowerShell の `prepare` である。

`row_count` が 100000000 を超えるときは `allow_huge=YES` が必要である。

## 確認済みのことと限界

`tests/Run-UnitTests.ps1` は、プランの引用、CSV 方言、INSERT、ダンプ引数、破壊的操作の拒否、偽の mysql クライアントによるダンプ再試行、Excel ブックの往復、PowerShell と awk の SHA256 一致を新しい PowerShell プロセスで実行する。`examples/orders.plan.txt` の 20 行生成と、子の `order_id` が 1 から 20 に収まることも見る。

同じマシンで `.xlsm` の生成を確認した。ブックに `xl/vbaProject.bin` があり、起動した Excel は終了し、事前に無かった `AccessVBOM` は事後も無い。

この環境には MySQL 8.4 のクライアントも起動中のサーバもなく、Docker は止めたままである。実データベースへのラウンドトリップは未実施である。
