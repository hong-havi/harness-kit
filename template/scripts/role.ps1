#!/usr/bin/env pwsh
# 역할 세션 실행기: 작업 점유 → worktree 준비 → 역할 주입 → Claude Code 실행
# 사용: .\scripts\role.ps1 <planner|implementer|reviewer|qa> [작업ID]
#   작업ID 생략 시 해당 역할의 다음 작업을 자동 선택 (planner 는 없어도 실행)
#   $env:HARNESS_DRY_RUN='1'  → 아무것도 바꾸지 않고 실행할 명령만 출력

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Role = '',
    [Parameter(Position = 1)] [string] $Id = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Die { param([string] $Msg)
    [Console]::Error.WriteLine("✗ $Msg")
    exit 1
}

if ($Role -notin @('planner', 'implementer', 'reviewer', 'qa')) {
    Die '사용법: role.ps1 <planner|implementer|reviewer|qa> [작업ID]'
}

$gitCommonDirRaw = & git rev-parse --path-format=absolute --git-common-dir 2>$null
if (-not $gitCommonDirRaw) { Die 'git 저장소가 아닙니다' }
$MAIN = (Resolve-Path (Split-Path -Parent ($gitCommonDirRaw.Trim()))).Path
$TASK = Join-Path $MAIN 'scripts\task.ps1'
$DRY = $env:HARNESS_DRY_RUN

$roleFile = Join-Path $MAIN "roles\$Role.md"
if (-not (Test-Path -LiteralPath $roleFile)) { Die "역할 정의 없음: $roleFile" }

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) { $claudeCmd = Get-Command claude.cmd -ErrorAction SilentlyContinue }
if (-not $claudeCmd -and -not $DRY) { Die 'claude CLI 를 찾을 수 없습니다' }

if (-not $Id) {
    $Id = (& $TASK next $Role 2>$null)
    if ($Id) { $Id = $Id.Trim() }
    if (-not $Id -and $Role -ne 'planner') {
        Die "$Role 가 처리할 작업이 없습니다 ('task.ps1 list' 로 확인)"
    }
}

$dir = $MAIN
if ($Role -ne 'planner') {
    $branch = (& $TASK get $Id branch).Trim()
    $base = (& $TASK get $Id base).Trim()
    $wt = (& $TASK worktree $Id).Trim()
    if (-not $wt) {
        if ($Role -ne 'implementer') { Die "$Id 의 worktree 가 없습니다. implementer 단계가 먼저 필요합니다" }
        $wt = Join-Path (Split-Path -Parent $MAIN) ((Split-Path -Leaf $MAIN) + "-$Id")
        $hasBranch = $false
        & git -C $MAIN show-ref --verify --quiet "refs/heads/$branch"
        if ($LASTEXITCODE -eq 0) { $hasBranch = $true }
        if ($DRY) {
            Write-Output "[dry-run] git worktree add $wt ($branch, base: $base)"
        }
        elseif ($hasBranch) {
            & git -C $MAIN worktree add $wt $branch
            if ($LASTEXITCODE -ne 0) { Die "worktree 생성 실패" }
        }
        else {
            & git -C $MAIN worktree add -b $branch $wt $base
            if ($LASTEXITCODE -ne 0) { Die "worktree 생성 실패" }
        }
    }
    $dir = $wt
}

if ($Id) {
    if ($DRY) { Write-Output "[dry-run] task.ps1 claim $Id $Role" }
    else {
        & $TASK claim $Id $Role
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

$env:HARNESS_ROLE = $Role
$env:HARNESS_TASK = $Id
$env:HARNESS_MAIN = $MAIN

$systemPrompt = [System.IO.File]::ReadAllText($roleFile)
$claudeArgs = @('--append-system-prompt', $systemPrompt)
if ($dir -ne $MAIN) {
    $claudeArgs += @('--add-dir', (Join-Path $MAIN 'work'))
}
$claudeArgs += "/harness:$Role $Id"

if ($DRY) {
    Write-Output "[dry-run] Set-Location $dir"
    Write-Output "[dry-run] HARNESS_ROLE=$Role HARNESS_TASK=$Id claude --append-system-prompt <roles/$Role.md> $(($claudeArgs[2..($claudeArgs.Count-1)]) -join ' ')"
    exit 0
}

Set-Location $dir
& $claudeCmd.Source @claudeArgs
exit $LASTEXITCODE
