#!/usr/bin/env pwsh
# 작업 상태 관리. 상태 전이는 반드시 이 스크립트로만 한다 (게이트가 여기 있다).
# 어느 worktree 에서 실행해도 항상 메인 체크아웃의 work/ 를 다룬다.

# 인자는 자동 변수 $args 로 받는다 (param 선언을 쓰면 positional binding 이 뒤 인자를 삼킨다)
$A = @($args)
$Command = if ($A.Count -gt 0) { [string]$A[0] } else { '' }
$Rest = if ($A.Count -gt 1) { @($A[1..($A.Count - 1)]) } else { @() }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Die { param([string] $Msg)
    [Console]::Error.WriteLine("✗ $Msg")
    exit 1
}

$gitCommonDirRaw = & git rev-parse --path-format=absolute --git-common-dir 2>$null
if (-not $gitCommonDirRaw) { Die 'git 저장소가 아닙니다' }
$script:MAIN = (Resolve-Path (Split-Path -Parent ($gitCommonDirRaw.Trim()))).Path
$script:WORK = Join-Path $MAIN 'work'
$script:TASKS = Join-Path $WORK 'tasks'
$script:HANDOFFS = Join-Path $WORK 'handoffs'
$script:TPL = Join-Path $WORK 'templates'
$script:MARKER = 'TODO: 작성을 마치면'

function Show-Usage {
    @'
사용법: task.ps1 <명령> [인자]
  new <제목>                 새 작업 생성 (todo)
  list [상태]                작업 목록
  next <역할>                역할이 처리할 다음 작업 ID 출력
  claim <ID> <역할>          작업 점유
  release <ID>               점유 해제
  show <ID>                  작업 내용과 관련 파일 경로
  get <ID> <필드>            frontmatter 필드 값
  handoff <ID> <역할>        인수인계 파일 생성(없으면) 후 경로 출력
  worktree <ID>              작업 worktree 경로 출력
  move <ID> <상태>           상태 전이 (게이트 검사)
상태 흐름: todo → planned → in_review → in_qa → done  (리뷰/QA 반려 시 changes_requested)
'@
}

function Write-Utf8Lf { param([string] $Path, [string[]] $Lines)
    $content = ($Lines -join "`n") + "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $enc)
}

function Read-Lines { param([string] $Path)
    $text = [System.IO.File]::ReadAllText($Path)
    # 마지막 개행에서 생기는 빈 요소 제거
    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
    if ($text.EndsWith("`r")) { $text = $text.Substring(0, $text.Length - 1) }
    return ,($text -split "`r?`n")
}

function Fm-Get { param([string] $File, [string] $Key)
    $lines = Read-Lines $File
    $inFm = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($i -eq 0 -and $line -eq '---') { $inFm = $true; continue }
        if ($inFm -and $line -eq '---') { break }
        if (-not $inFm) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 0) { continue }
        if ($line.Substring(0, $idx) -eq $Key) {
            return $line.Substring($idx + 1).Trim()
        }
    }
    return ''
}

function Fm-Set { param([string] $File, [string] $Key, [string] $Value)
    $lines = Read-Lines $File
    $inFm = $false
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($i -eq 0 -and $line -eq '---') { $inFm = $true; $out.Add($line); continue }
        if ($inFm -and $line -eq '---') { $inFm = $false; $out.Add($line); continue }
        if ($inFm) {
            $idx = $line.IndexOf(':')
            if ($idx -ge 0 -and $line.Substring(0, $idx) -eq $Key) {
                $out.Add("${Key}: $Value")
                continue
            }
        }
        $out.Add($line)
    }
    Write-Utf8Lf -Path $File -Lines $out
}

function Task-File { param([string] $Id)
    $f = Join-Path $TASKS "$Id.md"
    if (-not (Test-Path -LiteralPath $f)) { Die "작업 없음: $Id" }
    return $f
}

function Role-Inputs { param([string] $Role)
    switch ($Role) {
        'planner'     { return ,@('todo') }
        'implementer' { return ,@('planned', 'changes_requested') }
        'reviewer'    { return ,@('in_review') }
        'qa'          { return ,@('in_qa') }
        default       { Die "알 수 없는 역할: $Role (planner|implementer|reviewer|qa)" }
    }
}

function Handoff-Name { param([string] $Role)
    switch ($Role) {
        'planner'     { return '01-plan.md' }
        'implementer' { return '02-impl.md' }
        'reviewer'    { return '03-review.md' }
        'qa'          { return '04-qa.md' }
        default       { Die "알 수 없는 역할: $Role" }
    }
}

function Acquire-Lock {
    $lockPath = Join-Path $WORK '.lock'
    $i = 0
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
            return
        } catch {
            $i++
            if ($i -gt 50) {
                Die "잠금 획득 실패. 다른 프로세스가 없다면 $lockPath 을 삭제하세요"
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Release-Lock {
    $lockPath = Join-Path $WORK '.lock'
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Worktree-Of { param([string] $Branch)
    $raw = & git -C $MAIN worktree list --porcelain 2>$null
    if (-not $raw) { return '' }
    $current = ''
    foreach ($line in @($raw)) {
        if ($line -like 'worktree *') { $current = $line.Substring(9) }
        elseif ($line -eq "branch refs/heads/$Branch") { return $current }
    }
    return ''
}

function Verdict-Of { param([string] $File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $lines = Read-Lines $File
    $last = ''
    foreach ($line in $lines) {
        if ($line -match '^verdict:') { $last = $line }
    }
    if (-not $last) { return '' }
    $result = ($last -replace '^verdict:\s*', '') -replace '\s+$', ''
    return $result
}

function Rel-Path { param([string] $Path)
    $prefix = $MAIN
    if ($Path.StartsWith($prefix)) {
        return $Path.Substring($prefix.Length).TrimStart('/','\')
    }
    return $Path
}

function Require-Done { param([string] $File)
    if (-not (Test-Path -LiteralPath $File) -or ((Get-Item -LiteralPath $File).Length -eq 0)) {
        Die "인수인계 파일이 없습니다: $(Rel-Path $File)  ('task.ps1 handoff' 로 생성 후 작성)"
    }
    $content = [System.IO.File]::ReadAllText($File)
    if ($content.Contains($MARKER)) {
        Die "인수인계 파일이 작성 중 상태입니다 (첫 줄 TODO 마커 삭제 필요): $(Rel-Path $File)"
    }
}

function Require-Verdict { param([string] $File, [string] $Expected)
    $v = Verdict-Of $File
    if ($v -ne $Expected) {
        $cur = if ($v) { $v } else { '없음' }
        Die "$(Rel-Path $File) 의 verdict 가 '$Expected' 여야 합니다 (현재: '$cur')"
    }
}

function Run-Check { param([string] $Id, [string] $File)
    $branch = Fm-Get $File 'branch'
    $base = Fm-Get $File 'base'
    $wt = Worktree-Of $branch
    if (-not $wt) { Die "브랜치 $branch 의 worktree 가 없습니다" }
    $dirty = & git -C $wt status --porcelain -- . ':(exclude)work' 2>$null
    if ($dirty) { Die "커밋되지 않은 변경이 있습니다 ($wt). 커밋 후 다시 시도하세요" }
    $commitsRaw = & git -C $MAIN rev-list --count "$base..$branch" 2>$null
    $commits = 0
    if ($commitsRaw) { [void][int]::TryParse($commitsRaw.Trim(), [ref]$commits) }
    if ($commits -eq 0) { Die "$branch 에 $base 대비 커밋이 없습니다" }
    Write-Output "▶ $wt 에서 check 실행"
    $checkPs1 = Join-Path $wt 'scripts\check.ps1'
    if (-not (Test-Path -LiteralPath $checkPs1)) { Die 'check.ps1 가 없습니다' }
    Push-Location $wt
    try {
        & $checkPs1
        if ($LASTEXITCODE -ne 0) { Die 'check 실패. 통과시킨 뒤 다시 시도하세요' }
    } finally {
        Pop-Location
    }
}

function Archive-Round { param([string] $Id)
    $h = Join-Path $HANDOFFS $Id
    $existing = @(Get-ChildItem -LiteralPath $h -Directory -Filter 'round-*' -ErrorAction SilentlyContinue)
    $n = $existing.Count + 1
    $roundDir = Join-Path $h "round-$n"
    New-Item -ItemType Directory -Path $roundDir -Force | Out-Null
    foreach ($name in @('02-impl.md', '03-review.md', '04-qa.md')) {
        $src = Join-Path $h $name
        if (Test-Path -LiteralPath $src) {
            Move-Item -LiteralPath $src -Destination (Join-Path $roundDir $name) -Force
        }
    }
    Write-Output "  이번 라운드 기록 보관: work/handoffs/$Id/round-$n/"
}

function Cmd-New { param([string[]] $A)
    $title = ($A -join ' ').Trim()
    if (-not $title) { Die '사용법: task.ps1 new <제목>' }
    New-Item -ItemType Directory -Path $TASKS -Force | Out-Null
    Acquire-Lock
    try {
        $nums = @(Get-ChildItem -LiteralPath $TASKS -Filter 'T-*.md' -ErrorAction SilentlyContinue |
            ForEach-Object { if ($_.BaseName -match '^T-(\d+)$') { [int]$matches[1] } })
        $max = ($nums | Measure-Object -Maximum).Maximum
        $n = if ($max) { [int]$max + 1 } else { 1 }
        $id = 'T-{0:D3}' -f $n
        $baseRaw = & git -C $MAIN symbolic-ref --short HEAD 2>$null
        $base = if ($baseRaw) { $baseRaw.Trim() } else { 'main' }
        $date = Get-Date -Format 'yyyy-MM-dd'
        $tpl = [System.IO.File]::ReadAllText((Join-Path $TPL 'task.md'))
        $out = $tpl.Replace('{ID}', $id).Replace('{TITLE}', $title).Replace('{BASE}', $base).Replace('{DATE}', $date)
        $out = $out -replace "`r`n", "`n"
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $TASKS "$id.md"), $out, $enc)
        Write-Output $id
    } finally {
        Release-Lock
    }
}

function Cmd-List { param([string[]] $A)
    $filter = if ($A -and $A.Count -gt 0) { $A[0] } else { '' }
    $fmt = '{0,-7} {1,-18} {2,-12} {3}'
    Write-Output ($fmt -f 'ID', 'STATUS', 'OWNER', 'TITLE')
    $files = @(Get-ChildItem -LiteralPath $TASKS -Filter 'T-*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $s = Fm-Get $f.FullName 'status'
        if ($filter -and $s -ne $filter) { continue }
        Write-Output ($fmt -f (Fm-Get $f.FullName 'id'), $s, (Fm-Get $f.FullName 'owner'), (Fm-Get $f.FullName 'title'))
    }
}

function Cmd-Next { param([string[]] $A)
    if (-not $A -or $A.Count -lt 1) { Die '역할 필요' }
    $inputs = Role-Inputs $A[0]
    $files = @(Get-ChildItem -LiteralPath $TASKS -Filter 'T-*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($st in $inputs) {
        foreach ($f in $files) {
            if ((Fm-Get $f.FullName 'status') -eq $st -and -not (Fm-Get $f.FullName 'owner')) {
                Write-Output (Fm-Get $f.FullName 'id')
                return
            }
        }
    }
    [Console]::Error.WriteLine("$($A[0]) 가 처리할 작업이 없습니다")
    exit 1
}

function Cmd-Claim { param([string[]] $A)
    if (-not $A -or $A.Count -lt 2) { Die 'ID 와 역할 필요' }
    $id = $A[0]; $role = $A[1]
    $f = Task-File $id
    Acquire-Lock
    try {
        $s = Fm-Get $f 'status'
        $owner = Fm-Get $f 'owner'
        $inputs = Role-Inputs $role
        if ($inputs -notcontains $s) { Die "$id 는 $s 상태라 $role 가 맡을 수 없습니다" }
        if ($owner -and $owner -ne $role) { Die "$id 는 이미 $owner 가 점유 중입니다" }
        Fm-Set $f 'owner' $role
        Write-Output "✓ $id 점유: $role"
    } finally {
        Release-Lock
    }
}

function Cmd-Release { param([string[]] $A)
    if (-not $A -or $A.Count -lt 1) { Die 'ID 필요' }
    $f = Task-File $A[0]
    Fm-Set $f 'owner' ''
    Write-Output "✓ $($A[0]) 점유 해제"
}

function Cmd-Show { param([string[]] $A)
    if (-not $A -or $A.Count -lt 1) { Die 'ID 필요' }
    $id = $A[0]
    $f = Task-File $id
    $h = Join-Path $HANDOFFS $id
    Write-Output [System.IO.File]::ReadAllText($f)
    Write-Output ''
    Write-Output '── 경로 ──'
    Write-Output "작업 파일 : $f"
    Write-Output "인수인계  : $h\"
    if (Test-Path -LiteralPath $h) {
        $items = @(Get-ChildItem -LiteralPath $h -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object FullName)
        foreach ($item in $items) {
            $rel = $item.FullName.Substring($h.Length).TrimStart('/','\')
            Write-Output "    $rel"
        }
    }
    $wt = Worktree-Of (Fm-Get $f 'branch')
    $disp = if ($wt) { $wt } else { '(없음)' }
    Write-Output "worktree  : $disp"
}

function Cmd-Get { param([string[]] $A)
    if (-not $A -or $A.Count -lt 2) { Die 'ID 와 필드 필요' }
    $f = Task-File $A[0]
    Write-Output (Fm-Get $f $A[1])
}

function Cmd-Handoff { param([string[]] $A)
    if (-not $A -or $A.Count -lt 2) { Die 'ID 와 역할 필요' }
    $id = $A[0]; $role = $A[1]
    [void](Task-File $id)
    $name = Handoff-Name $role
    $p = Join-Path (Join-Path $HANDOFFS $id) $name
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $p)) {
        $tpl = [System.IO.File]::ReadAllText((Join-Path $TPL 'handoff.md'))
        $out = $tpl.Replace('{ID}', $id).Replace('{ROLE}', $role)
        $out = $out -replace "`r`n", "`n"
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($p, $out, $enc)
    }
    Write-Output $p
}

function Cmd-Worktree { param([string[]] $A)
    if (-not $A -or $A.Count -lt 1) { Die 'ID 필요' }
    $f = Task-File $A[0]
    Write-Output (Worktree-Of (Fm-Get $f 'branch'))
}

function Cmd-Move { param([string[]] $A)
    if (-not $A -or $A.Count -lt 2) { Die 'ID 와 상태 필요' }
    $id = $A[0]; $to = $A[1]
    $f = Task-File $id
    $from = Fm-Get $f 'status'
    $h = Join-Path $HANDOFFS $id
    $trans = "$from>$to"
    if ($trans -eq 'todo>planned') {
        Require-Done (Join-Path $h '01-plan.md')
        $dirty = & git -C $MAIN status --porcelain -- docs 2>$null
        if ($dirty) {
            Die 'docs/ 에 커밋되지 않은 변경이 있습니다. implementer worktree 는 base 브랜치에서 갈라지므로 planner 의 docs/ 변경은 planned 로 넘기기 전에 커밋해야 반영됩니다'
        }
    }
    elseif ($trans -eq 'planned>in_review' -or $trans -eq 'changes_requested>in_review') {
        Require-Done (Join-Path $h '02-impl.md')
        Run-Check $id $f
    }
    elseif ($trans -eq 'in_review>in_qa') {
        Require-Done (Join-Path $h '03-review.md')
        Require-Verdict (Join-Path $h '03-review.md') 'approve'
    }
    elseif ($trans -eq 'in_review>changes_requested') {
        Require-Done (Join-Path $h '03-review.md')
        Require-Verdict (Join-Path $h '03-review.md') 'changes'
    }
    elseif ($trans -eq 'in_qa>done') {
        Require-Done (Join-Path $h '04-qa.md')
        Require-Verdict (Join-Path $h '04-qa.md') 'pass'
    }
    elseif ($trans -eq 'in_qa>changes_requested') {
        Require-Done (Join-Path $h '04-qa.md')
        Require-Verdict (Join-Path $h '04-qa.md') 'fail'
    }
    else {
        Die "허용되지 않은 전이: $from → $to"
    }
    Acquire-Lock
    try {
        if ($to -eq 'changes_requested') { Archive-Round $id }
        Fm-Set $f 'status' $to
        Fm-Set $f 'owner' ''
        Write-Output "✓ ${id}: $from → $to"
        if ($to -eq 'done') {
            $branch = Fm-Get $f 'branch'
            $wt = Worktree-Of $branch
            Write-Output '  병합은 사람이 확인 후 진행하세요:'
            Write-Output "    git -C `"$MAIN`" merge --no-ff $branch"
            if ($wt) {
                Write-Output "    git -C `"$MAIN`" worktree remove `"$wt`"; git -C `"$MAIN`" branch -d $branch"
            }
        }
    } finally {
        Release-Lock
    }
}

switch ($Command) {
    'new'      { Cmd-New $Rest; break }
    'list'     { Cmd-List $Rest; break }
    'next'     { Cmd-Next $Rest; break }
    'claim'    { Cmd-Claim $Rest; break }
    'release'  { Cmd-Release $Rest; break }
    'show'     { Cmd-Show $Rest; break }
    'get'      { Cmd-Get $Rest; break }
    'handoff'  { Cmd-Handoff $Rest; break }
    'worktree' { Cmd-Worktree $Rest; break }
    'move'     { Cmd-Move $Rest; break }
    { @('', '-h', '--help', 'help') -contains $_ } { Show-Usage; break }
    default    { Show-Usage; exit 1 }
}
