$ErrorActionPreference = 'Stop'
if (-not ('System.Numerics.BigInteger' -as [type])) {
    Add-Type -AssemblyName System.Numerics
}
$root = $PSScriptRoot
if (-not ('AuroraDataTool.Rng64' -as [type])) {
    Add-Type -Path (Join-Path $root 'native\AuroraGen.cs') -ReferencedAssemblies System.Numerics
}
. (Join-Path $root 'lib\PlanFormat.ps1')
. (Join-Path $root 'lib\MysqlClient.ps1')
. (Join-Path $root 'lib\Schema.ps1')
. (Join-Path $root 'lib\Commands.ps1')
. (Join-Path $root 'lib\Workbook.ps1')
Export-ModuleMember -Function *
