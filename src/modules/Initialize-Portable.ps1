# ============================================================
# Initialize-Portable.ps1
# メインメニュー [3] ポータブル用フォルダ・初期設定の作成／修復
# メインメニュー [4] ポータブルデータフォルダ (data) を開く
# ============================================================

function Find-ClineMcpHardLinkPatchTarget([string]$Source) {
    $unpatchedRx = '(?<dest>[A-Za-z_$][0-9A-Za-z_$]*)\s*=\s*(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*\.join\)?\(\s*[A-Za-z_$][0-9A-Za-z_$]*\s*,\s*(?:[A-Za-z_$][0-9A-Za-z_$.]*\.mcpSettings|["'']cline_mcp_settings\.json["''])\s*\)(?:\s*,\s*|\s*;\s*(?:let|const|var)\s+)(?<tmp>[A-Za-z_$][0-9A-Za-z_$]*)\s*=\s*`[^`\r\n]{1,220}`\s*;\s*try\s*\{\s*await\s+(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*\.writeFile\)?\(\s*\k<tmp>\s*,[^;\r\n]{1,260}?flag\s*:\s*["'']wx["''][^;\r\n]{0,80}?\)\s*(?:,|;)\s*await\s+(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*(?<call>\.link(?<closeParen>\)?)\(\s*\k<tmp>\s*,\s*\k<dest>\s*\))\s*(?:;|\s)*\}\s*catch\s*\(\s*(?<err>[A-Za-z_$][0-9A-Za-z_$]*)\s*\)\s*\{\s*if\s*\(\s*\k<err>\.code\s*!==\s*["'']EEXIST["'']\s*\)\s*throw\s+\k<err>'
    $patchedRx   = '(?<dest>[A-Za-z_$][0-9A-Za-z_$]*)\s*=\s*(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*\.join\)?\(\s*[A-Za-z_$][0-9A-Za-z_$]*\s*,\s*(?:[A-Za-z_$][0-9A-Za-z_$.]*\.mcpSettings|["'']cline_mcp_settings\.json["''])\s*\)(?:\s*,\s*|\s*;\s*(?:let|const|var)\s+)(?<tmp>[A-Za-z_$][0-9A-Za-z_$]*)\s*=\s*`[^`\r\n]{1,220}`\s*;\s*try\s*\{\s*await\s+(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*\.writeFile\)?\(\s*\k<tmp>\s*,[^;\r\n]{1,260}?flag\s*:\s*["'']wx["''][^;\r\n]{0,80}?\)\s*(?:,|;)\s*await\s+(?:\(0,\s*)?[A-Za-z_$][0-9A-Za-z_$.]*\.copyFile\)?\(\s*\k<tmp>\s*,\s*\k<dest>\s*,\s*(?:1|[A-Za-z_$][0-9A-Za-z_$.]*COPYFILE_EXCL)\s*\)\s*(?:;|\s)*\}\s*catch\s*\('

    $unpatchedMap = @{}
    $patchedCount = 0
    $hasNearbyLink = $false

    foreach ($anchor in @('.mcpSettings', '"cline_mcp_settings.json"', "'cline_mcp_settings.json'")) {
        $pos = 0
        while (($idx = $Source.IndexOf($anchor, $pos, [StringComparison]::Ordinal)) -ge 0) {
            $pos = $idx + $anchor.Length
            $winStart = [Math]::Max(0, $idx - 160)
            $winLen   = [Math]::Min($Source.Length - $winStart, 760)
            $window   = $Source.Substring($winStart, $winLen)

            if ($window.IndexOf('.link(', [StringComparison]::Ordinal) -ge 0 -or
                $window.IndexOf('.link)(', [StringComparison]::Ordinal) -ge 0) {
                $hasNearbyLink = $true
            }
            if ([regex]::IsMatch($window, $patchedRx)) {
                $patchedCount++
            }
            foreach ($m in [regex]::Matches($window, $unpatchedRx)) {
                $callGroup = $m.Groups['call']
                $absIndex  = $winStart + $callGroup.Index
                if (-not $unpatchedMap.ContainsKey($absIndex)) {
                    $tmpName  = $m.Groups['tmp'].Value
                    $destName = $m.Groups['dest'].Value
                    $closeP   = $m.Groups['closeParen'].Value
                    $unpatchedMap[$absIndex] = [pscustomobject]@{
                        Index       = $absIndex
                        Length      = $callGroup.Length
                        Replacement = ('.copyFile' + $closeP + '(' + $tmpName + ',' + $destName + ',1)')
                    }
                }
            }
        }
    }

    if ($unpatchedMap.Count -eq 1) {
        $only = @($unpatchedMap.Values)[0]
        return [pscustomobject]@{
            Status      = 'NeedsPatch'
            Index       = $only.Index
            Length      = $only.Length
            Replacement = $only.Replacement
        }
    }
    if ($unpatchedMap.Count -eq 0 -and $patchedCount -ge 1) {
        return [pscustomobject]@{ Status = 'AlreadyPatched' }
    }
    if ($unpatchedMap.Count -eq 0 -and -not $hasNearbyLink) {
        return [pscustomobject]@{ Status = 'NotNeeded' }
    }
    return [pscustomobject]@{ Status = 'UnrecognizedLinkPattern' }
}

function Repair-ClineMcpExfat([switch]$Force) {
    # Cline initializes its MCP settings file via fs.link(tmp, target) on every read/watch.
    # Non-hardlink filesystems (exFAT, FAT32, etc.) reject link() with EISDIR/EPERM.
    # COPYFILE_EXCL (1) preserves the EEXIST/no-overwrite contract across all filesystems.
    $settingsDir = Join-Path $cline 'data\settings'
    if (-not $Force -and (Test-PortableHardLinkSupport $settingsDir)) { return }
    $extensions = Join-Path $data 'extensions'
    if (-not (Test-Path -LiteralPath $extensions -PathType Container)) { return }

    $patchedAny = $false
    foreach ($extension in (Get-ChildItem -LiteralPath $extensions -Directory -Filter 'saoudrizwan.claude-dev-*')) {
        $manifest = Join-Path $extension.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $package = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($package.publisher -cne 'saoudrizwan' -or $package.name -cne 'claude-dev') { continue }
        $ver = [string]$package.version
        if ($ver -notmatch '^[0-9]+(?:\.[0-9A-Za-z._-]+)*$') {
            Write-Warning "Cline 拡張のバージョン形式が不正なため互換修正をスキップしました: $($extension.FullName)"
            continue
        }
        $bundle = Join-Path $extension.FullName 'dist\extension.js'
        if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) { continue }

        $extBundle = ConvertTo-ExtendedPath $bundle
        $source = [IO.File]::ReadAllText($extBundle, [Text.Encoding]::UTF8)
        $targetPlan = Find-ClineMcpHardLinkPatchTarget $source
        if ($targetPlan.Status -eq 'AlreadyPatched' -or $targetPlan.Status -eq 'NotNeeded') {
            continue
        }
        if ($targetPlan.Status -ne 'NeedsPatch') {
            Write-Warning "Cline ${ver}: MCP 設定のハードリンク処理形式が未知のため互換修正を適用できませんでした（ファイル無改変）: $bundle"
            continue
        }

        $hash = Get-PortableFileSha256 $bundle
        $backupDir = Join-Path $cline ("compatibility\backups\saoudrizwan.claude-dev-$ver")
        $extBackupDir = ConvertTo-ExtendedPath $backupDir
        [void][IO.Directory]::CreateDirectory($extBackupDir)
        $backup = Join-Path $backupDir ("extension.$hash.js")
        $extBackup = ConvertTo-ExtendedPath $backup
        if (-not [IO.File]::Exists($extBackup)) {
            [IO.File]::Copy($extBundle, $extBackup, $false)
        }
        if ((Get-PortableFileSha256 $backup) -ine $hash) {
            throw "Cline exFAT fix: backup verification failed: $backup"
        }

        $patched = $source.Substring(0, $targetPlan.Index) + $targetPlan.Replacement + $source.Substring($targetPlan.Index + $targetPlan.Length)
        $verifyPlan = Find-ClineMcpHardLinkPatchTarget $patched
        if ($verifyPlan.Status -ne 'AlreadyPatched') {
            throw "Cline exFAT fix: post-patch structure verification failed for Cline $ver."
        }
        try {
            [IO.File]::WriteAllText($extBundle, $patched, (New-Object Text.UTF8Encoding($false)))
            if ([IO.File]::ReadAllText($extBundle, [Text.Encoding]::UTF8) -cne $patched) {
                throw 'Cline exFAT fix: verification of the patched extension failed.'
            }
        }
        catch {
            [IO.File]::Copy($extBackup, $extBundle, $true)
            throw
        }
        $patchedAny = $true
        Write-Host "[修正] Cline $ver のハードリンク非対応ファイルシステム向け MCP 設定読み込み互換処理を適用しました。"
        Write-Host "  バックアップ: $backup"
    }

    if ($patchedAny -and (Get-Command Get-RunningPortableProcesses -ErrorAction SilentlyContinue)) {
        $running = @(Get-RunningPortableProcesses $root)
        if ($running.Count -gt 0) {
            Write-Host '[注意] ポータブル版 VSCode が稼働中です。MCP 互換修正を反映するため、VSCode を再起動（またはウィンドウを再読み込み）してください。' -ForegroundColor Yellow
        }
    }
}

function Move-LegacyPortableClineDirectory {
    $legacyCline = Join-Path $data 'cline'
    if ($legacyCline -ieq $cline) { return }
    if ((Test-Path -LiteralPath $legacyCline -PathType Container) -and -not (Test-Path -LiteralPath $cline)) {
        [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $cline))
        [IO.Directory]::Move($legacyCline, $cline)
        Write-Host "[移行] 既存の Cline データを新パスへ移行しました: $cline"
    }
}

function Install-PortableClineRules {
    $modDir = if ($modulesRoot) { $modulesRoot } elseif ($sourceRoot) { Join-Path $sourceRoot 'modules' } else { $PSScriptRoot }
    $ruleName = 'playwright-mcp-snapshot.md'
    $templatePath = Join-Path $modDir $ruleName
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "必須の Cline ルールテンプレートが見つかりません: $templatePath"
    }
    $rulesDir = Join-Path $cline 'rules'
    [void][IO.Directory]::CreateDirectory($rulesDir)
    $targetRulePath = Join-Path $rulesDir $ruleName
    if (-not (Test-Path -LiteralPath $targetRulePath -PathType Leaf) -or (Get-Item -LiteralPath $targetRulePath).Length -eq 0) {
        $ruleContent = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($targetRulePath, $ruleContent, (New-Object Text.UTF8Encoding($false)))
    }
}

function Update-PortableVSCodeTerminalSettings {
    $paths = Get-PortableIsolationPaths
    $settingsPath = Join-Path $data 'user-data\User\settings.json'
    $settingsObj = [pscustomobject]@{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $parsed = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $parsed) { $settingsObj = $parsed }
        }
        catch {
            Write-Warning "settings.json の自動環境更新をスキップしました（手動編集形式を保持）: $settingsPath"
            return
        }
    } else {
        Set-PortableProperty $settingsObj 'files.autoSave' 'afterDelay'
        Set-PortableProperty $settingsObj 'editor.formatOnSave' $false
    }

    $credStore = if ($env:PORTABLE_GIT_CREDENTIAL_STORE -in @('dpapi', 'cache', 'none')) {
        $env:PORTABLE_GIT_CREDENTIAL_STORE.ToLowerInvariant()
    } else {
        'dpapi'
    }

    $termEnv = $settingsObj.'terminal.integrated.env.windows'
    if (-not $termEnv) { $termEnv = [pscustomobject]@{} }
    Set-PortableProperty $termEnv 'USERPROFILE'          $paths.Home
    Set-PortableProperty $termEnv 'HOME'                 $paths.Home
    if ($paths.Home -match '^([A-Za-z]:)(\\.*)$') {
        Set-PortableProperty $termEnv 'HOMEDRIVE'        $Matches[1]
        Set-PortableProperty $termEnv 'HOMEPATH'         $Matches[2]
    }
    else {
        Set-PortableProperty $termEnv 'HOMEDRIVE'        $null
        Set-PortableProperty $termEnv 'HOMEPATH'         $null
    }
    Set-PortableProperty $termEnv 'APPDATA'              $paths.AppDataRoaming
    Set-PortableProperty $termEnv 'LOCALAPPDATA'         $paths.AppDataLocal
    Set-PortableProperty $termEnv 'XDG_CONFIG_HOME'      $paths.XdgConfigHome
    Set-PortableProperty $termEnv 'XDG_DATA_HOME'        $paths.XdgDataHome
    Set-PortableProperty $termEnv 'XDG_STATE_HOME'       $paths.XdgStateHome
    Set-PortableProperty $termEnv 'XDG_CACHE_HOME'       $paths.XdgCacheHome
    Set-PortableProperty $termEnv 'TEMP'                 $paths.TmpDir
    Set-PortableProperty $termEnv 'TMP'                  $paths.TmpDir
    Set-PortableProperty $termEnv 'TMPDIR'               $paths.TmpDir
    Set-PortableProperty $termEnv 'CLINE_DIR'            $paths.ClineDir
    Set-PortableProperty $termEnv 'CLINE_DATA_DIR'       $paths.ClineDataDir
    Set-PortableProperty $termEnv 'GIT_CONFIG_GLOBAL'    $paths.GitGlobalConfig
    Set-PortableProperty $termEnv 'GIT_CONFIG_SYSTEM'    $paths.GitSystemConfig
    Set-PortableProperty $termEnv 'GCM_CREDENTIAL_STORE' $credStore
    Set-PortableProperty $termEnv 'GCM_DPAPI_STORE_PATH' $paths.GcmDpapiStore
    Set-PortableProperty $termEnv 'GH_CONFIG_DIR'        $paths.GhConfigDir
    $effectiveSsh = Get-PortableEffectiveSshCommandPath $paths
    if ($effectiveSsh) {
        Set-PortableProperty $termEnv 'GIT_SSH'          $effectiveSsh
    }
    else {
        Set-PortableProperty $termEnv 'GIT_SSH'          $null
    }
    Set-PortableProperty $termEnv 'OneDrive'             $null
    Set-PortableProperty $termEnv 'OneDriveConsumer'     $null
    Set-PortableProperty $termEnv 'OneDriveCommercial'   $null

    if (-not $settingsObj.PSObject.Properties['extensions.autoUpdate']) {
        Set-PortableProperty $settingsObj 'extensions.autoUpdate' $false
    }
    Set-PortableProperty $settingsObj 'terminal.integrated.env.windows' $termEnv
    Write-PortableJson $settingsPath $settingsObj
}

function Initialize-Portable {
    $paths = Get-PortableIsolationPaths
    [void][IO.Directory]::CreateDirectory($paths.Home)
    Move-LegacyPortableClineDirectory
    Ensure-PortableProfileDirectories $paths
    foreach ($dir in @(
        (Join-Path $data 'user-data\User')
        (Join-Path $data 'extensions')
        $paths.NpmCacheDir
        $cline
        (Join-Path $cline 'data\settings')
        (Join-Path $cline 'rules')
        (Join-Path $paths.Home '.agents\skills')
        $paths.XdgConfigHome
        $paths.XdgDataHome
        $paths.XdgStateHome
        $paths.XdgCacheHome
        $paths.GhConfigDir
        $paths.GitStateRoot
    )) {
        [void][IO.Directory]::CreateDirectory($dir)
    }
    Set-PortableRestrictedDirectoryAcl $paths.SshDir
    Set-PortableRestrictedDirectoryAcl $paths.GcmDpapiStore

    Install-PortableClineRules
    if (Get-Command Initialize-PortableGitConfig -ErrorAction SilentlyContinue) {
        Initialize-PortableGitConfig
    }
    if (Get-Command Initialize-PortableSshShims -ErrorAction SilentlyContinue) {
        Initialize-PortableSshShims
    }
    Update-PortableVSCodeTerminalSettings
    Repair-ClineMcpExfat
    if (Get-Command Set-PortableMcpSettings -ErrorAction SilentlyContinue) {
        Set-PortableMcpSettings
    }
}

function Open-PortableDataFolder {
    Initialize-Portable
    Start-Process explorer.exe -ArgumentList (ConvertTo-NativeArgument $data)
}
