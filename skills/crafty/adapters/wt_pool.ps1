<#
wt_pool.ps1: fixed worktree slots per repo (crafty.ps1 wt lease / release / pool), leased like phone lanes; a slot is never
deleted, so its build caches stay warm, and one naming scheme for every pooled resource (member n = the n-th bird).
  & <kit>/skills/crafty/crafty.ps1 wt lease -Repo <r> -Branch <b> -Agent <id> [-Target] [-Scope] [-Session] [-WaitMinutes 60]
  & <kit>/skills/crafty/crafty.ps1 wt release -Agent <id> [-Repo] | -Dir <slot> [-Reason]   uncommitted work: a WIP commit, else parked
  & <kit>/skills/crafty/crafty.ps1 wt pool [-Repo] [-Json] | -Migrate [-DryRun]   slots; per-task worktrees go when nothing is lost
Inputs: kit.local.json pool.size (10), pool.names, repos[].poolSize. State: <runtime>/work/wt-slots/<bird>-<repo>.json (+ wait/).
Dot-sourced by lib.ps1 (adapters/*.ps1); the Invoke-Wt* verbs run inside crafty.ps1 Invoke-Wt (its parameters and helpers).
Exit codes: 0 ok · 1 problem (no slot within -WaitMinutes, a branch another agent holds, git failed) · 2 usage.
Sections: L13 worktrees · L64 names · L75 slots · L101 lease · L198 release · L226 sync · L270 pool
#>
#Requires -Version 7
# ---- worktrees: helpers of crafty.ps1 wt (Invoke-Wt, sweep); Get-WtDirty runs inside Invoke-Wt (its Meta)
# { param($path) -> 'a board agent' | 'a running process' | $null }: a live row's claims + the worktrees its agent checkpointed
# since it joined (a kitty's own worktree went after its push), or a process (editor, build, shell) in the folder
function Get-KitWtHeldTest {
  $now = Get-Date
  $script:KitWtClaimed = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.status -ne 'left' -and $_.beat -and ($now - [datetime]$_.beat).TotalHours -lt [double](Get-KitParam 'board.rowHours') } | ForEach-Object {
      $liveRow = $_; $liveRow.worktrees
      if ($liveRow.agent -and $liveRow.joined) { @((Read-KitState (Get-KitCheckpointFile $liveRow.agent "$($liveRow.run)")).steps | Where-Object { $_.dir -and $_.at -and [datetime]$_.at -ge [datetime]$liveRow.joined } | ForEach-Object { $_.dir }) }
    } | Where-Object { "$_" -match '^([A-Za-z]:)?[\\/]' } | ForEach-Object { [IO.Path]::GetFullPath("$_").TrimEnd('\', '/').ToLower() })
  $claimedAt = $script:KitWtClaimed; $cmdLines = @(Get-SysProcs | Where-Object { $_.Id -ne $PID -and $_.CommandLine } | ForEach-Object { $_.CommandLine.Replace('/', '\').ToLower() })
  { param($p) $l = $p.ToLower(); if ($l -in $claimedAt) { 'a board agent' } elseif (@($cmdLines | Where-Object { $_.Contains($l) }).Count) { 'a running process' } }.GetNewClosure()
}
# the worktree root, git-excluded in an outer repo (else untracked there)
function Add-WtRoot($rt) {
  New-Item -ItemType Directory -Force $rt | Out-Null
  $outer = git -C $rt rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $outer) {
    $outer = (Resolve-Path $outer.Trim()).Path; $rootFull = (Resolve-Path $rt).Path
    if ($rootFull.StartsWith($outer, [StringComparison]::OrdinalIgnoreCase) -and $rootFull.Length -gt $outer.Length) {
      $rel = '/' + $rootFull.Substring($outer.Length).TrimStart('\', '/').Replace('\', '/') + '/'
      $ex = Join-Path (git -C $outer rev-parse --path-format=absolute --git-common-dir).Trim() 'info/exclude'
      New-Item -ItemType Directory -Force (Split-Path $ex) | Out-Null
      if (-not ((Test-Path $ex) -and (Select-String -Path $ex -SimpleMatch -Pattern $rel -Quiet))) { Add-Content $ex $rel }
    }
  }
}
# name or alias: repos[].checkout, else <reposRoot>/<name>
function Resolve-WtRepo($rr) {
  if (-not (Test-Path -LiteralPath $rr)) {
    $hit = @((Get-RepoConf $rr checkout $null), (Join-Path $KitConf.ReposRoot $rr)) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $hit) { throw "no repo $rr (not a folder, no kit.local.json repos[] checkout, not under $($KitConf.ReposRoot)): pass the checkout path" }
    $rr = $hit
  }
  (Resolve-Path $rr).Path
}
function Get-WtRepoConf($rp) {
  $kc = $KitConf.ConfigFile; if (-not ($kc -and (Test-Path $kc))) { return }
  $rpn = $rp.TrimEnd('\', '/'); @((Get-Content $kc -Raw | ConvertFrom-Json).repos) | Where-Object { $_.checkout -and ((Resolve-Path $_.checkout -ErrorAction SilentlyContinue).Path -eq $rpn) } | Select-Object -First 1
}
# kit.local.json dep source of a target; configured but missing: error
function Get-WtDepSource($rp, $tg) {
  $rc = Get-WtRepoConf $rp; if (-not $rc) { return }
  $cand = if ($rc.linkFromByTarget -and (Get-KitMember $rc.linkFromByTarget $tg)) { (Get-KitMember $rc.linkFromByTarget $tg) } elseif ($rc.linkFrom -and $tg -eq $rc.target) { $rc.linkFrom } else { $null }
  if ($cand -and -not (Test-Path $cand)) { throw "kit.local.json dep source $cand ($(Split-Path $rp -Leaf), target $tg) is missing: create it (git worktree add --detach <path> origin/$tg + frozen-lockfile install) or fix kit.local.json" }
  $cand
}
# porcelain status minus the worktree's own dependency links
function Get-WtDirty($d) {
  $mine = @(@(Meta $d 'links') | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetRelativePath($d, $_).Replace('\', '/') })
  @(git -C $d status --porcelain 2>$null | Where-Object { $_ -and ($_.Substring(3).Trim('"').TrimEnd('/') -notin $mine) })
}
# ---- names: member n of every pool is the n-th bird
# one naming scheme for every pooled resource: member n of a pool (worktree slot, env lane, phone lane) = the n-th bird
$script:KitBirds = @('Falcon', 'Kestrel', 'Osprey', 'Heron', 'Merlin', 'Harrier', 'Kite', 'Swift', 'Raven', 'Wren', 'Egret', 'Ibis', 'Lark', 'Owl', 'Petrel', 'Robin', 'Shrike', 'Tern', 'Finch', 'Plover')
function Get-KitBirdName([int]$N) { $b = @(Get-KitSetting 'pool.names' $script:KitBirds); if ($N -ge 1 -and $N -le $b.Count) { "$($b[$N - 1])" } else { "Bird$N" } }
# "<pool>·<Bird>": env lane shop2 -> shop·Kestrel (lane 1 = <env>, lane k = <env><k>; envs.<env><k> overrides: the shortest base wins); else the name
function Get-KitPoolLabel([string]$Kind, [string]$Name) {
  if ($Kind -eq 'env' -and ($envs = Get-KitSetting 'localEnv.envs' $null)) {
    foreach ($e in @((Get-KitProps $envs).Name | Sort-Object Length)) { if ($Name -match "^$([regex]::Escape($e))(?<k>\d*)$") { return "$e·$(Get-KitBirdName $(if ($Matches.k) { [int]$Matches.k } else { 1 }))" } }
  }
  $Name
}
# ---- slots: a repo's pool size and its slots (worktrees marked <git dir>/claude-slot)
# the repos[] entry whose checkout it is, else origin's last path segment, else the folder
function Get-KitCheckoutName([string]$Repo) {
  $rp = (Resolve-Path -LiteralPath $Repo -ErrorAction SilentlyContinue).Path
  foreach ($x in @(Get-KitValue 'repos' @())) { if ($x.name -and $x.checkout -and (Resolve-Path -LiteralPath $x.checkout -ErrorAction SilentlyContinue).Path -eq $rp) { return "$($x.name)" } }
  $u = "$(git -C $Repo remote get-url origin 2>$null)".Trim(); if ($u) { (($u -replace '\.git$') -split '[/:\\]')[-1] } else { Split-Path $Repo -Leaf }
}
# repos[].poolSize, else pool.size (10); the kit's own clone: 0 (kitty keeps wt new)
function Get-KitPoolSize([string]$Repo) {
  if ((Resolve-Path -LiteralPath $Repo -ErrorAction SilentlyContinue).Path -eq (Resolve-Path -LiteralPath $KitConf.Kit).Path) { return 0 }
  $n = Get-RepoConf (Get-KitCheckoutName $Repo) 'poolSize' $null; if ($null -ne $n) { [int]$n } else { [int](Get-KitParam 'pool.size') }
}
function Get-KitSlotFile([string]$Leaf) { Join-Path (Get-KitPath wt-slots -Create) "$Leaf.json" }
# a repo's slots: worktrees marked <git dir>/claude-slot (= n, the bird index), by n
function Get-KitSlots([string]$Repo) {
  $rl = Split-Path $Repo -Leaf
  @(foreach ($w in @(Get-KitWorktrees $Repo)) {
      $gf = Join-Path $w.path '.git'; if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { continue }
      $gd = ("$(Get-Content -LiteralPath $gf -TotalCount 1)" -replace '^gitdir:\s*').Trim(); if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $w.path $gd }
      $sf = Join-Path $gd 'claude-slot'; if (-not (Test-Path -LiteralPath $sf)) { continue }
      $n = [int]"$(Get-Content -LiteralPath $sf -TotalCount 1)".Trim(); $leaf = Split-Path $w.path -Leaf
      [pscustomobject]@{ n = $n; name = "$rl·$(Get-KitBirdName $n)"; path = $w.path; branch = $w.branch; head = $w.head; gitDir = $gd; file = (Get-KitSlotFile $leaf) }
    }) | Sort-Object n
}
function Read-KitSlotLease([string]$File) { if (Test-Path -LiteralPath $File) { try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json } catch { $null } } }
function Test-KitSlotDir([string]$Dir) { $gf = Join-Path $Dir '.git'; if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return $false }; $gd = ("$(Get-Content -LiteralPath $gf -TotalCount 1)" -replace '^gitdir:\s*').Trim(); [bool]($gd -and (Test-Path -LiteralPath (Join-Path $gd 'claude-slot'))) }
# ---- lease: wt lease
function Invoke-WtLease {   # a free slot of the repo's pool on -Branch (fair queue when all are leased); created lazily up to the pool size
  if (-not ($Repo -and $Branch -and $Agent)) { throw 'lease needs -Repo -Branch -Agent' }
  $Repo = Resolve-WtRepo $Repo; $rl = Split-Path $Repo -Leaf; $size = Get-KitPoolSize $Repo
  if ($size -lt 1) { throw "wt lease: $(Get-KitCheckoutName $Repo) has no pool (repos[].poolSize 0, or the kit itself): wt new" }
  if (-not $Target) { $Target = "$(Get-RepoConf (Get-KitCheckoutName $Repo) 'target' '')"; if (-not $Target) { $Target = "$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/' } }
  if (-not $Target) { throw 'wt lease: no target (repos[].target, origin/HEAD): pass -Target' }
  G -C $Repo fetch -q origin $Target | Out-Null
  $remoteBranch = "$(git -C $Repo ls-remote --heads origin "refs/heads/$Branch" 2>$null)".Trim()   # bare name would suffix-match
  git -C $Repo show-ref --verify --quiet "refs/heads/$Branch"; $localBranch = -not $LASTEXITCODE
  if (-not $localBranch -and -not $remoteBranch) {   # a new branch: wt new's prior-work gate
    $tk = if ($Task) { $Task } elseif (($rx = Get-KitTaskTagRx) -and $Branch -match $rx) { $Matches.id }
    Assert-KitPrior $tk $Repo "wt lease $Branch" $Override $Branch
    if ($tk) { Update-KitTaskIndex $tk { param($x) if ($x.prior) { $x.prior.claimed = @(@($x.prior.claimed) + $Branch | Where-Object { $_ } | Select-Object -Unique) } } }
  }
  $sdir = Get-KitPath wt-slots -Create; $wdir = Join-Path $sdir 'wait'; New-Item -ItemType Directory -Force $wdir | Out-Null
  $poolLock = Join-Path $sdir "$rl.pool"; $wf = Join-Path $wdir "$(ConvertTo-KitSlug $Agent)-$rl.json"; $since = (Get-Date).ToString('o')
  $slotRoot = if ($Root) { $Root } else { @($KitConf.WorktreeRoots)[0] }
  $deadline = (Get-Date).AddMinutes($WaitMinutes); $got = $null; $told = $false
  Write-KitAtomic $wf (@{ agent = $Agent; repo = $rl; branch = $Branch; since = $since } | ConvertTo-Json -Compress)
  try {
    while (-not $got) {
      $got = Invoke-KitLocked $poolLock {
        if (Test-Path -LiteralPath $wf) { (Get-Item -LiteralPath $wf).LastWriteTime = Get-Date }   # heartbeat: 3 min untouched = a dead waiter
        $slots = @(Get-KitSlots $Repo); $byN = @{}; $ls = @{}
        foreach ($s in $slots) { $byN[$s.n] = $s; $ls[$s.n] = Read-KitSlotLease $s.file }
        $reserved = @(foreach ($n in 1..$size) { if (-not $byN[$n]) { $rf = Get-KitSlotFile "$((Get-KitBirdName $n).ToLower())-$rl"; $ro = Read-KitSlotLease $rf
              if ($ro.creating -and (Test-KitLive $ro)) { $n } elseif ($ro) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue } } })   # a slot being created
        $mine = @($slots | Where-Object { $o = $ls[$_.n]; $o -and -not $o.parked -and $o.agent -eq $Agent -and $o.branch -eq $Branch })[0]
        if ($mine) { return $mine }   # already ours
        $pick = @($slots | Where-Object { $_.branch -eq $Branch })[0]   # a resume, handoff or fix round: the slot that has the branch
        if ($pick -and ($o = $ls[$pick.n]) -and -not $o.parked -and (Update-KitLease $o)) { throw "wt lease: $Branch is checked out in $($pick.name) ($($pick.path)), leased by $($o.agent): two agents never share a slot; board msg $($o.agent) or wait for its release" }
        if (-not $pick) {
          foreach ($s in $slots) {   # holder gone past the grace + clean: freed here (dirty: supervise's reaper commits WIP first)
            $o = $ls[$s.n]; if (-not $o -or $o.parked -or $o.creating) { continue }
            $s0 = "$($o.seen)"; if (Update-KitLease $o) { if ("$($o.seen)" -ne $s0) { Write-KitAtomic $s.file ($o | ConvertTo-Json -Depth 5) }; continue }
            if (@(Get-WtDirty $s.path).Count) { continue }
            if ($s.branch) { git -C $s.path switch -q --detach 2>$null | Out-Null; Meta $s.path 'lastbranch' $s.branch; $s.branch = '' }
            Remove-Item -LiteralPath $s.file -Force; $ls[$s.n] = $null; Write-KitLeaseLog reclaim slot $s.name $o "reclaim: no live holder for $($o.graceMin) min"
          }
          $free = @($slots | Where-Object { -not $ls[$_.n] }); $room = [math]::Max(0, $size - $slots.Count - $reserved.Count)
          $ahead = @(Get-ChildItem -LiteralPath $wdir -Filter "*-$rl.json" -File | Where-Object { $_.FullName -ne $wf -and ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 } | ForEach-Object { Read-KitSlotLease $_.FullName } | Where-Object { $_.repo -eq $rl -and [datetimeoffset]$_.since -lt [datetimeoffset]$since })
          if ($ahead.Count -ge $free.Count + $room) { return $null }   # fair: older waiters first
          foreach ($s in @(@($free | Where-Object { "$(Meta $_.path 'lastbranch')".Trim() -eq $Branch }) + $free)) { if (-not @(Get-WtDirty $s.path).Count) { $pick = $s; break } }   # warm for this branch first, then the lowest
          if (-not $pick) {
            if (-not $room) { return $null }
            $n = @(1..$size | Where-Object { -not $byN[$_] -and $_ -notin $reserved })[0]; $sleaf = "$((Get-KitBirdName $n).ToLower())-$rl"
            $pick = [pscustomobject]@{ n = $n; name = "$rl·$(Get-KitBirdName $n)"; path = (Join-Path $slotRoot $sleaf); branch = ''; head = ''; new = $true; file = (Get-KitSlotFile $sleaf) }
          }
        }
        $lease = [ordered]@{ slot = $pick.name; n = $pick.n; repo = $Repo; path = $pick.path; branch = $Branch; since = (Get-Date).ToString('o') } + (New-KitLease $Agent $Session)
        if ($pick.new) { $lease.creating = $true }
        Write-KitAtomic $pick.file ($lease | ConvertTo-Json -Depth 5)
        $lg = @{}; foreach ($k in $lease.Keys) { $lg[$k] = $lease[$k] }; $lg.at = $since; Write-KitLeaseLog acquire slot $pick.name $lg   # since = when it began to wait
        $pick
      } | Select-Object -Last 1
      if (-not $got) {
        if ((Get-Date) -gt $deadline) { throw "no $rl slot free within $WaitMinutes min (all $size leased: wt pool -Repo $rl shows the holders)" }
        if (-not $told) { "all $size $rl slots are leased; waiting for a release (fair queue) ..."; $told = $true }
        Wait-KitPoll 20
      }
    }
  } finally { Remove-Item -LiteralPath $wf -Force -ErrorAction SilentlyContinue }
  $p = $got.path; $cur = ''; $h0 = ''
  try {
    if ($got.new) {
      if (Test-Path -LiteralPath $p) { throw "wt lease: $p exists but is no slot (a half-made slot or an old worktree): wt remove -Dir $p -Force, then lease again" }
      Add-WtRoot (Split-Path $p)
      G -C $Repo worktree add -q --detach $p "origin/$Target" | Out-Null
      Meta $p 'slot' $got.n
      "new slot $($got.name) (pool $(@(Get-KitSlots $Repo).Count)/$size): $p"
    } else { $cur = "$(git -C $p branch --show-current 2>$null)".Trim(); $h0 = "$(git -C $p rev-parse HEAD 2>$null)".Trim() }
    if ($cur -ne $Branch) {
      if ($cur) { git -C $p switch -q --detach 2>$null | Out-Null }   # an unleased slot left on a branch
      $sw = if ($localBranch) { git -C $p switch -q $Branch 2>&1 } elseif ($remoteBranch) { G -C $Repo fetch -q origin $Branch | Out-Null; git -C $p switch -q -c $Branch --track "origin/$Branch" 2>&1 } else { git -C $p switch -q --no-track -c $Branch "origin/$Target" 2>&1 }
      if ($LASTEXITCODE) { $said = (@($sw) | ForEach-Object { "$_" }) -join ' '; $inRx = "already (?:checked out|used by worktree) at '(?<w>[^']+)'"
        throw "wt lease: git switch $Branch failed in $($got.name): $said$(if ($said -match $inRx) { " -> it is checked out in $($Matches.w) (an older worktree): work there, or wt remove it first" })" }
    }
    Meta $p 'target' $Target
    $scf = Join-Path (GitDir $p) 'claude-scope'
    if ($Scope) { Meta $p 'scope' (@(Split-KitList $Scope -Sep '\s*,\s*') -join "`n") } elseif (Test-Path -LiteralPath $scf) { Remove-Item -LiteralPath $scf -Force }   # brief agents[].paths
    $depOut = @(Set-WtDeps $p $Repo $Target $LinkFrom)
    $o = Read-KitSlotLease $got.file; if ($o) { $o = $o | Select-Object -Property * -ExcludeProperty creating; Set-KitProp $o branch $Branch; Write-KitAtomic $got.file ($o | ConvertTo-Json -Depth 5) }
  } catch {
    $err = $_; Invoke-KitLocked $poolLock { $o = Read-KitSlotLease $got.file; if ($o -and $o.agent -eq $Agent) {   # dirty (a resumed parked slot): parked again, never orphaned
        if ((Test-Path -LiteralPath $got.path) -and @(Get-WtDirty $got.path).Count) { $pw = "lease failed, files kept: $($err.Exception.Message)"; Set-KitProp $o parked $true; Set-KitProp $o parkedAt (Get-Date).ToString('o'); Set-KitProp $o parkedWhy $pw.Substring(0, [math]::Min(300, $pw.Length)); Write-KitAtomic $got.file ($o | ConvertTo-Json -Depth 5) }
        else { Remove-Item -LiteralPath $got.file -Force }
        Write-KitLeaseLog release slot $got.name $o "lease failed: $($err.Exception.Message)" } }
    throw $err
  }
  "worktree: $p"
  "slot:     $($got.name) (leased by $Agent; done: wt release -Agent $Agent)"
  "branch:   $Branch$(if ($cur -eq $Branch) { ' (already here)' } elseif ($localBranch) { ' (local branch, as is)' } elseif ($remoteBranch) { ' (from origin)' } else { " (new, from origin/$Target)" })"
  if ($Scope) { "area:     $Scope (wt commit, devtools.py mr / merge refuse files outside)" }
  if ($h0) { $gone = @(git -C $p diff --name-only --diff-filter=D $h0 HEAD 2>$null).Count; "files:    $(@(git -C $p diff --name-only $h0 HEAD 2>$null).Count) changed by the switch, not $(@(git -C $p ls-files).Count) written by a fresh worktree$(if ($gone) { "; $gone deleted: their build outputs may linger in ignored folders" })" }
  $depOut
}
# ---- release: wt release
function Invoke-WtRelease {   # -Agent: every slot it holds (-Repo: of one repo) · -Dir: that slot; uncommitted work -> a WIP commit, else parked
  if (-not ($Agent -or $Dir)) { throw 'release needs -Agent <id> or -Dir <slot>' }
  $want = if ($Dir) { [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/').Replace('\', '/').ToLower() }
  $held = @(Get-ChildItem -LiteralPath (Get-KitPath wt-slots -Create) -Filter '*.json' -File | ForEach-Object { $o = Read-KitSlotLease $_.FullName; if ($o) { [pscustomobject]@{ f = $_.FullName; o = $o } } } |
    Where-Object { if ($want) { "$($_.o.path)".Replace('\', '/').TrimEnd('/').ToLower() -eq $want } else { $_.o.agent -eq $Agent -and -not $_.o.parked -and (-not $Repo -or (Split-Path "$($_.o.repo)" -Leaf) -eq (Split-Path $Repo -Leaf)) } })
  if (-not $held.Count) { "$(if ($Dir) { "${Dir}: no lease" } else { "no slot held by $Agent" })"; return }
  $why = if ($Reason) { $Reason } else { 'released' }
  foreach ($h in $held) {
    $o = $h.o; $p = $o.path; $lf = $h.f
    if (-not (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $lf -Force; Write-KitLeaseLog release slot $o.slot $o "$why (folder gone)"; "released $($o.slot): its folder is gone"; continue }
    $br = "$(git -C $p branch --show-current 2>$null)".Trim(); $dirty = @(Get-WtDirty $p)
    if ($dirty.Count) {   # never lost: a WIP commit on its branch (hooks run), else parked for that branch
      $said = 'uncommitted files on a detached HEAD'
      if ($br) { git -C $p add -A -- @($dirty | ForEach-Object { ($_.Substring(3).Trim('"') -split ' -> ')[-1] }) 2>$null; $said = @(git -C $p commit -q -m "wip: $($o.slot) released with uncommitted work ($why)" 2>&1 | ForEach-Object { "$_" }) -join ' '; $wc = $LASTEXITCODE; if ($wc) { git -C $p reset -q 2>$null; $said = "WIP commit refused (exit $wc) $said".Trim() } else { $said = '' } }
      if ($said) {
        Set-KitProp $o parked $true; Set-KitProp $o parkedAt (Get-Date).ToString('o'); $pw = "uncommitted files: $said"; Set-KitProp $o parkedWhy $pw.Substring(0, [math]::Min(300, $pw.Length)); Write-KitAtomic $lf ($o | ConvertTo-Json -Depth 5)
        Write-KitLeaseLog release slot $o.slot $o "$why (parked)"; "PARKED $($o.slot) ($p): $said; wt lease -Branch $(if ($br) { $br } else { '<branch>' }) -Repo $(Split-Path $o.repo -Leaf) -Agent <id> resumes it, nobody else gets it"; continue
      }
      "$($o.slot): uncommitted work committed on $br as a WIP commit"
    }
    if ($br) { git -C $p switch -q --detach 2>$null | Out-Null; Meta $p 'lastbranch' $br }   # HEAD stays: no file written
    $scf = Join-Path (GitDir $p) 'claude-scope'; if (Test-Path -LiteralPath $scf) { Remove-Item -LiteralPath $scf -Force }
    $bn = if ($br) { try { $bv = Get-KitBranchVerdict $o.repo $br @{} -IdleHours 0; if ($bv.delete) { git -C $o.repo branch -D $br 2>$null | Out-Null; "; branch $br deleted ($($bv.why))" } else { "; branch $br kept ($($bv.why))" } } catch { "; branch $br kept" } }
    Remove-Item -LiteralPath $lf -Force; Write-KitLeaseLog release slot $o.slot $o $Reason
    "released $($o.slot) ($p)$bn"
  }
}
# ---- sync: every pooled repo (wt pool; supervise every sync.everyMinutes): one fetch, fast-forward each local branch strictly
# behind its upstream (checked out: ff-only when clean), prune lane branches no worktree holds and gone-upstream branches merged
# into the target; diverged or dirty: listed only. Free clean slots sit detached at origin/<target>; pool.warm free slots exist.
function Sync-KitRepo([string]$Repo, [switch]$DryRun) {
  $rl = Split-Path $Repo -Leaf; $r = [ordered]@{ repo = $rl; at = (Get-Date).ToString('o'); ff = @(); diverged = @(); dirty = @(); pruned = @(); warmed = @(); err = '' }
  $fo = @(git -C $Repo fetch -q --prune origin 2>&1); if ($LASTEXITCODE) { $r.err = "fetch failed: $(@($fo)[-1])"; return [pscustomobject]$r }
  $tgt = "$(Get-RepoConf (Get-KitCheckoutName $Repo) 'target' '')"; if (-not $tgt) { $tgt = "$(git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null)".Trim() -replace '^origin/' }
  $keepRx = Get-KitKeepBranchRx $Repo; $at = @{}; foreach ($w in @(Get-KitWorktrees $Repo)) { if ($w.branch) { $at[$w.branch] = $w.path } }
  foreach ($ln in @(git -C $Repo for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads 2>$null)) {
    $b, $u, $tr = "$ln" -split '\|', 3; $wd = $at[$b]
    if ($b -like 'lane/*' -or $b -like 'localenv/*') {   # a lane's branch = target + test merges, rebuilt at its next build
      if (-not $wd) { if (-not $DryRun) { git -C $Repo branch -D $b 2>$null | Out-Null }; $r.pruned += "$b (lane branch, no worktree)" }; continue }
    if (-not $u) { continue }
    if ($tr -eq '[gone]') {
      if (-not $wd -and $b -notmatch $keepRx -and $tgt) { git -C $Repo merge-base --is-ancestor "refs/heads/$b" "origin/$tgt" 2>$null; if (-not $LASTEXITCODE) { if (-not $DryRun) { git -C $Repo branch -D $b 2>$null | Out-Null }; $r.pruned += "$b (upstream gone, merged into $tgt)" } }
      continue }
    $bh = if ($tr -match 'behind (\d+)') { [int]$Matches[1] } else { 0 }; if (-not $bh) { continue }
    if ($tr -match 'ahead') { $r.diverged += "$b $tr"; continue }
    if ($wd) {
      if (@(git -C $wd status --porcelain --untracked-files=no 2>$null).Count) { $r.dirty += "$b behind $bh ($wd)"; continue }
      if (-not $DryRun) { git -C $wd merge -q --ff-only "refs/remotes/$u" 2>$null | Out-Null; if ($LASTEXITCODE) { $r.diverged += "$b ff failed"; continue } }
    } elseif (-not $DryRun) { $old = "$(git -C $Repo rev-parse "refs/heads/$b")".Trim(); git -C $Repo update-ref "refs/heads/$b" "refs/remotes/$u" $old 2>$null | Out-Null; if ($LASTEXITCODE) { $r.diverged += "$b update failed"; continue } }
    $r.ff += "$b +$bh"
  }
  $size = Get-KitPoolSize $Repo; $warm = [math]::Min($size, [int]$(if ($null -ne ($pw = Get-RepoConf (Get-KitCheckoutName $Repo) 'poolWarm' $null)) { $pw } else { Get-KitParam 'pool.warm' }))
  if ($size -gt 0 -and $tgt -and -not $DryRun) {
    Invoke-KitLocked (Join-Path (Get-KitPath wt-slots -Create) "$rl.pool") {
      $slots = @(Get-KitSlots $Repo)
      foreach ($s in $slots) { if (-not (Read-KitSlotLease $s.file) -and -not $s.branch -and -not @(git -C $s.path status --porcelain --untracked-files=no 2>$null).Count) { git -C $s.path checkout -q --detach "origin/$tgt" 2>$null | Out-Null } }   # idle: at the target, no stale branch
      $byN = @{}; foreach ($s in $slots) { $byN[$s.n] = $s }; $free = @($slots | Where-Object { -not (Read-KitSlotLease $_.file) }).Count
      foreach ($n in @(1..$size | Where-Object { -not $byN[$_] -and -not (Test-Path -LiteralPath (Get-KitSlotFile "$((Get-KitBirdName $_).ToLower())-$rl")) })) {
        if ($free -ge $warm) { break }
        $p = Join-Path @($KitConf.WorktreeRoots)[0] "$((Get-KitBirdName $n).ToLower())-$rl"; if (Test-Path -LiteralPath $p) { continue }
        Add-WtRoot (Split-Path $p); git -C $Repo worktree add -q --detach $p "origin/$tgt" 2>$null | Out-Null; if ($LASTEXITCODE) { $r.err = "warm slot $n failed"; break }
        Meta $p 'slot' $n; $free++; $r.warmed += "$rl·$(Get-KitBirdName $n)"
      }
    }
  }
  $sf = Join-Path (New-Item -ItemType Directory -Force (Join-Path (Get-KitPath wt-slots -Create) 'sync')).FullName "$rl.json"
  if (-not $DryRun) { Write-KitAtomic $sf ([pscustomobject]$r | ConvertTo-Json -Depth 4) }
  [pscustomobject]$r
}
# the last sync per repo (the dashboard's Branches tile)
function Get-KitRepoSyncState { @(Get-ChildItem -LiteralPath (Join-Path (Get-KitPath wt-slots -Create) 'sync') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { } }) }
# ---- pool: wt pool [-Migrate]
function Invoke-WtPool {   # slots per pooled repo; -Migrate [-DryRun]: per-task worktrees of pooled repos go when nothing is lost, the rest listed
  $repos = if ($Repo) { @(Resolve-WtRepo $Repo) } else { @(Get-KitRepoDirs | Where-Object { (Get-KitPoolSize $_) -gt 0 }) }
  if ($Migrate) {
    $heldBy = Get-KitWtHeldTest
    foreach ($rp in $repos) {
      $bctx = @{}; $keepRx = Get-KitKeepBranchRx $rp
      foreach ($w in @(Get-KitWorktrees $rp | Select-Object -Skip 1)) {   # the first is the main checkout
        $d = $w.path; if (-not (Test-Path -LiteralPath $d) -or (Test-KitSlotDir $d)) { continue }
        $label = "$d$(if ($w.branch) { " ($($w.branch))" })"
        $dedicated = if ($w.branch -and $w.branch -match $keepRx) { 'protected or env branch' } elseif ((Split-Path $d -Leaf) -like 'deploymerge-*') { 'deploy merge' } elseif (-not $w.branch -and @(Get-DepLinkDefaults | Where-Object { $i = Get-Item -LiteralPath (Join-Path $d $_.dir) -Force -ErrorAction SilentlyContinue; $i -and -not $i.LinkType }).Count) { 'a dependency store' }
        if ($dedicated) { "dedicated  ${label}: $dedicated"; continue }
        if (($who = & $heldBy $d.Replace('/', '\'))) { "keep  ${label}: held by $who"; continue }
        if (@(Get-WtDirty $d).Count) { "keep  ${label}: uncommitted files"; continue }
        if ($w.branch) { $bv = Get-KitBranchVerdict $rp $w.branch $bctx -IdleHours 0 -IgnoreCheckout; if (-not $bv.delete) { "keep  ${label}: $($bv.why)"; continue }; $gw = $bv.why }
        elseif (-not "$(git -C $d for-each-ref --contains $w.head --count=1 --format='%(refname)' refs/remotes/origin 2>$null)".Trim()) { "keep  ${label}: detached HEAD on no remote branch"; continue }
        else { $gw = 'detached HEAD on the host' }
        if ($DryRun) { "would go  ${label}: $gw"; continue }
        $ro = @(try { Invoke-Wt remove -Dir $d 2>&1 | ForEach-Object { "$_" } } catch { "FAILED: $($_.Exception.Message)" }); "gone  ${label}: $gw; $($ro[-1])"
      }
    }
    return
  }
  $synced = @(foreach ($rp in $repos) { $sy = Sync-KitRepo $rp -DryRun:$DryRun; if (-not $Json) { "sync $($sy.repo): $(@($sy.ff).Count) fast-forwarded, $(@($sy.diverged).Count) diverged, $(@($sy.dirty).Count) dirty, $(@($sy.pruned).Count) pruned, $(@($sy.warmed).Count) warm slot(s) made$(if ($sy.err) { "; $($sy.err)" })"; foreach ($x in @($sy.diverged) + @($sy.dirty)) { "  kept: $x" } } })
  if (-not $Json) { $synced }
  $rows = @(foreach ($rp in $repos) { $size = Get-KitPoolSize $rp; foreach ($s in @(Get-KitSlots $rp)) { $o = Read-KitSlotLease $s.file
        [pscustomobject]@{ slot = $s.name; repo = (Split-Path $rp -Leaf); size = $size; path = $s.path; branch = $(if ($s.branch) { $s.branch } else { "detached $("$($s.head)".Substring(0, [math]::Min(8, "$($s.head)".Length)))" })
          state = $(if (-not $o) { 'free' } elseif ($o.parked) { 'parked' } elseif ($o.creating) { 'creating' } else { 'leased' }); agent = "$($o.agent)"; since = "$($o.since)"; why = "$($o.parkedWhy)" } } })
  $waiting = @(Get-ChildItem -LiteralPath (Join-Path (Get-KitPath wt-slots -Create) 'wait') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -lt 3 } | ForEach-Object { Read-KitSlotLease $_.FullName })
  if ($Json) { return ([ordered]@{ slots = $rows; waiting = $waiting } | ConvertTo-Json -Depth 4 -Compress) }
  foreach ($rp in $repos) { $mine = @($rows | Where-Object repo -eq (Split-Path $rp -Leaf)); "pool $(Split-Path $rp -Leaf): $($mine.Count)/$(Get-KitPoolSize $rp) slots, $(@($mine | Where-Object state -eq 'free').Count) free" }
  foreach ($r in $rows) { '  {0,-22} {1,-8} {2,-40} {3}' -f $r.slot, $r.state, $r.branch, $(if ($r.agent) { "$($r.agent) since $($r.since)$(if ($r.why) { ": $($r.why)" })" }) }
  foreach ($w in $waiting) { "  waiting: $($w.agent) for $($w.repo) ($($w.branch)) since $($w.since)" }
}
