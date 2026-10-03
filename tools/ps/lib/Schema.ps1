function ConvertTo-SqlLiteral {
    param([AllowNull()][string]$Value, [switch]$Null)
    if ($Null -or $null -eq $Value) { return 'NULL' }
    return "'" + ($Value.Replace("'", "''")) + "'"
}

function Get-SessionPreamble {
    param([string]$TimeZone)
    $tz = '+00:00'
    if (-not [string]::IsNullOrEmpty($TimeZone)) { $tz = $TimeZone.Replace("'", "''") }
    return @"
SET NAMES utf8mb4;
SET SESSION time_zone = '$tz';
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_BACKSLASH_ESCAPES';
"@
}

function ConvertFrom-EnumColumnType {
    param([string]$ColumnType)
    $text = [string]$ColumnType
    if ($text -notmatch '^(?i)(enum|set)\(') { return '' }
    $start = $text.IndexOf('(')
    $i = $start + 1
    $values = New-Object System.Collections.Generic.List[string]
    while ($i -lt $text.Length) {
        while ($i -lt $text.Length -and [char]::IsWhiteSpace($text[$i])) { $i++ }
        if ($i -ge $text.Length) { break }
        if ($text[$i] -eq ')') { break }
        if ($text[$i] -ne "'") { throw "Cannot parse ENUM or SET type: $text" }
        $i++
        $sb = New-Object System.Text.StringBuilder
        while ($i -lt $text.Length) {
            if ($text[$i] -eq "'") {
                if (($i + 1) -lt $text.Length -and $text[$i + 1] -eq "'") { [void]$sb.Append("'"); $i += 2; continue }
                $i++
                break
            }
            [void]$sb.Append($text[$i])
            $i++
        }
        $values.Add($sb.ToString())
        while ($i -lt $text.Length -and ($text[$i] -eq ',' -or [char]::IsWhiteSpace($text[$i]))) { $i++ }
    }
    return ($values.ToArray() -join '|')
}

function ConvertFrom-MysqlBatch {
    param([string]$Text)
    $rows = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = $Text -split "`n", -1
    $header = $null
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd("`r")
        if ($line.Length -eq 0) { continue }
        $fields = $line -split "`t", -1
        if ($null -eq $header) { $header = $fields; continue }
        $obj = @{}
        for ($i = 0; $i -lt $header.Length; $i++) {
            $v = ''
            if ($i -lt $fields.Length) { $v = $fields[$i] }
            if ($v -eq '\N') { $obj[$header[$i]] = $null } else { $obj[$header[$i]] = $v }
        }
        $rows.Add($obj)
    }
    return @($rows.ToArray())
}

function Get-SchemaQueries {
    param([string]$Database, [string[]]$Tables)
    $db = ConvertTo-SqlLiteral $Database
    $in = ''
    if ($Tables -and $Tables.Length -gt 0) {
        $quoted = @()
        foreach ($t in $Tables) { $quoted += (ConvertTo-SqlLiteral $t) }
        $in = ' AND TABLE_NAME IN (' + ($quoted -join ',') + ')'
    }
    $pre = Get-SessionPreamble
    $columns = @"
$pre
SELECT TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE, DATA_TYPE, IS_NULLABLE, COLUMN_KEY,
       EXTRA, COLUMN_DEFAULT, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, NUMERIC_SCALE,
       DATETIME_PRECISION, CHARACTER_SET_NAME, GENERATION_EXPRESSION
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = $($db)$($in)
ORDER BY TABLE_NAME, ORDINAL_POSITION;
"@
    $keys = @"
$pre
SELECT TABLE_NAME, COLUMN_NAME, CONSTRAINT_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, ORDINAL_POSITION
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = $db AND REFERENCED_TABLE_NAME IS NOT NULL$($in)
ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION;
"@
    $tables = @"
$pre
SELECT TABLE_NAME
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = $db AND TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
"@
    return @{ Columns = $columns; Keys = $keys; Tables = $tables }
}

function ConvertTo-ColumnMapFromInfo {
    param($Row, [hashtable]$ForeignKey)
    $type = [string]$Row['COLUMN_TYPE']
    $data = ([string]$Row['DATA_TYPE']).ToLowerInvariant()
    $extra = [string]$Row['EXTRA']
    $unsigned = 'NO'
    if ($type.ToLowerInvariant().Contains('unsigned')) { $unsigned = 'YES' }
    $generated = 'NO'
    if ($extra.ToLowerInvariant().Contains('virtual generated') -or $extra.ToLowerInvariant().Contains('stored generated')) { $generated = 'YES' }
    $auto = 'NO'
    if ($extra.ToLowerInvariant().Contains('auto_increment')) { $auto = 'YES' }
    $enum = ''
    if ($data -eq 'enum' -or $data -eq 'set') { $enum = ConvertFrom-EnumColumnType $type }
    $map = @{
        table = [string]$Row['TABLE_NAME']
        name = [string]$Row['COLUMN_NAME']
        ordinal = [string]$Row['ORDINAL_POSITION']
        column_type = $type
        data_type = $data
        is_nullable = [string]$Row['IS_NULLABLE']
        column_key = [string]$Row['COLUMN_KEY']
        extra = $extra
        column_default = [string]$Row['COLUMN_DEFAULT']
        char_length = [string]$Row['CHARACTER_MAXIMUM_LENGTH']
        num_precision = [string]$Row['NUMERIC_PRECISION']
        num_scale = [string]$Row['NUMERIC_SCALE']
        datetime_precision = [string]$Row['DATETIME_PRECISION']
        is_unsigned = $unsigned
        is_generated = $generated
        is_auto_increment = $auto
        enum_values = $enum
        include = 'YES'
        strategy = 'auto'
    }
    if ($null -ne $ForeignKey) {
        $map['fk_table'] = [string]$ForeignKey['REFERENCED_TABLE_NAME']
        $map['fk_column'] = [string]$ForeignKey['REFERENCED_COLUMN_NAME']
    }
    return $map
}

$script:StrategyOverlayKeys = @(
    'strategy','const_value','range_min','range_max','unique_mode','unique_start','unique_step','unique_prefix',
    'unique_pad','choice_list','template','pattern','null_ratio','string_length','string_min_length','string_max_length',
    'reference_table','reference_column','reference_mode','reference_start','reference_count','reference_step',
    'expression','include','overflow','unique_suffix','notes'
)

function Merge-LiveSchema {
    param([hashtable]$Plan, [hashtable[]]$LiveColumns, [hashtable[]]$ForeignKeys)
    $fk = @{}
    foreach ($k in $ForeignKeys) {
        $id = ([string]$k['TABLE_NAME']) + '|' + ([string]$k['COLUMN_NAME'])
        if (-not $fk.ContainsKey($id)) { $fk[$id] = $k }
    }
    $byTable = @{}
    foreach ($row in $LiveColumns) {
        $tn = [string]$row['TABLE_NAME']
        if (-not $byTable.ContainsKey($tn)) { $byTable[$tn] = @() }
        $id = $tn + '|' + [string]$row['COLUMN_NAME']
        $key = $null
        if ($fk.ContainsKey($id)) { $key = $fk[$id] }
        $byTable[$tn] += (ConvertTo-ColumnMapFromInfo $row $key)
    }
    $policy = [string]$Plan.Job['unknown_column_policy']
    foreach ($t in $Plan.Tables) {
        if ([string]$t['include'] -ne 'YES') { continue }
        $tn = [string]$t['name']
        if (-not $byTable.ContainsKey($tn)) { throw "Table '$tn' was not found in database $($Plan.Connection['database'])." }
        $planned = @{}
        foreach ($c in @($t.Columns)) { $planned[[string]$c['name']] = $c }
        $merged = @()
        foreach ($live in $byTable[$tn]) {
            $name = [string]$live['name']
            if ($planned.ContainsKey($name)) {
                $src = $planned[$name]
                foreach ($k in $script:StrategyOverlayKeys) {
                    if ($src.ContainsKey($k) -and -not [string]::IsNullOrEmpty([string]$src[$k])) { $live[$k] = [string]$src[$k] }
                }
                $planned.Remove($name)
            } else {
                if ($policy -eq 'error') { throw "Column ${tn}.${name} is not in the plan. Set unknown_column_policy=auto or skip, or export the workbook again." }
                if ($policy -eq 'skip') { $live['include'] = 'NO'; $live['strategy'] = 'skip' }
                if ($policy -eq 'auto') { $live['strategy'] = 'auto' }
            }
            $merged += $live
        }
        foreach ($left in @($planned.Keys)) { throw "Plan column ${tn}.${left} is not in the live table." }
        $t['Columns'] = $merged
    }
}

function Get-LoadOrder {
    param([hashtable[]]$Tables)
    $names = @()
    $set = @{}
    foreach ($t in $Tables) { $names += [string]$t['name']; $set[[string]$t['name']] = $true }
    $indegree = @{}
    $next = @{}
    foreach ($n in $names) { $indegree[$n] = 0; $next[$n] = @() }
    foreach ($t in $Tables) {
        $child = [string]$t['name']
        $parents = @{}
        foreach ($c in @($t.Columns)) {
            $p = [string]$c['fk_table']
            if ([string]::IsNullOrEmpty($p)) { $p = [string]$c['reference_table'] }
            if ([string]::IsNullOrEmpty($p) -or $p -eq $child) { continue }
            if (-not $set.ContainsKey($p)) { continue }
            $parents[$p] = $true
        }
        foreach ($p in $parents.Keys) {
            $next[$p] += $child
            $indegree[$child] = [int]$indegree[$child] + 1
        }
    }
    $ready = New-Object System.Collections.Generic.Queue[string]
    foreach ($n in $names) { if ([int]$indegree[$n] -eq 0) { $ready.Enqueue($n) } }
    $ordered = @()
    while ($ready.Count -gt 0) {
        $n = $ready.Dequeue()
        $ordered += $n
        foreach ($m in @($next[$n])) {
            $indegree[$m] = [int]$indegree[$m] - 1
            if ([int]$indegree[$m] -eq 0) { $ready.Enqueue($m) }
        }
    }
    if ($ordered.Length -ne $names.Length) {
        return @{ Names = $names; Cyclic = $true }
    }
    return @{ Names = $ordered; Cyclic = $false }
}

function Get-OrderedTables {
    param([hashtable[]]$Tables, [bool]$ParentsFirst)
    $order = Get-LoadOrder $Tables
    $map = @{}
    foreach ($t in $Tables) { $map[[string]$t['name']] = $t }
    $names = @($order.Names)
    if (-not $ParentsFirst) { [array]::Reverse($names) }
    $out = @()
    foreach ($n in $names) { $out += $map[$n] }
    return @{ Tables = $out; Cyclic = [bool]$order.Cyclic }
}

function Get-ColumnTransport {
    param([hashtable]$Column)
    $dt = ([string]$Column['data_type']).ToLowerInvariant()
    if ($dt -in @('binary','varbinary','tinyblob','blob','mediumblob','longblob')) { return 'hex' }
    if ($dt -in @('geometry','point','linestring','polygon','multipoint','multilinestring','multipolygon','geomcollection','geometrycollection')) { return 'wkb' }
    return 'text'
}

function Get-ExportSelect {
    param([string]$Database, [string]$Table, [hashtable[]]$Columns, [string]$Where, [string]$OrderBy, [int]$Limit, [int]$Offset)
    $parts = @()
    foreach ($c in $Columns) {
        $id = [AuroraDataTool.Sql]::QuoteIdent([string]$c['name'])
        $transport = Get-ColumnTransport $c
        $dt = ([string]$c['data_type']).ToLowerInvariant()
        if ($transport -eq 'hex') { $expr = "HEX($id)" }
        elseif ($transport -eq 'wkb') { $expr = "HEX(ST_AsWKB($id))" }
        elseif ($dt -eq 'bit') { $expr = "HEX(CONVERT(CAST($id AS UNSIGNED) USING utf8mb4))" }
        else { $expr = "HEX(CONVERT($id USING utf8mb4))" }
        $parts += "IF($id IS NULL, NULL, $expr)"
    }
    $sql = 'SELECT ' + ($parts -join ', ') + ' FROM ' + ([AuroraDataTool.Sql]::QuoteQualified($Database, $Table))
    if (-not [string]::IsNullOrEmpty($Where)) { $sql += ' WHERE ' + $Where }
    if (-not [string]::IsNullOrEmpty($OrderBy)) { $sql += ' ORDER BY ' + $OrderBy }
    if ($Limit -gt 0) { $sql += ' LIMIT ' + $Limit }
    if ($Offset -gt 0) { $sql += ' OFFSET ' + $Offset }
    return $sql
}

function Get-PrimaryColumns {
    param([hashtable[]]$Columns)
    $pk = @()
    foreach ($c in $Columns) {
        if ([string]$c['column_key'] -eq 'PRI') { $pk += $c }
    }
    return @($pk | Sort-Object { [int]$_['ordinal'] })
}

function New-TablesFromLiveRows {
    param([hashtable[]]$LiveColumns, [hashtable[]]$ForeignKeys)
    $fk = @{}
    foreach ($k in @($ForeignKeys)) {
        if ($null -eq $k) { continue }
        $id = ([string]$k['TABLE_NAME']) + '|' + ([string]$k['COLUMN_NAME'])
        if (-not $fk.ContainsKey($id)) { $fk[$id] = $k }
    }
    $tables = @{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($LiveColumns)) {
        if ($null -eq $row) { continue }
        $tn = [string]$row['TABLE_NAME']
        if (-not $tables.ContainsKey($tn)) {
            $tables[$tn] = @{ name = $tn; include = 'YES'; Columns = @() }
            $order.Add($tn)
        }
        $id = $tn + '|' + [string]$row['COLUMN_NAME']
        $key = $null
        if ($fk.ContainsKey($id)) { $key = $fk[$id] }
        $tables[$tn].Columns += ,(ConvertTo-ColumnMapFromInfo $row $key)
    }
    $out = @()
    foreach ($tn in $order) { $out += $tables[$tn] }
    return ,$out
}

function Get-ForeignKeyMaps {
    param([hashtable[]]$ForeignKeys)
    $out = @()
    foreach ($k in @($ForeignKeys)) {
        if ($null -eq $k) { continue }
        $out += @{
            table = [string]$k['TABLE_NAME']
            column = [string]$k['COLUMN_NAME']
            referenced_table = [string]$k['REFERENCED_TABLE_NAME']
            referenced_column = [string]$k['REFERENCED_COLUMN_NAME']
        }
    }
    return ,$out
}
