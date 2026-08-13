<#
.SYNOPSIS
    Load generator that runs scripts in a parallel sliding window.

.DESCRIPTION
    Launches multiple concurrent instances of scripts using PowerShell background jobs.
    Supports Python (.py), PowerShell (.ps1), and SQL Server (.sql) scripts.

    ScriptPath can be a single file or a folder. In folder mode, each slot pick a script
    at random from all matching files on every launch.

    Stops when -Count executions have been launched, when -Duration minutes have elapsed,
    or both - whichever comes first. At least one must be provided.

    When -Count is reached, any in-flight jobs are allowed to complete.
    When -Duration is reached, in-flight jobs are stopped immediately.

    SQL Server connections are configured via a JSON config file with named profiles,
    supporting both Windows Authentication and SQL Server Authentication.

.PARAMETER Language
    The language/runtime to use. Accepted values: 'python', 'powershell', 'sqlserver'.

.PARAMETER ScriptPath
    Path to a script file or a folder containing scripts. In folder mode the tool picks
    randomly from all files with the matching extension on each launch.

.PARAMETER Count
    Total number of script executions to launch. At least one of -Count or -Duration
    must be provided. When count is reached, in-flight jobs are allowed to complete.

.PARAMETER Duration
    How long to run in minutes. Accepts decimals (e.g. 1.5 = 90 seconds). At least one
    of -Count or -Duration must be provided. When duration is reached, in-flight jobs
    are stopped immediately.

.PARAMETER MaxConcurrent
    Maximum number of instances running at one time. Required when using -Duration
    without -Count. Defaults to -Count when only -Count is provided.
    Must be between 1 and 100.

.PARAMETER Delay
    Seconds to wait between launching each job. Accepts decimals (e.g. 0.5).
    Defaults to 0.

.PARAMETER SqlProfile
    Named SQL Server connection profile from the config file. Required when Language
    is 'sqlserver'.

.PARAMETER ConfigPath
    Path to the JSON config file containing SQL Server connection profiles.
    Defaults to 'run-parallel-config.json' in the same directory as this script.
    Only used when Language is 'sqlserver'.

.EXAMPLE
    .\Run-Parallel.ps1 -Language python -ScriptPath "C:\Queries\run_queries.py" -Count 20 -MaxConcurrent 5

    Runs run_queries.py 20 times with 5 instances at a time, waiting for in-flight jobs to complete.

.EXAMPLE
    .\Run-Parallel.ps1 -Language sqlserver -ScriptPath "C:\Queries" -Duration 10 -MaxConcurrent 5 -SqlProfile dev

    Randomly picks .sql scripts from C:\Queries and runs them for 10 minutes, 5 at a time.
    In-flight jobs are stopped when the 10-minute limit is reached.

.EXAMPLE
    .\Run-Parallel.ps1 -Language sqlserver -ScriptPath "C:\Queries" -Count 100 -Duration 5 -MaxConcurrent 10 -SqlProfile prod

    Runs up to 100 scripts for up to 5 minutes - stops at whichever limit is hit first.

.NOTES
    SQL Server support requires either the SqlServer PowerShell module or sqlcmd.

      Install SqlServer module (recommended):
        Install-Module SqlServer -Scope CurrentUser

      Install sqlcmd (fallback):
        https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility

    If your execution policy blocks unsigned scripts, run:
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

    Keep your config file out of source control - add it to .gitignore.
#>

# The password passed to SQL jobs is already plain text in the config file.
# Wrapping it in SecureString internally would provide no additional security at the source,
# so we suppress the PSScriptAnalyzer rule rather than introduce false reassurance.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Password is read from a plain-text JSON config file. SecureString would provide no security benefit.'
)]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Runtime to use: 'python', 'powershell', or 'sqlserver'")]
    [ValidateSet("python", "powershell", "sqlserver")]
    [string]$Language,

    [Parameter(Mandatory = $true, HelpMessage = "Path to a script file or folder of scripts")]
    [ValidateScript({
        if (-not (Test-Path $_)) {
            throw "Path not found: '$_'"
        }
        return $true
    })]
    [string]$ScriptPath,

    [Parameter(HelpMessage = "Total executions to launch. At least one of -Count or -Duration must be provided")]
    [ValidateRange(1, 10000)]
    [int]$Count,

    [Parameter(HelpMessage = "How long to run in minutes (decimals allowed). At least one of -Count or -Duration must be provided")]
    [ValidateRange(0.1, 1440)]
    [double]$Duration,

    [Parameter(HelpMessage = "Maximum concurrent instances. Required when using -Duration without -Count")]
    [ValidateRange(1, 100)]
    [int]$MaxConcurrent,

    [Parameter(HelpMessage = "Seconds to wait between launching each job (default 0, decimals allowed)")]
    [ValidateRange(0, 3600)]
    [double]$Delay = 0,

    [Parameter(HelpMessage = "Named SQL Server connection profile. Required when Language is 'sqlserver'")]
    [string]$SqlProfile,

    [Parameter(HelpMessage = "Path to the JSON config file. Defaults to run-parallel-config.json next to this script")]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "run-parallel-config.json")
)

# ==============================
# Cross-parameter validation
# ==============================

$hasCount    = $PSBoundParameters.ContainsKey('Count')
$hasDuration = $PSBoundParameters.ContainsKey('Duration')

if (-not $hasCount -and -not $hasDuration) {
    Write-Error "At least one of -Count or -Duration must be provided."
    exit 1
}

# Resolve expected file extension for the language
$expectedExtensions = @{
    python     = ".py"
    powershell = ".ps1"
    sqlserver  = ".sql"
}
$expectedExtension = $expectedExtensions[$Language]

# Determine file vs folder mode and validate accordingly
$isFolder = Test-Path $ScriptPath -PathType Container

if ($isFolder) {
    $scriptFiles = @(Get-ChildItem -Path $ScriptPath -Filter "*$expectedExtension" -File)
    if ($scriptFiles.Count -eq 0) {
        Write-Error "No $Language scripts (*$expectedExtension) found in folder '$ScriptPath'."
        exit 1
    }
} else {
    if (-not (Test-Path $ScriptPath -PathType Leaf)) {
        Write-Error "Script file not found or path is a directory: '$ScriptPath'"
        exit 1
    }
    $actualExtension = [System.IO.Path]::GetExtension($ScriptPath).ToLower()
    if ($actualExtension -ne $expectedExtension) {
        Write-Error "Language '$Language' expects a '$expectedExtension' file but got '$actualExtension'. Check -Language and -ScriptPath are consistent."
        exit 1
    }
    $scriptFiles = $null
}

# Validate Python runtime is available
if ($Language -eq "python") {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Error "python not found on PATH. Ensure Python is installed and available in your PATH."
        exit 1
    }
}

# Resolve MaxConcurrent - required when duration-only, defaults to Count otherwise
if (-not $PSBoundParameters.ContainsKey('MaxConcurrent')) {
    if ($hasCount) {
        $MaxConcurrent = $Count
    } else {
        Write-Error "-MaxConcurrent is required when using -Duration without -Count."
        exit 1
    }
}

# Cap MaxConcurrent at Count when both are provided
if ($hasCount -and $MaxConcurrent -gt $Count) {
    Write-Warning "-MaxConcurrent ($MaxConcurrent) is greater than -Count ($Count). Capping at $Count."
    $MaxConcurrent = $Count
}

# Warn if SQL-only parameters are supplied for non-SQL languages
if ($Language -ne "sqlserver") {
    if ($SqlProfile) {
        Write-Warning "-SqlProfile is only used with -Language sqlserver and will be ignored."
    }
    if ($PSBoundParameters.ContainsKey("ConfigPath")) {
        Write-Warning "-ConfigPath is only used with -Language sqlserver and will be ignored."
    }
}

# ==============================
# SQL connection pre-flight
# ==============================

# How long to wait for the pre-flight connection before giving up.
$sqlConnectTimeoutSeconds = 15

function Get-SqlConnectionDiagnosis {
    <#
        Translates a raw SQL Server failure (error number and/or message text) into a
        plain-English cause and a concrete fix. Invoke-Sqlcmd gives us a structured error
        number; sqlcmd only gives text, so both are matched. Returns Cause = $null when
        nothing matches, letting the caller fall back to the raw message alone.
    #>
    param(
        [string]$Message,
        $Number
    )

    $cause = $null
    $hint  = $null

    if ($null -ne $Number) {
        switch ([int]$Number) {
            18456 {
                $cause = "SQL Server rejected the login - wrong username or password."
                $hint  = "Check 'username' and 'password' in profile '$SqlProfile'. Confirm the login exists on the server and is not disabled or locked out."
            }
            18452 {
                $cause = "The login is not associated with a trusted connection - the server is likely set to Windows-authentication-only."
                $hint  = "Either set 'auth' to 'windows' in profile '$SqlProfile', or enable Mixed Mode authentication on the server (and restart it)."
            }
            18470 {
                $cause = "The login exists but is disabled."
                $hint  = "Re-enable it: ALTER LOGIN [$($conn.username)] ENABLE;"
            }
            4060 {
                $cause = "Connected to the server, but the database could not be opened - it may not exist, be offline, or the login may have no access to it."
                $hint  = "Check the 'database' value in profile '$SqlProfile'. Confirm it is ONLINE and that the login is mapped to a user in it."
            }
            911 {
                $cause = "The requested database does not exist on this server."
                $hint  = "Check the 'database' value in profile '$SqlProfile' for typos, and that you are pointed at the right server."
            }
            4064 {
                $cause = "The login's default database is unavailable."
                $hint  = "Set an explicit, valid 'database' in profile '$SqlProfile', or fix the login's default database."
            }
            { $_ -in 40615, 40532 } {
                $cause = "Azure SQL refused the connection at the firewall - your client IP is not allowed."
                $hint  = "Add your current IP to the server's firewall rules in the Azure portal."
            }
            53 {
                $cause = "The server name could not be resolved or reached over the network."
                $hint  = "Check the 'server' value in profile '$SqlProfile'. Verify the host resolves (ping it), is powered on, and that TCP/IP is enabled in SQL Server Configuration Manager."
            }
            26 {
                $cause = "The named instance could not be located."
                $hint  = "Verify the instance name in 'server'. Named instances need the SQL Server Browser service running, and UDP 1434 open on the host."
            }
            { $_ -in 40, 10060, 10061 } {
                $cause = "The host was reached, but nothing accepted the connection - the SQL Server service for that instance is most likely stopped, or the port/instance name is wrong."
                $hint  = "Check the service is running (Get-Service 'MSSQL*'), that TCP/IP is enabled for the instance, and that inbound TCP is allowed through the firewall."
            }
            233 {
                $cause = "The server closed the connection immediately (no process on the other end of the pipe)."
                $hint  = "Often means the instance is not accepting TCP connections. Enable TCP/IP for the instance and restart the SQL Server service."
            }
            -2 {
                $cause = "The connection attempt timed out after $sqlConnectTimeoutSeconds seconds."
                $hint  = "The host may be unreachable, heavily loaded, or silently dropping packets at a firewall. Verify the server name and port."
            }
        }
    }

    if (-not $cause) {
        # Order matters: these run top-down and stop at the first match, so the most specific
        # patterns come first. A database-access failure also emits a generic "Login failed for
        # user" line, and sqlcmd prints both - checking the database cases first avoids
        # misreporting a missing database as bad credentials.
        switch -Regex ($Message) {
            'Cannot open user default database' {
                $cause = "The login's default database is unavailable."
                $hint  = "Set an explicit, valid 'database' in profile '$SqlProfile'."
                break
            }
            'Cannot open database' {
                $cause = "The server was reached and the login was accepted, but the database could not be opened - it may not exist, be offline, or the login may have no access to it."
                $hint  = "Check the 'database' value in profile '$SqlProfile' and that the login is mapped to a user in it."
                break
            }
            'not associated with a trusted SQL Server connection' {
                $cause = "The server is set to Windows-authentication-only, so the SQL login was refused."
                $hint  = "Set 'auth' to 'windows' in profile '$SqlProfile', or enable Mixed Mode authentication on the server."
                break
            }
            'certificate chain was issued by an authority that is not trusted|The target principal name is incorrect|SSL Provider|encryption.*certificate' {
                $cause = "The TLS handshake failed because the server's certificate is not trusted. Recent SqlServer module versions encrypt by default, so self-signed certificates are rejected unless you opt in."
                $hint  = "For a local or dev server, set 'trustServerCertificate' to true in profile '$SqlProfile'. For production, install a certificate the client trusts instead."
                break
            }
            'Login failed for user' {
                $cause = "SQL Server rejected the login - wrong username or password."
                $hint  = "Check 'username' and 'password' in profile '$SqlProfile'. Confirm the login exists on the server and is not disabled or locked out."
                break
            }
            'Error Locating Server/Instance Specified' {
                $cause = "The named instance could not be located."
                $hint  = "Verify the instance name in 'server'. Named instances need the SQL Server Browser service running and UDP 1434 open."
                break
            }
            'No such host is known|could not be resolved' {
                $cause = "The server name does not resolve in DNS."
                $hint  = "Check the 'server' value in profile '$SqlProfile' for typos, and that you are on a network that can resolve it (e.g. VPN connected)."
                break
            }
            'network-related or instance-specific error|server was not found or was not accessible|Named Pipes Provider' {
                $cause = "The server could not be reached - wrong name, not running, or blocked by a firewall."
                $hint  = "Verify 'server' in profile '$SqlProfile', that the SQL Server service is running, and that TCP/IP is enabled for the instance."
                break
            }
            'Timeout expired|timeout period elapsed|Connection Timeout Expired' {
                $cause = "The connection attempt timed out after $sqlConnectTimeoutSeconds seconds."
                $hint  = "The host may be unreachable, overloaded, or dropping packets at a firewall."
                break
            }
            'Access is denied|Access to the path' {
                $cause = "The operating system denied the connection attempt."
                $hint  = "If using Windows auth, confirm the account running this script has access to the server."
                break
            }
        }
    }

    return [pscustomobject]@{ Cause = $cause; Hint = $hint }
}

function Test-SqlConnection {
    <#
        Opens one real connection and runs 'SELECT 1', using the same execution method and
        credentials the load jobs will use, so a pass here means the jobs can connect too.
        Returns an object with Success, and on failure Cause/Hint/Raw for reporting.
    #>
    # Same reasoning as the script-level suppression: the password is already plain text in
    # the JSON config, so a SecureString parameter would add ceremony without adding security.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Password originates from a plain-text JSON config file.'
    )]
    param(
        [string]$Server,
        [string]$Database,
        [string]$AuthType,
        [string]$Username,
        [string]$Password,
        [bool]$TrustCertificate,
        [string]$Method,
        [int]$TimeoutSeconds
    )

    if ($Method -eq "Invoke-Sqlcmd") {
        try {
            Import-Module SqlServer -ErrorAction Stop
        } catch {
            return [pscustomobject]@{
                Success = $false
                Cause   = "The SqlServer module is installed but could not be loaded."
                Hint    = "Run 'Import-Module SqlServer' in a fresh session to see the load error, or reinstall with 'Install-Module SqlServer -Scope CurrentUser -Force'."
                Raw     = $_.Exception.Message
            }
        }

        $probe = @{
            ServerInstance    = $Server
            Database          = $Database
            Query             = "SELECT 1"
            ConnectionTimeout = $TimeoutSeconds
            ErrorAction       = "Stop"
        }
        if ($AuthType -eq "sql") {
            $probe.Username = $Username
            $probe.Password = $Password
        }
        if ($TrustCertificate) { $probe.TrustServerCertificate = $true }

        try {
            $null = Invoke-Sqlcmd @probe
            return [pscustomobject]@{ Success = $true }
        } catch {
            # Walk the exception chain for a SqlException-style error number. Duck-typed on
            # purpose: the module may surface either System.Data or Microsoft.Data SqlException.
            $number = $null
            $ex     = $_.Exception
            while ($null -ne $ex) {
                if ($null -ne $ex.PSObject.Properties['Number']) {
                    $number = $ex.Number
                    break
                }
                $ex = $ex.InnerException
            }

            $diagnosis = Get-SqlConnectionDiagnosis -Message $_.Exception.Message -Number $number
            return [pscustomobject]@{
                Success = $false
                Cause   = $diagnosis.Cause
                Hint    = $diagnosis.Hint
                Raw     = $_.Exception.Message
            }
        }
    }

    # sqlcmd fallback. -b returns a non-zero exit code on error, -l bounds the login wait.
    $sqlcmdArgs = @('-S', $Server, '-d', $Database, '-Q', 'SELECT 1', '-l', $TimeoutSeconds, '-b')
    if ($AuthType -eq "sql") {
        $sqlcmdArgs += @('-U', $Username, '-P', $Password)
    } else {
        $sqlcmdArgs += '-E'
    }
    if ($TrustCertificate) { $sqlcmdArgs += '-C' }

    $output = & sqlcmd @sqlcmdArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ Success = $true }
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = "sqlcmd exited with code $LASTEXITCODE but produced no output."
    }

    # sqlcmd reports errors as "Msg 18456, Level 14, State 1" - recover the number if present.
    $number = $null
    if ($text -match 'Msg\s+(\d+)') { $number = [int]$Matches[1] }

    $diagnosis = Get-SqlConnectionDiagnosis -Message $text -Number $number
    return [pscustomobject]@{
        Success = $false
        Cause   = $diagnosis.Cause
        Hint    = $diagnosis.Hint
        Raw     = $text
    }
}

# ==============================
# SQL Server setup
# ==============================

$sqlScriptBlock = $null

if ($Language -eq "sqlserver") {

    # Detect available SQL execution method
    $hasSqlModule = $null -ne (Get-Module -ListAvailable -Name SqlServer)
    $hasSqlCmd    = $null -ne (Get-Command sqlcmd -ErrorAction SilentlyContinue)

    if (-not $hasSqlModule -and -not $hasSqlCmd) {
        Write-Error @"
No SQL Server execution method found. Install one of the following:

  Invoke-Sqlcmd (recommended):
    Install-Module SqlServer -Scope CurrentUser

  sqlcmd (fallback):
    https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility
"@
        exit 1
    }

    $sqlMethod = if ($hasSqlModule) { "Invoke-Sqlcmd" } else { "sqlcmd" }
    Write-Host "SQL execution method: $sqlMethod" -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($SqlProfile)) {
        Write-Error "-SqlProfile is required when using -Language sqlserver."
        exit 1
    }

    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        Write-Error "Config file not found or path is a directory: '$ConfigPath'"
        exit 1
    }

    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Error "Failed to parse config file '$ConfigPath': $_"
        exit 1
    }

    if ($null -eq $config.profiles) {
        Write-Error "Config file '$ConfigPath' is missing a 'profiles' object."
        exit 1
    }

    if ($null -eq $config.profiles.$SqlProfile) {
        $available = ($config.profiles.PSObject.Properties.Name) -join ", "
        Write-Error "Profile '$SqlProfile' not found in config. Available profiles: $available"
        exit 1
    }

    $conn = $config.profiles.$SqlProfile

    foreach ($field in @("server", "database", "auth")) {
        if ([string]::IsNullOrWhiteSpace($conn.$field)) {
            Write-Error "Profile '$SqlProfile' is missing required field '$field' or its value is blank."
            exit 1
        }
    }

    $authType          = $conn.auth.Trim().ToLower()
    $trustCertificate  = $conn.trustServerCertificate -eq $true

    if ($null -ne $conn.port) {
        $portNum = $conn.port -as [int]
        if ($null -eq $portNum -or $portNum -lt 1 -or $portNum -gt 65535) {
            Write-Error "Profile '$SqlProfile' has an invalid port '$($conn.port)'. Must be an integer between 1 and 65535."
            exit 1
        }
        $serverString = "$($conn.server.Trim()),$portNum"

        # A named instance plus an explicit port is contradictory: the port wins and the
        # instance name is ignored, so you can silently reach a different instance.
        if ($conn.server -match '\\') {
            Write-Warning "Profile '$SqlProfile' sets both a named instance ('$($conn.server.Trim())') and a port ($portNum). The port takes precedence and the instance name is ignored - remove one of them to be sure which instance you reach."
        }
    } else {
        $serverString = $conn.server.Trim()
    }

    if ($authType -eq "sql") {
        if ([string]::IsNullOrWhiteSpace($conn.username) -or [string]::IsNullOrWhiteSpace($conn.password)) {
            Write-Error "Profile '$SqlProfile' uses SQL auth but is missing 'username' or 'password'."
            exit 1
        }
        if ($sqlMethod -eq "Invoke-Sqlcmd") {
            if ($trustCertificate) {
                $sqlScriptBlock = {
                    param($path, $server, $database, $username, $password)
                    Import-Module SqlServer
                    Invoke-Sqlcmd -ServerInstance $server -Database $database -Username $username -Password $password -InputFile $path -TrustServerCertificate -ErrorAction Stop
                }
            } else {
                $sqlScriptBlock = {
                    param($path, $server, $database, $username, $password)
                    Import-Module SqlServer
                    Invoke-Sqlcmd -ServerInstance $server -Database $database -Username $username -Password $password -InputFile $path -ErrorAction Stop
                }
            }
        } else {
            if ($trustCertificate) {
                $sqlScriptBlock = {
                    param($path, $server, $database, $username, $password)
                    # -b makes sqlcmd return a non-zero exit code on a T-SQL error; without the
                    # throw, a native exit code leaves the job State as Completed and the
                    # failure goes unreported.
                    sqlcmd -S $server -d $database -U $username -P $password -i "$path" -C -b
                    if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
                }
            } else {
                $sqlScriptBlock = {
                    param($path, $server, $database, $username, $password)
                    sqlcmd -S $server -d $database -U $username -P $password -i "$path" -b
                    if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
                }
            }
        }
    } elseif ($authType -eq "windows") {
        if ($sqlMethod -eq "Invoke-Sqlcmd") {
            if ($trustCertificate) {
                $sqlScriptBlock = {
                    param($path, $server, $database)
                    Import-Module SqlServer
                    Invoke-Sqlcmd -ServerInstance $server -Database $database -InputFile $path -TrustServerCertificate -ErrorAction Stop
                }
            } else {
                $sqlScriptBlock = {
                    param($path, $server, $database)
                    Import-Module SqlServer
                    Invoke-Sqlcmd -ServerInstance $server -Database $database -InputFile $path -ErrorAction Stop
                }
            }
        } else {
            if ($trustCertificate) {
                $sqlScriptBlock = {
                    param($path, $server, $database)
                    sqlcmd -S $server -d $database -E -i "$path" -C -b
                    if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
                }
            } else {
                $sqlScriptBlock = {
                    param($path, $server, $database)
                    sqlcmd -S $server -d $database -E -i "$path" -b
                    if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE" }
                }
            }
        }
    } else {
        Write-Error "Profile '$SqlProfile' has unknown auth type '$($conn.auth)'. Expected 'windows' or 'sql'."
        exit 1
    }

    # Prove the connection works before generating any load. Without this, a bad profile
    # produces one failed job per execution instead of a single actionable error.
    $authLabel = if ($authType -eq "sql") {
        "SQL auth as '$($conn.username)'"
    } else {
        "Windows auth as '$([Environment]::UserDomainName)\$([Environment]::UserName)'"
    }

    Write-Host "Testing connection to [$serverString] database [$($conn.database)] ($authLabel)..." -ForegroundColor Cyan

    $testArgs = @{
        Server           = $serverString
        Database         = $conn.database
        AuthType         = $authType
        TrustCertificate = $trustCertificate
        Method           = $sqlMethod
        TimeoutSeconds   = $sqlConnectTimeoutSeconds
    }
    if ($authType -eq "sql") {
        $testArgs.Username = $conn.username
        $testArgs.Password = $conn.password
    }

    $connectionTest = Test-SqlConnection @testArgs

    if (-not $connectionTest.Success) {
        $report = @(
            "Cannot connect to SQL Server. Aborting before any load was generated."
            ""
            "  Profile:  $SqlProfile (from $ConfigPath)"
            "  Server:   $serverString"
            "  Database: $($conn.database)"
            "  Auth:     $authLabel"
            "  Method:   $sqlMethod"
            ""
        )
        if ($connectionTest.Cause) {
            $report += "  Cause:    $($connectionTest.Cause)"
            if ($connectionTest.Hint) { $report += "  Fix:      $($connectionTest.Hint)" }
            $report += ""
        }
        $report += "  Reported by ${sqlMethod}:"
        $report += ($connectionTest.Raw -split "`r?`n" | ForEach-Object { "    $_" })

        Write-Error ($report -join "`n")
        exit 1
    }

    Write-Host "Connection OK." -ForegroundColor Green
}

# ==============================
# Job helpers
# ==============================

$runners = @{
    python     = { param($path) python $path }
    powershell = { param($path) & $path }
}

function Get-NextScriptPath {
    if ($script:scriptFiles) {
        return ($script:scriptFiles | Get-Random).FullName
    }
    return $script:ScriptPath
}

function Start-NextJob {
    $targetScript = Get-NextScriptPath
    switch ($Language) {
        "sqlserver" {
            if ($authType -eq "sql") {
                Start-Job -ScriptBlock $sqlScriptBlock -ArgumentList $targetScript, $serverString, $conn.database, $conn.username, $conn.password
            } else {
                Start-Job -ScriptBlock $sqlScriptBlock -ArgumentList $targetScript, $serverString, $conn.database
            }
        }
        default {
            Start-Job -ScriptBlock $runners[$Language] -ArgumentList $targetScript
        }
    }
}

function Receive-CompletedJobs {
    $done = @($activeJobs | Where-Object { $_.State -ne 'Running' })
    foreach ($job in $done) {
        # State alone is not enough: a non-terminating error inside the job leaves State as
        # Completed while still recording the error, so check the error stream too. Read it
        # before Receive-Job drains the job.
        $hadErrors = @($job.ChildJobs | Where-Object { $_.Error.Count -gt 0 }).Count -gt 0
        $output    = Receive-Job -Job $job 2>&1

        if ($job.State -eq "Failed" -or $hadErrors) {
            Write-Host "`n--- Job $($job.Id) [FAILED] ---" -ForegroundColor Red
            if ($output) { Write-Host $output }
            $script:failedCount++
        } else {
            $script:completedCount++
        }
        Remove-Job -Job $job
        [void]$activeJobs.Remove($job)
    }
}

function Test-DurationExceeded {
    return $hasDuration -and ((Get-Date) - $script:startTime).TotalSeconds -ge ($Duration * 60)
}

# ==============================
# Sliding window execution
# ==============================

$sourceDescription = if ($isFolder) {
    "$($scriptFiles.Count) script(s) randomly from '$ScriptPath'"
} else {
    "'$ScriptPath'"
}

$limitParts = @()
if ($hasCount)    { $limitParts += "$Count executions" }
if ($hasDuration) { $limitParts += "$Duration minute(s)" }

Write-Host "Starting: $Language | $sourceDescription | $MaxConcurrent concurrent | stopping after $($limitParts -join ' or ')." -ForegroundColor Cyan

$startTime      = Get-Date
$launched       = 0
$completedCount = 0
$failedCount    = 0
$killedCount    = 0
$activeJobs     = [System.Collections.Generic.List[object]]::new()

while ($true) {

    # Hard cutoff - duration check at the top of every iteration
    if (Test-DurationExceeded) { break }

    # Fill the pool
    while ($activeJobs.Count -lt $MaxConcurrent -and (-not $hasCount -or $launched -lt $Count) -and -not (Test-DurationExceeded)) {
        $launched++
        $job = Start-NextJob
        $activeJobs.Add($job)
        Write-Host "  Launched job $($job.Id) (run $launched$(if ($hasCount) { " of $Count" }))" -ForegroundColor Gray

        if ($Delay -gt 0 -and (-not $hasCount -or $launched -lt $Count)) {
            Start-Sleep -Seconds $Delay
        }
    }

    # Re-check duration after filling - a Delay sleep may have pushed us over
    if (Test-DurationExceeded) { break }

    # Count limit reached - wait for in-flight jobs to finish naturally
    if ($hasCount -and $launched -ge $Count) {
        if ($activeJobs.Count -gt 0) {
            Write-Host "`nAll $Count executions launched. Waiting for $($activeJobs.Count) in-flight job(s)..." -ForegroundColor Yellow
            $null = Wait-Job -Job $activeJobs
            Receive-CompletedJobs
        }
        break
    }

    # Wait for a slot to open - poll every 5 seconds so duration is checked regularly
    if ($activeJobs.Count -gt 0) {
        $null = Wait-Job -Job $activeJobs -Any -Timeout 5
        Receive-CompletedJobs
    }
}

# Duration expired - stop in-flight jobs immediately
if (Test-DurationExceeded -and $activeJobs.Count -gt 0) {
    $killedCount = $activeJobs.Count
    Write-Host "`nDuration limit reached. Stopping $killedCount in-flight job(s)..." -ForegroundColor Yellow
    $activeJobs | Stop-Job
    $activeJobs | Remove-Job -Force
    $activeJobs.Clear()
}

# ==============================
# Summary
# ==============================

$elapsed    = (Get-Date) - $startTime
$elapsedStr = if ($elapsed.TotalMinutes -ge 1) {
    "$([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"
} else {
    "$($elapsed.Seconds)s"
}

$summaryParts = @("$launched launched", "$completedCount completed", "$failedCount failed")
if ($killedCount -gt 0) { $summaryParts += "$killedCount stopped" }

$summaryColour = if ($failedCount -gt 0) { "Red" } else { "Cyan" }
Write-Host "`nFinished in $elapsedStr - $($summaryParts -join ', ')." -ForegroundColor $summaryColour

if ($failedCount -gt 0) { exit 1 }
