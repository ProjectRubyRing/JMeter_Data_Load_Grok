$script:AuroraActions = @('ping','dump','export-csv','delete','load-csv','generate','generate-and-load','prepare','cleanup','inspect')
$script:AuroraYesNo = @('YES','NO')
$script:AuroraDeleteModes = @('none','truncate','delete')
$script:AuroraCleanupModes = @('restore-csv','delete-inserted','truncate')
$script:AuroraLoadMethods = @('insert','local-infile')
$script:AuroraSslModes = @('REQUIRED','VERIFY_CA','VERIFY_IDENTITY','DISABLED')
$script:AuroraStringModes = @('ascii','unicode')
$script:AuroraUnknownPolicies = @('error','skip','auto')

$script:AuroraJobKeys = @(
    'action','row_count','batch_size','load_method','output_dir','dump_path','dump_scope',
    'dump_routines','dump_triggers','dump_events','seed','delete_mode','allow_destructive',
    'allow_delete_without_backup','confirm','disable_fk_checks','relax_unique_checks','charset',
    'time_zone','cleanup_mode','include_dump','include_csv_backup','null_ratio','string_mode',
    'max_packet_bytes','chunk_rows','reference_limit','verify_row_count','unknown_column_policy',
    'csv_dialect','allow_huge'
)
$script:AuroraJobDefaults = @{
    action = 'prepare'
    row_count = '1000'
    batch_size = '500'
    load_method = 'insert'
    output_dir = './out'
    dump_scope = 'database'
    dump_routines = 'YES'
    dump_triggers = 'YES'
    dump_events = 'YES'
    seed = '1'
    delete_mode = 'none'
    allow_destructive = 'NO'
    allow_delete_without_backup = 'NO'
    confirm = 'NO'
    disable_fk_checks = 'YES'
    relax_unique_checks = 'YES'
    charset = 'utf8mb4'
    time_zone = '+00:00'
    cleanup_mode = 'restore-csv'
    include_dump = 'YES'
    include_csv_backup = 'YES'
    null_ratio = '0'
    string_mode = 'ascii'
    max_packet_bytes = '4194304'
    chunk_rows = '5000'
    reference_limit = '200000'
    verify_row_count = 'YES'
    unknown_column_policy = 'error'
    csv_dialect = 'aurora1'
    allow_huge = 'NO'
}
$script:AuroraConnectionKeys = @('host','port','database','user','ssl_mode','ssl_ca','password_source')
$script:AuroraTableKeys = @(
    'name','include','row_count','delete_mode','csv_backup_path','load_csv_path',
    'cleanup_mode','marker_column','marker_value','notes'
)
$script:AuroraColumnKeys = @(
    'table','name','ordinal','column_type','data_type','is_nullable','column_key','extra','column_default',
    'char_length','num_precision','num_scale','datetime_precision','is_unsigned','is_generated','is_auto_increment',
    'enum_values','fk_table','fk_column','strategy','const_value','range_min','range_max','unique_mode','unique_start',
    'unique_step','unique_prefix','unique_pad','choice_list','template','pattern','null_ratio','string_length',
    'string_min_length','string_max_length','reference_table','reference_column','reference_mode','reference_start',
    'reference_count','reference_step','expression','include','overflow','unique_suffix','notes'
)
$script:AuroraMetaKeys = @('format_version','generated_at','generator','source_workbook')

function ConvertTo-PascalName {
    param([string]$Snake)
    $parts = $Snake.Split('_')
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $parts) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        [void]$sb.Append($p.Substring(0, 1).ToUpperInvariant())
        if ($p.Length -gt 1) { [void]$sb.Append($p.Substring(1)) }
    }
    return $sb.ToString()
}

function New-AuroraPlan {
    return @{
        Meta = @{ format_version = '1' }
        Connection = @{ port = '3306'; ssl_mode = 'REQUIRED'; password_source = 'env:AURORA_PASSWORD' }
        Job = @{}
        Tables = @()
    }
}

function Complete-AuroraPlan {
    param([hashtable]$Plan)
    foreach ($k in $script:AuroraJobDefaults.Keys) {
        if ([string]::IsNullOrEmpty([string]$Plan.Job[$k])) { $Plan.Job[$k] = [string]$script:AuroraJobDefaults[$k] }
    }
    if ([string]::IsNullOrEmpty([string]$Plan.Connection['port'])) { $Plan.Connection['port'] = '3306' }
    if ([string]::IsNullOrEmpty([string]$Plan.Connection['ssl_mode'])) { $Plan.Connection['ssl_mode'] = 'REQUIRED' }
    if ([string]::IsNullOrEmpty([string]$Plan.Connection['password_source'])) { $Plan.Connection['password_source'] = 'env:AURORA_PASSWORD' }
    if ([string]::IsNullOrEmpty([string]$Plan.Meta['format_version'])) { $Plan.Meta['format_version'] = '1' }
    foreach ($t in $Plan.Tables) {
        if ([string]::IsNullOrEmpty([string]$t['include'])) { $t['include'] = 'YES' }
        foreach ($c in $t.Columns) {
            if ([string]::IsNullOrEmpty([string]$c['include'])) { $c['include'] = 'YES' }
            if ([string]::IsNullOrEmpty([string]$c['strategy'])) { $c['strategy'] = 'auto' }
        }
    }
}

function Test-AuroraPlan {
    param([hashtable]$Plan)
    $errors = New-Object System.Collections.Generic.List[string]
    if ($Plan.Meta['format_version'] -ne '1') { $errors.Add('format_version must be 1.') }
    $action = [string]$Plan.Job['action']
    if ($script:AuroraActions -notcontains $action) { $errors.Add("action is invalid: $action") }
    foreach ($name in @('allow_destructive','allow_delete_without_backup','confirm','disable_fk_checks','relax_unique_checks','include_dump','include_csv_backup','dump_routines','dump_triggers','dump_events','verify_row_count','allow_huge')) {
        $v = [string]$Plan.Job[$name]
        if ($script:AuroraYesNo -notcontains $v) { $errors.Add("${name} must be YES or NO.") }
    }
    if ($script:AuroraDeleteModes -notcontains [string]$Plan.Job['delete_mode']) { $errors.Add('delete_mode must be none, truncate, or delete.') }
    if ($script:AuroraCleanupModes -notcontains [string]$Plan.Job['cleanup_mode']) { $errors.Add('cleanup_mode must be restore-csv, delete-inserted, or truncate.') }
    if ($script:AuroraLoadMethods -notcontains [string]$Plan.Job['load_method']) { $errors.Add('load_method must be insert or local-infile.') }
    if ($script:AuroraSslModes -notcontains [string]$Plan.Connection['ssl_mode']) { $errors.Add('ssl_mode is invalid.') }
    if ($script:AuroraStringModes -notcontains [string]$Plan.Job['string_mode']) { $errors.Add('string_mode must be ascii or unicode.') }
    if ($script:AuroraUnknownPolicies -notcontains [string]$Plan.Job['unknown_column_policy']) { $errors.Add('unknown_column_policy is invalid.') }
    if (@('database','tables') -notcontains [string]$Plan.Job['dump_scope']) { $errors.Add('dump_scope must be database or tables.') }
    if ([string]$Plan.Job['csv_dialect'] -ne 'aurora1') { $errors.Add('csv_dialect must be aurora1.') }
    if ([string]$Plan.Job['time_zone'] -notmatch '^[A-Za-z0-9_/+.:-]{1,64}$') { $errors.Add('time_zone contains a character that is not allowed in a session time zone.') }
    $dbActions = @('ping','dump','export-csv','delete','load-csv','generate-and-load','prepare','cleanup','inspect')
    if ($dbActions -contains $action) {
        foreach ($req in @('host','database','user')) {
            if ([string]::IsNullOrWhiteSpace([string]$Plan.Connection[$req])) { $errors.Add("connection.$req is required for $action.") }
        }
    }
    $port = 0
    if (-not [int]::TryParse([string]$Plan.Connection['port'], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $errors.Add('port must be 1..65535.') }
    foreach ($field in @('host','database','user','ssl_ca','password_source')) {
        $v = [string]$Plan.Connection[$field]
        if ($v -match '[\r\n]') { $errors.Add("connection.$field contains a newline.") }
    }
    if ([string]$Plan.Connection['password_source'] -notmatch '^(env:[A-Za-z_][A-Za-z0-9_]*|file:.+|prompt)$') {
        $errors.Add('password_source must be env:NAME, file:PATH, or prompt.')
    }
    $rows = 0L
    if (-not [long]::TryParse([string]$Plan.Job['row_count'], [ref]$rows) -or $rows -lt 0) { $errors.Add('row_count must be an integer >= 0.') }
    if ($rows -gt 100000000 -and [string]$Plan.Job['allow_huge'] -ne 'YES') { $errors.Add('row_count above 100000000 requires allow_huge=YES.') }
    $seed = [uint64]0
    if (-not [uint64]::TryParse([string]$Plan.Job['seed'], [ref]$seed)) { $errors.Add('seed must be an integer from 0 through 2^64-1.') }
    foreach ($intField in @('batch_size','max_packet_bytes','chunk_rows','reference_limit')) {
        $n = 0
        if (-not [int]::TryParse([string]$Plan.Job[$intField], [ref]$n) -or $n -lt 1) { $errors.Add("$intField must be an integer >= 1.") }
    }
    $ratio = 0.0
    if (-not [double]::TryParse([string]$Plan.Job['null_ratio'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ratio) -or $ratio -lt 0 -or $ratio -gt 1) {
        $errors.Add('null_ratio must be between 0 and 1.')
    }
    $names = @{}
    foreach ($t in $Plan.Tables) {
        $tn = [string]$t['name']
        if ([string]::IsNullOrWhiteSpace($tn)) { $errors.Add('A table section is missing name.'); continue }
        if ($names.ContainsKey($tn)) { $errors.Add("Duplicate table section: $tn") }
        $names[$tn] = $true
        if ($script:AuroraYesNo -notcontains [string]$t['include']) { $errors.Add("${tn}.include must be YES or NO.") }
        if (-not [string]::IsNullOrEmpty([string]$t['delete_mode']) -and $script:AuroraDeleteModes -notcontains [string]$t['delete_mode']) { $errors.Add("${tn}.delete_mode is invalid.") }
        if (-not [string]::IsNullOrEmpty([string]$t['cleanup_mode']) -and $script:AuroraCleanupModes -notcontains [string]$t['cleanup_mode']) { $errors.Add("${tn}.cleanup_mode is invalid.") }
        if (-not [string]::IsNullOrEmpty([string]$t['row_count'])) {
            $tr = 0L
            if (-not [long]::TryParse([string]$t['row_count'], [ref]$tr) -or $tr -lt 0) { $errors.Add("${tn}.row_count is invalid.") }
        }
        foreach ($c in $t.Columns) {
            if ([string]$c['table'] -ne $tn) { $errors.Add("Column $($c['name']) is listed under $tn but its table field is $($c['table']).") }
            if ([string]::IsNullOrWhiteSpace([string]$c['name'])) { $errors.Add("A column of $tn has no name.") }
        }
    }
    return @($errors.ToArray())
}

function Read-AuroraPlan {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Plan file was not found: $Path" }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $utf8)
    $plan = New-AuroraPlan
    $section = ''
    $current = $null
    $pendingColumn = $null
    $lineNo = 0
    foreach ($raw in ($text -split "`n", -1)) {
        $lineNo++
        $line = $raw.TrimEnd("`r")
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
        if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
            if ($null -ne $pendingColumn) {
                $tableName = [string]$pendingColumn['table']
                if ([string]::IsNullOrWhiteSpace($tableName)) { throw "A [column] section is missing table before line $lineNo." }
                $owner = $null
                foreach ($t in $plan.Tables) { if ([string]$t['name'] -eq $tableName) { $owner = $t; break } }
                if ($null -eq $owner) {
                    $owner = @{ name = $tableName; include = 'YES'; Columns = @() }
                    $plan.Tables += $owner
                }
                $owner.Columns += $pendingColumn
                $pendingColumn = $null
            }
            $section = $trim.Substring(1, $trim.Length - 2).Trim().ToLowerInvariant()
            if (@('meta','connection','job','table','column') -notcontains $section) { throw "Unknown section [$section] at line $lineNo." }
            if ($section -eq 'table') {
                $current = @{ Columns = @() }
                $plan.Tables += $current
            } elseif ($section -eq 'column') {
                $current = @{}
                $pendingColumn = $current
            } else { $current = $null }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { throw "Expected key=value at line ${lineNo}." }
        $key = $line.Substring(0, $eq).Trim().ToLowerInvariant()
        $value = $line.Substring($eq + 1)
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2).Replace('\"','"').Replace('\\','\')
        } else { $value = $value.Trim() }
        if ($key -eq 'password') { throw "Do not store a password in the plan. Use password_source. Line $lineNo." }
        $allowed = @()
        $target = $null
        switch ($section) {
            'meta' { $allowed = $script:AuroraMetaKeys; $target = $plan.Meta }
            'connection' { $allowed = $script:AuroraConnectionKeys; $target = $plan.Connection }
            'job' { $allowed = $script:AuroraJobKeys; $target = $plan.Job }
            'table' { $allowed = $script:AuroraTableKeys; $target = $current }
            'column' { $allowed = $script:AuroraColumnKeys; $target = $current }
            default { throw "A key appeared before a section at line $lineNo." }
        }
        if ($null -eq $target) { throw "Section [$section] is not open at line $lineNo." }
        if ($allowed -notcontains $key) { throw "Unknown key '$key' in [$section] at line $lineNo." }
        $target[$key] = $value
    }
    if ($null -ne $pendingColumn) {
        $tableName = [string]$pendingColumn['table']
        if ([string]::IsNullOrWhiteSpace($tableName)) { throw 'A [column] section is missing table.' }
        $owner = $null
        foreach ($t in $plan.Tables) { if ([string]$t['name'] -eq $tableName) { $owner = $t; break } }
        if ($null -eq $owner) {
            $owner = @{ name = $tableName; include = 'YES'; Columns = @() }
            $plan.Tables += $owner
        }
        $owner.Columns += $pendingColumn
    }
    return $plan
}

function ConvertTo-PlanValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $trim = $Value.Trim()
    $needsQuote = ($trim -ne $Value) -or ($Value.Contains('"')) -or ($Value.Contains('\'))
    if (-not $needsQuote) { return $Value }
    return '"' + ($Value.Replace('\','\\').Replace('"','\"')) + '"'
}

function Write-AuroraPlan {
    param([Parameter(Mandatory=$true)][hashtable]$Plan, [Parameter(Mandatory=$true)][string]$Path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# aurora-load-plan format 1')
    [void]$sb.AppendLine('# Password is never stored in this file.')
    function Append-Section([string]$Name, [string[]]$Keys, [hashtable]$Bag) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[' + $Name + ']')
        foreach ($k in $Keys) {
            if ($Bag.ContainsKey($k) -and $null -ne $Bag[$k] -and [string]$Bag[$k] -ne '') {
                [void]$sb.AppendLine($k + '=' + (ConvertTo-PlanValue ([string]$Bag[$k])))
            }
        }
    }
    Append-Section 'meta' $script:AuroraMetaKeys $Plan.Meta
    Append-Section 'connection' $script:AuroraConnectionKeys $Plan.Connection
    Append-Section 'job' $script:AuroraJobKeys $Plan.Job
    foreach ($t in $Plan.Tables) {
        Append-Section 'table' $script:AuroraTableKeys $t
        foreach ($c in @($t.Columns)) {
            Append-Section 'column' $script:AuroraColumnKeys $c
        }
    }
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $sb.ToString().Replace("`r`n","`n"), $utf8)
}

function Get-IncludedTables {
    param([hashtable]$Plan, [string]$Only)
    $want = $null
    if (-not [string]::IsNullOrWhiteSpace($Only)) {
        $want = @{}
        foreach ($n in ($Only -split ',')) {
            $t = $n.Trim()
            if ($t.Length -gt 0) { $want[$t] = $true }
        }
    }
    $out = @()
    foreach ($t in $Plan.Tables) {
        if ([string]$t['include'] -ne 'YES') { continue }
        if ($null -ne $want -and -not $want.ContainsKey([string]$t['name'])) { continue }
        $out += $t
    }
    return $out
}

function Get-TableRowCount {
    param([hashtable]$Plan, [hashtable]$Table)
    if (-not [string]::IsNullOrEmpty([string]$Table['row_count'])) { return [long]$Table['row_count'] }
    return [long]$Plan.Job['row_count']
}

function Resolve-PlanRelativePath {
    param([string]$PlanPath, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    $base = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($PlanPath))
    return [System.IO.Path]::GetFullPath((Join-Path $base $Path))
}

function Get-TextSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $hash = $sha.ComputeHash($utf8.GetBytes($Text))
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function New-ColumnSpecFromMap {
    param([hashtable]$Map)
    $spec = New-Object AuroraDataTool.ColumnSpec
    foreach ($k in @($Map.Keys)) {
        $prop = ConvertTo-PascalName $k
        $pi = $spec.GetType().GetProperty($prop)
        if ($null -eq $pi) { continue }
        $raw = $Map[$k]
        if ($pi.PropertyType -eq [int]) {
            $n = 0
            [void][int]::TryParse([string]$raw, [ref]$n)
            $pi.SetValue($spec, $n, $null)
        } elseif ($pi.PropertyType.IsArray) {
            if ($null -eq $raw) { $pi.SetValue($spec, $null, $null) }
            else { $pi.SetValue($spec, [string[]]$raw, $null) }
        } else {
            if ($null -eq $raw) { $pi.SetValue($spec, $null, $null) }
            else { $pi.SetValue($spec, [string]$raw, $null) }
        }
    }
    return $spec
}

function Copy-ColumnSpecToMap {
    param($Spec)
    $map = @{}
    foreach ($k in $script:AuroraColumnKeys) {
        $prop = ConvertTo-PascalName $k
        $pi = $Spec.GetType().GetProperty($prop)
        if ($null -eq $pi) { continue }
        $v = $pi.GetValue($Spec, $null)
        if ($null -ne $v -and [string]$v -ne '') { $map[$k] = [string]$v }
    }
    return $map
}
