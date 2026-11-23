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
    $paths = Get-PortableIsolationPaths
    if (-not $server.env) { $server | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force }
    Set-PortableProperty $server.env 'ELECTRON_RUN_AS_NODE' '1'
    Set-PortableProperty $server.env 'USERPROFILE'          $paths.Home
    Set-PortableProperty $server.env 'HOME'                 $paths.Home
    Set-PortableProperty $server.env 'APPDATA'              $paths.AppDataRoaming
    Set-PortableProperty $server.env 'LOCALAPPDATA'         $paths.AppDataLocal
    Set-PortableProperty $server.env 'TEMP'                 $paths.TmpDir
    Set-PortableProperty $server.env 'TMP'                  $paths.TmpDir
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
    $nodeEnv = @{ ELECTRON_RUN_AS_NODE = '1' }
    foreach ($key in $Environment.Keys) { $nodeEnv[$key] = $Environment[$key] }
    Set-PortableChildEnvironment -Info $info -ExtraEnvironment $nodeEnv
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = if ($CaptureOutput) { $process.StandardOutput.ReadToEnd() }
        Wait-PortableProcess $process 'ポータブル Node / MCP を処理しています'
        if ($process.ExitCode -ne 0) { throw "Portable Node command failed (exit $($process.ExitCode)): $($NodeArgs -join ' ')" }
        if ($CaptureOutput) { return $output }
    }
    finally { $process.Dispose() }
}

function Install-PortableEnvironment {
    Write-PortableStage 1 'フォルダと初期設定を確認しています'
    Initialize-Portable
    Write-PortableStage 2 'VS Code 本体を確認しています'
    if (-not (Test-Path -LiteralPath $code -PathType Leaf)) {
        Write-Host '[Setup] Installing VS Code ZIP edition...'
        $current = Get-VSCodeMetadata $root
        $release = Get-LatestVSCodeRelease $current
        $zip = Save-VSCodeReleasePackage $current $release
        if (-not (Install-VSCodeFromZip $zip $release.Sha256)) { throw 'VS Code installation was cancelled.' }
    }
    Write-PortableStage 3 '日本語パックと Cline を確認しています'
    foreach ($id in @('MS-CEINTL.vscode-language-pack-ja', $clineExtensionId)) {
        if (-not (Get-InstalledExtensionVersion $id)) {
            Write-Host "[Setup] Installing $id ..."
            Invoke-PortableCodeCli @('--install-extension', $id)
            if (-not (Get-InstalledExtensionVersion $id)) { throw "Extension verification failed: $id" }
        }
    }
    Set-PortableJapanese
    $argvPath = Join-Path $data 'argv.json'
    # VS Code writes JSON with comments here. Preserve existing user choices.
    if (-not (Test-Path -LiteralPath $argvPath)) {
        Write-PortableJson $argvPath ([ordered]@{ locale = 'ja'; 'enable-crash-reporter' = $false; 'crash-reporter-id' = [guid]::NewGuid().ToString() })
    }

    Write-PortableStage 4 'ポータブル Git を確認しています'
    Install-PortableGit
    Write-PortableStage 5 'Playwright MCP を確認しています'
    $mcpRoot = Join-Path $cline 'mcp\playwright'
    [void][IO.Directory]::CreateDirectory($mcpRoot)
    $mcpSourceDir = if ($modulesRoot) { $modulesRoot } else { Join-Path $sourceRoot 'modules' }
    foreach ($name in @('start-mcp.js', 'verify-mcp.js')) {
        $content = [IO.File]::ReadAllText((Join-Path $mcpSourceDir $name), [Text.Encoding]::UTF8)
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
    Write-PortableStage 6 'ポータブル Chromium を確認しています'
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
    Write-PortableStage 7 'ブラウザーと MCP の動作を確認しています'
    try { Invoke-PortableNode @((Join-Path $mcpRoot 'verify-mcp.js')) }
    finally { Write-Progress -Id 10 -Activity 'ポータブル環境の準備' -Completed }
    Write-Host "[Ready] Portable VS Code / Japanese / Git / Cline / Playwright MCP: $root" -ForegroundColor Green
}