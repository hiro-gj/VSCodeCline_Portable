# ============================================================
# Copy-Optional.ps1
# メインメニュー [5] 通常版 VSCode / Cline から設定・拡張機能をコピー
# ============================================================

function Copy-Optional([string]$Label, [string]$Source, [string]$Destination) {
    if (-not (Confirm-Action "$Label をコピーしますか？ ポータブル側の同名ファイルは上書きされます")) { return }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Host "[スキップ] コピー元がありません: $Source"
        return
    }
    # No /MIR or /MOVE: never delete or modify the source. Exclude junctions.
    & robocopy.exe $Source $Destination /E /XJ /R:1 /W:1 /NP
    if ($LASTEXITCODE -ge 8) { throw "コピー失敗: $Label (robocopy=$LASTEXITCODE)" }
    Write-Host "[完了] $Label"
}

function Copy-FromStandardEnvironment {
    Write-Host '通常版側は読み取りのみです。コピー先はポータブル側です。'
    Write-Host '両方の VSCode を終了してからの実行を推奨します。'
    Write-Host 'コピー先をバックアップしてください。設定内の絶対パスは自動変換されません。'
    if (-not (Confirm-Action '引き継ぎメニューへ進みますか？')) { return $false }
    Initialize-Portable
    $srcAppData     = if ($script:HostAppData)     { $script:HostAppData }     else { $env:APPDATA }
    $srcUserProfile = if ($script:HostUserProfile) { $script:HostUserProfile } else { $env:USERPROFILE }
    Copy-Optional 'VSCode ユーザー設定' (Join-Path $srcAppData 'Code\User')               (Join-Path $data 'user-data\User')
    Copy-Optional 'VSCode 拡張機能'     (Join-Path $srcUserProfile '.vscode\extensions')  (Join-Path $data 'extensions')
    Copy-Optional 'Cline 設定'          (Join-Path $srcUserProfile '.cline\data\settings') (Join-Path $cline 'data\settings')
    return $true
}
