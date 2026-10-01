#!/usr/bin/env pwsh
# 이 프로젝트의 단일 검증 진입점. 에이전트, Stop 훅, task.ps1 게이트가 모두 이것을 호출한다.
# 명령은 scripts/check.conf 에서 설정한다 (bash 와 공용 포맷: KEY="VALUE").

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)

$confPath = Join-Path $PSScriptRoot 'check.conf'
if (-not (Test-Path -LiteralPath $confPath)) {
    [Console]::Error.WriteLine('✗ scripts/check.conf 가 없습니다')
    exit 1
}

$conf = @{ LINT_CMD = ''; TYPECHECK_CMD = ''; TEST_CMD = '' }
foreach ($line in Get-Content -LiteralPath $confPath) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*([A-Z_]+)\s*=\s*"(.*)"\s*$') {
        $conf[$matches[1]] = $matches[2]
    }
}

$fail = 0
$ran = 0
function Invoke-Step { param([string] $Name, [string] $Cmd)
    if (-not $Cmd) { return }
    $script:ran++
    Write-Output "▶ ${Name}: $Cmd"
    # PowerShell 과 Git Bash 양쪽을 지원하도록 cmd.exe 로 위임하지 않고 pwsh 직접 실행.
    # 사용자가 check.conf 에 PowerShell 로 해석 가능한 명령을 넣는다.
    Invoke-Expression $Cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Output "✗ $Name 실패"
        $script:fail = 1
    }
}

Invoke-Step 'lint' $conf['LINT_CMD']
Invoke-Step 'typecheck' $conf['TYPECHECK_CMD']
Invoke-Step 'test' $conf['TEST_CMD']

if ($ran -eq 0) {
    [Console]::Error.WriteLine('✗ 검증 명령이 하나도 설정되지 않았습니다. scripts/check.conf 를 설정하세요.')
    exit 1
}
if ($fail -eq 0) { Write-Output '✓ check 통과' }
exit $fail
