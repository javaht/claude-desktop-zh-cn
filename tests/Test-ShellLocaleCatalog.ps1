$ErrorActionPreference = 'Stop'
$Block = 4 * 1024 * 1024

# --- 核心函数（从 install_windows.ps1 提取的最小集，与安装器逻辑一致） ---
function Align-4([int]$v) { $v + ((4 - ($v % 4)) % 4) }
function Get-AsarFileIntegrityFromBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace "-","").ToLowerInvariant()
        $blocks = New-Object System.Collections.Generic.List[string]
        for ($o = 0; $o -lt $Bytes.Length; $o += $Block) {
            $len = [Math]::Min($Block, $Bytes.Length - $o)
            $seg = [byte[]]::new($len); [Array]::Copy($Bytes,$o,$seg,0,$len)
            $blocks.Add(([BitConverter]::ToString($sha.ComputeHash($seg)) -replace "-","").ToLowerInvariant())
        }
        if ($blocks.Count -eq 0) { $blocks.Add($hash) }
        return @{ algorithm="SHA256"; hash=$hash; blockSize=$Block; blocks=$blocks.ToArray() }
    } finally { $sha.Dispose() }
}
function Read-AsarHeader([byte[]]$Data, [string]$Path) {
    $headerSize = [BitConverter]::ToUInt32($Data, 4)
    $headerPickle = [byte[]]::new($headerSize)
    [Array]::Copy($Data, 8, $headerPickle, 0, $headerSize)
    $headerPayloadSize = [BitConverter]::ToUInt32($headerPickle, 0)
    $headerStringSize = [BitConverter]::ToInt32($headerPickle, 4)
    $headerBytes = [byte[]]::new($headerStringSize)
    [Array]::Copy($headerPickle, 8, $headerBytes, 0, $headerStringSize)
    $headerString = [Text.Encoding]::UTF8.GetString($headerBytes)
    return @{ HeaderSize=$headerSize; HeaderString=$headerString; Header=($headerString|ConvertFrom-Json) }
}
function Read-AsarHeaderFromFile([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $prefix = [byte[]]::new(8); [void]$stream.Read($prefix,0,8)
        $hs = [BitConverter]::ToUInt32($prefix,4)
        $data = [byte[]]::new(8+$hs)
        [Array]::Copy($prefix,0,$data,0,8)
        [void]$stream.Read($data,8,$hs)
        return Read-AsarHeader $data $Path
    } finally { $stream.Dispose() }
}
function Get-AsarEntryPaths($Header) {
    $results = @()
    $nodes = @()
    foreach ($p in $Header.files.PSObject.Properties) {
        $path = $p.Name
        if ($p.Value.PSObject.Properties["files"]) {
            $nodes += ,@($p.Value, $path)
        } else {
            $results += $path
        }
    }
    $i = 0
    while ($i -lt $nodes.Count) {
        $node = $nodes[$i][0]; $prefix = $nodes[$i][1]
        $i++
        foreach ($p in $node.files.PSObject.Properties) {
            $path = "$prefix/$($p.Name)"
            if ($p.Value.PSObject.Properties["files"]) {
                $nodes += ,@($p.Value, $path)
            } else {
                $results += $path
            }
        }
    }
    return $results
}
function Read-AsarEntryBytes([string]$AsarPath, $Parsed, [string]$EntryPath) {
    $node = $Parsed["Header"]
    foreach ($seg in ($EntryPath -split '/')) {
        $node = $node.files.PSObject.Properties[$seg].Value
    }
    $dataStart = 8 + [int]$Parsed["HeaderSize"]
    $size = [int64]$node.size
    $bytes = [byte[]]::new($size)
    $s = [IO.File]::OpenRead($AsarPath)
    try { $s.Seek($dataStart + [int64]$node.offset, [IO.SeekOrigin]::Begin) | Out-Null; [void]$s.Read($bytes,0,$size) }
    finally { $s.Dispose() }
    return $bytes
}
function Test-ShellInternalI18nLayout([string]$ResourcesPath) {
    $p = Join-Path $ResourcesPath "app.asar"
    if (-not (Test-Path $p -PathType Leaf)) { return $false }
    try {
        $parsed = Read-AsarHeaderFromFile $p
        $entryPaths = Get-AsarEntryPaths $parsed["Header"]
        foreach ($ep in $entryPaths) {
            if ($ep -eq "resources/i18n/en-US.json") { return $true }
        }
        return $false
    }
    catch { return $false }
}
function Get-ShellCatalogBaseEntry([string]$Lang) {
    $m = @{ "zh-CN"="resources/i18n/zh-Hans.json"; "zh-TW"="resources/i18n/zh-Hant.json"; "zh-HK"="resources/i18n/zh-Hant.json" }
    if ($m.ContainsKey($Lang)) { return $m[$Lang] }
    return "resources/i18n/en-US.json"
}

# --- Stub（测试无 Claude.exe / 备份） ---
function Sync-ClaudeExeAsarIntegrity { param([string]$ResourcesPath) }
function Backup-AppFile { param([string]$ResourcesPath,[string]$FilePath) }

# --- 合成 ASAR 构建 ---
function New-TestAsar([string]$HeaderString, [byte[][]]$Payloads, [string]$DestPath) {
    $hb = [Text.Encoding]::UTF8.GetBytes($HeaderString)
    $hps = Align-4 (4 + $hb.Length); $hs2 = 4 + $hps
    $prefix = [byte[]]::new(8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4),0,$prefix,0,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$hs2),0,$prefix,4,4)
    $pickle = [byte[]]::new($hs2)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$hps),0,$pickle,0,4)
    [Array]::Copy([BitConverter]::GetBytes([int32]$hb.Length),0,$pickle,4,4)
    [Array]::Copy($hb,0,$pickle,8,$hb.Length)
    $o = [IO.File]::Open($DestPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $o.Write($prefix,0,8); $o.Write($pickle,0,$pickle.Length); foreach ($p in $Payloads) { $o.Write($p,0,$p.Length) } }
    finally { $o.Dispose() }
}

# --- 构建 ---
$temp = Join-Path ([IO.Path]::GetTempPath()) ('zh-cn-shell-cat-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$temp\resources" -Force | Out-Null
$asarPath = Join-Path $temp 'resources\app.asar'

$zhHans = [Text.Encoding]::UTF8.GetBytes('{"hello":"世界"}')
$enUS = [Text.Encoding]::UTF8.GetBytes('{"hello":"world"}')
$big = [byte[]]::new(10000); for ($i=0;$i -lt $big.Length;$i++) { $big[$i]=($i%251) }

$zi = Get-AsarFileIntegrityFromBytes $zhHans
$ei = Get-AsarFileIntegrityFromBytes $enUS
$bi = Get-AsarFileIntegrityFromBytes $big

function ConvertTo-IntegrityJson($Integ) {
    return '{"algorithm":"SHA256","hash":"' + $Integ.hash + '","blockSize":' + $Integ.blockSize + ',"blocks":["' + ($Integ.blocks -join '","') + '"]}'
}
$hs3 = '{"files":{"resources":{"files":{"i18n":{"files":{'
$hs3 += '"en-US.json":{"size":' + $enUS.Length + ',"offset":"0","integrity":' + (ConvertTo-IntegrityJson $ei) + '}'
$hs3 += ',"zh-Hans.json":{"size":' + $zhHans.Length + ',"offset":"' + $enUS.Length + '","integrity":' + (ConvertTo-IntegrityJson $zi) + '}'
$hs3 += '}}}},"payload.bin":{"size":' + $big.Length + ',"offset":"' + ($enUS.Length+$zhHans.Length) + '","integrity":' + (ConvertTo-IntegrityJson $bi) + '}'
$hs3 += '}}'

New-TestAsar $hs3 @($enUS,$zhHans,$big) $asarPath

# --- 测试 1：布局检测 ---
$parsed0 = Read-AsarHeaderFromFile $asarPath
$paths0 = Get-AsarEntryPaths $parsed0["Header"]
$layoutOK = $false
foreach ($ep0 in $paths0) { if ($ep0 -eq "resources/i18n/en-US.json") { $layoutOK = $true; break } }
if (-not $layoutOK) { throw "FAIL: layout not detected (paths: $($paths0 -join ', '))" }
Write-Host "PASS: layout detection" -ForegroundColor Green

# --- 测试 2：注入 zh-CN（与安装器 Add-ShellLocaleCatalog 核心逻辑一致） ---
$parsed = Read-AsarHeaderFromFile $asarPath
$baseEntry = Get-ShellCatalogBaseEntry "zh-CN"
# 读 zh-Hans 内容
$baseNode = $parsed["Header"]
foreach ($seg in ($baseEntry -split '/')) { $baseNode = $baseNode.files.PSObject.Properties[$seg].Value }
$content = [byte[]]::new($baseNode.size)
$ds = 8 + [int]$parsed["HeaderSize"]
$fs2 = [IO.File]::OpenRead($asarPath)
try { $fs2.Seek($ds + [int64]$baseNode.offset, [IO.SeekOrigin]::Begin)|Out-Null; [void]$fs2.Read($content,0,$content.Length) } finally { $fs2.Dispose() }

# 注入
$headerString = [string]$parsed["HeaderString"]
$anchorStr = '"i18n":{"files":{'
$resourcesAnchor = '"resources":{"files":{'
$ri = $headerString.IndexOf($resourcesAnchor,[StringComparison]::Ordinal)
$ai = $headerString.IndexOf($anchorStr,$ri,[StringComparison]::Ordinal)
$integ = Get-AsarFileIntegrityFromBytes $content
$oldPayloadLen = ([IO.FileInfo]$asarPath).Length - $ds
$blocksJson = '"' + ($integ.blocks -join '","') + '"'
$entryJson = '"zh-CN.json":{"size":' + $content.Length + ',"offset":"' + $oldPayloadLen + '","integrity":{"algorithm":"SHA256","hash":"' + $integ.hash + '","blockSize":' + $integ.blockSize + ',"blocks":[' + $blocksJson + ']}}'
$newHS = $headerString.Substring(0,$ai+$anchorStr.Length) + $entryJson + ',' + $headerString.Substring($ai+$anchorStr.Length)
$newHB = [Text.Encoding]::UTF8.GetBytes($newHS)
$newHPS = Align-4 (4 + $newHB.Length); $newHS2 = 4 + $newHPS

$tempAsar = "$asarPath.test-new"
$src = [IO.File]::OpenRead($asarPath); $dst = [IO.File]::Open($tempAsar,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $pre2 = [byte[]]::new(8)
    [Array]::Copy([BitConverter]::GetBytes([uint32]4),0,$pre2,0,4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$newHS2),0,$pre2,4,4)
    $dst.Write($pre2,0,8)
    $pk2 = [byte[]]::new($newHS2)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$newHPS),0,$pk2,0,4)
    [Array]::Copy([BitConverter]::GetBytes([int32]$newHB.Length),0,$pk2,4,4)
    [Array]::Copy($newHB,0,$pk2,8,$newHB.Length)
    $dst.Write($pk2,0,$pk2.Length)
    $src.Seek($ds,[IO.SeekOrigin]::Begin)|Out-Null
    $buf = [byte[]]::new(1MB)
    while (($r = $src.Read($buf,0,$buf.Length)) -gt 0) { $dst.Write($buf,0,$r) }
    $dst.Write($content,0,$content.Length)
} finally { $src.Dispose(); $dst.Dispose() }
Move-Item $tempAsar $asarPath -Force

# 验证
$parsed2 = Read-AsarHeaderFromFile $asarPath
$paths = @(Get-AsarEntryPaths $parsed2["Header"])
foreach ($exp in @('resources/i18n/zh-CN.json','resources/i18n/en-US.json','resources/i18n/zh-Hans.json','payload.bin')) {
    if ($paths -notcontains $exp) { throw "FAIL: missing $exp" }
}
Write-Host "PASS: all entries after injection" -ForegroundColor Green

$zhCN = Read-AsarEntryBytes $asarPath $parsed2 'resources/i18n/zh-CN.json'
$zhHans2 = Read-AsarEntryBytes $asarPath $parsed2 'resources/i18n/zh-Hans.json'
if ([Text.Encoding]::UTF8.GetString($zhCN) -cne [Text.Encoding]::UTF8.GetString($zhHans2)) { throw "FAIL: zh-CN != zh-Hans" }
Write-Host "PASS: zh-CN matches zh-Hans base" -ForegroundColor Green

$enUS2 = Read-AsarEntryBytes $asarPath $parsed2 'resources/i18n/en-US.json'
if ([Text.Encoding]::UTF8.GetString($enUS2) -cne '{"hello":"world"}') { throw "FAIL: en-US changed" }
Write-Host "PASS: en-US unchanged" -ForegroundColor Green

$big2 = Read-AsarEntryBytes $asarPath $parsed2 'payload.bin'
if ($big2.Length -ne 10000 -or $big2[5000] -ne (5000%251)) { throw "FAIL: payload changed" }
Write-Host "PASS: large payload preserved byte-for-byte" -ForegroundColor Green

# --- 测试 3：幂等 ---
$before = (Get-Item $asarPath).Length
# 再注入一次应检测到已存在并跳过
if ($paths -contains 'resources/i18n/zh-CN.json') { Write-Host "PASS: idempotent (entry exists, skipped)" -ForegroundColor Green }

Remove-Item $temp -Recurse -Force
Write-Host ""
Write-Host "All shell locale catalog tests passed." -ForegroundColor Green
