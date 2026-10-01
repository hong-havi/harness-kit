#!/usr/bin/env pwsh
# Stop 훅: 코드 변경이 있으면 check 를 통과해야 세션을 끝낼 수 있다.
# 한 번 차단된 뒤(stop_hook_active) 에는 무한 루프 방지를 위해 통과시킨다.
# 최종 방어선은 task.ps1 move 의 게이트다.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
if ($env:HARNESS_ROLE -in @('planner', 'reviewer', 'qa')) { exit 0 }

$inputRaw = [Console]::In.ReadToEnd()
if ($inputRaw) {
    try {
        $input = $inputRaw | ConvertFrom-Json -ErrorAction Stop
        if ($input.PSObject.Properties['stop_hook_active'] -and $input.stop_hook_active) { exit 0 }
    } catch { }
}

$proj = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
if (-not (Test-Path -LiteralPath $proj)) { exit 0 }
Set-Location $proj

$dirty = & git status --porcelain -- . ':(exclude)work' ':(exclude)docs' 2>$null
if (-not $dirty) { exit 0 }

$checkScript = Join-Path $proj 'scripts\check.ps1'
if (-not (Test-Path -LiteralPath $checkScript)) { exit 0 }

$output = & $checkScript 2>&1
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('check 가 실패했습니다. 수정한 뒤 종료하세요:')
    $tail = @($output) | Select-Object -Last 60
    foreach ($line in $tail) { [Console]::Error.WriteLine($line) }
    exit 2
}
exit 0
