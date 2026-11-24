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
    $vsSettings = [IO.File]::ReadAllText((Join-Path $data 'user-data\User\settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($vsSettings.'extensions.autoUpdate' -eq $false) 'extensions.autoUpdate was not disabled by default'
    Write-Host '[PASS] Modules layout, .cline\rules deployment, legacy migration, and full portable isolation'

    # 5. Verify multi-version Cline exFAT MCP compatibility patch and Set-PortableMcpSettings
    $clineVariants = [ordered]@{
        '4.1.26' = @{
            Source   = 'async function Ok(t){let e=aA.join(t,JA.mcpSettings),r=`${e}.tmp.${process.pid}.${Date.now()}`;try{await db.default.writeFile(r,JSON.stringify({mcpServers:{}},null,2),{encoding:"utf8",flag:"wx"}),await db.default.link(r,e)}catch(i){if(i.code!=="EEXIST")throw i}finally{await db.default.unlink(r).catch(()=>{})}return e}'
            Expected = 'await db.default.copyFile(r,e,1)'
            Patched  = $true
        }
        '4.1.27' = @{
            Source   = 'async function Dk(t){let e=oA.join(t,ey.mcpSettings),r=`${e}.tmp.${process.pid}.${Date.now()}`;try{await cb.default.writeFile(r,JSON.stringify({mcpServers:{}},null,2),{encoding:"utf8",flag:"wx"}),await cb.default.link(r,e)}catch(i){if(i.code!=="EEXIST")throw i}finally{await cb.default.unlink(r).catch(()=>{})}return e}'
            Expected = 'await cb.default.copyFile(r,e,1)'
            Patched  = $true
        }
        '4.99.0' = @{
            Source   = 'const z9=async n=>{const a=(0,p1.join)(n,G2.mcpSettings);const b=`${a}.tmp.${process.pid}`;try{await (0,fs1.writeFile)(b,"{}",{encoding:"utf-8",flag:"wx"});await (0,fs1.link)(b,a)}catch(c){if(c.code!=="EEXIST")throw c}finally{await (0,fs1.unlink)(b).catch(()=>{})}return a}'
            Expected = 'await (0,fs1.copyFile)(b,a,1)'
            Patched  = $true
        }
        '5.0.0'  = @{
            Source   = 'async function Up(t){let e=oA.join(t,ey.mcpSettings);await cb.default.writeFile(e,"{}",{encoding:"utf8",flag:"wx"}).catch(i=>{if(i.code!=="EEXIST")throw i});return e}'
            Expected = 'await cb.default.writeFile(e,"{}",{encoding:"utf8",flag:"wx"})'
            Patched  = $false
        }
    }
    foreach ($ver in $clineVariants.Keys) {
        $extFolder = Join-Path $data ("extensions\saoudrizwan.claude-dev-$ver")
        [void][IO.Directory]::CreateDirectory((Join-Path $extFolder 'dist'))
        Write-PortableJson (Join-Path $extFolder 'package.json') @{ publisher = 'saoudrizwan'; name = 'claude-dev'; version = $ver }
        [IO.File]::WriteAllText((Join-Path $extFolder 'dist\extension.js'), $clineVariants[$ver].Source, (New-Object Text.UTF8Encoding($false)))
    }
    Repair-ClineMcpExfat -Force
    $snapshotsAfterFirst = @{}
    foreach ($ver in $clineVariants.Keys) {
        $bundlePath = Join-Path $data ("extensions\saoudrizwan.claude-dev-$ver\dist\extension.js")
        $afterText  = [IO.File]::ReadAllText($bundlePath, [Text.Encoding]::UTF8)
        $snapshotsAfterFirst[$ver] = $afterText
        Assert ($afterText.Contains($clineVariants[$ver].Expected)) "Cline $ver was not expectedly handled"
        $backupFolder = Join-Path $cline ("compatibility\backups\saoudrizwan.claude-dev-$ver")
        if ($clineVariants[$ver].Patched) {
            Assert (-not $afterText.Contains('.link(')) "Cline $ver still contains .link("
            Assert (Test-Path -LiteralPath $backupFolder -PathType Container) "Backup missing for Cline $ver"
        }
        else {
            Assert ($afterText -ceq $clineVariants[$ver].Source) "Upstream-fixed Cline $ver should remain untouched"
            Assert (-not (Test-Path -LiteralPath $backupFolder)) "Unnecessary backup created for Cline $ver"
        }
    }
    Repair-ClineMcpExfat -Force
    foreach ($ver in $clineVariants.Keys) {
        $bundlePath = Join-Path $data ("extensions\saoudrizwan.claude-dev-$ver\dist\extension.js")
        Assert ([IO.File]::ReadAllText($bundlePath, [Text.Encoding]::UTF8) -ceq $snapshotsAfterFirst[$ver]) "Repair-ClineMcpExfat not idempotent for $ver"
    }

    $mcpDir = Join-Path $cline 'mcp\playwright'
    [void][IO.Directory]::CreateDirectory($mcpDir)
    [IO.File]::WriteAllText((Join-Path $mcpDir 'start-mcp.js'), '// stub', (New-Object Text.UTF8Encoding($false)))
    $mcpSettingsPath = Join-Path $cline 'data\settings\cline_mcp_settings.json'
    [IO.File]::WriteAllText($mcpSettingsPath, '', (New-Object Text.UTF8Encoding($false)))
    Set-PortableMcpSettings
    $mcpJson = [IO.File]::ReadAllText($mcpSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($mcpJson.mcpServers.playwright.command -eq $code) 'Set-PortableMcpSettings did not set command from empty file'
    Assert ($mcpJson.mcpServers.playwright.cwd -eq $mcpDir) 'Set-PortableMcpSettings did not set cwd'
    Assert (-not $mcpJson.mcpServers.playwright.env.PSObject.Properties['PLAYWRIGHT_BROWSERS_PATH']) 'PLAYWRIGHT_BROWSERS_PATH should not be set'
    Assert ($mcpJson.mcpServers.playwright.env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD -eq '1') 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD missing'

    Set-PortableProperty $mcpJson.mcpServers 'otherServer' ([pscustomobject]@{ type = 'stdio'; command = 'node' })
    Set-PortableProperty $mcpJson.mcpServers.playwright 'command' 'Z:\old\Code.exe'
    Set-PortableProperty $mcpJson.mcpServers.playwright.env 'PLAYWRIGHT_BROWSERS_PATH' 'Z:\legacy\browsers'
    Set-PortableProperty $mcpJson.mcpServers.playwright 'autoApprove' @('browser_navigate')
    Write-PortableJson $mcpSettingsPath $mcpJson
    Set-PortableMcpSettings
    $mcpJson2 = [IO.File]::ReadAllText($mcpSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($mcpJson2.mcpServers.playwright.command -eq $code) 'Relocated command was not repaired'
    Assert (-not $mcpJson2.mcpServers.playwright.env.PSObject.Properties['PLAYWRIGHT_BROWSERS_PATH']) 'Legacy PLAYWRIGHT_BROWSERS_PATH was not removed'
    Assert ($mcpJson2.mcpServers.playwright.env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD -eq '1') 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD missing after repair'
    Assert ($mcpJson2.mcpServers.playwright.autoApprove[0] -eq 'browser_navigate') 'autoApprove was lost'
    Assert ($mcpJson2.mcpServers.otherServer.command -eq 'node') 'Custom MCP server was lost'
    Write-Host '[PASS] Multi-version Cline MCP exFAT fix (4.1.26/4.1.27/future/upstream) and MCP settings resilience'

    # 6. Verify unpinned MCP policy, local Edge resolver, and 4-component metadata
    . (Join-Path $modulesRoot 'Get-PortableMetadata.ps1')
    . (Join-Path $modulesRoot 'Install-FromLocalPackage.ps1')
    $installEnvSource = [IO.File]::ReadAllText((Join-Path $modulesRoot 'Install-PortableEnvironment.ps1'), [Text.Encoding]::UTF8)
    $readmeSource = [IO.File]::ReadAllText((Join-Path $repoParent 'README.md'), [Text.Encoding]::UTF8)
    $startMcpSource = [IO.File]::ReadAllText((Join-Path $modulesRoot 'start-mcp.js'), [Text.Encoding]::UTF8)
    $verifyMcpSource = [IO.File]::ReadAllText((Join-Path $modulesRoot 'verify-mcp.js'), [Text.Encoding]::UTF8)
    Assert (-not $installEnvSource.Contains('0.0.85')) 'Hardcoded 0.0.85 pin still present in Install-PortableEnvironment.ps1'
    Assert (-not $readmeSource.Contains('0.0.85')) 'Hardcoded 0.0.85 pin restriction still present in README.md'
    Assert (-not $installEnvSource.Contains('Install-PortableChromium')) 'Install-PortableChromium still present'
    Assert (-not $startMcpSource.Contains('chromium.executablePath')) 'start-mcp.js still uses chromium.executablePath()'
    Assert ($startMcpSource.Contains("'--browser', 'msedge'")) 'start-mcp.js must default to --browser msedge'
    Assert ($verifyMcpSource.Contains("channel: 'msedge'")) 'verify-mcp.js must launch msedge channel'

    $resolvedEdge = Get-LocalEdgeExecutablePath
    Assert ($resolvedEdge -and (Test-Path -LiteralPath $resolvedEdge -PathType Leaf)) 'Get-LocalEdgeExecutablePath failed to find local Edge'

    Assert ((ConvertTo-ComparableGitVersion 'git version 2.56.1.windows.1') -eq '2.56.1.1') 'Comparable Git version (windows.1) mismatch'
    Assert ((ConvertTo-ComparableGitVersion 'v2.56.1.windows.2') -eq '2.56.1.2') 'Comparable Git version (windows.2) mismatch'
    Assert ((ConvertTo-ComparableGitVersion 'MinGit-2.56.1-64-bit.zip') -eq '2.56.1.1') 'Comparable Git version (MinGit 3-part) mismatch'
    Assert ((Compare-VersionString (ConvertTo-ComparableGitVersion '2.56.1.windows.1') (ConvertTo-ComparableGitVersion '2.56.1.windows.2')) -lt 0) 'Git windows.1 -> windows.2 comparison failed'

    [void][IO.Directory]::CreateDirectory((Join-Path $mcpDir 'node_modules\@playwright\mcp'))
    [IO.File]::WriteAllText((Join-Path $mcpDir 'node_modules\@playwright\mcp\cli.js'), '// cli', (New-Object Text.UTF8Encoding($false)))
    Write-PortableJson (Join-Path $mcpDir 'node_modules\@playwright\mcp\package.json') @{ name = '@playwright/mcp'; version = '0.0.86' }
    Assert ((Get-InstalledPlaywrightMcpVersion) -eq '0.0.86') 'Get-InstalledPlaywrightMcpVersion failed'

    Write-PortableJson (Join-Path $data 'tools\git\portable-install.json') @{ version = 'git version 2.56.1.windows.1'; sha256 = ('a' * 64); asset = 'MinGit-2.56.1-64-bit.zip' }
    $gitInstalled = Get-InstalledPortableGitInfo
    Assert ($gitInstalled.Version -eq '2.56.1.windows.1') 'Get-InstalledPortableGitInfo display version mismatch'
    Assert ($gitInstalled.ComparableVersion -eq '2.56.1.1') 'Get-InstalledPortableGitInfo comparable version mismatch'
    Assert (Test-ZipContainsMinGit $zip) 'Test-ZipContainsMinGit did not detect MinGit fixture archive'
    Write-Host '[PASS] Unpinned MCP policy, local Edge resolver, and 4-component update metadata'
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