function Resolve-ClientExe {
    param([Parameter(Mandatory=$true)][string]$Name)
    if (Test-Path -LiteralPath $Name) { return (Resolve-Path -LiteralPath $Name).Path }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    throw "Client program '$Name' was not found. Install MySQL 8.4 client tools and add mysql.exe and mysqldump.exe to PATH."
}

function ConvertTo-WindowsArgument {
    param([string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\', ($bs * 2 + 1))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\', ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-OptionQuoted {
    param([string]$Value)
    $esc = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $esc + '"'
}

function New-MysqlDefaultsFile {
    param([hashtable]$Connection, [Parameter(Mandatory=$true)][string]$Password)
    if ($Password -match '[\r\n]') { throw 'The password contains a newline and cannot be passed in an option file.' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('aurora-data-tool-' + [guid]::NewGuid().ToString('n') + '.cnf')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[client]')
    $lines.Add('host=' + (ConvertTo-OptionQuoted ([string]$Connection['host'])))
    $lines.Add('port=' + [string]$Connection['port'])
    $lines.Add('user=' + (ConvertTo-OptionQuoted ([string]$Connection['user'])))
    $lines.Add('password=' + (ConvertTo-OptionQuoted $Password))
    $lines.Add('protocol=tcp')
    $lines.Add('default-character-set=utf8mb4')
    $lines.Add('max-allowed-packet=1073741824')
    $lines.Add('connect-timeout=30')
    $ssl = [string]$Connection['ssl_mode']
    if (-not [string]::IsNullOrEmpty($ssl)) { $lines.Add('ssl-mode=' + $ssl) }
    if (-not [string]::IsNullOrEmpty([string]$Connection['ssl_ca'])) {
        $lines.Add('ssl-ca=' + (ConvertTo-OptionQuoted ([string]$Connection['ssl_ca'])))
    }
    [System.IO.File]::WriteAllText($path, (($lines.ToArray()) -join "`n") + "`n", $utf8)
    try {
        & icacls $path /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
    } catch {
        Write-Warning "Could not restrict the temporary client defaults file ACL: $($_.Exception.Message)"
    }
    return $path
}

function Remove-MysqlDefaultsFile {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $wipe = New-Object byte[] $bytes.Length
        [System.IO.File]::WriteAllBytes($Path, $wipe)
    } catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-AuroraPassword {
    param([hashtable]$Plan, [string]$PasswordFile, [string]$PasswordEnv)
    if (-not [string]::IsNullOrEmpty($PasswordFile)) {
        if (-not (Test-Path -LiteralPath $PasswordFile)) { throw "Password file was not found: $PasswordFile" }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        return ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PasswordFile), $utf8)).TrimEnd("`r", "`n")
    }
    $source = [string]$Plan.Connection['password_source']
    if (-not [string]::IsNullOrEmpty($PasswordEnv)) { $source = 'env:' + $PasswordEnv }
    if ($source -like 'env:*') {
        $name = $source.Substring(4)
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($value)) { throw "Environment variable $name is empty. Set the Aurora password there." }
        return $value
    }
    if ($source -like 'file:*') {
        $file = $source.Substring(5)
        if (-not (Test-Path -LiteralPath $file)) { throw "Password file was not found: $file" }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        return ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $file), $utf8)).TrimEnd("`r", "`n")
    }
    if ($source -eq 'prompt') {
        $secure = Read-Host -AsSecureString 'Aurora password'
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    throw "password_source '$source' is not env:NAME, file:PATH, or prompt."
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [byte[]]$StdinBytes,
        [string]$StdinFile,
        [string]$StdoutFile
    )
    $quoted = @()
    foreach ($a in $ArgumentList) { $quoted += (ConvertTo-WindowsArgument $a) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    if (-not $proc.Start()) { throw "Failed to start $FilePath" }
    $outTarget = $null
    $outMemory = $null
    try {
        if ([string]::IsNullOrEmpty($StdoutFile)) {
            $outMemory = New-Object System.IO.MemoryStream
            $outTarget = $outMemory
        } else {
            $parent = Split-Path -Parent $StdoutFile
            if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $outTarget = [System.IO.File]::Create($StdoutFile)
        }
        $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outTarget)
        $errMemory = New-Object System.IO.MemoryStream
        $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errMemory)
        if (-not [string]::IsNullOrEmpty($StdinFile)) {
            $inFs = [System.IO.File]::OpenRead($StdinFile)
            try { $inFs.CopyTo($proc.StandardInput.BaseStream) } finally { $inFs.Dispose() }
        } elseif ($StdinBytes -and $StdinBytes.Length -gt 0) {
            $proc.StandardInput.BaseStream.Write($StdinBytes, 0, $StdinBytes.Length)
        }
        $proc.StandardInput.Close()
        if (-not $proc.WaitForExit(1000 * 60 * 60 * 6)) {
            try { $proc.Kill() } catch { }
            throw "Process timed out: $FilePath"
        }
        $outCopy.Wait()
        $errCopy.Wait()
        $proc.WaitForExit()
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $stderr = $utf8.GetString($errMemory.ToArray())
        $stdout = ''
        if ($null -ne $outMemory) { $stdout = $utf8.GetString($outMemory.ToArray()) }
        return @{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    } finally {
        if ($null -ne $outTarget) { $outTarget.Dispose() }
        $proc.Dispose()
    }
}

function Invoke-MysqlText {
    param(
        [Parameter(Mandatory=$true)][string]$MysqlExe,
        [Parameter(Mandatory=$true)][string]$DefaultsFile,
        [string]$Database,
        [string]$Sql,
        [string]$StdoutFile,
        [string]$StdinFile,
        [switch]$Quick,
        [switch]$LocalInfile
    )
    $args = @("--defaults-extra-file=$DefaultsFile", '--batch', '--raw', '--default-character-set=utf8mb4', '--protocol=tcp')
    if ($Quick) { $args += '--quick' }
    if ($LocalInfile) { $args += '--local-infile=1' }
    if (-not [string]::IsNullOrEmpty($Database)) { $args += $Database }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $stdinBytes = $null
    if ([string]::IsNullOrEmpty($StdinFile)) { $stdinBytes = $utf8.GetBytes([string]$Sql) }
    $result = Invoke-NativeProcess -FilePath $MysqlExe -ArgumentList $args -StdinBytes $stdinBytes -StdinFile $StdinFile -StdoutFile $StdoutFile
    if ($result.ExitCode -ne 0) {
        $detail = $result.Stderr.Trim()
        if ([string]::IsNullOrEmpty($detail)) { $detail = $result.Stdout.Trim() }
        throw "mysql exited with code $($result.ExitCode): $detail"
    }
    return $result
}

function Get-DumpArguments {
    param([hashtable]$Plan, [string]$DefaultsFile, [string]$ResultFile)
    $job = $Plan.Job
    $dumpArgList = @(
        "--defaults-extra-file=$DefaultsFile",
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
        '--events'
    )
    if ([string]$job['dump_routines'] -ne 'YES') { $dumpArgList = @($dumpArgList | Where-Object { $_ -ne '--routines' }) }
    if ([string]$job['dump_triggers'] -ne 'YES') { $dumpArgList = @($dumpArgList | Where-Object { $_ -ne '--triggers' }) }
    if ([string]$job['dump_events'] -ne 'YES') { $dumpArgList = @($dumpArgList | Where-Object { $_ -ne '--events' }) }
    if ([string]$job['dump_scope'] -eq 'tables') {
        $dumpArgList += [string]$Plan.Connection['database']
        foreach ($t in (Get-IncludedTables $Plan)) { $dumpArgList += [string]$t['name'] }
    } else {
        $dumpArgList += '--databases'
        $dumpArgList += [string]$Plan.Connection['database']
    }
    $dumpArgList += "--result-file=$ResultFile"
    return ,$dumpArgList
}
