# Run with Windows PowerShell 5.1; no external test framework required.
$ErrorActionPreference = 'Stop'
$modulesRoot = $PSScriptRoot
$sourceRoot  = Split-Path -LiteralPath $modulesRoot
$repoParent  = Split-Path -LiteralPath $sourceRoot
foreach ($name in @('Common-Helpers.ps1', 'Initialize-Portable.ps1', 'Install-PortableEnvironment.ps1', 'Set-PortableJapanese.ps1', 'Install-PortableGit.ps1')) {
    . (Join-Path $modulesRoot $name)
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$vscodeDir   = Join-Path $repoParent 'VSCode'
$hadVSCode   = Test-Path -LiteralPath $vscodeDir
$testTmpBase = Join-Path $vscodeDir 'data\tmp'
[void][IO.Directory]::CreateDirectory($testTmpBase)
$sandbox = Join-Path $testTmpBase ('portable-tests-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $sandbox 'data'
$root = $sandbox
$code = Join-Path $root 'Code.exe'
$cline = Join-Path $data 'home\.cline'

try {
    # 1. Verify src and src\modules structure
    $looseFiles = @(Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object { $_.Name -ine 'Start-VSCodeCline_Portable.cmd' })
    Assert ($looseFiles.Count -eq 0) 'src root must contain only Start-VSCodeCline_Portable.cmd'
    Assert (Test-Path -LiteralPath (Join-Path $modulesRoot 'start-mcp.js') -PathType Leaf) 'start-mcp.js missing in src\modules'
    Assert (Test-Path -LiteralPath (Join-Path $modulesRoot 'verify-mcp.js') -PathType Leaf) 'verify-mcp.js missing in src\modules'
    Assert (Test-Path -LiteralPath (Join-Path $modulesRoot 'playwright-mcp-snapshot.md') -PathType Leaf) 'Rule template missing in src\modules'
    Write-Host '[PASS] Directory structure: src\modules separation'

    $extension = Join-Path $data 'extensions\ms-ceintl.vscode-language-pack-ja-1.0.0'
    [void][IO.Directory]::CreateDirectory((Join-Path $extension 'translations'))
    [IO.File]::WriteAllText((Join-Path $extension 'translations\main.i18n.json'), '{}')
    Write-PortableJson (Join-Path $extension 'package.json') @{
        name = 'vscode-language-pack-ja'; publisher = 'MS-CEINTL'; version = '1.0.0'
        __metadata = @{ id = 'test-uuid' }
        contributes = @{ localizations = @(@{ languageId = 'ja'; localizedLanguageName = 'Japanese'; translations = @(@{ id = 'vscode'; path = './translations/main.i18n.json' }) }) }
    }
    function Get-InstalledExtensionVersion { return '1.0.0' }
    Set-PortableJapanese
    $cachePath = Join-Path $data 'user-data\languagepacks.json'
    $cache = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
    Assert ($cache.ja.translations.vscode -eq (Join-Path $extension 'translations\main.i18n.json')) 'Fresh install: incorrect translation path'
    Assert ($cache.ja.extensions[0].extensionIdentifier.uuid -eq 'test-uuid') 'UUID lost'
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $expected = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes('test-uuid1.0.0')))).Replace('-', '').ToLowerInvariant() }
    finally { $md5.Dispose() }
    Assert ($cache.ja.hash -eq $expected) 'Incorrect VS Code cache hash'
    Set-PortableProperty $cache 'fr' ([pscustomobject]@{ label = 'Keep me' })
    $cache.ja.translations.vscode = 'Z:\old-drive\main.i18n.json'
    Write-PortableJson $cachePath $cache
    Set-PortableJapanese
    $cache = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
    Assert ($cache.fr.label -eq 'Keep me') 'Other language was overwritten'
    Assert (Test-Path -LiteralPath $cache.ja.translations.vscode) 'Drive relocation was not repaired'
    $before = [IO.File]::ReadAllText($cachePath)
    Set-PortableJapanese
    Assert ([IO.File]::ReadAllText($cachePath) -ceq $before) 'Cache preparation is not idempotent'
    Write-Host '[PASS] Japanese cache: fresh install, hash, drive relocation, preservation, idempotency'

    # Verify the real ZIP extraction/copy/hash logic without an Internet download.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixture = Join-Path $sandbox 'git-fixture'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'cmd'))
    [IO.File]::WriteAllText((Join-Path $fixture 'cmd\git.exe'), 'fixture')
    $zip = Join-Path $sandbox 'fixture.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($fixture, $zip)
    $script:fixtureHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    function Initialize-NetworkConfig {}
    function Get-PortableCodeArchitecture { return @{ Arch = 'x64' } }
    function Invoke-RestMethod {
        return @{ assets = @(@{ name = 'MinGit-1.2.3-64-bit.zip'; digest = 'sha256:' + $script:fixtureHash; browser_download_url = 'https://fixture.invalid/git.zip' }) }
    }
    . (Join-Path $modulesRoot 'Update-VSCodeOnline.ps1')
    # Restore only the downloader mock after loading the real ZIP helper.
    function Save-UrlToFile($Url, $DestinationPath) {
        [void][IO.Directory]::CreateDirectory((Split-Path -LiteralPath $DestinationPath))
        [IO.File]::Copy($zip, $DestinationPath, $true)
    }
    # Intercept native execution in this test; the live smoke test uses git.exe.
    function git.exe { $global:LASTEXITCODE = 0; return 'git version fixture' }
    $installText = (Get-Command Install-PortableGit).Definition
    $installText = $installText.Replace('& $stagedExe --version', 'git.exe --version').Replace('& $gitExe --version', 'git.exe --version')
    $install = [scriptblock]::Create($installText)
    & $install
    Assert (Test-Path -LiteralPath (Join-Path $data 'tools\git\cmd\git.exe')) 'Git was not installed'
    $info = New-Object Diagnostics.ProcessStartInfo
    $originalPath = $env:PATH
    Set-PortableGitEnvironment $info
    Assert ($info.EnvironmentVariables['PATH'].StartsWith((Join-Path $data 'tools\git\cmd') + ';')) 'Child PATH was not configured'
    Assert ($env:PATH -ceq $originalPath) 'Parent PATH was changed'
    function Invoke-RestMethod { throw 'An existing installation must not access the network' }
    & $install
    $data = Join-Path $sandbox 'bad-hash-data'
    function Invoke-RestMethod { return @{ assets = @(@{ name = 'MinGit-1.2.3-64-bit.zip'; digest = 'sha256:' + ('0' * 64); browser_download_url = 'https://fixture.invalid/git.zip' }) } }
    $rejected = $false
    try { & $install } catch { $rejected = $_.Exception.Message -like '*SHA-256*' }
    Assert $rejected 'Invalid Git hash was not rejected'
    Assert (-not (Test-Path -LiteralPath (Join-Path $data 'tools\git\cmd\git.exe'))) 'Invalid Git archive was installed'
    Write-Host '[PASS] Git: ZIP install, child-only PATH, offline reuse, SHA-256 rejection'

    # 4. Verify portable isolation, global rules deployment, legacy cline migration, child env
    $sandboxData = Join-Path $sandbox 'data'
    $data = $sandboxData
    $cline = Join-Path $data 'home\.cline'
    $legacyDir = Join-Path $data 'cline\data\settings'
    [void][IO.Directory]::CreateDirectory($legacyDir)
    [IO.File]::WriteAllText((Join-Path $legacyDir 'legacy.json'), '{}')

    [void][IO.Directory]::CreateDirectory((Join-Path $data 'tools\git\cmd'))
    [void][IO.Directory]::CreateDirectory((Join-Path $data 'tools\git\usr\bin'))
    [void][IO.Directory]::CreateDirectory((Join-Path $data 'tools\git\etc'))
    [IO.File]::WriteAllText((Join-Path $data 'tools\git\cmd\git.exe'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $data 'tools\git\usr\bin\ssh.exe'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $data 'tools\git\etc\gitconfig'), "[include]`r`n`tpath = C:/Program Files/Git/etc/gitconfig`r`n")

    Initialize-Portable

    Assert (Test-Path -LiteralPath (Join-Path $cline 'data\settings\legacy.json') -PathType Leaf) 'Legacy cline data was not migrated'
    $deployedRule = Join-Path $cline 'rules\playwright-mcp-snapshot.md'
    Assert (Test-Path -LiteralPath $deployedRule -PathType Leaf) 'playwright-mcp-snapshot.md was not deployed to .cline\rules'
    Assert ([IO.File]::ReadAllText($deployedRule, [Text.Encoding]::UTF8) -ceq [IO.File]::ReadAllText((Join-Path $modulesRoot 'playwright-mcp-snapshot.md'), [Text.Encoding]::UTF8)) 'Rule content mismatch'

    $childInfo = New-Object Diagnostics.ProcessStartInfo
    $childInfo.EnvironmentVariables['OneDrive'] = 'C:\HostOneDrive'
    $origUserProfile = $env:USERPROFILE
    Set-PortableChildEnvironment -Info $childInfo -IncludeGitPath

    Assert ($childInfo.EnvironmentVariables['USERPROFILE'] -eq (Join-Path $data 'home')) 'Child USERPROFILE not isolated'
    Assert ($childInfo.EnvironmentVariables['CLINE_DIR'] -eq $cline) 'Child CLINE_DIR does not match home\.cline'
    Assert ($childInfo.EnvironmentVariables['GCM_CREDENTIAL_STORE'] -eq 'dpapi') 'GCM store not set to dpapi'
    Assert (-not $childInfo.EnvironmentVariables.ContainsKey('OneDrive')) 'OneDrive variable was not stripped'
    Assert ($childInfo.EnvironmentVariables['PATH'].StartsWith((Join-Path $data 'tools\git\cmd') + ';' + (Join-Path $data 'tools\bin') + ';')) 'Child PATH order incorrect'
    Assert ($env:USERPROFILE -ceq $origUserProfile) 'Parent USERPROFILE was mutated'
    Write-Host '[PASS] Modules layout, .cline\rules deployment, legacy migration, and full portable isolation'
}
finally {
    # The target is the unique sandbox created above, never an application folder.
    if ($sandbox -and (Split-Path -Leaf $sandbox) -like 'portable-tests-*' -and (Test-Path -LiteralPath $sandbox)) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
    if (-not $hadVSCode -and (Test-Path -LiteralPath $vscodeDir)) {
        $remaining = @(Get-ChildItem -LiteralPath $vscodeDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $vscodeDir -Recurse -Force
        }
    }
}