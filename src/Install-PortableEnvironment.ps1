# Portable bootstrap. Paths are derived by the launcher, never from a drive letter.
function Write-PortableJson([string]$Path, $Value) {
    $json = ($Value | ConvertTo-Json -Depth 50) + "`r`n"
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -ceq $json) { return }
    [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $Path))
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Set-PortableProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-PortableMcpSettings {
    $mcpRoot = Join-Path $cline 'mcp\playwright'
    if (-not (Test-Path -LiteralPath (Join-Path $mcpRoot 'start-mcp.js'))) { return }
    $settingsPath = Join-Path $cline 'data\settings\cline_mcp_settings.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) {
        [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    } else { [pscustomobject]@{} }
    if (-not $settings.mcpServers) {
        $settings | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $server = $settings.mcpServers.playwright
    if (-not $server) { $server = [pscustomobject]@{ disabled = $false; timeout = 60 } }
    Set-PortableProperty $server 'type' 'stdio'
    Set-PortableProperty $server 'command' $code
    Set-PortableProperty $server 'args' @((Join-Path $mcpRoot 'start-mcp.js'))
    if (-not $server.env) { $server | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force }
    Set-PortableProperty $server.env 'ELECTRON_RUN_AS_NODE' '1'
    Set-PortableProperty $settings.mcpServers 'playwright' $server
    Write-PortableJson $settingsPath $settings
}

function Invoke-PortableNode([string[]]$NodeArgs, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $root, [switch]$CaptureOutput) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $code
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $CaptureOutput.IsPresent
    $info.Arguments = (@($NodeArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -like 'VSCODE_*' -or $key -like 'CLINE_*') { $info.EnvironmentVariables.Remove($key) }
    }
    $info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $info.EnvironmentVariables['TEMP'] = Join-Path $data 'tmp'
    $info.EnvironmentVariables['TMP'] = Join-Path $data 'tmp'
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = $Environment[$key] }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = if ($CaptureOutput) { $process.StandardOutput.ReadToEnd() }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Portable Node command failed (exit $($process.ExitCode)): $($NodeArgs -join ' ')" }
        if ($CaptureOutput) { return $output }
    }
    finally { $process.Dispose() }
}

function Install-PortableEnvironment {
    Initialize-Portable
    if (-not (Test-Path -LiteralPath $code -PathType Leaf)) {
        Write-Host '[Setup] Installing VS Code ZIP edition...'
        $current = Get-VSCodeMetadata $root
        $release = Get-LatestVSCodeRelease $current
        $zip = Save-VSCodeReleasePackage $current $release
        if (-not (Install-VSCodeFromZip $zip $release.Sha256)) { throw 'VS Code installation was cancelled.' }
    }
    foreach ($id in @('MS-CEINTL.vscode-language-pack-ja', $clineExtensionId)) {
        if (-not (Get-InstalledExtensionVersion $id)) {
            Write-Host "[Setup] Installing $id ..."
            Invoke-PortableCodeCli @('--install-extension', $id)
            if (-not (Get-InstalledExtensionVersion $id)) { throw "Extension verification failed: $id" }
        }
    }
    $argvPath = Join-Path $data 'argv.json'
    # VS Code writes JSON with comments here. Preserve existing user choices.
    if (-not (Test-Path -LiteralPath $argvPath)) {
        Write-PortableJson $argvPath ([ordered]@{ locale = 'ja'; 'enable-crash-reporter' = $false; 'crash-reporter-id' = [guid]::NewGuid().ToString() })
    }

    $mcpRoot = Join-Path $cline 'mcp\playwright'
    [void][IO.Directory]::CreateDirectory($mcpRoot)
    foreach ($name in @('start-mcp.js', 'verify-mcp.js')) {
        $content = [IO.File]::ReadAllText((Join-Path $sourceRoot $name), [Text.Encoding]::UTF8)
        $target = Join-Path $mcpRoot $name
        if (-not (Test-Path -LiteralPath $target) -or [IO.File]::ReadAllText($target) -cne $content) {
            [IO.File]::WriteAllText($target, $content, (New-Object Text.UTF8Encoding($false)))
        }
    }
    $mcpCli = Join-Path $mcpRoot 'node_modules\@playwright\mcp\cli.js'
    $mcpMarker = Join-Path $mcpRoot 'portable-package.json'
    if (-not (Test-Path -LiteralPath $mcpCli) -or -not (Test-Path -LiteralPath $mcpMarker)) {
        Write-Host '[Setup] Installing Playwright MCP with the VS Code Node runtime...'
        $npmRoot = Join-Path $data 'tmp\portable-npm'
        $npmCli = Join-Path $npmRoot 'package\bin\npm-cli.js'
        if (-not (Test-Path -LiteralPath $npmCli)) {
            Initialize-NetworkConfig
            $npm = Invoke-RestMethod -Uri 'https://registry.npmjs.org/npm/10.9.2' -TimeoutSec 30
            $archive = Join-Path $data 'tmp\npm-10.9.2.tgz'
            Save-UrlToFile $npm.dist.tarball $archive 'Downloading bootstrap npm'
            $hash = [Security.Cryptography.SHA512]::Create()
            $stream = [IO.File]::OpenRead($archive)
            try { $integrity = 'sha512-' + [Convert]::ToBase64String($hash.ComputeHash($stream)) }
            finally { $stream.Dispose(); $hash.Dispose() }
            if ($integrity -cne $npm.dist.integrity) { throw 'npm package integrity check failed.' }
            [void][IO.Directory]::CreateDirectory($npmRoot)
            & tar.exe -xzf $archive -C $npmRoot
            if ($LASTEXITCODE -ne 0) { throw 'npm package extraction failed.' }
        }
        Write-PortableJson (Join-Path $mcpRoot 'package.json') @{
            name = 'portable-playwright-mcp'; private = $true; dependencies = @{ '@playwright/mcp' = '0.0.85' }
        }
        # An explicit package avoids npm treating Electron's prefix as a global
        # install of '.' (which would require unsupported exFAT symlinks).
        Invoke-PortableNode -NodeArgs @($npmCli, 'install', '@playwright/mcp@0.0.85', '--prefix', $mcpRoot, '--cache', (Join-Path $data 'tmp\npm-cache'), '--no-audit', '--no-fund', '--ignore-scripts', '--bin-links=false') -WorkingDirectory $mcpRoot
        Write-PortableJson $mcpMarker @{ version = '0.0.85' }
    }
    $browserPath = Join-Path $mcpRoot 'browsers'
    $browserMarker = Join-Path $browserPath 'portable-install.json'
    $playwrightPackage = [IO.File]::ReadAllText((Join-Path $mcpRoot 'node_modules\playwright\package.json')) | ConvertFrom-Json
    $installedBrowser = if (Test-Path -LiteralPath $browserMarker) { [IO.File]::ReadAllText($browserMarker) | ConvertFrom-Json } else { $null }
    if (-not $installedBrowser -or $installedBrowser.version -ne $playwrightPackage.version) {
        Write-Host '[Setup] Installing portable Chromium...'
        # Playwright's directory-lock heartbeat is unreliable on exFAT. Ask its
        # CLI for the official platform-specific downloads, then extract them
        # without that lock. The final smoke test checks the actual executables.
        $plan = Invoke-PortableNode -NodeArgs @((Join-Path $mcpRoot 'node_modules\playwright\cli.js'), 'install', '--dry-run', '--no-shell', 'chromium') -Environment @{ PLAYWRIGHT_BROWSERS_PATH = $browserPath } -CaptureOutput
        $downloads = [regex]::Matches($plan, '(?m)^  Install location:\s+([^\r\n]+)\r?\n  Download url:\s+(https://[^\r\n]+)')
        if ($downloads.Count -lt 1) { throw "Cannot parse Playwright browser download plan: $plan" }
        foreach ($download in $downloads) {
            $destination = $download.Groups[1].Value.Trim()
            $prefix = [IO.Path]::GetFullPath($browserPath).TrimEnd('\') + '\'
            if (-not [IO.Path]::GetFullPath($destination).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid browser destination.' }
            $complete = Join-Path $destination 'INSTALLATION_COMPLETE'
            if (Test-Path -LiteralPath $complete) { continue }
            $zip = Join-Path $data ('tmp\' + (Split-Path -Leaf $destination) + '.zip')
            Save-UrlToFile $download.Groups[2].Value.Trim() $zip 'Downloading portable browser component'
            Expand-ZipArchiveFast $zip $destination
            [IO.File]::WriteAllText($complete, '')
        }
        Write-PortableJson $browserMarker @{ version = $playwrightPackage.version }
    }
    Initialize-Portable
    Invoke-PortableNode @((Join-Path $mcpRoot 'verify-mcp.js'))
    Write-Host "[Ready] Portable VS Code / Japanese / Cline / Playwright MCP: $root" -ForegroundColor Green
}