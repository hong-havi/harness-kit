#!/usr/bin/env pwsh
# PreToolUse 훅: 역할별 파일 쓰기 범위를 강제한다.
# HARNESS_ROLE 이 없으면(사람이 직접 연 세션) 아무것도 막지 않는다.
# 한계: Bash/PowerShell 명령을 통한 파일 쓰기는 여기서 막지 못한다.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$role = $env:HARNESS_ROLE
if (-not $role) { exit 0 }

$inputRaw = [Console]::In.ReadToEnd()
if (-not $inputRaw) { exit 0 }

try {
    $hookInput = $inputRaw | ConvertFrom-Json -ErrorAction Stop
} catch { exit 0 }

$path = $null
if ($hookInput.PSObject.Properties['tool_input']) {
    $ti = $hookInput.tool_input
    foreach ($key in @('file_path', 'notebook_path')) {
        if ($ti.PSObject.Properties[$key]) {
            $path = [string]$ti.$key
            if ($path) { break }
        }
    }
}
if (-not $path) { exit 0 }

$projRaw = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
$proj = (Resolve-Path -LiteralPath $projRaw).Path
$main = if ($env:HARNESS_MAIN) { (Resolve-Path -LiteralPath $env:HARNESS_MAIN).Path } else { $proj }

if (-not [System.IO.Path]::IsPathRooted($path)) {
    $path = Join-Path $proj $path
}
# 상위 존재 디렉터리 기준으로 정규화 (파일이 아직 없을 수 있음)
$dir = Split-Path -Parent $path
while ($dir -and -not (Test-Path -LiteralPath $dir)) { $dir = Split-Path -Parent $dir }
if ($dir) {
    $resolvedDir = (Resolve-Path -LiteralPath $dir).Path
    $leaf = $path.Substring($dir.Length)
    $P = ($resolvedDir + $leaf)
} else {
    $P = $path
}

function Block { param([string] $Reason)
    [Console]::Error.WriteLine("[$role] 쓰기 차단: $P — $Reason")
    exit 2
}

function Under { param([string] $Child, [string] $Parent)
    if (-not $Parent) { return $false }
    $p = $Parent.TrimEnd('/','\') + [System.IO.Path]::DirectorySeparatorChar
    return $Child.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase) -or ($Child -eq $Parent)
}

# 하네스 자체는 사람만 수정
$harnessPaths = @(
    '.claude', 'roles', 'scripts\hooks',
    'scripts\task.sh', 'scripts\task.ps1',
    'scripts\role.sh', 'scripts\role.ps1',
    'scripts\check.sh', 'scripts\check.ps1',
    'scripts\check.conf', 'work\templates'
)
foreach ($root in @($main, $proj)) {
    foreach ($h in $harnessPaths) {
        $hp = Join-Path $root $h
        if ($P -ieq $hp -or (Under $P $hp)) {
            Block "하네스 파일은 사람만 수정합니다. 필요하면 인수인계의 '하네스 개선 제안'에 적으세요"
        }
    }
}

$mainWork = Join-Path $main 'work'
$mainHandoffs = Join-Path $mainWork 'handoffs'
$mainTasks = Join-Path $mainWork 'tasks'

if (Under $P $mainHandoffs) { exit 0 }
if (Under $P $mainTasks) {
    if ($role -eq 'planner') { exit 0 }
    Block '작업 파일은 planner 만 편집하며, 상태 변경은 .\scripts\task.ps1 로 합니다'
}

$projDocs = Join-Path $main 'docs'
switch ($role) {
    'planner' {
        if (Under $P $projDocs) { exit 0 }
        Block 'planner 는 docs/ 와 work/ 만 수정합니다. 코드는 implementer 몫입니다'
    }
    'implementer' {
        $projWork = Join-Path $proj 'work'
        if (Under $P $projWork) { Block '작업 상태는 메인 체크아웃의 work/ 에만 둡니다' }
        if (Under $P $proj) { exit 0 }
        Block "현재 worktree($proj) 밖은 수정할 수 없습니다"
    }
    { $_ -in @('reviewer', 'qa') } {
        Block "$role 는 인수인계 파일(work/handoffs/)만 작성합니다. 수정 사항은 지적으로 남기세요"
    }
}
exit 0
