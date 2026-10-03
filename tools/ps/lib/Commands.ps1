function Write-ToolLog {
    param([string]$Message, [string]$LogPath)
    $line = ([DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')) + ' ' + $Message
    Write-Host $line
    if (-not [string]::IsNullOrEmpty($LogPath)) {
        try { [System.IO.File]::AppendAllText($LogPath, $line + "`n", (New-Object System.Text.UTF8Encoding $false)) } catch { }
    }
}

function Get-PlanOutputDir {
    param([string]$PlanPath, [hashtable]$Plan)
    $dir = Resolve-PlanRelativePath $PlanPath ([string]$Plan.Job['output_dir'])
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function ConvertTo-FileToken {
    param([string]$Name)
    $token = [regex]::Replace([string]$Name, '[^A-Za-z0-9_-]', '_')
    if ([string]::IsNullOrEmpty($token)) { return 'table' }
    return $token
}

function Test-ActionMutates {
    param([string]$Action)
    return @('delete','load-csv','generate-and-load','prepare','cleanup') -contains $Action
}

function Assert-Confirmed {
    param([hashtable]$Plan, [bool]$Execute, [string]$Action, [bool]$Destructive)
    if (-not (Test-ActionMutates $Action)) { return }
    if (-not $Execute) { throw "Dry-run: '$Action' was not applied. Set confirm=YES in the plan and pass -Execute." }
    if ([string]$Plan.Job['confirm'] -ne 'YES') { throw "Refusing '$Action' because confirm is not YES." }
    if ($Destructive -and [string]$Plan.Job['allow_destructive'] -ne 'YES') {
        throw "Refusing destructive '$Action' because allow_destructive is not YES."
    }
}

function Invoke-QueryRows {
    param($MysqlExe, $DefaultsFile, $Database, [string]$Sql)
    $result = Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $Database -Sql $Sql
    return @(ConvertFrom-MysqlBatch $result.Stdout)
}

function Invoke-QueryScalar {
    param($MysqlExe, $DefaultsFile, $Database, [string]$Sql)
    $rows = @(Invoke-QueryRows -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $Database -Sql $Sql)
    if ($rows.Count -lt 1) { throw 'The query returned no row.' }
    $first = $rows[0]
    foreach ($k in @($first.Keys)) { return [string]$first[$k] }
    throw 'The query returned an empty row.'
}

function Resolve-TableStrategies {
    param([hashtable]$Table, [long]$RowCount)
    $warnings = New-Object System.Collections.Generic.List[string]
    $ordered = @($Table.Columns | Sort-Object { [int]$_['ordinal'] })
    $resolved = @()
    foreach ($col in $ordered) {
        $keptValues = $null
        if ($col.ContainsKey('reference_values')) { $keptValues = $col['reference_values'] }
        $spec = New-ColumnSpecFromMap $col
        $local = New-Object System.Collections.Generic.List[string]
        [AuroraDataTool.StrategyResolver]::Resolve($spec, $local)
        foreach ($w in $local) { [void]$warnings.Add($w) }
        $errors = [AuroraDataTool.StrategyResolver]::Validate($spec, $RowCount)
        if ($errors.Count -gt 0) { throw (($errors | ForEach-Object { [string]$_ }) -join "`n") }
        $map = Copy-ColumnSpecToMap $spec
        if ($null -ne $keptValues) { $map['reference_values'] = $keptValues }
        $resolved += $map
    }
    $Table.Columns = $resolved
    return @($warnings.ToArray())
}

function Update-UniqueStarts {
    param([hashtable]$Table, [hashtable]$Plan, $MysqlExe, $DefaultsFile, [bool]$Offline)
    $db = [string]$Plan.Connection['database']
    foreach ($col in @($Table.Columns)) {
        $wants = $false
        if ([string]$col['strategy'] -eq 'unique' -and [string]::IsNullOrEmpty([string]$col['unique_start'])) { $wants = $true }
        $template = [string]$col['template']
        if ([string]$col['strategy'] -eq 'template' -and $template.Contains('{seq') -and [string]::IsNullOrEmpty([string]$col['unique_start'])) { $wants = $true }
        if (-not $wants) { continue }
        $mode = [string]$col['unique_mode']
        $dt = [string]$col['data_type']
        $numeric = $mode -eq 'sequence' -and ($dt -match 'int|decimal|numeric|year|bit')
        if ($numeric -and -not $Offline) {
            $id = [AuroraDataTool.Sql]::QuoteIdent([string]$col['name'])
            $from = [AuroraDataTool.Sql]::QuoteQualified($db, [string]$Table['name'])
            $sql = (Get-SessionPreamble ([string]$Plan.Job['time_zone'])) + "`nSELECT COALESCE(MAX($id),0)+1 AS n FROM $from;`n"
            $col['unique_start'] = Invoke-QueryScalar -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql
        } elseif ([string]::IsNullOrEmpty([string]$col['unique_start'])) {
            $col['unique_start'] = '1'
        }
    }
}

function Update-ReferenceColumns {
    param([hashtable]$Plan, [hashtable]$Table, [hashtable]$ParentState, $MysqlExe, $DefaultsFile, [bool]$Offline)
    $db = [string]$Plan.Connection['database']
    foreach ($col in @($Table.Columns)) {
        if ([string]$col['strategy'] -ne 'reference') { continue }
        $mode = [string]$col['reference_mode']
        if ($mode -eq 'virtual' -and -not [string]::IsNullOrEmpty([string]$col['reference_start']) -and -not [string]::IsNullOrEmpty([string]$col['reference_count'])) { continue }
        if ($mode -eq 'list' -and $col['reference_values']) { continue }
        $refTable = [string]$col['reference_table']
        $refCol = [string]$col['reference_column']
        if ([string]::IsNullOrEmpty($refTable) -or [string]::IsNullOrEmpty($refCol)) {
            throw "Column $($col['table']).$($col['name']) uses reference without a target."
        }
        if ($refTable -eq [string]$Table['name']) {
            $src = $null
            foreach ($other in @($Table.Columns)) { if ([string]$other['name'] -eq $refCol) { $src = $other; break } }
            if ($null -eq $src -or [string]$src['strategy'] -ne 'unique' -or [string]$src['unique_mode'] -ne 'sequence') {
                throw "Self-reference $($col['name']) requires $($refCol) to use strategy unique and unique_mode sequence."
            }
            $col['reference_mode'] = 'prior'
            $col['reference_start'] = [string]$src['unique_start']
            $col['reference_step'] = [string]$src['unique_step']
            continue
        }
        if ($ParentState.ContainsKey($refTable)) {
            $parent = $ParentState[$refTable]
            if ($parent.Covers -and [string]$parent.Column -eq $refCol) {
                $col['reference_mode'] = 'virtual'
                $col['reference_start'] = [string]$parent.Start
                $col['reference_step'] = [string]$parent.Step
                $col['reference_count'] = [string]$parent.Count
                continue
            }
        }
        if ($Offline) { throw "Column $($col['table']).$($col['name']) needs a live reference pool. Run prepare or generate-and-load, or set reference_mode=virtual." }
        $limit = [int]$Plan.Job['reference_limit']
        $id = [AuroraDataTool.Sql]::QuoteIdent($refCol)
        $from = [AuroraDataTool.Sql]::QuoteQualified($db, $refTable)
        $sql = (Get-SessionPreamble ([string]$Plan.Job['time_zone'])) + "`nSELECT DISTINCT $id AS v FROM $from WHERE $id IS NOT NULL LIMIT $($limit + 1);`n"
        $rows = @(Invoke-QueryRows -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql)
        if ($rows.Count -eq 0) { throw "Reference pool ${refTable}.${refCol} is empty." }
        if ($rows.Count -gt $limit) { throw "Reference pool ${refTable}.${refCol} exceeds reference_limit=$limit." }
        $values = @()
        foreach ($row in $rows) { $values += [string]$row['v'] }
        $col['reference_mode'] = 'list'
        $col['reference_values'] = [string[]]$values
    }
}

function New-SpecArray {
    param([hashtable[]]$Columns)
    $specs = @()
    foreach ($col in $Columns) {
        $spec = New-ColumnSpecFromMap $col
        if ($col.ContainsKey('reference_values') -and $null -ne $col['reference_values']) {
            $spec.ReferenceValues = [string[]]$col['reference_values']
        }
        if ($col.ContainsKey('transport')) { $spec.Transport = [string]$col['transport'] }
        $specs += $spec
    }
    return ,$specs
}

function Write-CsvMeta {
    param([string]$Path, [hashtable[]]$Columns)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('format=aurora1')
    foreach ($col in $Columns) {
        [void]$sb.AppendLine('[column]')
        [void]$sb.AppendLine('name=' + [string]$col['name'])
        [void]$sb.AppendLine('data_type=' + [string]$col['data_type'])
        [void]$sb.AppendLine('transport=' + (Get-ColumnTransport $col))
        [void]$sb.AppendLine('nullable=' + [string]$col['is_nullable'])
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $sb.ToString().Replace("`r`n", "`n"), $utf8)
}

function Read-CsvMeta {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText($Path, $utf8)
    $cols = @()
    $cur = $null
    foreach ($raw in ($text -split "`n", -1)) {
        $line = $raw.TrimEnd("`r").Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line -eq '[column]') {
            if ($null -ne $cur) { $cols += $cur }
            $cur = @{}
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1 -or $null -eq $cur) { continue }
        $cur[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
    }
    if ($null -ne $cur) { $cols += $cur }
    return ,$cols
}

function Export-OneTableCsv {
    param([hashtable]$Plan, [hashtable]$Table, [string]$CsvPath, [string]$MysqlExe, [string]$DefaultsFile, [string]$LogPath)
    $db = [string]$Plan.Connection['database']
    $cols = @($Table.Columns | Sort-Object { [int]$_['ordinal'] })
    if ($cols.Count -eq 0) { throw "Table $($Table['name']) has no columns." }
    $names = @()
    $transports = @()
    foreach ($c in $cols) { $names += [string]$c['name']; $transports += (Get-ColumnTransport $c) }
    $pk = @(Get-PrimaryColumns $cols)
    $pkIsKeyset = $true
    foreach ($p in $pk) { if ((Get-ColumnTransport $p) -ne 'text') { $pkIsKeyset = $false } }
    if ($pk.Count -eq 0) { $pkIsKeyset = $false }
    $chunk = [int]$Plan.Job['chunk_rows']
    $tsv = $CsvPath + '.tsv'
    $part = $CsvPath + '.part'
    if (Test-Path -LiteralPath $CsvPath) { Remove-Item -LiteralPath $CsvPath -Force }
    $total = [long]0
    $offset = 0
    $lastKeys = $null
    $guard = 0
    while ($true) {
        $guard++
        if ($guard -gt 10000000) { throw "Export of $($Table['name']) did not advance." }
        $where = ''
        $order = ''
        if ($pk.Count -gt 0) {
            $orderParts = @()
            foreach ($p in $pk) { $orderParts += [AuroraDataTool.Sql]::QuoteIdent([string]$p['name']) }
            $order = $orderParts -join ', '
        }
        if ($pkIsKeyset -and $null -ne $lastKeys) {
            $literals = @()
            $ids = @()
            for ($i = 0; $i -lt $pk.Count; $i++) {
                $ids += [AuroraDataTool.Sql]::QuoteIdent([string]$pk[$i]['name'])
                $literals += [AuroraDataTool.Sql]::Literal([string]$lastKeys[$i], $false, [string]$pk[$i]['data_type'])
            }
            if ($pk.Count -eq 1) { $where = $ids[0] + ' > ' + $literals[0] }
            else { $where = '(' + ($ids -join ',') + ') > (' + ($literals -join ',') + ')' }
        }
        $useOffset = 0
        if (-not $pkIsKeyset) { $useOffset = $offset }
        $select = Get-ExportSelect -Database $db -Table ([string]$Table['name']) -Columns $cols -Where $where -OrderBy $order -Limit $chunk -Offset $useOffset
        $sql = (Get-SessionPreamble ([string]$Plan.Job['time_zone'])) + "`n" + $select + ";`n"
        Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql -StdoutFile $tsv -Quick | Out-Null
        $count = [AuroraDataTool.HexTable]::ConvertTsv($tsv, $part, [string[]]$names, [string[]]$transports)
        $includeHeader = -not (Test-Path -LiteralPath $CsvPath)
        $last = [AuroraDataTool.AuroraCsv]::AppendPart($part, $CsvPath, [bool]$includeHeader)
        $total += [long]$count
        if ([long]$count -lt $chunk) { break }
        if ($pkIsKeyset) {
            if ($null -eq $last) { throw "Export chunk for $($Table['name']) was empty unexpectedly." }
            $newKeys = @()
            for ($i = 0; $i -lt $pk.Count; $i++) {
                $idx = [array]::IndexOf($names, [string]$pk[$i]['name'])
                $newKeys += [string]$last[$idx]
            }
            if ($null -ne $lastKeys -and (($newKeys -join "`t") -eq ($lastKeys -join "`t"))) { throw "Primary key did not advance while exporting $($Table['name'])." }
            $lastKeys = $newKeys
        } else { $offset += $chunk }
    }
    Remove-Item -LiteralPath $tsv, $part -Force -ErrorAction SilentlyContinue
    Write-CsvMeta -Path ($CsvPath + '.meta.txt') -Columns $cols
    Write-ToolLog "Exported $($Table['name']) rows=$total file=$CsvPath" $LogPath
    return $total
}

function Remove-TableData {
    param([hashtable]$Plan, [hashtable]$Table, [string]$Mode, [string]$MysqlExe, [string]$DefaultsFile, [string]$LogPath)
    if ($Mode -eq 'none' -or [string]::IsNullOrEmpty($Mode)) { return }
    $db = [string]$Plan.Connection['database']
    $sql = Get-SessionPreamble ([string]$Plan.Job['time_zone'])
    $disable = [string]$Plan.Job['disable_fk_checks'] -eq 'YES'
    if ($disable) { $sql += "SET SESSION foreign_key_checks = 0;`n" }
    $q = [AuroraDataTool.Sql]::QuoteQualified($db, [string]$Table['name'])
    if ($Mode -eq 'truncate') { $sql += "TRUNCATE TABLE $q;`n" }
    elseif ($Mode -eq 'delete') { $sql += "DELETE FROM $q;`n" }
    else { throw "Unknown delete_mode '$Mode'." }
    if ($disable) { $sql += "SET SESSION foreign_key_checks = 1;`n" }
    Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql | Out-Null
    Write-ToolLog "Deleted $($Table['name']) mode=$Mode" $LogPath
}

function Get-LoadDataStatement {
    param([string]$Database, [string]$TableName, [string]$CsvPath, [string[]]$ColumnNames, [string]$TimeZone, [bool]$DisableFk, [bool]$RelaxUnique)
    $pathSql = ($CsvPath -replace '\\', '/').Replace("'", "''")
    $colsSql = @()
    foreach ($name in $ColumnNames) { $colsSql += [AuroraDataTool.Sql]::QuoteIdent([string]$name) }
    $tz = '+00:00'
    if (-not [string]::IsNullOrEmpty($TimeZone)) { $tz = $TimeZone.Replace("'", "''") }
    # LOAD DATA reads TERMINATED BY '\n' and ESCAPED BY '\\' as backslash escapes.
    # NO_BACKSLASH_ESCAPES would make those literals backslash-n and two backslashes.
    $load = "SET NAMES utf8mb4;`n"
    $load += "SET SESSION time_zone = '$tz';`n"
    $load += "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO';`n"
    if ($DisableFk) { $load += "SET SESSION foreign_key_checks = 0;`n" }
    if ($RelaxUnique) { $load += "SET SESSION unique_checks = 0;`n" }
    $load += "LOAD DATA LOCAL INFILE '$pathSql' INTO TABLE " + ([AuroraDataTool.Sql]::QuoteQualified($Database, $TableName))
    $load += ' CHARACTER SET utf8mb4 FIELDS TERMINATED BY '','' ENCLOSED BY ''"'' ESCAPED BY ''\\'' LINES TERMINATED BY ''\n'' IGNORE 1 LINES ('
    $load += ($colsSql -join ',') + ");`n"
    if ($RelaxUnique) { $load += "SET SESSION unique_checks = 1;`n" }
    if ($DisableFk) { $load += "SET SESSION foreign_key_checks = 1;`n" }
    return $load
}

function Import-OneCsv {
    param([hashtable]$Plan, [string]$TableName, [string]$CsvPath, [hashtable[]]$Columns, [string]$MysqlExe, [string]$DefaultsFile, [string]$LogPath)
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV was not found: $CsvPath" }
    $db = [string]$Plan.Connection['database']
    $meta = @(Read-CsvMeta ($CsvPath + '.meta.txt'))
    $metaMap = @{}
    foreach ($m in $meta) { $metaMap[[string]$m['name']] = $m }
    $byName = @{}
    foreach ($c in $Columns) { $byName[[string]$c['name']] = $c }
    $reader = New-Object AuroraDataTool.AuroraCsv+Reader $CsvPath
    try { $header = $reader.ReadRecord() } finally { $reader.Dispose() }
    if ($null -eq $header) { throw "CSV has no header: $CsvPath" }
    $headerNames = @($header.Values)
    foreach ($name in $headerNames) {
        if (-not $byName.ContainsKey([string]$name)) { throw "CSV column '$name' is not in table $TableName." }
    }
    $loadCols = @()
    $insertNames = @()
    $loadDataOk = $true
    foreach ($src in @($Columns | Sort-Object { [int]$_['ordinal'] })) {
        $copy = @{}
        foreach ($k in @($src.Keys)) { $copy[$k] = $src[$k] }
        $name = [string]$copy['name']
        $generated = [string]$copy['is_generated'] -eq 'YES'
        $isExpr = [string]$copy['strategy'] -eq 'expression'
        $skipped = $generated -or $isExpr -or [string]$copy['include'] -eq 'NO' -or [string]$copy['strategy'] -eq 'skip'
        if ($generated) { $copy['strategy'] = 'skip'; $copy['include'] = 'NO' }
        if ($skipped) { $loadDataOk = $false }
        else {
            $present = $false
            foreach ($h in $headerNames) { if ([string]$h -eq $name) { $present = $true; break } }
            if (-not $present) { throw "CSV $CsvPath is missing column $name." }
            $copy['strategy'] = 'const'
            $copy['include'] = 'YES'
            $copy['transport'] = 'text'
            if ($metaMap.ContainsKey($name) -and -not [string]::IsNullOrEmpty([string]$metaMap[$name]['transport'])) {
                $copy['transport'] = [string]$metaMap[$name]['transport']
            }
            if ([string]$copy['transport'] -ne 'text') { $loadDataOk = $false }
            $insertNames += $name
        }
        $loadCols += $copy
    }
    if ($loadDataOk) {
        $headerSet = @{}
        foreach ($h in $headerNames) { $headerSet[[string]$h] = $true }
        if ($headerSet.Count -ne $insertNames.Count) { $loadDataOk = $false }
        foreach ($name in $insertNames) { if (-not $headerSet.ContainsKey($name)) { $loadDataOk = $false } }
    }
    $specs = New-SpecArray $loadCols
    $sqlPath = $CsvPath + '.load.sql'
    $disable = [string]$Plan.Job['disable_fk_checks'] -eq 'YES'
    $relax = [string]$Plan.Job['relax_unique_checks'] -eq 'YES'
    [AuroraDataTool.Generator]::WriteInsertFile($CsvPath, $sqlPath, $db, $TableName, [AuroraDataTool.ColumnSpec[]]$specs, [int]$Plan.Job['batch_size'], [int]$Plan.Job['max_packet_bytes'], $disable, $relax, [string]$Plan.Job['time_zone'])
    $loadedByFile = $false
    if ($loadDataOk -and [string]$Plan.Job['load_method'] -eq 'local-infile') {
        try {
            $orderedHeader = @()
            foreach ($h in $headerNames) { $orderedHeader += [string]$h }
            $load = Get-LoadDataStatement -Database $db -TableName $TableName -CsvPath $CsvPath -ColumnNames $orderedHeader -TimeZone ([string]$Plan.Job['time_zone']) -DisableFk $disable -RelaxUnique $relax
            Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $load -LocalInfile | Out-Null
            $loadedByFile = $true
            Write-ToolLog "Loaded $TableName with LOAD DATA LOCAL INFILE" $LogPath
        } catch {
            Write-ToolLog "LOAD DATA LOCAL failed, falling back to INSERT: $($_.Exception.Message)" $LogPath
        }
    }
    if (-not $loadedByFile) {
        Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -StdinFile $sqlPath | Out-Null
        Write-ToolLog "Loaded $TableName with batched INSERT from $sqlPath" $LogPath
    }
}

function Get-TableCount {
    param([hashtable]$Plan, [string]$TableName, [string]$MysqlExe, [string]$DefaultsFile)
    $db = [string]$Plan.Connection['database']
    $sql = (Get-SessionPreamble ([string]$Plan.Job['time_zone'])) + "`nSELECT COUNT(*) AS c FROM " + ([AuroraDataTool.Sql]::QuoteQualified($db, $TableName)) + ";`n"
    return [long](Invoke-QueryScalar -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql)
}

function New-GeneratedCsv {
    param([hashtable]$Plan, [hashtable]$Table, [string]$CsvPath, [uint64]$Seed)
    $specs = New-SpecArray @($Table.Columns)
    $rows = Get-TableRowCount $Plan $Table
    $result = [AuroraDataTool.Generator]::WriteCsv($Seed, [long]$rows, [string]$Plan.Job['string_mode'], [AuroraDataTool.ColumnSpec[]]$specs, $CsvPath)
    if (-not $result.Ok) { throw (($result.Errors | ForEach-Object { [string]$_ }) -join "`n") }
    foreach ($w in @($result.Warnings)) { if (-not [string]::IsNullOrEmpty([string]$w)) { Write-Warning ([string]$w) } }
    $outCols = @()
    foreach ($name in @($result.OutputColumns)) {
        foreach ($c in @($Table.Columns)) { if ([string]$c['name'] -eq [string]$name) { $outCols += $c; break } }
    }
    Write-CsvMeta -Path ($CsvPath + '.meta.txt') -Columns $outCols
    return [long]$result.RowCount
}

function Get-PlanFileSha256 {
    param([string]$Path)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $utf8)
    return Get-TextSha256 $text
}

function Get-SafeIntegerLiteral {
    param([string]$Value, [string]$Label)
    if ([string]$Value -notmatch '^-?(0|[1-9][0-9]*)$') { throw "Refusing $Label value '$Value' because it is not a decimal integer." }
    return [string]$Value
}

function Write-RunState {
    param([string]$Path, [hashtable]$State)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('format_version=1')
    [void]$sb.AppendLine('[run]')
    foreach ($k in @('action','database','seed','started_at','finished_at','status','plan_sha256','cleanup_mode')) {
        [void]$sb.AppendLine($k + '=' + [string]$State[$k])
    }
    [void]$sb.AppendLine('[dump]')
    [void]$sb.AppendLine('path=' + [string]$State['dump_path'])
    foreach ($t in @($State['tables'])) {
        [void]$sb.AppendLine('[table]')
        foreach ($k in @('name','csv_backup','generated_csv','rows_before','rows_loaded','deleted','delete_mode','pk_column','pk_start','pk_end','marker_column','marker_value','max_pk_before')) {
            [void]$sb.AppendLine($k + '=' + [string]$t[$k])
        }
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $sb.ToString().Replace("`r`n", "`n"), $utf8)
}

function Read-RunState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Run state was not found: $Path" }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText($Path, $utf8)
    $state = @{ tables = @() }
    $section = ''
    $cur = $null
    foreach ($raw in ($text -split "`n", -1)) {
        $line = $raw.TrimEnd("`r")
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
        if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
            $section = $trim.Substring(1, $trim.Length - 2)
            if ($section -eq 'table') { $cur = @{}; $state.tables += $cur }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq)
        $value = $line.Substring($eq + 1)
        if ($section -eq 'table') { $cur[$key] = $value }
        elseif ($section -eq 'dump' -and $key -eq 'path') { $state['dump_path'] = $value }
        else { $state[$key] = $value }
    }
    return $state
}

function Invoke-AuroraPing {
    param([hashtable]$Plan, [string]$MysqlExe, [string]$DefaultsFile, [string]$LogPath)
    $db = [string]$Plan.Connection['database']
    $sql = (Get-SessionPreamble ([string]$Plan.Job['time_zone'])) + "`nSELECT VERSION() AS version, @@local_infile AS local_infile, @@sql_mode AS sql_mode;`n"
    $rows = @(Invoke-QueryRows -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql)
    if ($rows.Count -lt 1) { throw 'VERSION() returned no row.' }
    $version = [string]$rows[0]['version']
    Write-ToolLog "Connected. VERSION()=$version local_infile=$($rows[0]['local_infile'])" $LogPath
    if ($version -notmatch '^8\.4\.') { Write-Warning "Server version '$version' is not MySQL 8.4. This tool targets Aurora MySQL 8.4.7." }
    return $version
}

function Invoke-AuroraDump {
    param([hashtable]$Plan, [string]$PlanPath, [string]$MysqldumpExe, [string]$DefaultsFile, [string]$LogPath)
    $outDir = Get-PlanOutputDir $PlanPath $Plan
    $dump = [string]$Plan.Job['dump_path']
    if ([string]::IsNullOrEmpty($dump)) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $dump = Join-Path $outDir ((ConvertTo-FileToken ([string]$Plan.Connection['database'])) + "-$stamp.sql")
    } else { $dump = Resolve-PlanRelativePath $PlanPath $dump }
    $parent = Split-Path -Parent $dump
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $argList = Get-DumpArguments -Plan $Plan -DefaultsFile $DefaultsFile -ResultFile $dump
    Write-ToolLog "mysqldump -> $dump" $LogPath
    $result = Invoke-NativeProcess -FilePath $MysqldumpExe -ArgumentList $argList
    if ($result.ExitCode -ne 0 -and $result.Stderr -match 'unknown option' -and $result.Stderr -match 'column-statistics') {
        $retry = @($argList | Where-Object { $_ -ne '--column-statistics=0' })
        Write-ToolLog 'mysqldump does not support --column-statistics=0; retrying without it.' $LogPath
        $result = Invoke-NativeProcess -FilePath $MysqldumpExe -ArgumentList $retry
    }
    if ($result.ExitCode -ne 0) { throw "mysqldump exited with code $($result.ExitCode): $($result.Stderr.Trim())" }
    if (-not (Test-Path -LiteralPath $dump)) { throw "mysqldump reported success but did not create $dump" }
    Write-ToolLog "Dump written: $dump" $LogPath
    return $dump
}

function Get-EffectiveDeleteMode {
    param([hashtable]$Plan, [hashtable]$Table)
    $mode = [string]$Table['delete_mode']
    if ([string]::IsNullOrEmpty($mode)) { $mode = [string]$Plan.Job['delete_mode'] }
    if ([string]::IsNullOrEmpty($mode)) { return 'none' }
    return $mode
}

function Invoke-AuroraAction {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Plan,
        [Parameter(Mandatory=$true)][string]$PlanPath,
        [Parameter(Mandatory=$true)][string]$Action,
        [bool]$Execute,
        [string]$MysqlExe,
        [string]$MysqldumpExe,
        [string]$Password,
        [string]$OnlyTables,
        [string]$RunStatePath
    )
    Complete-AuroraPlan $Plan
    $Plan.Job['action'] = $Action
    $problems = @(Test-AuroraPlan $Plan)
    if ($problems.Count -gt 0) { throw ($problems -join "`n") }
    $included = @(Get-IncludedTables $Plan $OnlyTables)
    $needsTables = @('export-csv','delete','load-csv','generate','generate-and-load','prepare','cleanup')
    if ($needsTables -contains $Action -and $included.Count -eq 0) { throw 'No included table is selected.' }
    if ($Action -eq 'dump' -and [string]$Plan.Job['dump_scope'] -eq 'tables' -and $included.Count -eq 0) {
        throw 'dump_scope=tables requires at least one included table.'
    }
    $destructive = $false
    if ($Action -eq 'delete' -or $Action -eq 'cleanup') { $destructive = $true }
    if ($Action -eq 'prepare') {
        foreach ($t in $included) { if ((Get-EffectiveDeleteMode $Plan $t) -ne 'none') { $destructive = $true } }
    }
    if (-not $Execute -and (Test-ActionMutates $Action)) {
        Write-Host "Dry-run for '$Action'. No database session was opened."
        Write-Host ("Database: {0}  tables: {1}" -f $Plan.Connection['database'], (($included | ForEach-Object { $_.name }) -join ', '))
        Write-Host ("confirm={0} allow_destructive={1} delete_mode={2} cleanup_mode={3}" -f $Plan.Job['confirm'], $Plan.Job['allow_destructive'], $Plan.Job['delete_mode'], $Plan.Job['cleanup_mode'])
        Write-Host 'Pass -Execute after setting confirm=YES to apply this plan.'
        return
    }
    Assert-Confirmed -Plan $Plan -Execute $Execute -Action $Action -Destructive $destructive
    $outDir = Get-PlanOutputDir $PlanPath $Plan
    $log = Join-Path $outDir 'tool.log'
    $offline = ($Action -eq 'generate')
    $mysql = $null
    $dumpExe = $null
    $defaults = $null
    try {
        if (-not $offline) {
            if ([string]::IsNullOrEmpty($MysqlExe)) { $MysqlExe = 'mysql' }
            $mysql = Resolve-ClientExe $MysqlExe
            $dumpExe = $MysqldumpExe
            if (-not [string]::IsNullOrEmpty($dumpExe)) { $dumpExe = Resolve-ClientExe $dumpExe }
            $defaults = New-MysqlDefaultsFile -Connection $Plan.Connection -Password $Password
            if ($Action -eq 'ping') { Invoke-AuroraPing -Plan $Plan -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log | Out-Null; return }
            if ($Action -eq 'dump') { Invoke-AuroraDump -Plan $Plan -PlanPath $PlanPath -MysqldumpExe $dumpExe -DefaultsFile $defaults -LogPath $log | Out-Null; return }
            if ($Action -eq 'inspect') { throw 'inspect is dispatched by the entry script.' }
            Invoke-AuroraPing -Plan $Plan -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log | Out-Null
            $queries = Get-SchemaQueries -Database ([string]$Plan.Connection['database']) -Tables @($included | ForEach-Object { [string]$_['name'] })
            $live = @(Invoke-QueryRows -MysqlExe $mysql -DefaultsFile $defaults -Database ([string]$Plan.Connection['database']) -Sql $queries.Columns)
            $keys = @(Invoke-QueryRows -MysqlExe $mysql -DefaultsFile $defaults -Database ([string]$Plan.Connection['database']) -Sql $queries.Keys)
            Merge-LiveSchema -Plan $Plan -LiveColumns $live -ForeignKeys $keys
        }
        $db = [string]$Plan.Connection['database']
        $orderedInfo = Get-OrderedTables -Tables $included -ParentsFirst $true
        if ($orderedInfo.Cyclic -and [string]$Plan.Job['disable_fk_checks'] -ne 'YES') {
            throw 'The selected tables have a foreign-key cycle. Set disable_fk_checks=YES or remove a relationship.'
        }
        $parentFirst = @($orderedInfo.Tables)
        $childFirst = @(Get-OrderedTables -Tables $included -ParentsFirst $false).Tables
        $seed = [uint64]0
        [void][uint64]::TryParse([string]$Plan.Job['seed'], [ref]$seed)
        $state = @{
            action = $Action
            database = $db
            seed = [string]$seed
            started_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            finished_at = ''
            status = 'partial'
            plan_sha256 = (Get-PlanFileSha256 $PlanPath)
            cleanup_mode = [string]$Plan.Job['cleanup_mode']
            dump_path = ''
            tables = @()
        }
        $statePath = Join-Path $outDir 'run-state.txt'
        if (-not [string]::IsNullOrEmpty($RunStatePath)) { $statePath = $RunStatePath }
        $parentState = @{}

        if ($Action -eq 'cleanup') {
            Invoke-AuroraCleanup -Plan $Plan -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log -StatePath $statePath -ChildFirst $childFirst -ParentFirst $parentFirst
            return
        }

        if ($Action -eq 'prepare' -and [string]$Plan.Job['include_dump'] -eq 'YES') {
            if ([string]::IsNullOrEmpty($dumpExe)) { throw 'prepare with include_dump=YES requires mysqldump. Pass -Mysqldump.' }
            $state['dump_path'] = Invoke-AuroraDump -Plan $Plan -PlanPath $PlanPath -MysqldumpExe $dumpExe -DefaultsFile $defaults -LogPath $log
        }

        foreach ($table in $parentFirst) {
            $entry = @{
                name = [string]$table['name']
                csv_backup = ''
                generated_csv = ''
                rows_before = ''
                rows_loaded = '0'
                deleted = 'NO'
                delete_mode = 'none'
                pk_column = ''
                pk_start = ''
                pk_end = ''
                marker_column = [string]$table['marker_column']
                marker_value = [string]$table['marker_value']
                max_pk_before = ''
            }
            $state.tables += $entry
        }
        Write-RunState -Path $statePath -State $state

        if ($Action -in @('export-csv','prepare') -or ([string]$Plan.Job['include_csv_backup'] -eq 'YES' -and $Action -in @('delete','generate-and-load','load-csv'))) {
            $backupDir = Join-Path $outDir 'backup'
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
            foreach ($table in $parentFirst) {
                $entry = $null
                foreach ($e in $state.tables) { if ($e.name -eq [string]$table['name']) { $entry = $e; break } }
                $target = [string]$table['csv_backup_path']
                if ([string]::IsNullOrEmpty($target)) { $target = Join-Path $backupDir ((ConvertTo-FileToken ([string]$table['name'])) + '.csv') }
                else { $target = Resolve-PlanRelativePath $PlanPath $target }
                $rows = Export-OneTableCsv -Plan $Plan -Table $table -CsvPath $target -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log
                $entry.csv_backup = $target
                $entry.rows_before = [string]$rows
                Write-RunState -Path $statePath -State $state
                if ($Action -eq 'export-csv') { continue }
            }
            if ($Action -eq 'export-csv') { $state.status = 'success'; $state.finished_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); Write-RunState -Path $statePath -State $state; return }
        }

        if ($Action -eq 'delete' -or $Action -eq 'prepare') {
            foreach ($table in $childFirst) {
                $mode = Get-EffectiveDeleteMode $Plan $table
                if ($Action -eq 'delete' -and $mode -eq 'none') { $mode = 'delete' }
                if ($mode -eq 'none') { continue }
                $entry = $null
                foreach ($e in $state.tables) { if ($e.name -eq [string]$table['name']) { $entry = $e; break } }
                if ([string]$Plan.Job['allow_delete_without_backup'] -ne 'YES' -and [string]::IsNullOrEmpty([string]$entry.csv_backup)) {
                    throw "Refusing to delete $($table['name']) without a CSV backup. Export first or set allow_delete_without_backup=YES."
                }
                Remove-TableData -Plan $Plan -Table $table -Mode $mode -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log
                $entry.deleted = 'YES'
                $entry.delete_mode = $mode
                Write-RunState -Path $statePath -State $state
            }
            if ($Action -eq 'delete') { $state.status = 'success'; $state.finished_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); Write-RunState -Path $statePath -State $state; return }
        }

        $generateActions = @('generate','generate-and-load','prepare')
        $loadActions = @('load-csv','generate-and-load','prepare')
        foreach ($table in $parentFirst) {
            $entry = $null
            foreach ($e in $state.tables) { if ($e.name -eq [string]$table['name']) { $entry = $e; break } }
            $rowCount = Get-TableRowCount $Plan $table
            if ($generateActions -contains $Action) {
                $warns = @(Resolve-TableStrategies -Table $table -RowCount $rowCount)
                foreach ($w in $warns) { if (-not [string]::IsNullOrEmpty([string]$w)) { Write-ToolLog "WARN $w" $log } }
                $offline = ($Action -eq 'generate')
                Update-UniqueStarts -Table $table -Plan $Plan -MysqlExe $mysql -DefaultsFile $defaults -Offline $offline
                Update-ReferenceColumns -Plan $Plan -Table $table -ParentState $parentState -MysqlExe $mysql -DefaultsFile $defaults -Offline $offline
                $warns2 = @(Resolve-TableStrategies -Table $table -RowCount $rowCount)
                foreach ($w in $warns2) { if (-not [string]::IsNullOrEmpty([string]$w)) { Write-ToolLog "WARN $w" $log } }
                $genDir = Join-Path $outDir 'generated'
                if (-not (Test-Path -LiteralPath $genDir)) { New-Item -ItemType Directory -Path $genDir -Force | Out-Null }
                $genPath = Join-Path $genDir ((ConvertTo-FileToken ([string]$table['name'])) + '.csv')
                $loaded = New-GeneratedCsv -Plan $Plan -Table $table -CsvPath $genPath -Seed $seed
                $entry.generated_csv = $genPath
                $entry.rows_loaded = [string]$loaded
                $seq = $null
                foreach ($c in @($table.Columns)) {
                    if ([string]$c['strategy'] -eq 'unique' -and [string]$c['unique_mode'] -eq 'sequence' -and [string]$c['include'] -eq 'YES') { $seq = $c; if ([string]$c['column_key'] -eq 'PRI') { break } }
                }
                if ($null -ne $seq) {
                    $entry.pk_column = [string]$seq['name']
                    $entry.pk_start = [string]$seq['unique_start']
                    $step = [System.Numerics.BigInteger]::Parse([string]$seq['unique_step'])
                    $start = [System.Numerics.BigInteger]::Parse([string]$seq['unique_start'])
                    $end = $start
                    if ($loaded -gt 0) { $end = $start + ([System.Numerics.BigInteger]::new([long]($loaded - 1)) * $step) }
                    $entry.pk_end = $end.ToString()
                }
                $parentState[[string]$table['name']] = @{
                    Covers = ($entry.deleted -eq 'YES' -and $null -ne $seq)
                    Column = $(if ($null -ne $seq) { [string]$seq['name'] } else { '' })
                    Start = $(if ($null -ne $seq) { [string]$seq['unique_start'] } else { '' })
                    Step = $(if ($null -ne $seq) { [string]$seq['unique_step'] } else { '1' })
                    Count = [string]$loaded
                }
                Write-ToolLog "Generated $($table['name']) rows=$loaded file=$genPath" $log
            }
            if ($loadActions -contains $Action) {
                $csv = [string]$entry.generated_csv
                if ($Action -eq 'load-csv' -or -not [string]::IsNullOrEmpty([string]$table['load_csv_path'])) {
                    if (-not [string]::IsNullOrEmpty([string]$table['load_csv_path'])) { $csv = Resolve-PlanRelativePath $PlanPath ([string]$table['load_csv_path']) }
                }
                if ([string]::IsNullOrEmpty($csv)) { throw "No CSV to load for $($table['name'])." }
                $before = Get-TableCount -Plan $Plan -TableName ([string]$table['name']) -MysqlExe $mysql -DefaultsFile $defaults
                Import-OneCsv -Plan $Plan -TableName ([string]$table['name']) -CsvPath $csv -Columns @($table.Columns) -MysqlExe $mysql -DefaultsFile $defaults -LogPath $log
                if ([string]$Plan.Job['verify_row_count'] -eq 'YES') {
                    $after = Get-TableCount -Plan $Plan -TableName ([string]$table['name']) -MysqlExe $mysql -DefaultsFile $defaults
                    $delta = $after - $before
                    $expect = 0L
                    if (-not [string]::IsNullOrEmpty([string]$entry.rows_loaded) -and $Action -ne 'load-csv') { $expect = [long]$entry.rows_loaded }
                    else {
                        $reader = New-Object AuroraDataTool.AuroraCsv+Reader $csv
                        try {
                            $expect = 0
                            $rec = $reader.ReadRecord()
                            while ($null -ne ($rec = $reader.ReadRecord())) { $expect++ }
                        } finally { $reader.Dispose() }
                    }
                    if ($delta -ne $expect) { throw "Row-count check failed for $($table['name']): inserted delta $delta, expected $expect (before=$before after=$after)." }
                    Write-ToolLog "Verified $($table['name']) delta=$delta" $log
                }
                if (-not $parentState.ContainsKey([string]$table['name'])) {
                    $parentState[[string]$table['name']] = @{ Covers = ($entry.deleted -eq 'YES'); Column = ''; Start = ''; Step = '1'; Count = '0' }
                }
            }
            Write-RunState -Path $statePath -State $state
        }
        $state.status = 'success'
        $state.finished_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-RunState -Path $statePath -State $state
        Write-ToolLog "Completed $Action" $log
    } finally {
        Remove-MysqlDefaultsFile $defaults
    }
}

function Invoke-AuroraCleanup {
    param([hashtable]$Plan, [string]$MysqlExe, [string]$DefaultsFile, [string]$LogPath, [string]$StatePath, $ChildFirst, $ParentFirst)
    $saved = Read-RunState $StatePath
    $mode = [string]$Plan.Job['cleanup_mode']
    if (-not [string]::IsNullOrEmpty([string]$saved['cleanup_mode'])) { $mode = [string]$saved['cleanup_mode'] }
    $bySaved = @{}
    foreach ($t in @($saved.tables)) { $bySaved[[string]$t['name']] = $t }
    if ($mode -eq 'truncate' -or $mode -eq 'restore-csv' -or $mode -eq 'delete-inserted') {
        foreach ($table in @($ChildFirst)) {
            $savedTable = $bySaved[[string]$table['name']]
            if ($null -eq $savedTable) { throw "Run state has no entry for $($table['name'])." }
            if ($mode -eq 'delete-inserted') {
                if (-not [string]::IsNullOrEmpty([string]$savedTable['marker_column'])) {
                    $db = [string]$Plan.Connection['database']
                    $sql = Get-SessionPreamble ([string]$Plan.Job['time_zone'])
                    if ([string]$Plan.Job['disable_fk_checks'] -eq 'YES') { $sql += "SET SESSION foreign_key_checks = 0;`n" }
                    $sql += 'DELETE FROM ' + ([AuroraDataTool.Sql]::QuoteQualified($db, [string]$table['name'])) + ' WHERE ' + ([AuroraDataTool.Sql]::QuoteIdent([string]$savedTable['marker_column'])) + ' = ' + (ConvertTo-SqlLiteral ([string]$savedTable['marker_value'])) + ";`n"
                    Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql | Out-Null
                } elseif (-not [string]::IsNullOrEmpty([string]$savedTable['pk_column']) -and -not [string]::IsNullOrEmpty([string]$savedTable['pk_start'])) {
                    $db = [string]$Plan.Connection['database']
                    $sql = Get-SessionPreamble ([string]$Plan.Job['time_zone'])
                    if ([string]$Plan.Job['disable_fk_checks'] -eq 'YES') { $sql += "SET SESSION foreign_key_checks = 0;`n" }
                    $id = [AuroraDataTool.Sql]::QuoteIdent([string]$savedTable['pk_column'])
                    $pkLo = Get-SafeIntegerLiteral ([string]$savedTable['pk_start']) 'pk_start'
                    $pkHi = Get-SafeIntegerLiteral ([string]$savedTable['pk_end']) 'pk_end'
                    $sql += 'DELETE FROM ' + ([AuroraDataTool.Sql]::QuoteQualified($db, [string]$table['name'])) + " WHERE $id >= $pkLo AND $id <= $pkHi;`n"
                    Invoke-MysqlText -MysqlExe $MysqlExe -DefaultsFile $DefaultsFile -Database $db -Sql $sql | Out-Null
                } else { throw "delete-inserted needs a marker column or a recorded primary-key range for $($table['name'])." }
                Write-ToolLog "Removed inserted rows from $($table['name'])" $LogPath
            } else {
                $wipe = 'truncate'
                if ($mode -eq 'restore-csv' -and [string]$savedTable['delete_mode'] -eq 'delete') { $wipe = 'delete' }
                Remove-TableData -Plan $Plan -Table $table -Mode $wipe -MysqlExe $MysqlExe -DefaultsFile $defaults -LogPath $LogPath
            }
        }
    } else { throw "Unknown cleanup_mode '$mode'." }
    if ($mode -eq 'restore-csv') {
        foreach ($table in @($ParentFirst)) {
            $savedTable = $bySaved[[string]$table['name']]
            if ([string]::IsNullOrEmpty([string]$savedTable['csv_backup'])) { throw "No CSV backup is recorded for $($table['name'])." }
            if (-not (Test-Path -LiteralPath ([string]$savedTable['csv_backup']))) { throw "CSV backup is missing: $($savedTable['csv_backup'])" }
            Import-OneCsv -Plan $Plan -TableName ([string]$table['name']) -CsvPath ([string]$savedTable['csv_backup']) -Columns @($table.Columns) -MysqlExe $MysqlExe -DefaultsFile $defaults -LogPath $LogPath
            if ([string]$Plan.Job['verify_row_count'] -eq 'YES' -and -not [string]::IsNullOrEmpty([string]$savedTable['rows_before'])) {
                $after = Get-TableCount -Plan $Plan -TableName ([string]$table['name']) -MysqlExe $MysqlExe -DefaultsFile $defaults
                if ($after -ne [long]$savedTable['rows_before']) { throw "Restore check failed for $($table['name']): count=$after expected $($savedTable['rows_before'])." }
            }
            Write-ToolLog "Restored $($table['name']) from $($savedTable['csv_backup'])" $LogPath
        }
    }
    Write-ToolLog "Cleanup completed mode=$mode" $LogPath
}
