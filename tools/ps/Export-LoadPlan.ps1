param(
    [Parameter(Mandatory = $true)][string]$Workbook,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$Log
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path $here 'AuroraDataTool.psm1') -Force

function Write-ExportLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Log)) { return }
    $dir = Split-Path -Parent $Log
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Log, $Message + "`n", $utf8)
}

try {
    $plan = Import-AuroraWorkbook -Path $Workbook
    Complete-AuroraPlan $plan
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Test-AuroraPlan $plan)) { if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $problems.Add([string]$item) } }
    foreach ($table in @($plan.Tables)) {
        if ([string]$table['include'] -ne 'YES') { continue }
        $rowCount = Get-TableRowCount $plan $table
        foreach ($col in @($table.Columns)) {
            $strategy = [string]$col['strategy']
            if ([string]::IsNullOrWhiteSpace($strategy) -or $strategy -eq 'auto') { continue }
            $spec = New-ColumnSpecFromMap $col
            $warnings = New-Object System.Collections.Generic.List[string]
            [AuroraDataTool.StrategyResolver]::Resolve($spec, $warnings)
            $errors = [AuroraDataTool.StrategyResolver]::Validate($spec, [long]$rowCount)
            foreach ($err in @($errors)) { $problems.Add([string]$err) }
        }
    }
    if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
    Write-AuroraPlan -Plan $plan -Path $OutFile
    Write-ExportLog "Wrote $OutFile"
    Write-Host "Wrote $OutFile"
    exit 0
} catch {
    $message = $_.Exception.Message
    Write-ExportLog $message
    Write-Host $message
    exit 1
}
