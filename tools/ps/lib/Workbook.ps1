$script:JaLabels = @{
    host = 'ホスト'; port = 'ポート'; database = 'データベース'; user = 'ユーザー'
    ssl_mode = 'SSLモード'; ssl_ca = 'CA証明書'; password_source = 'パスワードの取得元'
    action = '動作'; row_count = '生成行数'; batch_size = 'INSERTバッチ件数'; load_method = 'ロード方法'
    output_dir = '出力ディレクトリ'; dump_path = 'ダンプ出力パス'; dump_scope = 'ダンプ範囲'
    dump_routines = 'ルーチンを含める'; dump_triggers = 'トリガーを含める'; dump_events = 'イベントを含める'
    seed = '乱数シード'; delete_mode = '削除方法'; allow_destructive = '破壊的操作を許可'
    allow_delete_without_backup = 'バックアップなし削除を許可'; confirm = '実行確認'
    disable_fk_checks = '外部キー検査を無効化'; relax_unique_checks = '一意検査を緩める'
    charset = '文字セット'; time_zone = 'タイムゾーン'; cleanup_mode = '後片付け方法'
    include_dump = 'ダンプを取得'; include_csv_backup = 'CSVバックアップを取得'; null_ratio = 'NULL比率'
    string_mode = '文字列モード'; max_packet_bytes = '最大パケットバイト'; chunk_rows = 'CSV分割行数'
    reference_limit = '参照値の上限'; verify_row_count = '行数を検証'
    unknown_column_policy = '未知の列の扱い'; csv_dialect = 'CSV形式'; allow_huge = '巨大行数を許可'
    name = '名前'; include = '対象'; csv_backup_path = 'CSVバックアップパス'; load_csv_path = 'ロードするCSV'
    marker_column = 'マーカー列'; marker_value = 'マーカー値'; notes = 'メモ'
    table = 'テーブル'; ordinal = '順序'; column_type = '列型'; data_type = 'データ型'
    is_nullable = 'NULL許可'; column_key = 'キー'; extra = '追加属性'; column_default = '既定値'
    char_length = '文字長'; num_precision = '精度'; num_scale = '小数桁'; datetime_precision = '時刻精度'
    is_unsigned = '符号なし'; is_generated = '生成列'; is_auto_increment = '自動採番'
    enum_values = 'ENUM/SET値'; fk_table = '参照テーブル'; fk_column = '参照列'; strategy = '生成方法'
    const_value = '固定値'; range_min = '最小'; range_max = '最大'; unique_mode = '一意方式'
    unique_start = '開始値'; unique_step = '刻み'; unique_prefix = '接頭辞'; unique_pad = 'ゼロ埋め桁'
    choice_list = '選択リスト'; template = 'テンプレート'; pattern = 'パターン'
    string_length = '文字数'; string_min_length = '最小文字数'; string_max_length = '最大文字数'
    reference_table = '参照元テーブル'; reference_column = '参照元列'; reference_mode = '参照方式'
    reference_start = '参照開始'; reference_count = '参照件数'; reference_step = '参照刻み'
    expression = 'SQL式'; overflow = '桁あふれ'; unique_suffix = '一意接尾辞'
    column = '列'; referenced_table = '参照先テーブル'; referenced_column = '参照先列'
}

$script:ColumnGrayKeys = @(
    'ordinal','column_type','data_type','is_nullable','column_key','extra','column_default',
    'char_length','num_precision','num_scale','datetime_precision','is_unsigned','is_generated',
    'is_auto_increment','enum_values','fk_table','fk_column'
)

function ConvertTo-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function ConvertTo-ColumnName {
    param([int]$Index)
    $n = $Index
    $s = ''
    while ($n -gt 0) {
        $n--
        $s = [char](65 + ($n % 26)) + $s
        $n = [int][math]::Floor($n / 26)
    }
    return $s
}

function Get-ColumnIndexFromRef {
    param([string]$Ref)
    $letters = ($Ref -replace '[0-9]', '')
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
    return $n
}

function Get-InlineCell {
    param([string]$Ref, [string]$Text, [int]$Style)
    if ($null -eq $Text) { $Text = '' }
    $space = ''
    if ($Text.StartsWith(' ') -or $Text.EndsWith(' ') -or $Text.Contains("`n") -or $Text.Contains("`r")) { $space = ' xml:space="preserve"' }
    return '<c r="' + $Ref + '" t="inlineStr" s="' + $Style + '"><is><t' + $space + '>' + (ConvertTo-XmlText $Text) + '</t></is></c>'
}

function Get-JaLabel {
    param([string]$Key)
    if ($script:JaLabels.ContainsKey($Key)) { return [string]$script:JaLabels[$Key] }
    return $Key
}

function New-GridWorksheetXml {
    param([string[]]$Keys, [hashtable[]]$Rows, [string[]]$GrayKeys, [hashtable]$Validations, [int]$LastDataRow)
    $gray = @{}
    foreach ($g in @($GrayKeys)) { $gray[$g] = $true }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    [void]$sb.Append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="2" topLeftCell="A3" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
    $width = [Math]::Max(8, $Keys.Count)
    [void]$sb.Append('<cols><col min="1" max="' + $width + '" width="22" customWidth="1"/></cols><sheetData>')
    [void]$sb.Append('<row r="1">')
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        $ref = (ConvertTo-ColumnName ($i + 1)) + '1'
        [void]$sb.Append((Get-InlineCell $ref (Get-JaLabel $Keys[$i]) 1))
    }
    [void]$sb.Append('</row><row r="2">')
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        $ref = (ConvertTo-ColumnName ($i + 1)) + '2'
        [void]$sb.Append((Get-InlineCell $ref $Keys[$i] 2))
    }
    [void]$sb.Append('</row>')
    $r = 3
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        [void]$sb.Append('<row r="' + $r + '">')
        for ($i = 0; $i -lt $Keys.Count; $i++) {
            $key = $Keys[$i]
            $text = ''
            if ($row.ContainsKey($key) -and $null -ne $row[$key]) { $text = [string]$row[$key] }
            $style = 3
            if ($gray.ContainsKey($key)) { $style = 2 }
            $ref = (ConvertTo-ColumnName ($i + 1)) + [string]$r
            [void]$sb.Append((Get-InlineCell $ref $text $style))
        }
        [void]$sb.Append('</row>')
        $r++
    }
    [void]$sb.Append('</sheetData>')
    $rules = @()
    if ($null -ne $Validations) {
        for ($i = 0; $i -lt $Keys.Count; $i++) {
            $key = $Keys[$i]
            if (-not $Validations.ContainsKey($key)) { continue }
            $letter = ConvertTo-ColumnName ($i + 1)
            $rules += '<dataValidation type="list" allowBlank="1" showErrorMessage="1" sqref="' + $letter + '3:' + $letter + $LastDataRow + '"><formula1>' + $Validations[$key] + '</formula1></dataValidation>'
        }
    }
    if ($rules.Count -gt 0) {
        [void]$sb.Append('<dataValidations count="' + $rules.Count + '">')
        foreach ($rule in $rules) { [void]$sb.Append($rule) }
        [void]$sb.Append('</dataValidations>')
    }
    [void]$sb.Append('</worksheet>')
    return $sb.ToString()
}

function New-HelpWorksheetXml {
    param([string]$Exporter, [string]$OutputPlan)
    $lines = @(
        @('Aurora データ投入ツール', ''),
        @('エクスポータースクリプト', $Exporter),
        @('出力する設定ファイル', $OutputPlan),
        @('', ''),
        @('手順', ''),
        @('1. 接続、ジョブ、テーブル、列の各シートを確認します。', ''),
        @('2. 列シートの「生成方法」以降を編集します。スキーマ列（灰色）はデータベースから取得した情報です。', ''),
        @('3. ブックを保存してから、ボタン「処理設定ファイルを出力する」を押します。', ''),
        @('4. 出力されたテキストファイルを指定して、PowerShell または RHEL のスクリプトを実行します。', ''),
        @('', ''),
        @('パスワードはこのブックへ保存しません。password_source は env:変数名、file:パス、prompt のいずれかです。', ''),
        @('データを消す、または大量投入するには、confirm を YES にし、実行時に -Execute を付けます。', ''),
        @('削除を伴う動作は allow_destructive=YES も必要です。既定の delete_mode は none です。', ''),
        @('生成方法 auto は実行時に列の型から決まります。AUTO_INCREMENT の整数は一意な明示値になります。', ''),
        @('選択肢の区切りは縦棒 | です。空文字は $EMPTY$、SQL の NULL は $NULL$ と書きます。', ''),
        @('ランダム文字列のパターンは # 数字、A 大文字、a 小文字、X 英数字、\ で次の文字をそのまま出します。', ''),
        @('テンプレートは {seq} {seq:4} {uuid} {rand} {rand:100} {alpha:8} {digit:4} {hex:8} {choice:A|B} を使えます。', '')
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    [void]$sb.Append('<cols><col min="1" max="1" width="88" customWidth="1"/><col min="2" max="2" width="78" customWidth="1"/></cols><sheetData>')
    $r = 1
    foreach ($line in $lines) {
        [void]$sb.Append('<row r="' + $r + '">')
        $style = 0
        if ($r -eq 1) { $style = 1 }
        [void]$sb.Append((Get-InlineCell ('A' + $r) $line[0] $style))
        [void]$sb.Append((Get-InlineCell ('B' + $r) $line[1] 3))
        [void]$sb.Append('</row>')
        $r++
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function New-ListWorksheetXml {
    $columns = @(
        @('生成方法','auto','skip','const','range','unique','random','choice','template','pattern','null','reference','datetime','expression'),
        @('YES/NO','YES','NO'),
        @('一意方式','sequence','sequence_prefixed','uuid'),
        @('削除方法','none','truncate','delete'),
        @('後片付け','restore-csv','delete-inserted','truncate'),
        @('ロード方法','insert','local-infile'),
        @('SSL','REQUIRED','VERIFY_CA','VERIFY_IDENTITY','DISABLED'),
        @('文字列','ascii','unicode'),
        @('未知の列','error','skip','auto'),
        @('ダンプ範囲','database','tables'),
        @('参照方式','virtual','list','prior'),
        @('桁あふれ','error','truncate')
    )
    $max = 1
    foreach ($c in $columns) { if ($c.Count -gt $max) { $max = $c.Count } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    for ($r = 1; $r -le $max; $r++) {
        [void]$sb.Append('<row r="' + $r + '">')
        for ($c = 0; $c -lt $columns.Count; $c++) {
            $text = ''
            if ($r -le $columns[$c].Count) { $text = [string]$columns[$c][$r - 1] }
            $style = 0
            if ($r -eq 1) { $style = 1 }
            [void]$sb.Append((Get-InlineCell ((ConvertTo-ColumnName ($c + 1)) + $r) $text $style))
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function Get-WorkbookStylesXml {
    return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="3">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
    <font><i/><sz val="10"/><color rgb="FF595959"/><name val="Calibri"/></font>
  </fonts>
  <fills count="5">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/></patternFill></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="4">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
  </cellXfs>
</styleSheet>
'@
}

function Get-ListFormulaMap {
    return @{
        strategy = '''リスト''!$A$2:$A$14'
        include = '''リスト''!$B$2:$B$3'
        dump_routines = '''リスト''!$B$2:$B$3'
        dump_triggers = '''リスト''!$B$2:$B$3'
        dump_events = '''リスト''!$B$2:$B$3'
        allow_destructive = '''リスト''!$B$2:$B$3'
        allow_delete_without_backup = '''リスト''!$B$2:$B$3'
        confirm = '''リスト''!$B$2:$B$3'
        disable_fk_checks = '''リスト''!$B$2:$B$3'
        relax_unique_checks = '''リスト''!$B$2:$B$3'
        include_dump = '''リスト''!$B$2:$B$3'
        include_csv_backup = '''リスト''!$B$2:$B$3'
        verify_row_count = '''リスト''!$B$2:$B$3'
        allow_huge = '''リスト''!$B$2:$B$3'
        unique_suffix = '''リスト''!$B$2:$B$3'
        unique_mode = '''リスト''!$C$2:$C$4'
        delete_mode = '''リスト''!$D$2:$D$4'
        cleanup_mode = '''リスト''!$E$2:$E$4'
        load_method = '''リスト''!$F$2:$F$3'
        ssl_mode = '''リスト''!$G$2:$G$5'
        string_mode = '''リスト''!$H$2:$H$3'
        unknown_column_policy = '''リスト''!$I$2:$I$4'
        dump_scope = '''リスト''!$J$2:$J$3'
        reference_mode = '''リスト''!$K$2:$K$4'
        overflow = '''リスト''!$L$2:$L$3'
    }
}

function Write-ZipText {
    param($Zip, [string]$Name, [string]$Text)
    $entry = $Zip.CreateEntry($Name.Replace('\', '/'))
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $stream = $entry.Open()
    try {
        $bytes = $utf8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

function New-AuroraWorkbook {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExporterScript,
        [string]$OutputPlanPath,
        [hashtable[]]$ForeignKeys,
        [switch]$NoButton
    )
    Complete-AuroraPlan $Plan
    if ([string]::IsNullOrWhiteSpace($ExporterScript)) {
        $ExporterScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Export-LoadPlan.ps1'))
    }
    if ([string]::IsNullOrWhiteSpace($OutputPlanPath)) {
        $OutputPlanPath = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($Path), '.plan.txt')
    }
    $formulas = Get-ListFormulaMap
    $connRow = @{}
    foreach ($k in $script:AuroraConnectionKeys) { if ($Plan.Connection.ContainsKey($k)) { $connRow[$k] = [string]$Plan.Connection[$k] } }
    $jobRow = @{}
    foreach ($k in $script:AuroraJobKeys) { if ($Plan.Job.ContainsKey($k)) { $jobRow[$k] = [string]$Plan.Job[$k] } }
    $tableRows = @()
    $columnRows = @()
    foreach ($t in @($Plan.Tables)) {
        $tableRows += $t
        foreach ($c in @($t.Columns)) { $columnRows += $c }
    }
    $fkRows = @()
    if ($ForeignKeys) { $fkRows = @($ForeignKeys) }
    else {
        foreach ($c in $columnRows) {
            if (-not [string]::IsNullOrWhiteSpace([string]$c['fk_table'])) {
                $fkRows += @{ table = [string]$c['table']; column = [string]$c['name']; referenced_table = [string]$c['fk_table']; referenced_column = [string]$c['fk_column'] }
            }
        }
    }
    $sheets = @(
        @{ Name = '使い方'; Xml = (New-HelpWorksheetXml $ExporterScript $OutputPlanPath) },
        @{ Name = '接続'; Xml = (New-GridWorksheetXml $script:AuroraConnectionKeys @($connRow) @() $formulas 3) },
        @{ Name = 'ジョブ'; Xml = (New-GridWorksheetXml $script:AuroraJobKeys @($jobRow) @() $formulas 3) },
        @{ Name = 'テーブル'; Xml = (New-GridWorksheetXml $script:AuroraTableKeys $tableRows @() $formulas 500) },
        @{ Name = '列'; Xml = (New-GridWorksheetXml $script:AuroraColumnKeys $columnRows $script:ColumnGrayKeys $formulas 2000) },
        @{ Name = '外部キー'; Xml = (New-GridWorksheetXml @('table','column','referenced_table','referenced_column') $fkRows @() @{} 500) },
        @{ Name = 'リスト'; Xml = (New-ListWorksheetXml); Hidden = $true }
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $xlsx = $full
    $wantMacro = $full.ToLowerInvariant().EndsWith('.xlsm') -and -not $NoButton
    if ($wantMacro) { $xlsx = [System.IO.Path]::ChangeExtension($full, '.xlsx') }
    $parent = Split-Path -Parent $xlsx
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $xlsx) { Remove-Item -LiteralPath $xlsx -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open($xlsx, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $types = New-Object System.Text.StringBuilder
            [void]$types.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            [void]$types.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
            [void]$types.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
            [void]$types.Append('<Default Extension="xml" ContentType="application/xml"/>')
            [void]$types.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
            [void]$types.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
            for ($i = 1; $i -le $sheets.Count; $i++) {
                [void]$types.Append('<Override PartName="/xl/worksheets/sheet' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
            }
            [void]$types.Append('</Types>')
            Write-ZipText $zip '[Content_Types].xml' $types.ToString()
            Write-ZipText $zip '_rels/.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
            $rels = New-Object System.Text.StringBuilder
            [void]$rels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
            for ($i = 1; $i -le $sheets.Count; $i++) {
                [void]$rels.Append('<Relationship Id="rId' + $i + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + $i + '.xml"/>')
            }
            [void]$rels.Append('<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
            Write-ZipText $zip 'xl/_rels/workbook.xml.rels' $rels.ToString()
            $book = New-Object System.Text.StringBuilder
            [void]$book.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            [void]$book.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>')
            for ($i = 0; $i -lt $sheets.Count; $i++) {
                $state = ''
                if ($sheets[$i].Hidden) { $state = ' state="hidden"' }
                [void]$book.Append('<sheet name="' + (ConvertTo-XmlText $sheets[$i].Name) + '" sheetId="' + ($i + 1) + '"' + $state + ' r:id="rId' + ($i + 1) + '"/>')
            }
            [void]$book.Append('</sheets><definedNames>')
            [void]$book.Append('<definedName name="ExporterScript">' + '''使い方''!$B$2</definedName>')
            [void]$book.Append('<definedName name="OutputPlanPath">' + '''使い方''!$B$3</definedName>')
            [void]$book.Append('</definedNames></workbook>')
            Write-ZipText $zip 'xl/workbook.xml' $book.ToString()
            Write-ZipText $zip 'xl/styles.xml' (Get-WorkbookStylesXml)
            for ($i = 0; $i -lt $sheets.Count; $i++) {
                Write-ZipText $zip ('xl/worksheets/sheet' + ($i + 1) + '.xml') $sheets[$i].Xml
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    if ($wantMacro) {
        Add-AuroraWorkbookButton -XlsxPath $xlsx -XlsmPath $full
        return $full
    }
    if ($full -ne $xlsx -and $NoButton) {
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
        [System.IO.File]::Copy($xlsx, $full, $true)
    }
    return $xlsx
}

function Get-ExportMacroSource {
    return @'
Option Explicit

Public Sub ExportLoadPlan()
    Dim wb As Workbook
    Dim script As String
    Dim outPath As String
    Dim tmp As String
    Dim logPath As String
    Dim cmd As String
    Dim sh As Object
    Dim rc As Long
    On Error GoTo Fail
    Set wb = ThisWorkbook
    If Len(wb.Path) = 0 Then
        MsgBox "Save the workbook before exporting the plan.", vbExclamation
        Exit Sub
    End If
    wb.Save
    script = CStr(wb.Names("ExporterScript").RefersToRange.Value)
    outPath = CStr(wb.Names("OutputPlanPath").RefersToRange.Value)
    If Len(script) = 0 Or Len(outPath) = 0 Then
        MsgBox "Set the exporter script and the output plan path on the first sheet.", vbExclamation
        Exit Sub
    End If
    If Dir(script) = "" Then
        MsgBox "Exporter script was not found: " & script, vbCritical
        Exit Sub
    End If
    tmp = Environ$("TEMP") & "\aurora-plan-" & Format$(Now, "yyyymmddhhnnss") & ".xlsm"
    wb.SaveCopyAs tmp
    logPath = outPath & ".log"
    cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """ -Workbook """ & tmp & """ -OutFile """ & outPath & """ -Log """ & logPath & """"
    Set sh = CreateObject("WScript.Shell")
    rc = sh.Run("cmd.exe /s /c """ & cmd & """", 0, True)
    On Error Resume Next
    Kill tmp
    On Error GoTo Fail
    If rc <> 0 Then
        MsgBox "Plan export failed. See " & logPath, vbCritical
    Else
        MsgBox "Wrote " & outPath, vbInformation
    End If
    Exit Sub
Fail:
    MsgBox "Plan export failed: " & Err.Description, vbCritical
End Sub
'@
}

function Add-AuroraWorkbookButton {
    param([Parameter(Mandatory = $true)][string]$XlsxPath, [Parameter(Mandatory = $true)][string]$XlsmPath)
    $key = 'HKCU:\Software\Microsoft\Office\16.0\Excel\Security'
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $had = $false
    $old = 0
    $prop = Get-ItemProperty -Path $key -Name AccessVBOM -ErrorAction SilentlyContinue
    if ($null -ne $prop -and $null -ne $prop.AccessVBOM) { $had = $true; $old = [int]$prop.AccessVBOM }
    New-ItemProperty -Path $key -Name AccessVBOM -Value 1 -PropertyType DWord -Force | Out-Null
    if (-not ('AuroraDataTool.ExcelWindow' -as [type])) {
        Add-Type -Namespace AuroraDataTool -Name ExcelWindow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowThreadProcessId(int hWnd, out int processId);
'@
    }
    $excel = $null
    $wb = $null
    $module = $null
    $sheet = $null
    $button = $null
    $excelPid = 0
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.UserControl = $false
        $excel.AutomationSecurity = 1
        $procId = 0
        [void][AuroraDataTool.ExcelWindow]::GetWindowThreadProcessId([int]$excel.Hwnd, [ref]$procId)
        $excelPid = $procId
        $wb = $excel.Workbooks.Open((Resolve-Path -LiteralPath $XlsxPath).Path)
        foreach ($component in @($wb.VBProject.VBComponents)) {
            if ($component.Name -eq 'ExportLoadPlan') { $wb.VBProject.VBComponents.Remove($component) }
        }
        $module = $wb.VBProject.VBComponents.Add(1)
        $module.Name = 'ExportLoadPlan'
        $module.CodeModule.AddFromString((Get-ExportMacroSource))
        $sheet = $wb.Worksheets.Item(1)
        $button = $sheet.Buttons().Add(360, 78, 280, 34)
        $button.Name = 'ExportLoadPlanButton'
        $button.Caption = '処理設定ファイルを出力する'
        $button.OnAction = 'ExportLoadPlan'
        $target = [System.IO.Path]::GetFullPath($XlsmPath)
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        $wb.SaveAs($target, 52)
        $wb.Close($true)
        $wb = $null
    } finally {
        if ($null -ne $wb) { try { $wb.Close($false) } catch { } }
        foreach ($com in @($button, $sheet, $module, $wb)) {
            if ($null -eq $com) { continue }
            try { while ([Runtime.InteropServices.Marshal]::ReleaseComObject($com) -gt 0) { } } catch { }
        }
        if ($null -ne $excel) {
            try { $excel.Quit() } catch { }
            try { while ([Runtime.InteropServices.Marshal]::ReleaseComObject($excel) -gt 0) { } } catch { }
        }
        $excel = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        if ($excelPid -gt 0) {
            $proc = Get-Process -Id $excelPid -ErrorAction SilentlyContinue
            if ($null -ne $proc -and -not $proc.HasExited) {
                if (-not $proc.WaitForExit(8000)) { Stop-Process -Id $excelPid -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($had) { New-ItemProperty -Path $key -Name AccessVBOM -Value $old -PropertyType DWord -Force | Out-Null }
        else { Remove-ItemProperty -Path $key -Name AccessVBOM -ErrorAction SilentlyContinue }
    }
}

function Read-ZipXml {
    param($Zip, [string]$Name)
    $entry = $Zip.GetEntry($Name.Replace('\', '/'))
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $true
        $doc.Load($stream)
        return $doc
    } finally { $stream.Dispose() }
}

function Get-XlsxCellText {
    param($Cell, $Ns, [string[]]$Shared)
    $kind = $Cell.GetAttribute('t')
    if ($kind -eq 'inlineStr') {
        $texts = $Cell.SelectNodes('.//m:t', $Ns)
        $sb = New-Object System.Text.StringBuilder
        foreach ($node in @($texts)) { [void]$sb.Append($node.InnerText) }
        return $sb.ToString()
    }
    $valueNode = $Cell.SelectSingleNode('m:v', $Ns)
    if ($null -eq $valueNode) { return '' }
    if ($kind -eq 's') { return [string]$Shared[[int]$valueNode.InnerText] }
    if ($kind -eq 'b') { if ($valueNode.InnerText -eq '1') { return 'TRUE' }; return 'FALSE' }
    return $valueNode.InnerText
}

function Read-XlsxGrids {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open((Resolve-Path -LiteralPath $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $ns = New-Object System.Xml.XmlNamespaceManager (New-Object System.Xml.NameTable)
            $ns.AddNamespace('m', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            $ns.AddNamespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
            $ns.AddNamespace('p', 'http://schemas.openxmlformats.org/package/2006/relationships')
            $shared = @()
            $sst = Read-ZipXml $zip 'xl/sharedStrings.xml'
            if ($null -ne $sst) {
                $items = $sst.SelectNodes('/m:sst/m:si', $ns)
                $list = New-Object System.Collections.Generic.List[string]
                foreach ($si in @($items)) {
                    $texts = $si.SelectNodes('.//m:t', $ns)
                    $sb = New-Object System.Text.StringBuilder
                    foreach ($node in @($texts)) { [void]$sb.Append($node.InnerText) }
                    $list.Add($sb.ToString())
                }
                $shared = $list.ToArray()
            }
            $book = Read-ZipXml $zip 'xl/workbook.xml'
            $rels = Read-ZipXml $zip 'xl/_rels/workbook.xml.rels'
            $relMap = @{}
            foreach ($rel in @($rels.SelectNodes('/p:Relationships/p:Relationship', $ns))) {
                $relMap[$rel.GetAttribute('Id')] = $rel.GetAttribute('Target')
            }
            $grids = @{}
            foreach ($sheet in @($book.SelectNodes('/m:workbook/m:sheets/m:sheet', $ns))) {
                $name = $sheet.GetAttribute('name')
                if ($name -eq '使い方' -or $name -eq 'リスト') { continue }
                $rid = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
                $target = [string]$relMap[$rid]
                if ($target.StartsWith('/')) { $target = $target.TrimStart('/') } else { $target = 'xl/' + $target }
                $doc = Read-ZipXml $zip $target
                $matrix = @{}
                foreach ($row in @($doc.SelectNodes('//m:sheetData/m:row', $ns))) {
                    $rn = [int]$row.GetAttribute('r')
                    $matrix[$rn] = @{}
                    foreach ($cell in @($row.SelectNodes('m:c', $ns))) {
                        $ref = $cell.GetAttribute('r')
                        if ([string]::IsNullOrWhiteSpace($ref)) { continue }
                        $matrix[$rn][(Get-ColumnIndexFromRef $ref)] = Get-XlsxCellText $cell $ns $shared
                    }
                }
                if (-not $matrix.ContainsKey(2)) { throw "Sheet '$name' is missing the machine-key row (row 2)." }
                $data = @()
                $rn = 3
                while ($matrix.ContainsKey($rn)) {
                    $item = @{}
                    $any = $false
                    foreach ($col in @($matrix[2].Keys)) {
                        $key = [string]$matrix[2][$col]
                        if ([string]::IsNullOrWhiteSpace($key)) { continue }
                        $val = ''
                        if ($matrix[$rn].ContainsKey([int]$col)) { $val = [string]$matrix[$rn][[int]$col] }
                        if ($val -ne '') { $item[$key] = $val; $any = $true }
                    }
                    if (-not $any) { break }
                    $data += ,$item
                    $rn++
                }
                $grids[$name] = $data
            }
            return $grids
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Import-AuroraWorkbook {
    param([Parameter(Mandatory = $true)][string]$Path)
    $grids = Read-XlsxGrids -Path $Path
    foreach ($need in @('接続', 'ジョブ', 'テーブル', '列')) {
        if (-not $grids.ContainsKey($need)) { throw "Workbook is missing sheet '$need'." }
    }
    $plan = New-AuroraPlan
    $plan.Meta['generator'] = 'excel'
    $plan.Meta['source_workbook'] = [System.IO.Path]::GetFileName($Path)
    $plan.Meta['generated_at'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $conn = $null
    foreach ($row in @($grids['接続'])) { $conn = $row; break }
    if ($null -ne $conn) {
        foreach ($k in $script:AuroraConnectionKeys) { if ($conn.ContainsKey($k)) { $plan.Connection[$k] = [string]$conn[$k] } }
    }
    $job = $null
    foreach ($row in @($grids['ジョブ'])) { $job = $row; break }
    if ($null -ne $job) {
        foreach ($k in $script:AuroraJobKeys) { if ($job.ContainsKey($k)) { $plan.Job[$k] = [string]$job[$k] } }
    }
    $tables = @()
    $byName = @{}
    foreach ($row in @($grids['テーブル'])) {
        if ([string]::IsNullOrWhiteSpace([string]$row['name'])) { continue }
        $table = @{ Columns = @() }
        foreach ($k in $script:AuroraTableKeys) { if ($row.ContainsKey($k)) { $table[$k] = [string]$row[$k] } }
        $tables += $table
        $byName[[string]$table['name']] = $table
    }
    foreach ($row in @($grids['列'])) {
        if ([string]::IsNullOrWhiteSpace([string]$row['name'])) { continue }
        $tableName = [string]$row['table']
        if ([string]::IsNullOrWhiteSpace($tableName)) { throw 'A column row is missing table.' }
        if (-not $byName.ContainsKey($tableName)) {
            $created = @{ name = $tableName; include = 'YES'; Columns = @() }
            $tables += $created
            $byName[$tableName] = $created
        }
        $col = @{}
        foreach ($k in $script:AuroraColumnKeys) { if ($row.ContainsKey($k)) { $col[$k] = [string]$row[$k] } }
        $col['table'] = $tableName
        $byName[$tableName].Columns += ,$col
    }
    if ($grids.ContainsKey('外部キー')) {
        foreach ($fk in @($grids['外部キー'])) {
            $tableName = [string]$fk['table']
            $columnName = [string]$fk['column']
            if ([string]::IsNullOrWhiteSpace($tableName) -or [string]::IsNullOrWhiteSpace($columnName)) { continue }
            if (-not $byName.ContainsKey($tableName)) { continue }
            foreach ($col in @($byName[$tableName].Columns)) {
                if ([string]$col['name'] -ne $columnName) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$col['fk_table'])) { $col['fk_table'] = [string]$fk['referenced_table'] }
                if ([string]::IsNullOrWhiteSpace([string]$col['fk_column'])) { $col['fk_column'] = [string]$fk['referenced_column'] }
            }
        }
    }
    $plan.Tables = $tables
    return $plan
}

function New-ColumnMap {
    param([hashtable]$Values)
    $map = @{ include = 'YES'; strategy = 'auto' }
    foreach ($k in @($Values.Keys)) { $map[$k] = [string]$Values[$k] }
    return $map
}

function New-SampleAuroraPlan {
    $plan = New-AuroraPlan
    $plan.Connection['host'] = 'your-aurora-cluster.example.com'
    $plan.Connection['database'] = 'appdb'
    $plan.Connection['user'] = 'appuser'
    $plan.Job['action'] = 'prepare'
    $plan.Job['row_count'] = '20'
    $plan.Job['seed'] = '7'
    $plan.Job['output_dir'] = './out'
    $orders = @{
        name = 'orders'; include = 'YES'; Columns = @(
            (New-ColumnMap @{ table='orders'; name='id'; ordinal='1'; column_type='bigint'; data_type='bigint'; is_nullable='NO'; column_key='PRI'; extra='auto_increment'; is_auto_increment='YES' }),
            (New-ColumnMap @{ table='orders'; name='email'; ordinal='2'; column_type='varchar(255)'; data_type='varchar'; is_nullable='NO'; char_length='255' }),
            (New-ColumnMap @{ table='orders'; name='status'; ordinal='3'; column_type="enum('NEW','PAID','SHIPPED','CANCELLED')"; data_type='enum'; is_nullable='NO'; enum_values='NEW|PAID|SHIPPED|CANCELLED' }),
            (New-ColumnMap @{ table='orders'; name='amount'; ordinal='4'; column_type='decimal(10,2)'; data_type='decimal'; is_nullable='NO'; num_precision='10'; num_scale='2' }),
            (New-ColumnMap @{ table='orders'; name='note'; ordinal='5'; column_type='varchar(100)'; data_type='varchar'; is_nullable='YES'; char_length='100' }),
            (New-ColumnMap @{ table='orders'; name='created_at'; ordinal='6'; column_type='datetime'; data_type='datetime'; is_nullable='NO'; datetime_precision='0' }),
            (New-ColumnMap @{ table='orders'; name='flag'; ordinal='7'; column_type='tinyint(1)'; data_type='tinyint'; is_nullable='NO' })
        )
    }
    $items = @{
        name = 'order_items'; include = 'YES'; Columns = @(
            (New-ColumnMap @{ table='order_items'; name='id'; ordinal='1'; column_type='bigint'; data_type='bigint'; is_nullable='NO'; column_key='PRI'; extra='auto_increment'; is_auto_increment='YES' }),
            (New-ColumnMap @{ table='order_items'; name='order_id'; ordinal='2'; column_type='bigint'; data_type='bigint'; is_nullable='NO'; column_key='MUL'; fk_table='orders'; fk_column='id' }),
            (New-ColumnMap @{ table='order_items'; name='sku'; ordinal='3'; column_type='varchar(32)'; data_type='varchar'; is_nullable='NO'; char_length='32' }),
            (New-ColumnMap @{ table='order_items'; name='qty'; ordinal='4'; column_type='int'; data_type='int'; is_nullable='NO' }),
            (New-ColumnMap @{ table='order_items'; name='price'; ordinal='5'; column_type='decimal(10,2)'; data_type='decimal'; is_nullable='NO'; num_precision='10'; num_scale='2' })
        )
    }
    $plan.Tables = @($orders, $items)
    return $plan
}

function New-SampleWorkbook {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$NoButton)
    $plan = New-SampleAuroraPlan
    return New-AuroraWorkbook -Plan $plan -Path $Path -NoButton:$NoButton
}

function Invoke-AuroraInspect {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Plan,
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [string]$MysqlExe,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$WorkbookPath,
        [string]$OnlyTables
    )
    Complete-AuroraPlan $Plan
    $Plan.Job['action'] = 'inspect'
    $problems = @(Test-AuroraPlan $Plan)
    if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
    if ([string]::IsNullOrWhiteSpace($MysqlExe)) { $MysqlExe = 'mysql' }
    $mysql = Resolve-ClientExe $MysqlExe
    $defaults = $null
    try {
        $outDir = Get-PlanOutputDir $PlanPath $Plan
        $defaults = New-MysqlDefaultsFile -Connection $Plan.Connection -Password $Password
        Invoke-AuroraPing -Plan $Plan -MysqlExe $mysql -DefaultsFile $defaults -LogPath (Join-Path $outDir 'tool.log') | Out-Null
        $names = @()
        if (-not [string]::IsNullOrWhiteSpace($OnlyTables)) {
            foreach ($n in ($OnlyTables -split ',')) { if ($n.Trim().Length -gt 0) { $names += $n.Trim() } }
        } else {
            foreach ($t in @(Get-IncludedTables $Plan)) { $names += [string]$t['name'] }
        }
        $db = [string]$Plan.Connection['database']
        $queries = Get-SchemaQueries -Database $db -Tables $names
        $live = @(Invoke-QueryRows -MysqlExe $mysql -DefaultsFile $defaults -Database $db -Sql $queries.Columns)
        $keys = @(Invoke-QueryRows -MysqlExe $mysql -DefaultsFile $defaults -Database $db -Sql $queries.Keys)
        $fresh = @(New-TablesFromLiveRows -LiveColumns $live -ForeignKeys $keys)
        if ($names.Count -gt 0) {
            $have = @{}
            foreach ($t in $fresh) { $have[[string]$t['name']] = $true }
            foreach ($n in $names) { if (-not $have.ContainsKey($n)) { throw "Table '$n' was not found in $db." } }
        }
        $old = @{}
        foreach ($t in @($Plan.Tables)) {
            foreach ($c in @($t.Columns)) { $old[([string]$t['name']) + '|' + [string]$c['name']] = $c }
        }
        foreach ($t in $fresh) {
            foreach ($c in @($t.Columns)) {
                $id = ([string]$t['name']) + '|' + [string]$c['name']
                if (-not $old.ContainsKey($id)) { continue }
                foreach ($k in $script:StrategyOverlayKeys) {
                    if ($old[$id].ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace([string]$old[$id][$k])) { $c[$k] = [string]$old[$id][$k] }
                }
            }
        }
        $Plan.Tables = $fresh
        $fkMaps = @(Get-ForeignKeyMaps $keys)
        New-AuroraWorkbook -Plan $Plan -Path $WorkbookPath -ForeignKeys $fkMaps | Out-Null
    } finally {
        Remove-MysqlDefaultsFile $defaults
    }
}
