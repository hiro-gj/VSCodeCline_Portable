# ============================================================
# Common-Helpers.ps1
# 共通 UI 対話・ネイティブ引数エスケープ関数群
# ============================================================

function Confirm-Action([string]$Message) {
    return (Read-Host "$Message [y/N]") -ieq 'y'
}

function Wait-Menu {
    [void](Read-Host 'Enter キーでメニューに戻ります')
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows argument quoting: preserve spaces, quotes and trailing backslashes.
    return '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}
