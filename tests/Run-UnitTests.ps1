$ErrorActionPreference = 'Stop'
$script:Failures = New-Object System.Collections.Generic.List[string]
$repo = Split-Path -Parent $PSScriptRoot
$out = Join-Path $PSScriptRoot 'out'
if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

function Add-Failure {
    param([string]$Name, [string]$Detail)
    $script:Failures.Add("$Name :: $Detail")
    Write-Host "FAIL $Name :: $Detail"
}

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    if (-not $Condition) { Add-Failure $Name $Detail }
    else { Write-Host "OK   $Name" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ([string]$Actual -ne [string]$Expected) { Add-Failure $Name ("expected [" + $Expected + "] actual [" + $Actual + "]") }
    else { Write-Host "OK   $Name" }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern, [string]$Name)
    $threw = $false
    $message = ''
    try { & $Body } catch { $threw = $true; $message = $_.Exception.Message }
    if (-not $threw) { Add-Failure $Name 'no exception' }
    elseif ($message -notmatch $Pattern) { Add-Failure $Name $message }
    else { Write-Host "OK   $Name" }
}

Write-Host 'parse'
Get-ChildItem -LiteralPath (Join-Path $repo 'tools\ps') -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { Add-Failure ("parse " + $_.Name) ($errors[0].ToString()) }
    else { Write-Host ("OK   parse " + $_.Name) }
}
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) { Add-Failure 'parse tests' ($errors[0].ToString()) }

Write-Host 'import'
Import-Module -Name (Join-Path $repo 'tools\ps\AuroraDataTool.psm1') -Force
Assert-True ($null -ne ('AuroraDataTool.Rng64' -as [type])) 'compile AuroraGen.cs' 'type missing'

function New-MiniPlan {
    $plan = New-AuroraPlan
    $plan.Connection['host'] = 'db.example'
    $plan.Connection['database'] = 'appdb'
    $plan.Connection['user'] = 'appuser'
    $plan.Connection['ssl_mode'] = 'DISABLED'
    $plan.Job['action'] = 'generate'
    $plan.Job['output_dir'] = $out
    $plan.Job['row_count'] = '2'
    $plan.Job['seed'] = '7'
    $plan.Job['include_dump'] = 'NO'
    $plan.Job['include_csv_backup'] = 'NO'
    $plan.Tables = @(
        @{
            name = 'demo'
            include = 'YES'
            Columns = @(
                @{
                    table = 'demo'; name = 'id'; ordinal = '1'; data_type = 'bigint'; column_type = 'bigint'
                    is_nullable = 'NO'; column_key = 'PRI'; is_auto_increment = 'YES'; strategy = 'unique'
                    unique_mode = 'sequence'; unique_start = '1'; unique_step = '1'; include = 'YES'
                }
            )
        }
    )
    return $plan
}

Write-Host 'plan roundtrip'
$plan = New-MiniPlan
$plan.Tables[0].Columns += @{
    table = 'demo'; name = 'note'; ordinal = '2'; data_type = 'varchar'; column_type = 'varchar(40)'
    is_nullable = 'YES'; strategy = 'const'; include = 'YES'; const_value = ('a\b"c')
}
$plan.Tables[0].Columns += @{
    table = 'demo'; name = 'tail'; ordinal = '3'; data_type = 'varchar'; column_type = 'varchar(40)'
    is_nullable = 'YES'; strategy = 'const'; include = 'YES'; const_value = ('end\')
}
$plan.Tables[0].Columns += @{
    table = 'demo'; name = 'lead'; ordinal = '4'; data_type = 'varchar'; column_type = 'varchar(40)'
    is_nullable = 'YES'; strategy = 'const'; include = 'YES'; const_value = ' hi'
}
$planPath = Join-Path $out 'roundtrip.plan.txt'
Write-AuroraPlan -Plan $plan -Path $planPath
$loaded = Read-AuroraPlan -Path $planPath
$by = @{}
foreach ($c in $loaded.Tables[0].Columns) { $by[$c['name']] = [string]$c['const_value'] }
Assert-Equal $by['note'] ('a\b"c') 'plan quote roundtrip'
Assert-Equal $by['tail'] ('end\') 'plan trailing backslash'
Assert-Equal $by['lead'] ' hi' 'plan leading space'
$bad = Join-Path $out 'password.plan.txt'
[System.IO.File]::WriteAllText($bad, "[connection]`npassword=secret`n", (New-Object System.Text.UTF8Encoding $false))
Assert-Throws { Read-AuroraPlan -Path $bad } 'password' 'plan rejects password key'

Write-Host 'sql and enum'
$bt = [char]96
Assert-Equal ([AuroraDataTool.Sql]::QuoteIdent('id')) ($bt + 'id' + $bt) 'quote ident'
Assert-True ([AuroraDataTool.Sql]::IsBareNumeric('int', '7')) 'bare 7' 'expected bare'
Assert-True (-not [AuroraDataTool.Sql]::IsBareNumeric('int', '007')) 'reject 007' '007 was bare'
Assert-True (-not [AuroraDataTool.Sql]::IsBareNumeric('varchar', '7')) 'varchar stays quoted' 'varchar was bare'
Assert-Equal (ConvertFrom-EnumColumnType "enum('NEW','PAID','O''Brien')") "NEW|PAID|O'Brien" 'enum parse'
$err = ''
Assert-True ([AuroraDataTool.StrategyResolver]::ExpressionSafe('UUID()', [ref]$err)) 'expression uuid' $err
Assert-True (-not [AuroraDataTool.StrategyResolver]::ExpressionSafe('1; DROP TABLE t', [ref]$err)) 'expression rejects separator' 'accepted'
Assert-Throws { Get-SafeIntegerLiteral '01' 'pk' } 'not a decimal integer' 'reject padded integer'
Assert-Equal (Get-SafeIntegerLiteral '-12' 'pk') '-12' 'accept negative integer'

Write-Host 'strategies and order'
$spec = New-Object AuroraDataTool.ColumnSpec
$spec.Table = 'orders'
$spec.Name = 'id'
$spec.DataType = 'bigint'
$spec.ColumnType = 'bigint'
$spec.IsNullable = 'NO'
$spec.ColumnKey = 'PRI'
$spec.IsAutoIncrement = 'YES'
$spec.Strategy = 'auto'
$warnings = New-Object 'System.Collections.Generic.List[string]'
[AuroraDataTool.StrategyResolver]::Resolve($spec, $warnings)
Assert-Equal $spec.Strategy 'unique' 'auto increment becomes unique'
Assert-Equal $spec.Notes '[auto]' 'auto note once'
[AuroraDataTool.StrategyResolver]::Resolve($spec, $warnings)
Assert-Equal $spec.Notes '[auto]' 'second resolve keeps one auto note'
$orders = @{ name = 'orders'; include = 'YES'; Columns = @(@{ name = 'id'; fk_table = ''; reference_table = '' }) }
$items = @{ name = 'order_items'; include = 'YES'; Columns = @(@{ name = 'order_id'; fk_table = 'orders'; fk_column = 'id' }) }
$order = Get-LoadOrder @($items, $orders)
Assert-Equal (($order.Names) -join ',') 'orders,order_items' 'parent first'
Assert-True (-not $order.Cyclic) 'no cycle' 'cycle flag'
$cycle = Get-LoadOrder @(
    @{ name = 'a'; Columns = @(@{ fk_table = 'b' }) },
    @{ name = 'b'; Columns = @(@{ fk_table = 'a' }) }
)
Assert-True $cycle.Cyclic 'cycle detected' 'expected cycle'

Write-Host 'dump arguments'
$dumpPlan = New-MiniPlan
$dumpPlan.Job['action'] = 'dump'
$dumpPlan.Job['dump_scope'] = 'tables'
$dumpPlan.Tables += @{ name = 'hidden'; include = 'NO'; Columns = @() }
$null = Complete-AuroraPlan $dumpPlan
$dumpArgs = Get-DumpArguments -Plan $dumpPlan -DefaultsFile 'C:\t.cnf' -ResultFile 'C:\out.sql'
$expectedDump = @(
    '--defaults-extra-file=C:\t.cnf',
    '--single-transaction',
    '--quick',
    '--skip-lock-tables',
    '--no-tablespaces',
    '--set-gtid-purged=OFF',
    '--column-statistics=0',
    '--default-character-set=utf8mb4',
    '--hex-blob',
    '--routines',
    '--triggers',
    '--events',
    'appdb',
    'demo',
    '--result-file=C:\out.sql'
)
Assert-Equal ($dumpArgs -join "`n") ($expectedDump -join "`n") 'dump argv tables scope'
$dumpPlan.Job['dump_scope'] = 'database'
$dumpPlan.Job['dump_routines'] = 'NO'
$dumpArgs = Get-DumpArguments -Plan $dumpPlan -DefaultsFile 'C:\t.cnf' -ResultFile 'C:\out.sql'
Assert-True (($dumpArgs -join ' ') -match '--databases appdb' -and ($dumpArgs -notcontains '--routines') -and ($dumpArgs -notcontains 'demo')) 'dump argv database scope' ($dumpArgs -join ' ')

Write-Host 'load data sql'
$loadSql = Get-LoadDataStatement -Database 'appdb' -TableName 'demo' -CsvPath 'C:\data\a.csv' -ColumnNames @('id') -TimeZone '+00:00' -DisableFk $false -RelaxUnique $false
$fragment = 'ESCAPED BY ''\\'' LINES TERMINATED BY ''\n'''
Assert-True ($loadSql.Contains($fragment)) 'load data escapes' 'fragment missing'
Assert-True ($loadSql.Contains('C:/data/a.csv')) 'load data path' 'path missing'
Assert-True (-not $loadSql.Contains('NO_BACKSLASH_ESCAPES')) 'load data sql mode' 'backslash escapes disabled'
Assert-True ($loadSql.Contains('IGNORE 1 LINES')) 'load data header skip' 'ignore missing'

Write-Host 'csv dialect'
$csvPath = Join-Path $out 'dialect.csv'
$utf8 = New-Object System.Text.UTF8Encoding $false
$writer = New-Object System.IO.StreamWriter($csvPath, $false, $utf8)
try {
    [AuroraDataTool.AuroraCsv]::WriteHeader($writer, @('a','b'))
    $values = @('a,b"c', ("line`nnext"), ("x\y"), ([string]([char]26) + 'Z'), 'あ', '\N')
    $nulls = @($false, $false, $false, $false, $false, $false)
    [AuroraDataTool.AuroraCsv]::WriteRow($writer, $values, $nulls)
    [AuroraDataTool.AuroraCsv]::WriteRow($writer, @($null, ''), @($true, $false))
} finally { $writer.Dispose() }
$reader = New-Object AuroraDataTool.AuroraCsv+Reader $csvPath
try {
    $header = $reader.ReadRecord()
    $row = $reader.ReadRecord()
    $nullRow = $reader.ReadRecord()
} finally { $reader.Dispose() }
Assert-Equal ($header.Values -join '|') 'a|b' 'csv header'
Assert-Equal $row.Values[0] 'a,b"c' 'csv comma and quote'
Assert-Equal $row.Values[1] "line`nnext" 'csv newline'
Assert-Equal $row.Values[2] ("x\y") 'csv backslash'
Assert-Equal $row.Values[3] ([string]([char]26) + 'Z') 'csv char 26'
Assert-Equal $row.Values[4] 'あ' 'csv unicode'
Assert-Equal $row.Values[5] '\N' 'csv literal backslash-N'
Assert-True ($nullRow.IsNull[0] -and -not $nullRow.IsNull[1] -and $nullRow.Values[1] -eq '') 'csv null versus empty' 'null flag'

Write-Host 'insert sql'
$insertCsv = Join-Path $out 'insert.csv'
$insertSql = Join-Path $out 'insert.sql'
$iw = New-Object System.IO.StreamWriter($insertCsv, $false, $utf8)
try {
    [AuroraDataTool.AuroraCsv]::WriteHeader($iw, @('id','blob','geom'))
    [AuroraDataTool.AuroraCsv]::WriteRow($iw, @('1','AB','0102'), @($false,$false,$false))
} finally { $iw.Dispose() }
$id = New-Object AuroraDataTool.ColumnSpec
$id.Name = 'id'; $id.DataType = 'bigint'; $id.Strategy = 'const'; $id.Include = 'YES'; $id.Transport = 'text'
$blob = New-Object AuroraDataTool.ColumnSpec
$blob.Name = 'blob'; $blob.DataType = 'blob'; $blob.Strategy = 'const'; $blob.Include = 'YES'; $blob.Transport = 'hex'
$geom = New-Object AuroraDataTool.ColumnSpec
$geom.Name = 'geom'; $geom.DataType = 'geometry'; $geom.Strategy = 'const'; $geom.Include = 'YES'; $geom.Transport = 'wkb'
$expr = New-Object AuroraDataTool.ColumnSpec
$expr.Name = 'stamp'; $expr.DataType = 'datetime'; $expr.Strategy = 'expression'; $expr.Expression = 'UTC_TIMESTAMP()'; $expr.Include = 'YES'
[AuroraDataTool.Generator]::WriteInsertFile($insertCsv, $insertSql, 'appdb', 'demo', @($expr, $geom, $id, $blob), 500, 4194304, $false, $false, '+00:00')
$sqlText = [System.IO.File]::ReadAllText($insertSql, $utf8)
Assert-True ($sqlText.Contains("UNHEX('AB')")) 'hex insert' 'UNHEX missing'
Assert-True ($sqlText.Contains("ST_GeomFromWKB(UNHEX('0102'))")) 'wkb insert' 'WKB missing'
Assert-True ($sqlText.Contains('UTC_TIMESTAMP()')) 'expression insert' 'expression missing'
Assert-True ($sqlText.Contains('NO_BACKSLASH_ESCAPES')) 'insert sql mode' 'mode missing'

Write-Host 'rng'
$mixed = [AuroraDataTool.Rng64]::Mix([uint64]1, 'demo')
$rng = New-Object AuroraDataTool.Rng64 $mixed
$rngLines = New-Object System.Collections.Generic.List[string]
$rngLines.Add($mixed.ToString('x16'))
for ($i = 0; $i -lt 5; $i++) { $rngLines.Add($rng.Next().ToString('x16')) }
$when = [datetime]::MinValue
$whenErr = ''
[void][AuroraDataTool.StrategyResolver]::TryParseWhen('2024-01-01 00:00:00', 'datetime', [ref]$when, [ref]$whenErr)
$tickText = $when.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)

Write-Host 'safety paths'
$mini = New-MiniPlan
$miniFile = Join-Path $out 'mini.plan.txt'
Write-AuroraPlan -Plan $mini -Path $miniFile
$missing = 'C:\no\such\aurora-mysql.exe'
Invoke-AuroraAction -Plan $mini -PlanPath $miniFile -Action 'delete' -Execute $false -MysqlExe $missing -MysqldumpExe $missing -Password '' | Out-Null
Assert-True $true 'dry-run delete does not connect' ''
$danger = New-MiniPlan
$danger.Job['confirm'] = 'YES'
$danger.Job['allow_destructive'] = 'NO'
$danger.Job['delete_mode'] = 'truncate'
$dangerFile = Join-Path $out 'danger.plan.txt'
Write-AuroraPlan -Plan $danger -Path $dangerFile
Assert-Throws {
    Invoke-AuroraAction -Plan $danger -PlanPath $dangerFile -Action 'prepare' -Execute $true -MysqlExe $missing -MysqldumpExe $missing -Password 'x'
} 'allow_destructive' 'destructive prepare refused before mysql'

Write-Host 'offline generate'
$paritySrc = Join-Path $repo 'examples\parity.plan.txt'
$parity = Read-AuroraPlan -Path $paritySrc
$parity.Job['output_dir'] = $out
$parityFile = Join-Path $out 'parity.plan.txt'
Write-AuroraPlan -Plan $parity -Path $parityFile
Invoke-AuroraAction -Plan $parity -PlanPath $parityFile -Action 'generate' -Execute $false -MysqlExe $missing -MysqldumpExe $missing -Password '' | Out-Null
$genCsv = Join-Path $out 'generated\demo.csv'
Assert-True (Test-Path -LiteralPath $genCsv) 'generated csv exists' $genCsv
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $psHash = ([System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($genCsv)))).Replace('-', '').ToLowerInvariant()
} finally { $sha.Dispose() }

Write-Host 'defaults file'
$secret = 'p"a\ss word'
$cnf = New-MysqlDefaultsFile -Connection @{ host = 'db.example'; port = '3306'; user = 'appuser'; ssl_mode = 'DISABLED' } -Password $secret
$cnfText = [System.IO.File]::ReadAllText($cnf, $utf8)
$expectedPassword = 'password="' + 'p\"a\\ss word' + '"'
Assert-True ($cnfText.Contains($expectedPassword)) 'defaults password quoting' 'quoted password mismatch'
Assert-True ($cnfText.Contains('ssl-mode=DISABLED')) 'defaults ssl' 'ssl missing'
Remove-MysqlDefaultsFile -Path $cnf
Assert-True (-not (Test-Path -LiteralPath $cnf)) 'defaults file wiped' 'file remained'

Write-Host 'fake client'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$fake = Join-Path $out 'FakeClient.exe'
& $csc /nologo /out:$fake (Join-Path $repo 'tests\fakes\FakeClient.cs')
if ($LASTEXITCODE -ne 0) { Add-Failure 'compile fake client' "csc exit $LASTEXITCODE" }
else { Write-Host 'OK   compile fake client' }
$log = Join-Path $out 'fake-argv.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
$env:FAKE_CLIENT_LOG = $log
$env:FAKE_ECHO = '1'
$echo = Invoke-NativeProcess -FilePath $fake -ArgumentList @('--batch') -StdinBytes ($utf8.GetBytes('あ'))
$env:FAKE_ECHO = $null
Assert-Equal $echo.ExitCode '0' 'fake echo exit'
Assert-Equal $echo.Stdout 'あ' 'fake echo utf8'
$env:FAKE_REJECT_COLUMN_STATISTICS = '1'
$marker = Join-Path $out 'reject.marker'
if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
$env:FAKE_REJECT_MARKER = $marker
$dumpOut = Join-Path $out 'fake.sql'
if (Test-Path -LiteralPath $dumpOut) { Remove-Item -LiteralPath $dumpOut -Force }
$live = New-MiniPlan
$live.Job['dump_path'] = $dumpOut
$live.Job['dump_scope'] = 'database'
$live.Connection['password_source'] = 'env:AURORA_PASSWORD'
$liveFile = Join-Path $out 'live.plan.txt'
Write-AuroraPlan -Plan $live -Path $liveFile
$env:AURORA_PASSWORD = $secret
Invoke-AuroraAction -Plan $live -PlanPath $liveFile -Action 'dump' -Execute $true -MysqlExe $fake -MysqldumpExe $fake -Password $secret | Out-Null
Assert-True (Test-Path -LiteralPath $dumpOut) 'dump retry created file' $dumpOut
$argvLog = [System.IO.File]::ReadAllText($log, $utf8)
Assert-True ($argvLog.Contains('unknown option') -or (Test-Path -LiteralPath $marker)) 'dump retry marker' 'marker missing'
Assert-True (-not $argvLog.Contains($secret)) 'password stays out of argv' 'password leaked'
$markerText = ''
if (Test-Path -LiteralPath $marker) { $markerText = [System.IO.File]::ReadAllText($marker, $utf8) }
Assert-Equal $markerText 'rejected' 'column statistics rejected once'
$env:FAKE_REJECT_COLUMN_STATISTICS = $null
$env:FAKE_CLIENT_LOG = $null
$env:FAKE_REJECT_MARKER = $null
$env:AURORA_PASSWORD = $null

Write-Host 'workbook'
$xlsx = Join-Path $out 'sample.xlsx'
if (Test-Path -LiteralPath $xlsx) { Remove-Item -LiteralPath $xlsx -Force }
New-SampleWorkbook -Path $xlsx -NoButton | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($xlsx)
try {
    $bookEntry = $zip.GetEntry('xl/workbook.xml')
    $bookReader = New-Object System.IO.StreamReader($bookEntry.Open(), $utf8)
    try { $bookXml = $bookReader.ReadToEnd() } finally { $bookReader.Dispose() }
    $formula = ''
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -notlike 'xl/worksheets/*.xml') { continue }
        $sheetReader = New-Object System.IO.StreamReader($entry.Open(), $utf8)
        try { $sheetXml = $sheetReader.ReadToEnd() } finally { $sheetReader.Dispose() }
        if ($sheetXml.Contains('formula1')) { $formula += $sheetXml }
    }
} finally { $zip.Dispose() }
Assert-True ($bookXml.Contains("name=`"ExporterScript`">'使い方'!`$B`$2")) 'defined name exporter' 'defined name missing'
Assert-True ($formula.Contains("'リスト'!`$A`$2:`$A`$14")) 'validation formula' 'formula missing'
Assert-True (-not $formula.Contains([char]96)) 'validation formula has no backtick' 'backtick remained'
$imported = Import-AuroraWorkbook -Path $xlsx
Assert-Equal $imported.Connection['database'] 'appdb' 'workbook database'
$itemCol = $null
foreach ($t in $imported.Tables) {
    if ($t['name'] -ne 'order_items') { continue }
    foreach ($c in $t.Columns) { if ($c['name'] -eq 'order_id') { $itemCol = $c } }
}
Assert-Equal $itemCol['fk_table'] 'orders' 'workbook foreign key'
Assert-Equal $itemCol['strategy'] 'auto' 'workbook keeps auto'

Write-Host 'awk parity'
$awkCsv = Join-Path $out 'awk-demo.csv'
$awkRng = Join-Path $out 'awk-rng.txt'
$awkTicks = Join-Path $out 'awk-ticks.txt'
$awkDump = Join-Path $out 'awk-dump.txt'
$bash = Join-Path $repo 'tools\bash\aurora-data-tool.sh'
$wslRoot = '/mnt/c/Users/taka_/Grok/JMeter_Data_Load_Grok'
function Invoke-Wsl {
    param([string]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = '-e bash -c ' + (ConvertTo-WindowsArgument $Command)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}
$self = Invoke-Wsl "cd $wslRoot && LC_ALL=C awk -f tools/bash/aurora-gen.awk -v mode=selftest"
Assert-Equal $self.ExitCode '0' 'awk selftest exit'
Assert-True ($self.Stdout.Contains('selftest ok')) 'awk selftest' $self.Stderr
$rngRun = Invoke-Wsl "cd $wslRoot && LC_ALL=C awk -f tools/bash/aurora-gen.awk -v mode=rng -v seed=1 -v text=demo > tests/out/awk-rng.txt"
Assert-Equal $rngRun.ExitCode '0' 'awk rng exit'
$awkRngText = [System.IO.File]::ReadAllText($awkRng, $utf8).TrimEnd("`r","`n")
Assert-Equal ($awkRngText -replace "`r","") ($rngLines -join "`n") 'rng matches awk'
$tickRun = Invoke-Wsl "cd $wslRoot && LC_ALL=C awk -f tools/bash/aurora-gen.awk -v mode=ticks > tests/out/awk-ticks.txt"
Assert-Equal $tickRun.ExitCode '0' 'awk ticks exit'
$tickLines = @([System.IO.File]::ReadAllText($awkTicks, $utf8).TrimEnd("`r","`n") -split "`n")
Assert-Equal $tickLines[0].Trim() '2024-01-01 00:00:00' 'awk date format'
Assert-Equal $tickLines[1].Trim() $tickText 'ticks match dotnet'
$csvRun = Invoke-Wsl "cd $wslRoot && bash tools/bash/aurora-data-tool.sh generate --plan examples/parity.plan.txt --out tests/out/awk-gen --table demo"
Assert-Equal $csvRun.ExitCode '0' 'awk generate exit'
$awkFile = Join-Path $out 'awk-gen\demo.csv'
$sha2 = [System.Security.Cryptography.SHA256]::Create()
try {
    $awkHash = ([System.BitConverter]::ToString($sha2.ComputeHash([System.IO.File]::ReadAllBytes($awkFile)))).Replace('-', '').ToLowerInvariant()
} finally { $sha2.Dispose() }
Assert-Equal $awkHash $psHash 'csv sha256 matches powershell'
$dumpRun = Invoke-Wsl "cd $wslRoot && bash tools/bash/aurora-data-tool.sh dumpargs --plan examples/parity.plan.txt --defaults /tmp/client.cnf --result /tmp/out.sql > tests/out/awk-dump.txt"
Assert-Equal $dumpRun.ExitCode '0' 'awk dumpargs exit'
$awkDumpLines = @([System.IO.File]::ReadAllText($awkDump, $utf8).TrimEnd("`r","`n") -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
Assert-True ($awkDumpLines[0] -eq '--defaults-extra-file=/tmp/client.cnf' -and $awkDumpLines[1] -eq '--single-transaction' -and $awkDumpLines -contains '--set-gtid-purged=OFF' -and $awkDumpLines[-1] -eq '--result-file=/tmp/out.sql') 'awk dump flag order' ($awkDumpLines -join ' ')

Write-Host 'orders example'
$ordersSrc = Join-Path $repo 'examples\orders.plan.txt'
$ordersPlan = Read-AuroraPlan -Path $ordersSrc
$ordersPlan.Job['output_dir'] = (Join-Path $out 'orders')
$ordersFile = Join-Path $out 'orders.plan.txt'
Write-AuroraPlan -Plan $ordersPlan -Path $ordersFile
Invoke-AuroraAction -Plan $ordersPlan -PlanPath $ordersFile -Action 'generate' -Execute $false -MysqlExe $missing -MysqldumpExe $missing -Password '' | Out-Null
$ordersCsv = Join-Path $out 'orders\generated\orders.csv'
$itemsCsv = Join-Path $out 'orders\generated\order_items.csv'
$ordersLines = @(Get-Content -LiteralPath $ordersCsv)
$itemLines = @(Get-Content -LiteralPath $itemsCsv)
Assert-Equal $ordersLines.Count '21' 'orders row count'
Assert-Equal $itemLines.Count '21' 'order_items row count'
$badRef = $false
foreach ($line in $itemLines | Select-Object -Skip 1) {
    $cols = $line.Split(',')
    $n = 0
    if (-not [int]::TryParse($cols[1].Trim('"'), [ref]$n) -or $n -lt 1 -or $n -gt 20) { $badRef = $true }
}
Assert-True (-not $badRef) 'order_id stays inside 1..20' 'reference out of range'

if ($script:Failures.Count -gt 0) {
    Write-Host ("FAILED " + $script:Failures.Count)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
