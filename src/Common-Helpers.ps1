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

function Write-PortableStage([int]$Step, [string]$Message) {
    Write-Host "[起動中... $Step/7] $Message"
    Write-Progress -Id 10 -Activity 'ポータブル環境を準備しています（処理段階の目安）' -Status $Message -PercentComplete ([int](100 * $Step / 7))
}

function Wait-PortableProcess($Process, [string]$Activity) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $Process.WaitForExit(250)) {
            Write-Progress -Id 11 -Activity $Activity -Status ("起動中／処理中... {0:N0} 秒経過" -f $watch.Elapsed.TotalSeconds) -PercentComplete -1
        }
    }
    finally { Write-Progress -Id 11 -Activity $Activity -Completed }
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows argument quoting: preserve spaces, quotes and trailing backslashes.
    return '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}
