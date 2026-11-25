# ============================================================
# Install-FromLocalPackage.ps1
# アップデート管理 [7] ローカルファイル (.zip / .vsix / .tgz) からのオフライン更新
# ============================================================

function Test-ZipContainsMinGit([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $hasGitExe = $false
        $hasCodeExe = $false
        foreach ($entry in $archive.Entries) {
            $norm = $entry.FullName -replace '\\', '/'
            if ($norm -ieq 'cmd/git.exe') { $hasGitExe = $true }
            if ($norm -ieq 'Code.exe' -or $norm -imatch '^[^/]+/Code\.exe$') { $hasCodeExe = $true }
        }
        return ($hasGitExe -and -not $hasCodeExe)
    }
    finally { $archive.Dispose() }
}

function Install-FromLocalPackage {
    $candidates = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.zip', '.vsix', '.tgz')
    } | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) {
        Write-Host 'フォルダ内で検出されたパッケージ:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $sizeMb = [Math]::Round($candidates[$i].Length / 1MB, 1)
            Write-Host "  [$($i + 1)] $($candidates[$i].Name) ($sizeMb MB)"
        }
    }
    $prompt = if ($candidates.Count -gt 0) { '番号 または .zip / .vsix / .tgz のファイルパス（空欄で戻る）' } else { '.zip (VSCode/MinGit) / .vsix (Cline等) / .tgz (MCP) のパス（空欄で戻る）' }
    $raw = (Read-Host $prompt).Trim().Trim('"')
    if (-not $raw) { return }
    $pkgPath = $raw
    $num = 0
    if ([int]::TryParse($raw, [ref]$num) -and $num -ge 1 -and $num -le $candidates.Count) {
        $pkgPath = $candidates[$num - 1].FullName
    }
    if (-not (Test-Path -LiteralPath $pkgPath -PathType Leaf)) {
        throw "ファイルが見つかりません: $pkgPath"
    }
    $ext = [IO.Path]::GetExtension($pkgPath)
    if ($ext -ieq '.zip') {
        if (Test-ZipContainsMinGit $pkgPath) {
            if (-not (Confirm-Action "ZIP ファイルからポータブル Git (MinGit) を更新しますか？ ($(Split-Path -Leaf $pkgPath))")) { return }
            if (-not (Wait-PortableCodeClosed -Required $false)) { return }
            Install-PortableGit -LocalZipPath $pkgPath -Force
            Initialize-Portable
            $afterGit = Get-InstalledPortableGitInfo
            Write-Host "[完了] ポータブル Git の適用が完了しました: $($afterGit.Version)" -ForegroundColor Green
        }
        else {
            if (Confirm-Action "ZIP ファイルから VSCode 本体を更新しますか？ ($(Split-Path -Leaf $pkgPath))") {
                [void](Install-VSCodeFromZip -ZipPath $pkgPath -ExpectedSha256 '')
            }
        }
    }
    elseif ($ext -ieq '.vsix') {
        if (-not (Confirm-Action "VSIX から拡張機能をインストール／更新しますか？ ($(Split-Path -Leaf $pkgPath))")) { return }
        if (-not (Wait-PortableCodeClosed -Required $false)) { return }
        Invoke-PortableCodeCli @('--install-extension', $pkgPath, '--force')
        Initialize-Portable
        if ((Get-Command Set-PortableJapanese -ErrorAction SilentlyContinue) -and (Get-InstalledExtensionVersion 'MS-CEINTL.vscode-language-pack-ja')) {
            Set-PortableJapanese
        }
        Write-Host "[完了] VSIX の適用が完了しました: $(Split-Path -Leaf $pkgPath)" -ForegroundColor Green
    }
    elseif ($ext -ieq '.tgz') {
        if (-not (Confirm-Action "TGZ から Playwright MCP をインストール／更新しますか？ ($(Split-Path -Leaf $pkgPath))")) { return }
        if (-not (Wait-PortableCodeClosed -Required $false)) { return }
        [void](Install-PortablePlaywrightMcp -LocalTarball $pkgPath -Force -VerifyAfterSwap)
        $afterMcp = Get-InstalledPlaywrightMcpVersion
        Write-Host "[完了] Playwright MCP の適用が完了しました: $afterMcp" -ForegroundColor Green
    }
    else {
        throw "未対応のファイル形式です ($ext)。.zip / .vsix / .tgz を指定してください。"
    }
}
