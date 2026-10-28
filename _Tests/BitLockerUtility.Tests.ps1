#Requires -Version 5.1
<#
.SYNOPSIS
    Pester & AST verification tests for BitLockerUtility (BLU-01 through BLU-05).
    Compatible with Pester 3.4+ (inbox Windows PowerShell 5.1), Pester 5.x, and direct execution.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:MainScriptPath = Join-Path $script:RepoRoot 'Scripts\BitLockerUtility.ps1'
$script:MirrorScriptPath = Join-Path $script:RepoRoot 'BuiltWinPE\Add-Scripts\BitLockerUtility.ps1'
$script:BatchBuilderPath = Join-Path $script:RepoRoot 'BuiltWinPE\WinPEBuilder.bat'
$script:LegacyCmdPath = Join-Path $script:RepoRoot "Scripts\Previus version 2.0 - DON'T USE\BitLockerUtilities 2.0.cmd"

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    $script:DirectPassed = 0
    $script:DirectFailed = 0
    function Describe ([string]$Name, [scriptblock]$Fixture) {
        Write-Host "`n=== $Name ===" -ForegroundColor Cyan
        & $Fixture
        Write-Host "`nSummary: $($script:DirectPassed) passed, $($script:DirectFailed) failed." -ForegroundColor Cyan
        if ($script:DirectFailed -gt 0) { throw "$($script:DirectFailed) test(s) failed." }
    }
    function Context ([string]$Name, [scriptblock]$Fixture) {
        Write-Host "  [$Name]" -ForegroundColor Yellow
        & $Fixture
    }
    function It ([string]$Name, [scriptblock]$Test) {
        try {
            & $Test
            Write-Host "    [PASS] $Name" -ForegroundColor Green
            $script:DirectPassed++
        }
        catch {
            Write-Host "    [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
            $script:DirectFailed++
        }
    }
}

Describe 'BitLockerUtility Hardening Suite (BLU-01 .. BLU-05)' {

    $tokens = $null
    $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:MainScriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $script:ParseErrors = $parseErrors
    $script:MainContent = Get-Content -LiteralPath $script:MainScriptPath -Raw -Encoding UTF8
    $script:MirrorContent = Get-Content -LiteralPath $script:MirrorScriptPath -Raw -Encoding UTF8
    $script:BatchContent = Get-Content -LiteralPath $script:BatchBuilderPath -Raw -Encoding UTF8

    Context 'AST Syntax & Mirror Parity' {
        It 'parses Scripts\BitLockerUtility.ps1 with zero PowerShell AST syntax errors' {
            if ($script:ParseErrors.Count -ne 0) {
                throw "Expected 0 parse errors, got $($script:ParseErrors.Count): $($script:ParseErrors | Out-String)"
            }
        }

        It 'keeps Scripts\BitLockerUtility.ps1 and BuiltWinPE\Add-Scripts\BitLockerUtility.ps1 identical' {
            $mainHash = (Get-FileHash -LiteralPath $script:MainScriptPath -Algorithm SHA256).Hash
            $mirrorHash = (Get-FileHash -LiteralPath $script:MirrorScriptPath -Algorithm SHA256).Hash
            if ($mainHash -ne $mirrorHash) {
                throw "Hash mismatch between Scripts\BitLockerUtility.ps1 ($mainHash) and BuiltWinPE\Add-Scripts\BitLockerUtility.ps1 ($mirrorHash)"
            }
        }
    }

    Context 'BLU-01: BuiltWinPE\WinPEBuilder.bat Path Quoting & Unmount Error Handling' {
        It 'quotes %winpe_root%, %drivers_path%, %scripts_path%, and %ISO_Path% in WinPEBuilder.bat' {
            foreach ($expected in @(
                    'if exist "%winpe_root%" rd /q /s "%winpe_root%"',
                    'call copype.cmd amd64 "%winpe_root%"',
                    '/driver:"%drivers_path%"',
                    'xcopy "%scripts_path%" "%winpe_root%\mount\Windows\System32"',
                    'Makewinpemedia /iso /f "%winpe_root%" "%ISO_Path%\BitLockerUtility.iso"'
                )) {
                if (-not $script:BatchContent.Contains($expected)) {
                    throw "Missing expected quoted command in WinPEBuilder.bat: $expected"
                }
            }
        }

        It 'checks %ERRORLEVEL% after Dism /Unmount-Image before proceeding' {
            if ($script:BatchContent -notmatch 'Dism /Unmount-Image[\s\S]*?if %ERRORLEVEL% NEQ 0') {
                throw 'Missing %ERRORLEVEL% check after Dism /Unmount-Image in WinPEBuilder.bat'
            }
        }
    }

    Context 'BLU-02: BitLocker Recovery Key Format Validation & Memory Cleanup' {
        It 'validates 48-digit BitLocker recovery password with ^\d{6}(-\d{6}){7}$ and clears $Key in finally' {
            if (-not $script:MainContent.Contains('^\d{6}(-\d{6}){7}$')) {
                throw 'Missing strict recovery password regex ^\d{6}(-\d{6}){7}$'
            }
            if ($script:MainContent -notmatch 'finally\s*\{[\s\S]*?\$Key\s*=\s*\$null') {
                throw 'Missing $Key = $null in finally block'
            }
            if ($script:MainContent -notmatch 'finally\s*\{[\s\S]*?\$manageoutput\s*=\s*\$null') {
                throw 'Missing $manageoutput = $null in finally block'
            }
        }
    }

    Context 'BLU-03: Clean Exit Without Killing *cmd* Processes' {
        It 'does not invoke Get-Process -Name *cmd* | Stop-Process' {
            if ($script:MainContent -match 'Stop-Process' -or $script:MainContent -match '\*cmd\*') {
                throw 'BitLockerUtility.ps1 must not kill *cmd* processes on exit'
            }
        }
    }

    Context 'BLU-04: Safe Decryption Progress Loop' {
        It 'searches all lines of $DecrypProgress for Fully Decrypted and 0\.0% without fragile fixed-index until conditions' {
            if (-not $script:MainContent.Contains("(`$DecrypProgress -match 'Fully Decrypted') -and (`$DecrypProgress -match '0\.0%')")) {
                throw 'Missing full-array $DecrypProgress match condition'
            }
            if ($script:MainContent.Contains('$DecrypProgress[8] -match')) {
                throw 'Fragile fixed-index $DecrypProgress[8] check must be removed'
            }
        }
    }

    Context 'BLU-05: Drive Letter Normalization, WindowSize.Height Typo Fix, & Legacy Script Removal' {
        It 'uses exact drive letter comparison ($DriveLetter -eq ($_.DriveLetter + ":")) and normalized $cleanLetter' {
            if (-not $script:MainContent.Contains('$DriveLetter -eq ($_.DriveLetter + '':'')')) {
                throw 'Missing exact $DriveLetter -eq ($_.DriveLetter + ":") comparison'
            }
            if (-not $script:MainContent.Contains('$cleanLetter = $EnterDriveLetter.Trim().TrimEnd('':'').ToUpperInvariant()')) {
                throw 'Missing $cleanLetter drive letter normalization'
            }
            if ($script:MainContent.Contains('-like $EnterDriveLetter')) {
                throw 'Wildcard -like $EnterDriveLetter comparison must be removed'
            }
        }

        It 'fixes the $host.ui.rawui.windowsize.height typo in Set-WindowSize' {
            if (-not $script:MainContent.Contains('$host.ui.rawui.windowsize.height')) {
                throw 'Missing corrected $host.ui.rawui.windowsize.height reference'
            }
            if ($script:MainContent.Contains('heigth')) {
                throw 'Typo heigth still present in BitLockerUtility.ps1'
            }
        }

        It 'removes the vulnerable legacy BitLockerUtilities 2.0.cmd script' {
            if (Test-Path -LiteralPath $script:LegacyCmdPath) {
                throw "Legacy script still exists at $script:LegacyCmdPath"
            }
        }
    }
}
