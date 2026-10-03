# プランテキスト

UTF-8、BOM なし、改行は LF。`#` で始まる行だけがコメントである。セクションは `[meta]`、`[connection]`、`[job]`、`[table]`、`[column]`。未知のセクションと未知のキーはエラーになる。キー `password` は拒否する。

値に空白、引用符、バックスラッシュが含まれるときは二重引用符で囲む。書き出すときは `\` を `\\` にしてから `"` を `\"` にする。読むときは逆に、`\"` を先に戻してから `\\` を戻す。

相対パスはプランファイルのあるディレクトリから解決する。プロセスのカレントディレクトリからは解決しない。

## meta

| キー | 意味 |
| --- | --- |
| format_version | `1` 固定 |
| generated_at | 出力時刻。空なら省略 |
| generator | 出力したプログラム |
| source_workbook | 元のブック名 |

## connection

| キー | 意味 |
| --- | --- |
| host | ホスト。データベースへ繋ぐ動作では必須 |
| port | 1 から 65535。既定 3306 |
| database | データベース名 |
| user | ユーザー |
| ssl_mode | `REQUIRED`、`VERIFY_CA`、`VERIFY_IDENTITY`、`DISABLED` |
| ssl_ca | `VERIFY_CA` と `VERIFY_IDENTITY` の CA |
| password_source | `env:名前`、`file:パス`、`prompt` |

## job

空の項目は実行時に既定値で埋める。

| キー | 既定 | 意味 |
| --- | --- | --- |
| action | prepare | 実行する動作 |
| row_count | 1000 | テーブル側に件数がないときの生成行数 |
| batch_size | 500 | 1 つの INSERT に入れる行数 |
| load_method | insert | `insert` または `local-infile` |
| output_dir | ./out | ダンプ、CSV、実行状態の出力先 |
| dump_path | | ダンプファイル。空なら出力先に作る |
| dump_scope | database | `database` または `tables` |
| dump_routines | YES | ルーチンを含める |
| dump_triggers | YES | トリガーを含める |
| dump_events | YES | イベントを含める |
| seed | 1 | 0 から 2^64-1。0 は内部で固定値に置き換える |
| delete_mode | none | `none`、`truncate`、`delete` |
| allow_destructive | NO | 削除を伴う動作に必要 |
| allow_delete_without_backup | NO | CSV なし削除を許可 |
| confirm | NO | `-Execute` と組で更新を許可 |
| disable_fk_checks | YES | セッションの外部キー検査 |
| relax_unique_checks | YES | ロード中の一意検査 |
| charset | utf8mb4 | クライアント文字セット |
| time_zone | +00:00 | セッションのタイムゾーン。`:` を含めてよい |
| cleanup_mode | restore-csv | `restore-csv`、`delete-inserted`、`truncate` |
| include_dump | YES | prepare でダンプする |
| include_csv_backup | YES | 更新前に CSV を取る |
| null_ratio | 0 | ジョブの既定。列に値があるとその列だけが使う |
| string_mode | ascii | `ascii` または `unicode`（ひらがな） |
| max_packet_bytes | 4194304 | 1 バッチの上限 |
| chunk_rows | 5000 | CSV バックアップの分割 |
| reference_limit | 200000 | ライブ参照の DISTINCT 上限 |
| verify_row_count | YES | ロード後に COUNT(*) |
| unknown_column_policy | error | `error`、`skip`、`auto` |
| csv_dialect | aurora1 | この値だけ |
| allow_huge | NO | 1 億行超の許可 |

`time_zone` に使える文字は英数字、`_`、`/`、`+`、`.`、`:`、`-` で、長さは 1 から 64 である。

## table

`[table]` の直後に、そのテーブルの `[column]` を続ける。

| キー | 意味 |
| --- | --- |
| name | テーブル名 |
| include | `YES` または `NO` |
| row_count | このテーブルだけの生成行数 |
| delete_mode | ジョブの値を上書き |
| csv_backup_path | バックアップ CSV |
| load_csv_path | `load-csv` が読む CSV |
| cleanup_mode | このテーブルだけの後片付け |
| marker_column | `delete-inserted` の列 |
| marker_value | その値 |
| notes | メモ。実行には使わない |

## column

| キー | 意味 |
| --- | --- |
| table | 所属テーブル。セクションのテーブルと一致させる |
| name | 列名 |
| ordinal | 出力順 |
| column_type | `SHOW COLUMNS` の型。ENUM のメンバー解析に使う |
| data_type | `bigint` や `varchar` などのデータ型 |
| is_nullable | `YES` または `NO`。空は NOT NULL として検証する |
| column_key | `PRI`、`UNI`、`MUL` |
| extra | サーバの Extra |
| column_default | 既定値 |
| char_length | 文字数の上限 |
| num_precision | 数値の精度 |
| num_scale | 小数桁 |
| datetime_precision | 0 から 6 |
| is_unsigned | `YES` または `NO` |
| is_generated | 生成列は `YES` |
| is_auto_increment | `YES` または `NO` |
| enum_values | `NEW\|PAID` の形 |
| fk_table | 外部キーの親テーブル |
| fk_column | 親の列 |
| strategy | 下の生成方法 |
| const_value | `const` の値。`$NULL$` は NULL |
| range_min | 範囲の下限。含む |
| range_max | 範囲の上限。含む |
| unique_mode | `sequence`、`sequence_prefixed`、`uuid` |
| unique_start | 開始。既定 1。実行時に空なら MAX+1 を埋めることがある |
| unique_step | 刻み。既定 1 |
| unique_prefix | `sequence_prefixed` の接頭辞 |
| unique_pad | ゼロ埋め桁 |
| choice_list | `\|` 区切り |
| template | `{seq}` などを含む文字列 |
| pattern | `#` `A` `a` `X` と `\` |
| null_ratio | 0 から 1。空なら乱数を消費しない |
| string_length | `random` の長さ |
| string_min_length | 長さを乱数にするときの下限 |
| string_max_length | 上限 |
| reference_table | 参照する親 |
| reference_column | 参照する列 |
| reference_mode | `virtual`、`list`、`prior` |
| reference_start | virtual の開始 |
| reference_count | virtual の件数 |
| reference_step | virtual の刻み |
| expression | INSERT にそのまま入れる式。`;` とコメントは拒否 |
| include | `NO` なら投入しない |
| overflow | `error` または `truncate` |
| unique_suffix | `YES` ならランダム値の末尾に連番を足す |
| notes | `auto` から決めた列には `[auto]` が付く |

`expression` と `skip` と `include=NO` の列は生成 CSV に出さない。`expression` は INSERT の値リストへ式のまま入る。

## 生成方法

`auto` は次の順で決める。

1. 生成列と geometry は `skip`
2. 整数の AUTO_INCREMENT、または整数の主キー / 一意キーは `unique`
3. 外部キーは `reference`
4. ENUM / SET は `choice`
5. `tinyint(1)` は `0|1`
6. 数値と年と bit は `range`
7. 日付時刻は `datetime`。日付の既定範囲は 2024-01-01 から 2026-12-31
8. JSON は `{"n":{seq}}`
9. 名前に uuid、email、phone、zip を含む文字列はそれぞれ一意 UUID、テンプレート、パターン
10. その他の文字列は `random`

`unique` の UUID は乱数を消費しない。ジョブの seed、テーブル、列、行番号から 8-4-4-4-12 の形を作り、版ニブルを 4、variant を RFC の範囲に固定する。

`reference_mode=virtual` は `reference_start + 乱数 * reference_step` である。乱数は 0 以上 `reference_count` 未満。`prior` は同じテーブルのすでに出した行から選ぶ。`list` は実行時に埋めた値の配列から選ぶ。

`null_ratio` が空または 0 のときは、値を作ったあとに乱数を引かない。0 より大きいときだけ 1 回引き、閾値未満なら NULL にする。戦略自体が NULL を返したときは、追加では引かない。

## 実行状態

`output_dir/run-state.txt` に、動作、データベース、seed、開始時刻、状態（`partial` または `success`）、プランファイルの SHA256、バックアップと生成 CSV のパス、削除の有無、主キーの範囲、マーカーを書く。`cleanup` はこのファイルを読む。
