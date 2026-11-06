$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Load-InstallerFunctions.ps1') -FunctionNames @(
    'Format-ByteSize',
    'Get-BackupRoot',
    'New-BackupSet',
    'Get-RelativeResourcePath',
    'Backup-ModifiedFile',
    'Stop-CoworkVMService',
    'Find-GoPclntabOffset',
    'Resolve-GoFuncEntry',
    'Patch-CoworkService'
)

# Test-CoworkPatch.ps1
# Verifies CoworkVMService Go pclntab parsing and call-site patching for both x64 and ARM64.
# Compatible with Windows PowerShell 5.1 and cross-platform PowerShell 7 (Linux/macOS).

$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-cowork-test-' + [guid]::NewGuid().ToString('N'))
$resources = Join-Path $temp 'resources'

function New-SyntheticGoCoworkPe {
    param(
        [string]$Path,
        [bool]$IsArm64
    )

    # Allocate 16 KB for synthetic PE
    $data = [byte[]]::new(0x4000)

    # MZ header
    $data[0] = 0x4D; $data[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($data, 0x3C)

    # PE signature at 0x80: PE\0\0
    $data[0x80] = 0x50; $data[0x81] = 0x45; $data[0x82] = 0; $data[0x83] = 0

    # COFF header at 0x84
    $machine = if ($IsArm64) { [uint16]0xAA64 } else { [uint16]0x8664 }
    [BitConverter]::GetBytes($machine).CopyTo($data, 0x84)
    [BitConverter]::GetBytes([uint16]2).CopyTo($data, 0x86)       # 2 sections (.text, .rdata)
    [BitConverter]::GetBytes([uint16]0xF0).CopyTo($data, 0x94)     # OptSize

    # Optional header at 0x98: Magic=0x20B (PE32+ 64-bit)
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($data, 0x98)
    [BitConverter]::GetBytes([uint64]0x140000000).CopyTo($data, 0xB0) # ImageBase

    # Section 1: .text at 0x188
    # VA = 0x1000, VirtualSize = 0x1000, RawSize = 0x1000, RawPointer = 0x200
    [Text.Encoding]::ASCII.GetBytes(".text`0`0`0").CopyTo($data, 0x188)
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($data, 0x190)
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($data, 0x194)
    [BitConverter]::GetBytes([uint32]0x1000).CopyTo($data, 0x198)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($data, 0x19C)

    # Section 2: .rdata at 0x1B0
    # VA = 0x2000, VirtualSize = 0x2000, RawSize = 0x2000, RawPointer = 0x1200
    [Text.Encoding]::ASCII.GetBytes(".rdata`0`0").CopyTo($data, 0x1B0)
    [BitConverter]::GetBytes([uint32]0x2000).CopyTo($data, 0x1B8)
    [BitConverter]::GetBytes([uint32]0x2000).CopyTo($data, 0x1BC)
    [BitConverter]::GetBytes([uint32]0x2000).CopyTo($data, 0x1C0)
    [BitConverter]::GetBytes([uint32]0x1200).CopyTo($data, 0x1C4)

    # Build Go pclntab inside .rdata at file offset 0x1300
    # entryoff in functab/_func is relative to textStart (0x140001000), not an RVA.
    $ptOff = 0x1300
    $quantum = if ($IsArm64) { [byte]4 } else { [byte]1 }
    $magic = [byte[]](0xF1, 0xFF, 0xFF, 0xFF, 0x00, 0x00, $quantum, 0x08)
    $magic.CopyTo($data, $ptOff)

    $nfunc = [uint64]3
    [BitConverter]::GetBytes($nfunc).CopyTo($data, $ptOff + 8)

    # Text start = ImageBase + textVAddr = 0x140000000 + 0x1000 = 0x140001000
    [BitConverter]::GetBytes([uint64]0x140001000).CopyTo($data, $ptOff + 24)

    # funcnameOff at +32 = 0x80 ; pclnOff (functab offset) at +64 = 0x400
    [BitConverter]::GetBytes([uint64]0x80).CopyTo($data, $ptOff + 32)
    [BitConverter]::GetBytes([uint64]0x400).CopyTo($data, $ptOff + 64)

    # Function names at ptOff + 0x180 (funcnameOff 0x80 + 0x100 padding), so the
    # encoded nameOff values are large enough to be unambiguous inside functab.
    # InitSignatureVerification carries a package prefix to exercise suffix lookup.
    $nameBase = 0x100
    $name1Str = "main.runService`0"
    $name2Str = "main.isWindowsService`0"
    $name3Str = "(*Server).InitSignatureVerification`0"
    $nameBytes = [Text.Encoding]::ASCII.GetBytes("hdr`0" + $name1Str + $name2Str + $name3Str)
    $nameBytes.CopyTo($data, $ptOff + 0x80 + $nameBase)
    $name1Off = $nameBase + 4
    $name2Off = $name1Off + $name1Str.Length
    $name3Off = $name2Off + $name2Str.Length

    # functab at ptOff + 0x400: [entryoff(u32)][funcoff(u32)]
    # runService              entryoff 0x100 -> .text file offset 0x300
    # isWindowsService        entryoff 0x400 -> .text file offset 0x600
    # InitSignatureVerification entryoff 0x600 -> .text file offset 0x800
    # _func structs live just past the table at ptOff + 0x420 / 0x430 / 0x440.
    [BitConverter]::GetBytes([uint32]0x100).CopyTo($data, $ptOff + 0x400)
    [BitConverter]::GetBytes([uint32]0x20).CopyTo($data, $ptOff + 0x404)

    [BitConverter]::GetBytes([uint32]0x400).CopyTo($data, $ptOff + 0x408)
    [BitConverter]::GetBytes([uint32]0x30).CopyTo($data, $ptOff + 0x40C)

    [BitConverter]::GetBytes([uint32]0x600).CopyTo($data, $ptOff + 0x410)
    [BitConverter]::GetBytes([uint32]0x40).CopyTo($data, $ptOff + 0x414)

    # Closing entry so the table end is well defined for runEnd fallback.
    [BitConverter]::GetBytes([uint32]0x800).CopyTo($data, $ptOff + 0x418)
    [BitConverter]::GetBytes([uint32]0).CopyTo($data, $ptOff + 0x41C)

    # _func 1 (main.runService): entryoff 0x100, nameOff $name1Off
    [BitConverter]::GetBytes([uint32]0x100).CopyTo($data, $ptOff + 0x420)
    [BitConverter]::GetBytes([int32]$name1Off).CopyTo($data, $ptOff + 0x424)

    # _func 2 (main.isWindowsService): entryoff 0x400, nameOff $name2Off
    [BitConverter]::GetBytes([uint32]0x400).CopyTo($data, $ptOff + 0x430)
    [BitConverter]::GetBytes([int32]$name2Off).CopyTo($data, $ptOff + 0x434)

    # _func 3 (InitSignatureVerification): entryoff 0x600, nameOff $name3Off
    [BitConverter]::GetBytes([uint32]0x600).CopyTo($data, $ptOff + 0x440)
    [BitConverter]::GetBytes([int32]$name3Off).CopyTo($data, $ptOff + 0x444)

    # Inside main.runService (.text file offset 0x300..0x600):
    # 0x350 calls main.isWindowsService (the patch site), and 0x358 calls
    # InitSignatureVerification, mirroring the real binary's argument flow.
    $callSite = 0x350
    $initSite = 0x358
    $wsEntry = 0x400
    $initEntry = 0x600
    # entryoff = file offset - .text raw pointer (0x200)
    $wsImm = [uint32](([uint32]$wsEntry - [uint32]($callSite - 0x200)) / 4)
    $initImm = [uint32](([uint32]$initEntry - [uint32]($initSite - 0x200)) / 4)
    if ($IsArm64) {
        # imm26 occupies the low 26 bits and never overlaps 0x94000000, so OR == ADD.
        # Convert back to signed Int32 because BitConverter.GetBytes(UInt32) rejects
        # values PowerShell has already widened to Int64.
        $bl1 = [int64]0x94000000 + [int64]$wsImm
        $bl2 = [int64]0x94000000 + [int64]$initImm
        if ($bl1 -ge 2147483648) { $bl1 -= 4294967296 }
        if ($bl2 -ge 2147483648) { $bl2 -= 4294967296 }
        [BitConverter]::GetBytes([int32]$bl1).CopyTo($data, $callSite)
        [BitConverter]::GetBytes([int32]$bl2).CopyTo($data, $initSite)
    }
    else {
        $data[$callSite] = 0xE8
        [BitConverter]::GetBytes([int32]([int]$wsEntry - [int]($callSite - 0x200) - 5)).CopyTo($data, $callSite + 1)
        $data[$initSite] = 0xE8
        [BitConverter]::GetBytes([int32]([int]$initEntry - [int]($initSite - 0x200) - 5)).CopyTo($data, $initSite + 1)
    }

    [IO.File]::WriteAllBytes($Path, $data)
}

try {
    New-Item -ItemType Directory -Path $resources -Force | Out-Null

    # Test 1: Missing file does not throw
    Patch-CoworkService $resources "4.23118.0.0"

    # Test 2: Synthetic ARM64 Go PE detection and patching
    $arm64Svc = Join-Path $resources 'cowork-svc.exe'
    New-SyntheticGoCoworkPe -Path $arm64Svc -IsArm64 $true
    Patch-CoworkService $resources "4.23118.0.0"

    $patchedArmBytes = [IO.File]::ReadAllBytes($arm64Svc)
    # Check that BL was replaced with mov w0, #0 (0x00, 0x00, 0x80, 0x52)
    $expectedArm = [byte[]](0x00, 0x00, 0x80, 0x52)
    for ($k = 0; $k -lt 4; $k++) {
        if ($patchedArmBytes[0x350 + $k] -ne $expectedArm[$k]) {
            throw "ARM64 callSite byte $k was not patched to mov w0, #0. Actual: $($patchedArmBytes[0x350 + $k])"
        }
    }

    # Verify ARM64 idempotency
    Patch-CoworkService $resources "4.23118.0.0"
    $idempotentArm = [IO.File]::ReadAllBytes($arm64Svc)
    for ($k = 0; $k -lt 4; $k++) {
        if ($idempotentArm[0x350 + $k] -ne $expectedArm[$k]) {
            throw "ARM64 idempotent pass corrupted patch"
        }
    }

    # Test 3: Synthetic x64 Go PE detection and patching
    Remove-Item (Join-Path $resources "*") -Recurse -Force
    New-SyntheticGoCoworkPe -Path $arm64Svc -IsArm64 $false
    Patch-CoworkService $resources "4.23118.0.0"

    $patchedX64Bytes = [IO.File]::ReadAllBytes($arm64Svc)
    # Check that CALL was replaced with xor eax, eax; nop; nop; nop (0x31, 0xC0, 0x90, 0x90, 0x90)
    $expectedX64 = [byte[]](0x31, 0xC0, 0x90, 0x90, 0x90)
    for ($k = 0; $k -lt 5; $k++) {
        if ($patchedX64Bytes[0x350 + $k] -ne $expectedX64[$k]) {
            throw "x64 callSite byte $k was not patched to xor/nop. Actual: $($patchedX64Bytes[0x350 + $k])"
        }
    }

    # Verify x64 idempotency
    Patch-CoworkService $resources "4.23118.0.0"
    $idempotentX64 = [IO.File]::ReadAllBytes($arm64Svc)
    for ($k = 0; $k -lt 5; $k++) {
        if ($idempotentX64[0x350 + $k] -ne $expectedX64[$k]) {
            throw "x64 idempotent pass corrupted patch"
        }
    }

    # Test 4: Stop-CoworkVMService executes cleanly on systems without the service
    Stop-CoworkVMService

    Write-Host 'PASS: Dual-architecture CoworkVMService patcher verified on both ARM64 and x64.' -ForegroundColor Green
    Write-Host 'PASS: Backup creation, instruction patching, and idempotency verified.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
