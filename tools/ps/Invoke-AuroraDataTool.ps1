param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$Plan,
    [switch]$Execute,
    [string]$Mysql = 'mysql',
    [string]$Mysqldump = 'mysqldump',
    [string]$PasswordEnv,
    [string]$PasswordFile,
    [string]$OnlyTables,
    [string]$RunState,
    [string]$Workbook,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path $here 'AuroraDataTool.psm1') -Force
$known = @('ping','dump','export-csv','delete','load-csv','generate','generate-and-load','prepare','cleanup','inspect','export-plan','new-sample','self-test')
if ($known -notcontains $Action) { throw "Unknown action '$Action'." }

if ($Action -eq 'self-test') {
    $repo = Split-Path -Parent (Split-Path -Parent $here)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\Run-UnitTests.ps1')
    exit $LASTEXITCODE
}
if ($Action -eq 'new-sample') {
    if ([string]::IsNullOrWhiteSpace($Workbook)) { throw 'new-sample requires -Workbook.' }
    New-SampleWorkbook -Path $Workbook
    Write-Host "Wrote $Workbook"
    exit 0
}
if ($Action -eq 'export-plan') {
    if ([string]::IsNullOrWhiteSpace($Workbook)) { throw 'export-plan requires -Workbook.' }
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $OutFile = [System.IO.Path]::ChangeExtension($Workbook, '.plan.txt')
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Export-LoadPlan.ps1') -Workbook $Workbook -OutFile $OutFile
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($Plan)) { throw "$Action requires -Plan." }
$loaded = Read-AuroraPlan -Path $Plan
if ($Action -eq 'inspect') {
    if ([string]::IsNullOrWhiteSpace($Workbook)) { throw 'inspect requires -Workbook.' }
    $password = Get-AuroraPassword -Plan $loaded -PasswordFile $PasswordFile -PasswordEnv $PasswordEnv
    Invoke-AuroraInspect -Plan $loaded -PlanPath $Plan -MysqlExe $Mysql -Password $password -WorkbookPath $Workbook -OnlyTables $OnlyTables
    Write-Host "Wrote $Workbook"
    exit 0
}

$offline = @('generate')
$password = ''
if ($offline -notcontains $Action) {
    $password = Get-AuroraPassword -Plan $loaded -PasswordFile $PasswordFile -PasswordEnv $PasswordEnv
}
Invoke-AuroraAction -Plan $loaded -PlanPath $Plan -Action $Action -Execute:([bool]$Execute) -MysqlExe $Mysql -MysqldumpExe $Mysqldump -Password $password -OnlyTables $OnlyTables -RunStatePath $RunState
exit 0
