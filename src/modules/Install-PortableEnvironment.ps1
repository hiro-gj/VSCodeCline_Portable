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
    $settings = $null
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $raw = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $settings = $raw | ConvertFrom-Json
            }
            catch {
                $corruptBackup = $settingsPath + '.corrupt.' + (Get-Date -Format 'yyyyMMddHHmmss') + '.bak'
                [IO.File]::Copy($settingsPath, $corruptBackup, $true)
                Write-Warning "破損した cline_mcp_settings.json を退避し再生成します: $corruptBackup"
                $settings = $null
            }
        }
    }
    if ($null -eq $settings -or $settings -isnot [psobject]) {
        $settings = [pscustomobject]@{}
    }
    if (-not $settings.PSObject.Properties['mcpServers'] -or $null -eq $settings.mcpServers) {
        Set-PortableProperty $settings 'mcpServers' ([pscustomobject]@{})
    }
    $server = if ($settings.mcpServers.PSObject.Properties['playwright']) { $settings.mcpServers.playwright } else { $null }
    if ($null -eq $server) {
        $server = [pscustomobject]@{ disabled = $false; timeout = 60 }
    }
    Set-PortableProperty $server 'type' 'stdio'
    Set-PortableProperty $server 'command' ([string]$code)
    Set-PortableProperty $server 'args' @([string](Join-Path $mcpRoot 'start-mcp.js'))
    Set-PortableProperty $server 'cwd' ([string]$mcpRoot)
    $paths = Get-PortableIsolationPaths
    if (-not $server.PSObject.Properties['env'] -or $null -eq $server.env) {
        Set-PortableProperty $server 'env' ([pscustomobject]@{})
    }
    if ($server.env.PSObject.Properties['PLAYWRIGHT_BROWSERS_PATH']) {
        $server.env.PSObject.Properties.Remove('PLAYWRIGHT_BROWSERS_PATH')
    }
    Set-PortableProperty $server.env 'ELECTRON_RUN_AS_NODE'             '1'
    Set-PortableProperty $server.env 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD' '1'
    Set-PortableProperty $server.env 'USERPROFILE'                      ([string]$paths.Home)
    Set-PortableProperty $server.env 'HOME'                     ([string]$paths.Home)
    if ($paths.Home -match '^([A-Za-z]:)(\\.*)$') {
        Set-PortableProperty $server.env 'HOMEDRIVE' $Matches[1]
        Set-PortableProperty $server.env 'HOMEPATH'  $Matches[2]
    }
    else {
        if ($server.env.PSObject.Properties['HOMEDRIVE']) { $server.env.PSObject.Properties.Remove('HOMEDRIVE') }
        if ($server.env.PSObject.Properties['HOMEPATH'])  { $server.env.PSObject.Properties.Remove('HOMEPATH') }
    }
    Set-PortableProperty $server.env 'APPDATA'         ([string]$paths.AppDataRoaming)
    Set-PortableProperty $server.env 'LOCALAPPDATA'    ([string]$paths.AppDataLocal)
    Set-PortableProperty $server.env 'XDG_CONFIG_HOME' ([string]$paths.XdgConfigHome)
    Set-PortableProperty $server.env 'XDG_DATA_HOME'   ([string]$paths.XdgDataHome)
    Set-PortableProperty $server.env 'XDG_STATE_HOME'  ([string]$paths.XdgStateHome)
    Set-PortableProperty $server.env 'XDG_CACHE_HOME'  ([string]$paths.XdgCacheHome)
    Set-PortableProperty $server.env 'TEMP'            ([string]$paths.TmpDir)
    Set-PortableProperty $server.env 'TMP'             ([string]$paths.TmpDir)
    Set-PortableProperty $server.env 'TMPDIR'          ([string]$paths.TmpDir)
    foreach ($prop in @($server.env.PSObject.Properties)) {
        if ($null -eq $prop.Value) {
            $server.env.PSObject.Properties.Remove($prop.Name)
        }
        elseif ($prop.Value -isnot [string]) {
            $prop.Value = [string]$prop.Value
        }
    }
    Set-PortableProperty $settings.mcpServers 'playwright' $server
    Write-PortableJson $settingsPath $settings
}

function Invoke-PortableNode([string[]]$NodeArgs, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $root, [switch]$CaptureOutput) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $code
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.Arguments = (@($NodeArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $nodeEnv = @{ ELECTRON_RUN_AS_NODE = '1' }
    foreach ($key in $Environment.Keys) { $nodeEnv[$key] = $Environment[$key] }
    Set-PortableChildEnvironment -Info $info -ExtraEnvironment $nodeEnv
    $process = [Diagnostics.Process]::Start($info)
    try {
        $output = Wait-PortableProcess -Process $process -Activity 'ポータブル Node / MCP を処理しています' -PassThruStandardOutput:$CaptureOutput
        if ($process.ExitCode -ne 0) { throw "Portable Node command failed (exit $($process.ExitCode)): $($NodeArgs -join ' ')" }
        if ($CaptureOutput) { return $output }
    }
    finally { $process.Dispose() }
}

function Ensure-PortableBootstrapNpm {
    $npmRoot = Join-Path $data 'tmp\portable-npm'
    $npmCli = Join-Path $npmRoot 'package\bin\npm-cli.js'
    if (-not (Test-Path -LiteralPath $npmCli -PathType Leaf)) {
        Initialize-NetworkConfig
        $npm = Invoke-RestMethod -Uri 'https://registry.npmjs.org/npm/10.9.2' -Headers @{ 'User-Agent' = 'VSCode-Portable-Launcher/1.0' } -TimeoutSec 30
        $archive = Join-Path $data 'tmp\npm-10.9.2.tgz'
        Save-UrlToFile $npm.dist.tarball $archive '導入用 npm をダウンロードしています'
        $hash = [Security.Cryptography.SHA512]::Create()
        $stream = [IO.File]::OpenRead($archive)
        try { $integrity = 'sha512-' + [Convert]::ToBase64String($hash.ComputeHash($stream)) }
        finally { $stream.Dispose(); $hash.Dispose() }
        if ($integrity -cne $npm.dist.integrity) { throw 'npm package integrity check failed.' }
        [void][IO.Directory]::CreateDirectory($npmRoot)
        $tarOut = & tar.exe -xzf $archive -C $npmRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            $tarMsg = ($tarOut | ForEach-Object { [string]$_ }) -join ' '
            throw "npm package extraction failed: $tarMsg"
        }
    }
    return $npmCli
}

function Sync-PortableMcpScripts([string]$McpRoot) {
    [void][IO.Directory]::CreateDirectory($McpRoot)
    $mcpSourceDir = if ($modulesRoot) { $modulesRoot } else { Join-Path $sourceRoot 'modules' }
    foreach ($name in @('start-mcp.js', 'verify-mcp.js')) {
        $content = [IO.File]::ReadAllText((Join-Path $mcpSourceDir $name), [Text.Encoding]::UTF8)
        $target = Join-Path $McpRoot $name
        if (-not (Test-Path -LiteralPath $target) -or [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8) -cne $content) {
            [IO.File]::WriteAllText($target, $content, (New-Object Text.UTF8Encoding($false)))
        }
    }
}

function Remove-LegacyPortableBrowsers([string]$BrowserPath) {
    if (-not (Test-Path -LiteralPath $BrowserPath -PathType Container)) { return }
    $marker = Join-Path $BrowserPath 'portable-install.json'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $BrowserPath -Recurse -Force -ErrorAction Stop
            Write-Host "[整理] 旧ポータブル Chromium フォルダを削除しました: $BrowserPath"
        }
        catch {
            Write-Warning "旧ポータブル Chromium フォルダの削除をスキップしました: $BrowserPath ($($_.Exception.Message))"
        }
    }
}

function Install-PortablePlaywrightMcp([string]$TargetVersion = '', [string]$LocalTarball = '', [switch]$Force, [switch]$VerifyAfterSwap) {
    $mcpRoot = Join-Path $cline 'mcp\playwright'
    Sync-PortableMcpScripts $mcpRoot
    $mcpCli = Join-Path $mcpRoot 'node_modules\@playwright\mcp\cli.js'
    $mcpMarker = Join-Path $mcpRoot 'portable-package.json'
    if (-not $Force -and [string]::IsNullOrWhiteSpace($LocalTarball) -and (Test-Path -LiteralPath $mcpCli -PathType Leaf) -and (Test-Path -LiteralPath $mcpMarker -PathType Leaf)) {
        return $false
    }

    $installSpec = ''
    $depSpec = ''
    if (-not [string]::IsNullOrWhiteSpace($LocalTarball)) {
        if (-not (Test-Path -LiteralPath $LocalTarball -PathType Leaf)) {
            throw "指定された MCP パッケージ (.tgz) が見つかりません: $LocalTarball"
        }
        $installSpec = [IO.Path]::GetFullPath($LocalTarball)
        $depSpec = '*'
        Write-Host "[Setup] ローカルパッケージから Playwright MCP を導入／更新しています: $(Split-Path -Leaf $installSpec)"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
            $latestRel = Get-LatestPlaywrightMcpRelease
            $TargetVersion = $latestRel.Version
        }
        if ($TargetVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
            throw "Playwright MCP バージョン形式が不正です: $TargetVersion"
        }
        $installSpec = "@playwright/mcp@$TargetVersion"
        $depSpec = $TargetVersion
        Write-Host "[Setup] Installing Playwright MCP ($TargetVersion) with the VS Code Node runtime..."
    }

    $npmCli = Ensure-PortableBootstrapNpm
    $stageDir = Join-Path $data ('tmp\mcp-stage-' + [guid]::NewGuid().ToString('N'))
    $backupDir = Join-Path $data ('tmp\mcp-backup-' + [guid]::NewGuid().ToString('N'))
    $browserPath = Join-Path $mcpRoot 'browsers'
    $swapNames = @('node_modules', 'package.json', 'package-lock.json', 'portable-package.json')
    try {
        [void][IO.Directory]::CreateDirectory($stageDir)
        Write-PortableJson (Join-Path $stageDir 'package.json') @{
            name = 'portable-playwright-mcp'; private = $true; dependencies = @{ '@playwright/mcp' = $depSpec }
        }
        Invoke-PortableNode -NodeArgs @($npmCli, 'install', $installSpec, '--prefix', $stageDir, '--cache', (Join-Path $data 'tmp\npm-cache'), '--no-audit', '--no-fund', '--no-update-notifier', '--ignore-scripts', '--bin-links=false') -Environment @{ PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1' } -WorkingDirectory $stageDir
        $stagedCli = Join-Path $stageDir 'node_modules\@playwright\mcp\cli.js'
        if (-not (Test-Path -LiteralPath $stagedCli -PathType Leaf)) {
            throw 'Playwright MCP の展開検証に失敗しました (cli.js が見つかりません)。'
        }
        $stagedPkg = [IO.File]::ReadAllText((Join-Path $stageDir 'node_modules\@playwright\mcp\package.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $installedVer = [string]$stagedPkg.version

        [void][IO.Directory]::CreateDirectory($backupDir)
        $movedBackups = New-Object 'Collections.Generic.List[string]'
        $placedItems = New-Object 'Collections.Generic.List[string]'
        try {
            foreach ($itemName in $swapNames) {
                $livePath = Join-Path $mcpRoot $itemName
                if (Test-Path -LiteralPath $livePath) {
                    Move-UpdateItem -Source $livePath -Destination (Join-Path $backupDir $itemName)
                    $movedBackups.Add($itemName)
                }
            }
            foreach ($itemName in @('node_modules', 'package.json', 'package-lock.json')) {
                $stgPath = Join-Path $stageDir $itemName
                if (Test-Path -LiteralPath $stgPath) {
                    $placedItems.Add($itemName)
                    Move-UpdateItem -Source $stgPath -Destination (Join-Path $mcpRoot $itemName)
                }
            }
            $placedItems.Add('portable-package.json')
            Write-PortableJson $mcpMarker @{ version = $installedVer }
            Initialize-Portable
            if ($VerifyAfterSwap) {
                Invoke-PortableNode @((Join-Path $mcpRoot 'verify-mcp.js'))
            }
        }
        catch {
            foreach ($itemName in $placedItems) {
                $livePath = Join-Path $mcpRoot $itemName
                if (Test-Path -LiteralPath $livePath) {
                    Remove-Item -LiteralPath $livePath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            foreach ($itemName in $movedBackups) {
                $bakPath = Join-Path $backupDir $itemName
                if (Test-Path -LiteralPath $bakPath) {
                    try { Move-UpdateItem -Source $bakPath -Destination (Join-Path $mcpRoot $itemName) } catch {}
                }
            }
            throw
        }
        Remove-LegacyPortableBrowsers -BrowserPath $browserPath
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $stageDir)  { Remove-Item -LiteralPath $stageDir  -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Update-McpOnline([object]$PrefetchedRelease) {
    $curVer = Get-InstalledPlaywrightMcpVersion
    $rel = if ($PrefetchedRelease) { $PrefetchedRelease } else {
        Write-Host 'npm レジストリへ Playwright MCP の最新バージョンを確認しています...'
        Get-LatestPlaywrightMcpRelease
    }
    $curLabel = if ($curVer) { $curVer } else { '未インストール' }
    Write-Host "  Playwright MCP : 現在 $curLabel -> 最新 $($rel.Version)"
    if (-not $curVer) {
        if (-not (Confirm-Action "Playwright MCP ($($rel.Version)) をインストールしますか？")) { return $false }
    }
    elseif ((Compare-VersionString $curVer $rel.Version) -ge 0) {
        Write-Host '  -> Playwright MCP は既に最新バージョンです。' -ForegroundColor Green
        if (-not (Confirm-Action 'Playwright MCP を強制再インストール／再検証しますか？')) { return $false }
    }
    else {
        if (-not (Confirm-Action "Playwright MCP を $curVer から $($rel.Version) へアップデートしますか？")) { return $false }
    }
    if (-not (Wait-PortableCodeClosed -Required $false)) {
        Write-Host '[中止] Playwright MCP の更新をキャンセルしました。'
        return $false
    }
    [void](Install-PortablePlaywrightMcp -TargetVersion $rel.Version -Force -VerifyAfterSwap)
    $afterVer = Get-InstalledPlaywrightMcpVersion
    Write-Host "[完了] Playwright MCP バージョン: $afterVer （ローカル Microsoft Edge 連携・動作確認済み）" -ForegroundColor Green
    return $true
}

function Install-PortableEnvironment {
    $script:PortableStageActive = $true
    try {
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
        [void](Install-PortablePlaywrightMcp)
        Write-PortableStage 6 'ローカル Microsoft Edge を確認しています'
        $edgeExe = Get-LocalEdgeExecutablePath
        if (-not $edgeExe) {
            throw 'ローカル PC に Microsoft Edge (msedge.exe) が見つかりません。Microsoft Edge をインストールしてから再実行してください。'
        }
        Remove-LegacyPortableBrowsers -BrowserPath (Join-Path $mcpRoot 'browsers')
        Initialize-Portable
        Write-PortableStage 7 'ブラウザーと MCP の動作を確認しています'
        Invoke-PortableNode @((Join-Path $mcpRoot 'verify-mcp.js'))
    }
    finally {
        Complete-PortableStage
    }
    Write-Host "[Ready] Portable VS Code / Japanese / Git / Cline / Playwright MCP: $root" -ForegroundColor Green
}