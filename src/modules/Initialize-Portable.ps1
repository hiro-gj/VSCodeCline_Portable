# ============================================================
# Initialize-Portable.ps1
# メインメニュー [3] ポータブル用フォルダ・初期設定の作成／修復
# メインメニュー [4] ポータブルデータフォルダ (data) を開く
# ============================================================

function Repair-ClineMcpExfat {
    # Cline 4.1.26 unconditionally hard-links its MCP settings, even when present.
    # exFAT rejects that operation with EISDIR. COPYFILE_EXCL (1) preserves the
    # existing EEXIST/no-overwrite contract without requiring hard-link support.
    $volume = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($root))
    if ($volume.DriveFormat -ine 'exFAT') { return }
    $extensions = Join-Path $data 'extensions'
    if (-not (Test-Path -LiteralPath $extensions -PathType Container)) { return }
    $original = 'async function Ok(t){let e=aA.join(t,JA.mcpSettings),r=`${e}.tmp.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}`;try{await db.default.writeFile(r,JSON.stringify({mcpServers:{}},null,2),{encoding:"utf8",flag:"wx"}),await db.default.link(r,e)}catch(i){if(i.code!=="EEXIST")throw i}finally{await db.default.unlink(r).catch(()=>{})}return e}'
    $replacement = $original.Replace('await db.default.link(r,e)', 'await db.default.copyFile(r,e,1)')
    foreach ($extension in (Get-ChildItem -LiteralPath $extensions -Directory -Filter 'saoudrizwan.claude-dev-*')) {
        $manifest = Join-Path $extension.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $package = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($package.publisher -cne 'saoudrizwan' -or $package.name -cne 'claude-dev') { continue }
        if ($package.version -cne '4.1.26') {
            Write-Warning "Cline $($package.version): the exFAT MCP compatibility fix supports 4.1.26 only. Check MCP loading after upgrading."
            continue
        }
        $bundle = Join-Path $extension.FullName 'dist\extension.js'
        $source = [IO.File]::ReadAllText($bundle, [Text.Encoding]::UTF8)
        if ($source.Contains($replacement)) { continue }
        $offset = $source.IndexOf($original, [StringComparison]::Ordinal)
        if ($offset -lt 0 -or $source.IndexOf($original, $offset + $original.Length, [StringComparison]::Ordinal) -ge 0) {
            throw "Cline exFAT fix: unexpected extension code; no changes made: $bundle"
        }
        $hash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
        $backupDir = Join-Path $cline 'compatibility\backups\saoudrizwan.claude-dev-4.1.26'
        [void][IO.Directory]::CreateDirectory($backupDir)
        $backup = Join-Path $backupDir ("extension.$hash.js")
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            [IO.File]::Copy($bundle, $backup, $false)
        }
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ine $hash) {
            throw "Cline exFAT fix: backup verification failed: $backup"
        }
        $patched = $source.Substring(0, $offset) + $replacement + $source.Substring($offset + $original.Length)
        try {
            [IO.File]::WriteAllText($bundle, $patched, (New-Object Text.UTF8Encoding($false)))
            if ([IO.File]::ReadAllText($bundle, [Text.Encoding]::UTF8) -cne $patched) {
                throw 'Cline exFAT fix: verification of the patched extension failed.'
            }
        }
        catch {
            [IO.File]::Copy($backup, $bundle, $true)
            throw
        }
        Write-Host '[修正] Cline 4.1.26 の exFAT 向け MCP 設定読み込み互換処理を適用しました。'
        Write-Host "  バックアップ: $backup"
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
    Set-PortableProperty $termEnv 'APPDATA'              $paths.AppDataRoaming
    Set-PortableProperty $termEnv 'LOCALAPPDATA'         $paths.AppDataLocal
    Set-PortableProperty $termEnv 'XDG_CONFIG_HOME'      $paths.XdgConfigHome
    Set-PortableProperty $termEnv 'XDG_DATA_HOME'        $paths.XdgDataHome
    Set-PortableProperty $termEnv 'XDG_STATE_HOME'       $paths.XdgStateHome
    Set-PortableProperty $termEnv 'XDG_CACHE_HOME'       $paths.XdgCacheHome
    Set-PortableProperty $termEnv 'TEMP'                 $paths.TmpDir
    Set-PortableProperty $termEnv 'TMP'                  $paths.TmpDir
    Set-PortableProperty $termEnv 'CLINE_DIR'            $paths.ClineDir
    Set-PortableProperty $termEnv 'CLINE_DATA_DIR'       $paths.ClineDataDir
    Set-PortableProperty $termEnv 'GIT_CONFIG_GLOBAL'    $paths.GitGlobalConfig
    Set-PortableProperty $termEnv 'GIT_CONFIG_SYSTEM'    $paths.GitSystemConfig
    Set-PortableProperty $termEnv 'GCM_CREDENTIAL_STORE' $credStore
    Set-PortableProperty $termEnv 'GCM_DPAPI_STORE_PATH' $paths.GcmDpapiStore
    Set-PortableProperty $termEnv 'GH_CONFIG_DIR'        $paths.GhConfigDir
    if (Test-Path -LiteralPath $paths.GitSshExe -PathType Leaf) {
        Set-PortableProperty $termEnv 'GIT_SSH'          $paths.GitSshExe
    }
    Set-PortableProperty $termEnv 'OneDrive'             $null
    Set-PortableProperty $termEnv 'OneDriveConsumer'     $null
    Set-PortableProperty $termEnv 'OneDriveCommercial'   $null

    Set-PortableProperty $settingsObj 'terminal.integrated.env.windows' $termEnv
    Write-PortableJson $settingsPath $settingsObj
}

function Initialize-Portable {
    $paths = Get-PortableIsolationPaths
    [void][IO.Directory]::CreateDirectory($paths.Home)
    Move-LegacyPortableClineDirectory
    foreach ($dir in @(
        (Join-Path $data 'user-data\User')
        (Join-Path $data 'extensions')
        $paths.TmpDir
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
        $paths.DocumentsDir
        $paths.AppDataRoaming
        $paths.AppDataLocal
        $paths.AppDataLocalLow
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
