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

function Initialize-Portable {
    foreach ($relative in @('user-data\User', 'extensions', 'tmp', 'cline\data\settings')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $data $relative))
    }
    $settings = Join-Path $data 'user-data\User\settings.json'
    if (-not (Test-Path -LiteralPath $settings)) {
        [IO.File]::WriteAllText($settings, "{`r`n    `"files.autoSave`": `"afterDelay`",`r`n    `"editor.formatOnSave`": false`r`n}`r`n", (New-Object Text.UTF8Encoding($false)))
    }
    Repair-ClineMcpExfat
    if (Get-Command Set-PortableMcpSettings -ErrorAction SilentlyContinue) {
        Set-PortableMcpSettings
    }
}

function Open-PortableDataFolder {
    Initialize-Portable
    Start-Process explorer.exe -ArgumentList (ConvertTo-NativeArgument $data)
}
