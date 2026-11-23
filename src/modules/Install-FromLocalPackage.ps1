# ============================================================
# Install-FromLocalPackage.ps1
# アップデート管理 [5] ローカルファイル (.zip / .vsix) からのオフライン更新
# ============================================================

function Install-FromLocalPackage {
    $candidates = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -ieq '.zip' -or $_.Extension -ieq '.vsix'
    } | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -gt 0) {
        Write-Host 'フォルダ内で検出されたパッケージ:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $sizeMb = [Math]::Round($candidates[$i].Length / 1MB, 1)
            Write-Host "  [$($i + 1)] $($candidates[$i].Name) ($sizeMb MB)"
        }
    }
    $prompt = if ($candidates.Count -gt 0) { '番号 または .zip / .vsix のファイルパス（空欄で戻る）' } else { '.zip (VSCode) または .vsix (Cline等) のパス（空欄で戻る）' }
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
        if (Confirm-Action "ZIP ファイルから VSCode 本体を更新しますか？ ($(Split-Path -Leaf $pkgPath))") {
            [void](Install-VSCodeFromZip -ZipPath $pkgPath -ExpectedSha256 '')
        }
    }
    elseif ($ext -ieq '.vsix') {
        if (-not (Confirm-Action "VSIX から拡張機能をインストール／更新しますか？ ($(Split-Path -Leaf $pkgPath))")) { return }
        if (-not (Wait-PortableCodeClosed -Required $false)) { return }
        Invoke-PortableCodeCli @('--install-extension', $pkgPath, '--force')
        Write-Host "[完了] VSIX の適用が完了しました: $(Split-Path -Leaf $pkgPath)" -ForegroundColor Green
    }
    else {
        throw "未対応のファイル形式です ($ext)。.zip または .vsix を指定してください。"
    }
}
