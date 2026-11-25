# ============================================================
# Show-MainMenu.ps1
# ポータブルモード ランチャー & セットアップ メインメニュー
# ============================================================

function Show-MainMenu {
    while ($true) {
        $vsMain = Get-VSCodeMetadata $root
        $vsMainLabel = if ($vsMain.Version) { "$($vsMain.Version) ($($vsMain.Arch) / $($vsMain.Quality))" } elseif (Test-Path -LiteralPath $code -PathType Leaf) { 'バージョン不明' } else { '未検出 ([6] から導入可)' }
        $clineMainVer = Get-InstalledExtensionVersion $clineExtensionId
        $clineMainLabel = if ($clineMainVer) { $clineMainVer } else { '未インストール' }
        $mcpMainVer = Get-InstalledPlaywrightMcpVersion
        $mcpMainLabel = if ($mcpMainVer) { $mcpMainVer } else { '未インストール' }
        $gitMainInfo = Get-InstalledPortableGitInfo
        $gitMainLabel = if ($gitMainInfo) { "$($gitMainInfo.Version) ($data\tools\git\cmd\git.exe)" } else { "未インストール ($data\tools\git\cmd\git.exe)" }
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '  VSCode ポータブルモード ランチャー & セットアップ'
        Write-Host '============================================================'
        Write-Host "  対象フォルダ : $root"
        Write-Host "  VSCode 本体  : $vsMainLabel"
        Write-Host "  Cline 拡張   : $clineMainLabel"
        Write-Host "  PlaywrightMCP: $mcpMainLabel"
        Write-Host "  Git コマンド : $gitMainLabel"
        Write-Host "  VSCodeデータ : $data\user-data"
        Write-Host "  一時フォルダ : $data\tmp"
        Write-Host "  Clineルート  : $cline （バッチ経由の起動時に適用）"
        Write-Host '------------------------------------------------------------'
        Write-Host '  [1] ポータブル版 VSCode を起動する (デフォルト)'
        Write-Host '  [2] 開くフォルダまたはファイルを指定して起動する'
        Write-Host '  [3] ポータブル用フォルダ・初期設定を作成／修復する (起動しない)'
        Write-Host '  [4] ポータブルデータフォルダ (data) を開く'
        Write-Host '  [5] (オプション) 通常版 VSCode / Cline から設定・拡張機能をコピー'
        Write-Host '  [6] VSCode / Cline / MCP / Git のアップデート管理 (確認・オンライン更新・ローカル適用)'
        Write-Host '  [0] 終了'
        $selection = Read-Host '番号を入力してください [Enter=1]'
        if ([string]::IsNullOrWhiteSpace($selection)) { $selection = '1' }
        try {
            switch ($selection) {
                '1' {
                    if (-not (Test-Path -LiteralPath $data)) {
                        if (-not (Confirm-Action 'ポータブル用フォルダを作成して起動しますか？')) { break }
                    }
                    Start-Portable @()
                    exit 0
                }
                '2' {
                    $target = (Read-Host '開くパス（空欄で戻る）').Trim().Trim('"')
                    if (-not $target) { break }
                    if (-not (Test-Path -LiteralPath $target)) {
                        if (-not (Confirm-Action '存在しないパスです。このまま開きますか？')) { break }
                    }
                    Start-Portable @($target)
                    exit 0
                }
                '3' {
                    Initialize-Portable
                    Write-Host '[完了] 不足分を作成しました。既存の設定は変更していません。'
                    Wait-Menu
                }
                '4' {
                    Open-PortableDataFolder
                }
                '5' {
                    if (Copy-FromStandardEnvironment) {
                        Wait-Menu
                    }
                }
                '6' {
                    Show-UpdateMenu
                }
                '0' { exit 0 }
                default { Write-Host '[注意] 0～6 の番号を入力してください。' }
            }
        }
        catch {
            Write-Host "[エラー] $($_.Exception.Message)" -ForegroundColor Red
            Wait-Menu
        }
    }
}
