#Requires -Version 7
<#
naming.tests.ps1: the naming standard (kitbag.py naming): keys from the PRODUCT / AREA registry, sequential counters, every name kind
checked, names made from parts, the rename dry run (old code -> new key), NAME-CONFIG lint.
Usage: pwsh -NoProfile -File <kit>/tests/naming.tests.ps1 (or tests/kit-tests.ps1 -Area naming).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/kitbag_naming.py', 'skills/bossy/adapters/deploys.ps1', 'skills/pokey/adapters/deployed-checks.ps1')
$k = New-TestKit naming; $KB = Join-Path $k 'skills/bossy/kitbag.py'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd | Out-Null
function Kb { $o = & $py -X utf8 $KB @args 2>&1 | Out-String; [pscustomobject]@{ out = $o.Trim(); code = $LASTEXITCODE } }
$lc = Join-Path $k 'skills/crafty/kit.local.json'
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue'; PAY = 'Payments' } } }

# ---- keys: sequential per PRODUCT-AREA, zero-padded; an unknown code refused
$k1 = Kb naming next key SHOP CAT; $k2 = Kb naming next key SHOP CAT; $k3 = Kb naming next key SHOP PAY; $kx = Kb naming next key SHOP XYZ
Expect "next key: SHOP-CAT-001, -002, SHOP-PAY-001; an unknown AREA refused ($($kx.code))" ($k1.out -eq 'SHOP-CAT-001' -and $k2.out -eq 'SHOP-CAT-002' -and $k3.out -eq 'SHOP-PAY-001' -and
  $kx.code -ne 0 -and $kx.out -match 'unknown AREA XYZ')
$i1 = Kb naming next id buildy; $i2 = Kb naming next id buildy
Expect 'next id: <kind>-<nnnn>, one counter per kind, no date' ($i1.out -eq 'buildy-0001' -and $i2.out -eq 'buildy-0002')
# NO-DATE (owner 2026-11-24): old per-day counters fold into one past every id they made; a dated name is refused
Set-JsonFile (TkPath $k naming) @{ 'id:fix:20261123' = 4; 'id:fix:20261124' = 2 }; $i3 = Kb naming next id fix; $dn = Kb naming check run buildy-20261123-01; $dnd = Kb naming check doc 'SHOP-CAT-004 Spec v1 — 2026-11-24 notes'
Expect "NO-DATE: day counters fold (fix-0007), a dated run / doc refused ($($i3.out) | $($dn.out))" ($i3.out -eq 'fix-0007' -and $dn.code -eq 1 -and $dn.out -match 'NO-DATE' -and $dnd.code -eq 1 -and $dnd.out -match 'NO-DATE')

# ---- check: every kind, good and bad
$good = @{ key = 'SHOP-CAT-004'; item = 'SHOP-CAT-004.2 add-price-projection'; case = 'SHOP-CAT-004-TC03'; title = 'SHOP-CAT-004 public page'; tag = 'wave-2'
  doc = 'SHOP-CAT-004 Spec v3 — Public catalogue'; run = 'buildy-0042'; id = 'dec-0398'; agent = 'devy-01'; area = 'area-CAT'; lane = 'lane-02'
  branch = 'feat/SHOP-CAT-004-public-catalogue'; mr = 'feat(web): public catalogue page [SHOP-CAT-004]' }
$bad = @{ key = 'WEB-12'; item = 'SHOP-CAT-004.2'; case = 'T1'; title = '[Feature] Shop — G3 catalogue'; tag = 'Wave: 2'; doc = 'T1 testing doc (AI)'; run = 'wave-brief-a051'; id = 'd-20261123-x'
  agent = 'T1@150132'; area = 'X1'; lane = 'rm-kestrel'; branch = 'f/CU-14ab-sort'; mr = 'feat: sort (CU-14ab)' }
$gk = @($good.Keys | Where-Object { (Kb naming check $_ $good[$_]).code -ne 0 }); $bk = @($bad.Keys | Where-Object { (Kb naming check $_ $bad[$_]).code -eq 0 })
Expect "check: 13 standard names pass, 13 ad hoc ones fail (good failing: $($gk -join ','); bad passing: $($bk -join ','))" ($gk.Count -eq 0 -and $bk.Count -eq 0)
$ua = Kb naming check key SHOP-ORD-001; $ub = Kb naming check area area-ORD
Expect 'check: an unregistered AREA is named in the refusal' ($ua.code -eq 1 -and $ua.out -match 'unknown AREA ORD' -and $ub.out -match 'unknown AREA ORD')

# ---- make: names from parts fit their own check
$mt = Kb naming make title key=SHOP-CAT-004 type=Feature product=SHOP area=CAT 'outcome=Shop catalogue public page (api, web)'; $mb = Kb naming make branch type=feat key=SHOP-CAT-004 'slug=Public catalogue page'
$md = Kb naming make doc key=SHOP-CAT-004 kind=Spec ver=2 'title=Public catalogue'; $mc = Kb naming make case key=SHOP-CAT-004 n=3
Expect "make: title, branch, doc, case ($($mt.out) | $($mb.out))" ($mt.out -eq 'SHOP-CAT-004 public page' -and $mb.out -eq 'feat/SHOP-CAT-004-public-catalogue-page' -and
  $md.out -eq 'SHOP-CAT-004 Spec v2 — Public catalogue' -and $mc.out -eq 'SHOP-CAT-004-TC03' -and (Kb naming check title $mt.out).code -eq 0 -and (Kb naming check branch $mb.out).code -eq 0)

# ---- DUP-WORDS: a name never repeats its product, a leading area / type word, a repo list (owner 2026-11-23)
$dups = @(@('title', 'SHOP-CAT-001 [Feature] Shop — Catalogue: Public catalogue'), @('title', 'SHOP-CAT-001 [Feature] Catalogue: Catalogue blocks'),
  @('title', 'SHOP-CAT-001 [Feature] Catalogue: page (api, web)'), @('branch', 'feat/SHOP-CAT-004-shop-page'), @('mr', 'feat(web): Shop page [SHOP-CAT-004]'),
  @('doc', 'SHOP-CAT-004 Spec v3 — Spec of the page'), @('item', 'SHOP-CAT-004.2 catalogue-price'))
$dupMiss = @($dups | Where-Object { $r = Kb naming check $_[0] $_[1]; $r.code -ne 1 -or $r.out -notmatch 'DUP-WORDS' } | ForEach-Object { $_[1] })
$dupOk = Kb naming check title 'SHOP-CAT-001 Public catalogue (was G3)'
$mkd = Kb naming make doc key=SHOP-CAT-004 'kind=Testing goals' ver=2 'title=Testing goals for Shop page'; $mkb = Kb naming make branch type=feat key=SHOP-CAT-004 'slug=Shop catalogue blocks' tag=CU-14ab9
Expect "DUP-WORDS: 7 repeating names refused (missed: $($dupMiss -join ' | ')); make strips them ($($mkd.out) | $($mkb.out))" ($dupMiss.Count -eq 0 -and $dupOk.code -eq 0 -and
  $mkd.out -eq 'SHOP-CAT-004 Testing goals v2 — page' -and $mkb.out -eq 'feat/SHOP-CAT-004-cu-14ab9-blocks')

# ---- rename: a dry-run table, old code -> new key; plan registries for codes not yet in kit.local.json
Set-JsonFile "$wd/plan.json" @{ product = 'SHOP'; areas = @{ ORD = 'Orders' }; items = @(
  @{ code = 'G3'; id = 't-1'; area = 'CAT'; title = '[Feature] Shop — v2 G3 Public catalogue endpoint (api, web)' },
  @{ code = 'G5'; id = 't-2'; area = 'ORD'; title = '[Feature] Shop — v2 G5 Cart held in the browser (web)' },
  @{ code = 'G4'; id = 't-3'; area = 'CAT'; title = '[Feature] Shop — v2 G4 Catalogue blocks (web)' },
  @{ code = 'Z1'; id = 't-4'; area = 'BAD'; title = 'Z1 something' }, @{ code = 'G9'; id = 't-5'; title = 'SHOP-PAY-003 [Feature] Shop — Payments: Payments refunds (was G9)' }) }
$rn = Kb naming rename --plan "$wd/plan.json"
Expect "rename: dry-run rows G3 -> SHOP-CAT-001, G5 -> SHOP-ORD-001, G4 -> SHOP-CAT-002, unknown AREA flagged, exit 1 ($($rn.code))" ($rn.code -eq 1 -and
  $rn.out -match '\| G3 \| t-1 \| .* \| SHOP-CAT-001 \| SHOP-CAT-001 Public catalogue endpoint \(was G3\) \| feature, shop, catalogue \| — \| — \|' -and $rn.out -match '\| G5 \| t-2 \|.*\| SHOP-ORD-001 \|' -and
  $rn.out -match '\| G4 \| t-3 \|.*\| SHOP-CAT-002 \|' -and $rn.out -match 'unknown AREA BAD' -and $rn.out -match 'DRY RUN' -and $rn.out -match 'naming seed SHOP-CAT 2' -and
  $rn.out -match '\| G9 \| t-5 \|.*\| SHOP-PAY-003 \| SHOP-PAY-003 refunds \(was G9\) \| feature, shop, payments \| — \| — \|')
# ---- tags (owner 2026-11-24): one vocabulary; an exclusive group keeps one value (an old 'wave: <x> wave 1' label too); -value drops one; off-vocabulary refused
$tg1 = Kb naming tags key=SHOP-CAT-004 kind=Bug wave=2 --have 'wave: v2 wave 1,urgent'; $tg2 = Kb naming tags env=needs-deploy decision=-needs-owner --have 'on-stg,needs-owner,bug'; $tg3 = Kb naming tags risk=nope
$tj1 = $tg1.out | ConvertFrom-Json; $tj2 = $tg2.out | ConvertFrom-Json
Expect "tags: kind, product, area, wave-2 replace the old wave label; env one value, decision value dropped; unknown value exit 1 ($($tj1.tags -join ',') | $($tj2.tags -join ','))" (($tj1.tags -join ',') -eq 'urgent,bug,shop,catalogue,wave-2' -and
  ($tj1.remove -join ',') -eq 'wave: v2 wave 1' -and ($tj2.tags -join ',') -eq 'bug,needs-deploy' -and ($tj2.remove -join ',') -eq 'on-stg,needs-owner' -and $tg3.code -eq 1 -and $tg3.out -match 'not in the vocabulary')
# review: a re-run keeps a new-style bug a bug; a repo word equal to an AREA code is a repo tag; a person's 'team=core' label is no part; two waves refused
Set-JsonFile "$wd/plan2.json" @{ items = @(@{ id = 't-9'; title = 'SHOP-CAT-007 crash on save'; tags = @('bug', 'shop') }) }; $rn2 = Kb naming rename --plan "$wd/plan2.json" --json
$tg4 = Kb naming tags key=SHOP-CAT-004 repo=cat-svc --have 'team=core'; $tg5 = Kb naming tags 'wave=1,2'
Expect "tags review: rerun keeps bug, repo tag 'cat', a person's label kept, one wave ($($tg4.out) | $($rn2.out -replace '\s+', ' '))" ((($rn2.out | ConvertFrom-Json).tags -join ',') -eq 'bug,shop,catalogue' -and
  (($tg4.out | ConvertFrom-Json).tags -join ',') -eq 'team=core,cat,shop,catalogue' -and $tg5.code -eq 1 -and $tg5.out -match 'one value at a time')
# naming.titleStrip (owner 2026-11-24): org regexes cut old codes from retag titles
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue'; PAY = 'Payments' }; titleStrip = @('^Old v1 [A-Z]\d+\s+', '\s*\(was K\d\)') } }
Set-JsonFile "$wd/plan3.json" @{ items = @(@{ id = 't-8'; title = 'SHOP-CAT-008 [Feature] Catalogue: Old v1 G2 Price list (was K1)' }) }; $rn3 = Kb naming rename --plan "$wd/plan3.json" --json
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue'; PAY = 'Payments' } } }
Expect "titleStrip: old codes cut ($($rn3.out -replace '\s+', ' '))" (($rn3.out | ConvertFrom-Json).title -eq 'SHOP-CAT-008 Price list')
$sd = Kb naming seed SHOP-CAT 7; $k4 = Kb naming next key SHOP CAT; $mi = Kb naming make title key=BAD-X-1 product=ZZ area=Q outcome=x; $mn = Kb naming make case key=SHOP-CAT-004 n=abc
Expect "seed: next key after the migrated ones; make refuses a name off the standard (1) or a bad number (2) ($($k4.out) $($mi.code)$($mn.code))" ($sd.code -eq 0 -and $k4.out -eq 'SHOP-CAT-008' -and
  $mi.code -eq 1 -and $mi.out -match 'NAME title' -and $mn.code -eq 2)

# ---- tracker create: every new task keyed and named by naming make (spec area; a free-text bug: the parent's key); update keeps a live key
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $env:KIT_TRACKER_TYPE = 'none'
$tSpec = @{ kind = 'Feature'; title = 'Shop catalogue blocks (web)'; area = 'CAT'; list = 'L1'; problem = 'No blocks.'; goal = 'Blocks on pages.'; items = @(@{ code = 'A1'; desc = 'grid' }); acceptance = @('grid shows') } | ConvertTo-Json -Compress -Depth 5
$tDry = pwsh -NoProfile -File $D tracker render -Spec $tSpec 2>$null | ConvertFrom-Json; $tNew = pwsh -NoProfile -File $D tracker create -Spec $tSpec 2>$null | ConvertFrom-Json
$tBug = pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-1 -List L1 -Parent $tNew.id -Name 'Shop: crash on save' -Description 'd' 2>$null | ConvertFrom-Json; $tBug = pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json
$tNewV = pwsh -NoProfile -File $D tracker view $tNew.id 2>$null | ConvertFrom-Json; $tUpd = pwsh -NoProfile -File $D tracker update $tNew.id -Spec (@{ title = 'Catalogue blocks and nav' } | ConvertTo-Json -Compress) 2>$null | ConvertFrom-Json
$DT = Join-Path $k 'skills/crafty/devtools.py'; Set-JsonFile "$wd/mr.json" @{ type = 'feat'; scope = 'web'; change = 'Shop catalogue grid page'; task = $tNew.id }
$tMr = (& $py -X utf8 $DT render mr-title "$wd/mr.json" 2>$null | Out-String).Trim(); $tCm = @(& $py -X utf8 $DT render commit "$wd/mr.json" 2>$null)[0]
Set-Content "$wd/goals.md" "# goals`n`n| Check | Expected |`n|---|---|`n| C1 | grid |"; $null = & $py -X utf8 $DT doc 'T1 testing goals' "$wd/goals.md" --key "$($tNew.id):testing-goals" 2>$null
$null = & $py -X utf8 $DT doc 'T1 testing goals' "$wd/goals.md" --key "$($tNew.id):testing-goals" 2>$null; Set-Content "$wd/goals.md" "# goals v2"
$null = & $py -X utf8 $DT doc 'T1 testing goals' "$wd/goals.md" --key "$($tNew.id):testing-goals" 2>$null
$tDoc = (Get-ChildItem (TkPath $k published) -Filter '*testing-goals*.json' | Get-Content -Raw | ConvertFrom-Json).title
$tBr = Invoke-PsTest branch @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; Get-KitTaskBranch $args[1]; try { Get-KitTaskBranch $args[2] } catch { "REFUSED $_" }
'@ @($D, $tBug.id, (pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-2 -List L1 -Name 'Loose bug' -Description 'd' 2>$null | ConvertFrom-Json).id)
$tTyped = pwsh -NoProfile -File $D tracker create -List L2 -Spec (@{ kind = 'feature'; title = 'SHOP-CAT-999 [Feature] Catalogue: typed key'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'A1'; desc = 'x' }); acceptance = @('a') } | ConvertTo-Json -Compress -Depth 4) 2>$null | ConvertFrom-Json
$tArea = Invoke-PsTest samearea @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; "$(Test-KitSameArea 'SHOP-CAT-012 [Bug] Catalogue: x' $args[1])|$(Test-KitSameArea 'SHOP-PAY-001 [Bug] Payments: x' $args[1])|$(Test-KitSameArea '[Bug] old collector' $args[1])"
'@ @($D, $tNew.id)
Expect "tracker create: a typed key names only PRODUCT-AREA (next number, one type tag), -List fills the spec; a QA bug joins only its area's collector ($($tTyped.name) | $tArea)" (
  $tTyped.name -eq 'SHOP-CAT-011 typed key' -and (pwsh -NoProfile -File $D tracker view $tTyped.id 2>$null | ConvertFrom-Json).list -eq 'L2' -and "$tArea" -eq 'True|False|False')
$null = pwsh -NoProfile -File $D tracker create -List L2 -Spec (@{ kind = 'feature'; title = 'Catalogue typed key'; area = 'CAT'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'A1'; desc = 'x' }); acceptance = @('a') } | ConvertTo-Json -Compress -Depth 4) 2>$null; $tDupC = $LASTEXITCODE
$tNext = pwsh -NoProfile -File $D tracker create -List L2 -Spec (@{ kind = 'chore'; title = 'Price import job'; area = 'CAT'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'A1'; desc = 'x' }); acceptance = @('a') } | ConvertTo-Json -Compress -Depth 4) 2>$null | ConvertFrom-Json
$null = pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-1 -List L1 -Parent $tNew.id -Name 'Shop: crash on save again' -Description 'd2' 2>$null; $tReuse = (pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json).name
Expect "tracker create: a refused duplicate burns no key ($tDupC, next $($tNext.name)); a reused QA defect keeps its key ($tReuse)" ($tDupC -ne 0 -and $tNext.name -eq 'SHOP-CAT-012 Price import job' -and $tReuse -match '^SHOP-CAT-010 crash on save again$')
# a hand rename stays on every later kit write: rename keeps the key, update -Spec without a title (devtools finish), the group re-render, a QA re-run
$null = pwsh -NoProfile -File $D tracker rename $tNext.id 'Price import: owner words' 2>$null; $hr1 = (pwsh -NoProfile -File $D tracker view $tNext.id 2>$null | ConvertFrom-Json).name
$null = pwsh -NoProfile -File $D tracker update $tNext.id -Spec (@{ docs = @{ spec = 'https://d/s1' } } | ConvertTo-Json -Compress) 2>$null; $hr2 = (pwsh -NoProfile -File $D tracker view $tNext.id 2>$null | ConvertFrom-Json).name
$hr3 = Invoke-PsTest regroup @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $null = Publish-KitTaskSpec ([ordered]@{}) -Task $args[1]; Clear-TrackerMemo $args[1]; (Get-TrackerTask $args[1]).name
'@ @($D, $tNext.id)
$null = pwsh -NoProfile -File $D tracker rename $tBug.id 'SHOP-CAT-010 owner bug words' 2>$null
$null = pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-1 -List L1 -Parent $tNew.id -Name 'Shop: crash third time' -Description 'd3' 2>$null; $hr4 = (pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json).name
$kfq = Join-Path (TkPath $k published) 'qa-fx-naming-1_task.json'; $kq = Get-Content $kfq -Raw | ConvertFrom-Json; Set-JsonFile $kfq @{ key = $kq.key; id = $kq.id }   # a record from before names were kept
$null = pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-1 -List L1 -Parent $tNew.id -Name 'Shop: crash fourth time' -Description 'd4' 2>$null; $hr5 = (Get-Content $kfq -Raw | ConvertFrom-Json).name
Expect "keyed record without a name: the re-run keeps the title and records it ($hr5)" ($hr5 -ceq 'SHOP-CAT-010 owner bug words' -and (pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json).name -ceq $hr5)
Expect "hand rename kept: rename keeps the key, update / re-render / QA re-run keep the name ($hr1 | $hr2 | $(@($hr3)[-1]) | $hr4)" ($hr1 -ceq 'SHOP-CAT-012 Price import: owner words' -and $hr2 -ceq $hr1 -and "$(@($hr3)[-1])" -ceq $hr1 -and $hr4 -ceq 'SHOP-CAT-010 owner bug words')
Remove-Item Env:KIT_TRACKER_TYPE
Expect "keyed task: MR title, commit subject, doc title (v per changed round), branch (fix/ for a bug, the tracker tag kept); no key: -Branch needed ($tMr | $tCm | $tDoc | $($tBr -join ' | '))" (
  $tMr -eq 'feat(web): grid page [SHOP-CAT-009]' -and $tCm -eq 'feat(web): grid page [SHOP-CAT-009]' -and $tDoc -eq 'SHOP-CAT-009 Testing goals v2 — blocks and nav' -and
  @($tBr)[0] -match '^fix/SHOP-CAT-010-local-\d+-crash-on-save$' -and "$tBr" -match 'REFUSED .*no kit key')
Expect "tracker: render previews <P>-<A>-000, create allocates; a bug under it takes the parent's key; update keeps it; tags kind product area ($($tDry.name) | $($tNew.name) | $($tBug.name) | $($tUpd.name) | $($tNewV.tags) | $($tBug.tags))" (
  $tDry.name -eq 'SHOP-CAT-000 blocks' -and $tNew.name -eq 'SHOP-CAT-009 blocks' -and $tBug.name -eq 'SHOP-CAT-010 crash on save' -and $tUpd.name -eq 'SHOP-CAT-009 blocks and nav' -and
  ($tNewV.tags -join ',') -eq 'feature,shop,catalogue' -and ($tBug.tags -join ',') -eq 'bug,shop,catalogue,qa-found')
# owner 2026-11-24: a wave's area subtask is keyed from its parent; a rename never drops a key or type (RM-AGT-001 vanished by hand)
$env:KIT_TRACKER_TYPE = 'none'
$tSub = pwsh -NoProfile -File $D tracker create -Spec (@{ kind = 'Feature'; title = '[Feature] Shop Catalogue fix wave — grid page (web)'; parent = $tNew.id; newTask = 'wave area'; list = 'L1'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'A1'; desc = 'grid' }); acceptance = @('a'); links = @('https://x.example/1') } | ConvertTo-Json -Compress -Depth 5) 2>$null | ConvertFrom-Json
$null = pwsh -NoProfile -File $D tracker rename $tNew.id 'blocks and footer'; $null = pwsh -NoProfile -File $D tracker rename $tBug.id 'crash on load'
$tRn = (pwsh -NoProfile -File $D tracker view $tNew.id 2>$null | ConvertFrom-Json).name; $tRb = (pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json).name; Remove-Item Env:KIT_TRACKER_TYPE
Expect "keyed titles: a wave area subtask gets '<KEY> <outcome>' from its parent; tracker rename without a key keeps key (type: a tag) ($($tSub.name) | $tRn | $tRb)" (
  "$($tSub.name)" -match '^SHOP-CAT-\d{3} [a-z]' -and "$($tSub.name)" -cnotmatch 'Shop|Catalogue|\[|\(web\)' -and $tRn -eq 'SHOP-CAT-009 blocks and footer' -and $tRb -eq 'SHOP-CAT-010 crash on load')

# ---- standard flags (-Mr -Lane -TimeoutSeconds -Resume): the old names keep working one version; stamps: one helper per use
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$fr = Px $O decide record -Gate deploy -Item fx -Mr 'api!8' -Question q -Answer y -Source askuser | Out-String; $fw = Px $O decide check -Gate deploy -Mrs 'grp/api!8' | Out-String
$fl = foreach ($ff in 'skills/bossy/bossy.ps1', 'skills/crafty/crafty.ps1', 'skills/pokey/pokey.ps1', 'skills/phoney/phoney.ps1', 'skills/bossy/adapters/deploys.ps1') {
  $fa = [Management.Automation.Language.Parser]::ParseFile((Join-Path $src $ff), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.ParameterAst] }, $true)
  $fstd = @{ Mrs = 'Mr'; Lanes = 'Lane'; TimeoutSec = 'TimeoutSeconds'; Takeover = 'Resume' }   # a block that has the standard name already keeps the old one
  @($fa | Where-Object { ($fo = $_.Name.VariablePath.UserPath) -in $fstd.Keys -and -not ($_.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }) -and
    $fstd[$fo] -notin @($_.Parent.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } | ForEach-Object { "$ff $($_.Name)" }) }
# FLAGS-REST: every verb function (Invoke-*) takes -Item (old -Task / -Code), -Text (old -Message / -Msg), whole-word Seconds / Minutes
$fl += foreach ($ff in Get-ChildItem (Join-Path $src 'skills') -Recurse -Filter '*.ps1') {
  foreach ($fd in [Management.Automation.Language.Parser]::ParseFile($ff.FullName, [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -like 'Invoke-*' }, $true)) {
    $fps = if ($fd.Body.ParamBlock) { @($fd.Body.ParamBlock.Parameters) } else { @($fd.Parameters) }; $fnm = @($fps | ForEach-Object { $_.Name.VariablePath.UserPath }) + @($fps.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments.Value })
    foreach ($fp in $fps) { $fo = $fp.Name.VariablePath.UserPath
      $fwant = if ($fo -in 'Task', 'Code') { 'Item' } elseif ($fo -in 'Message', 'Msg') { 'Text' } elseif ($fo -cmatch '^([A-Z]\w*?)(Sec|Min)$') { "$($Matches[1])$(@{ Sec = 'Seconds'; Min = 'Minutes' }[$Matches[2]])" }
      if ($fwant -and $fwant -notin $fnm -and -not ($fo -eq 'Code' -and 'Task' -in $fnm)) { "$($ff.Name) $($fd.Name) -$fo" } } } }
$fs = pwsh -NoProfile -Command ". '$(Lib)'; Get-KitStamp file ([datetime]'2026-11-23T10:05:06Z'); Get-KitStamp stored ([datetime]'2026-11-23T10:05:06.5Z')"
Expect "flags: -Mr records, -Mrs finds it; every -Mrs / -Lanes / -TimeoutSec / -Takeover and verb -Task / -Code / -Message / -*Sec / -*Min has its standard alias ($($fl -join ', ')); stamps ($($fs -join ' '))" ($fr -match 'RECORDED' -and $fw -match 'WORD ' -and
  -not @($fl | Where-Object { $_ }).Count -and $fs[0] -eq '20261123-100506' -and $fs[1] -eq '2026-11-23T10:05:06.500Z')
# TS-STORED: writers store UTC ...Z; a fresh ...Z beat reads as local (board HH:mm local, age ~0, never stale)
$tsOut = Px $O board join -Type devy -Agent tsz-01 -Run tsr | Out-String; $tsFile = @(Get-ChildItem (TkPath $k board) -Filter 'tsz-01*.json')[0].FullName
$tsRaw = Get-Content -LiteralPath $tsFile -Raw; $tsLocal = ([datetimeoffset]($tsRaw | ConvertFrom-Json -DateKind String).beat).LocalDateTime.ToString('HH:mm'); $tsShow = Px $O board show | Out-String
$tsRead = pwsh -NoProfile -Command ". '$(Lib)'; `$e = Get-Content -LiteralPath '$tsFile' -Raw | ConvertFrom-Json; [int][math]::Abs(((Get-Date) - [datetime]`$e.beat).TotalMinutes); ([datetime]`$e.beat).ToString('HH:mm')"
$tsLeft = Px $O board leave -Agent tsz-01 | Out-String
Expect "TS-STORED: board beat stored as UTC ...Z, read back local ($($tsRead -join ' ')) and shown as local $tsLocal, not stale" ($tsRaw -match '"beat":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"' -and
  [int]$tsRead[0] -le 1 -and $tsRead[1] -eq $tsLocal -and $tsShow -match "tsz-01.*\| beat $tsLocal" -and $tsShow -notmatch 'STALE|QUIET')

# ---- scan: live names (a published doc title) vs the standard
$pub = TkPath $k published -Create; Set-JsonFile (Join-Path $pub 'T1_testing-ai.json') @{ key = 'T1:testing-ai'; title = 'T1 testing doc (AI)' }
$sc = Kb naming scan
Expect "scan: an ad hoc doc title is named with where it lives ($($sc.code))" ($sc.code -eq 1 -and $sc.out -match "WARN NAME published T1:testing-ai: doc 'T1 testing doc \(AI\)'")

# ---- lint: a registry code that is no 2-6 capitals
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ 'cat-1' = 'x' } } }
# NAME-FILE: a snake_case .ps1 is a problem; a hook entry point (named by settings.json, or by a script it names) is exempt
$nfA = Join-Path $k 'skills/crafty/adapters/fake_snake.ps1'; Set-Content $nfA '# fixture'
$nfH = Join-Path $k 'skills/crafty/hook_one.mjs'; Set-Content $nfH "// spawns hook_two.ps1"; Set-Content (Join-Path $k 'skills/crafty/hook_two.ps1') '# fixture'
$nfK = Join-Path $k 'skills/crafty/adapters/kebab-one.ps1'; Set-Content $nfK '# fixture'; $nfD = Join-Path $k 'skills/crafty/old-ref.md'; Set-Content $nfD "see adapters/kebab_one.ps1`nor adapters/kebab_one"; $nfL = Join-Path $k 'skills/crafty/adapters/org-x.local.ps1'; Set-Content $nfL '# fixture'
$nfS = Join-Path $k 'settings.json'; $nfS0 = if (Test-Path $nfS) { Get-Content $nfS -Raw }; Set-Content $nfS '{"hooks":{"PreToolUse":[{"hooks":[{"command":"node skills/crafty/hook_one.mjs"}]}]}}'
Set-Content (Join-Path $k "AGENTS.md") "# kit"; $ln = Kb lint $k
Expect 'lint NAME-CONFIG: a lower-case / punctuated area code is a problem' ($ln.out -match "NAME-CONFIG\s+kit.local.json: naming.areas code 'cat-1'")
Expect "lint NAME-FILE: a snake_case .ps1 counts; hook entry points (settings.json -> hook_one.mjs -> hook_two.ps1) are exempt" ($ln.out -match 'NAME-FILE\s+skills/crafty/adapters/fake_snake.ps1' -and $ln.out -notmatch 'NAME-FILE\s+skills/crafty/hook_(one|two)')
Expect 'lint OLD-NAME: the snake_case form of a live kebab-case script is its old name (no manifest row); an org overlay x.local.ps1 is no NAME-FILE' ($ln.out -match 'OLD-NAME\s+skills/crafty/old-ref.md:1: old name "kebab_one.ps1" \(now "kebab-one.ps1"\)' -and $ln.out -notmatch 'NAME-FILE\s+\S+org-x.local.ps1')
Set-Content $nfD 'or adapters/kebab_one'; $ln2 = Kb lint $k
Expect 'lint OLD-NAME: adapters/<snake stem> without an extension is the old name too' ($ln2.out -match 'OLD-NAME\s+skills/crafty/old-ref.md:1: old name "kebab_one.ps1"')
Remove-Item $nfA, $nfH, $nfK, $nfD, $nfL, (Join-Path $k 'skills/crafty/hook_two.ps1'); if ($null -ne $nfS0) { Set-Content $nfS $nfS0 -NoNewline } else { Remove-Item $nfS }
Set-Content "$lc.bak" '{}'; Set-Content "$lc.bak-0042" '{}'; Set-Content "$lc.bak-20261123-100506" '{}'; $lw = Kb lint $k --warn
Expect "lint --warn: NAME-BACKUP for a backup off <file>.bak-<nnnn> (NO-DATE; the old dated form passes one version) (not counted: exit $($lw.code))" (
  $lw.out -match 'WARN NAME-BACKUP skills/crafty/kit.local.json.bak:' -and $lw.out -notmatch 'NAME-BACKUP \S+\.bak-(0042|20261123-100506)')

# run lineage: a fresh agent of the same type on the next suffix run (kit-x-1520c -> kit-x-1520d) continues the handoff; another run does not
& $J @{ agent = 'kitty-kit-x-1520c'; type = 'kitty'; session = 'kx-a'; run = 'kit-x-1520c'; status = 'left'; handoffBrief = 'C:/b/kx.md'; joined = (Get-Date).AddHours(-2).ToString('o'); beat = (Get-Date).AddMinutes(-30).ToString('o') } (Join-Path (TkPath $k board -Create) 'kx-a.json')
$lnOther = Px $O board join -Type kitty -Agent kitty-kit-x-1530 -Run kit-x-1530 | Out-String; $lnMid = @(& { . $O; Get-KitHandoffs 24 }).agent -contains 'kitty-kit-x-1520c'
$lnJoin = Px $O board join -Type kitty -Agent kitty-kit-x-1520d -Run kit-x-1520d | Out-String; $lnAfter = @(& { . $O; Get-KitHandoffs 24 }).agent -contains 'kitty-kit-x-1520c'
Expect "handoff lineage: kitty-kit-x-1520d continues kitty-kit-x-1520c (CONTINUE, no HANDOFF left); kit-x-1530 does not" ($lnOther -notmatch 'CONTINUE' -and $lnMid -and $lnJoin -match 'CONTINUE: the previous kitty-kit-x-1520c \(kit-x-1520c\) handed off.*C:/b/kx\.md' -and -not $lnAfter)
# ---- N3 (owner 2026-11-23): board join gives <role>-<nn> (same run + area: the same id); legacy <role>-<run> aliased; labels
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$bj = { param($bjArgs) $bo = pwsh -NoProfile -File $O board join @bjArgs | Out-String; [pscustomobject]@{ id = $(if ($bo -match 'RUN-ID: you are (\S+)') { $Matches[1] }); out = $bo } }
$d1 = & $bj @('-Type', 'devy', '-Run', 'buildy-20261123-01', '-Area', 'area-CAT'); $null = pwsh -NoProfile -File $O board leave -Agent $d1.id
$d2 = & $bj @('-Type', 'devy', '-Run', 'buildy-20261123-01', '-Area', 'area-CAT'); $d3 = & $bj @('-Type', 'devy', '-Run', 'buildy-20261123-01', '-Area', 'area-PAY')
$kc = & $bj @('-Type', 'kitty', '-Run', 'kitty-build-20261123-01', '-Area', 'kit'); $null = pwsh -NoProfile -File $O board msg -Agent t -To kitty-kitty-build-20261123-01 -Text 'via alias'
$kcIn = pwsh -NoProfile -File $O board inbox -Agent $kc.id | Out-String; $co = & $bj @('-Type', 'coordinator')
$null = pwsh -NoProfile -File $O board join -Type devy -Agent api -Run buildy-old -Area api; $lg = & $bj @('-Type', 'devy', '-Run', 'buildy-old', '-Area', 'api')
Expect "board join: <role>-<nn>; the next phase of a run's area keeps it; another area a new one; <type>-<run> msg reaches it; the coordinator keeps its name; a live legacy row keeps its id ($($d1.id) $($d2.id) $($d3.id) $($kc.id))" (
  $d1.id -match '^devy-\d{2,}$' -and $d2.id -eq $d1.id -and $d3.id -match '^devy-\d{2,}$' -and $d3.id -ne $d1.id -and $kc.id -match '^kitty-\d{2,}$' -and $kcIn -match 'via alias' -and -not $co.id -and $co.out -match 'SESSION coordinator-[0-9a-f]{8}' -and $lg.id -eq 'api')
Set-JsonFile (Join-Path (TkPath $k launches -Create) 'self-buildy-n3.json') @{ script = 'buildy.js'; run = 'buildy-20261123-01'; at = '2026-11-23T10:00:00.000Z'; args = @{ brief = 'b.md'; label = 'SHOP-CAT-004 public price list' } }
$qd = Join-Path (TkPath $k qa-runs -Create) 'testy-20261123-02'; Set-JsonFile (Join-Path $qd 'run.json') @{ label = 'SHOP-PAY-001 card refunds'; started = '2026-11-23T10:00:00.000Z' }
$show = pwsh -NoProfile -File $O board show | Out-String
$lbl = pwsh -NoProfile -Command ". '$O'; Get-KitRunLabel ([pscustomobject]@{ name = 'v2-wave1'; agents = @(@{ items = 'A1, A2, A3' }) }) 'testy-20261123-09'; Get-KitRunLabel ([pscustomobject]@{ runDir = '$qd' }) 'select-x'
  Get-KitAgentLabel ([pscustomobject]@{ n = 'devy-01'; ar = 'area-CAT'; sub = 'devy' }); Get-KitAgentLabel ([pscustomobject]@{ n = 'briefy-v1retest'; sub = 'briefy' }); Get-KitAgentLabel ([pscustomobject]@{ n = 'JC'; sub = 'devy' })
  (Get-KitQaRunStart 'testy-20261123-02').ToString('o'); (Get-KitQaRunStart '2026-11-23-150132-old').ToString('HH:mm:ss')"
Expect "labels: board show '<KEY> <title> (<run id>)' + '<role>-<nn> · <area>'; dashboard runs and agents (no run id: the tooltip has it); QA run start from run.json, legacy folder kept ($($lbl -join ' | '))" (
  $show -match "run SHOP-CAT-004 public price list \(buildy-20261123-01\)" -and $show -match "$($d2.id) · area-CAT" -and $lbl[0] -eq 'v2-wave1 · 3 items' -and
  $lbl[1] -eq 'SHOP-PAY-001 card refunds' -and $lbl[2] -eq 'devy-01 · area-CAT' -and $lbl[3] -eq 'briefy-v1retest' -and $lbl[4] -eq 'JC · devy' -and
  [datetime]$lbl[5] -eq ([datetimeoffset]'2026-11-23T10:00:00Z').LocalDateTime -and $lbl[6] -eq '15:01:32')
# labels drop what the day group and kind chip show (owner 2026-11-24): no date, no role word; a number only on a collision
$ks = & $bj @('-Type', 'kitty', '-Run', 'kitty-fix-0007', '-Subject', 'rest', '-Area', 'kit'); $show2 = pwsh -NoProfile -File $O board show | Out-String
$rnm = pwsh -NoProfile -Command ". '$O'; Format-KitRunName 'kitty-fix-0007' 'rest'; Format-KitRunName 'kitty-20261124-rest'; Format-KitRunName 'buildy-0042'; Format-KitRunName 'v2-wave1'"
$lchk = @('fix: rest', 'kitty-20261124-rest', 'kitty: rest') | ForEach-Object { (Kb naming check label $_).code }
Expect "labels: kind + subject, no date / role word ($($rnm -join ' | '); check $($lchk -join ',')); board join -Subject shows 'fix: rest (kitty-fix-0007)'" (($rnm -join '|') -eq 'fix: rest|rest|buildy|v2-wave1' -and ($lchk -join ',') -eq '0,1,1' -and $show2 -match 'run fix: rest \(kitty-fix-0007\)')
# the wave-brief render names areas area-<AREA> (dependsOn follows, old ids aliased) and the run label '<KEY> <short title>'
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue'; PAY = 'Payments' } } }; $wpy = Join-Path $wd 'wave_ids_check.py'
Set-Content -LiteralPath $wpy -Encoding utf8 -Value @"
import json, sys
sys.path.insert(0, sys.argv[1])
import devtools as d
keys = {'t1': 'SHOP-CAT-004', 't2': 'SHOP-CAT-005', 't3': 'SHOP-PAY-001'}
d.task_key = lambda t: keys.get(t or '', '')
d._KEYS['name:t1'] = 'SHOP-CAT-004 [Feature] Catalogue: public price list for guests'
s = d.wave_ids({'agents': [{'id': 'JC', 'task': 't1', 'dependsOn': ['JP']}, {'id': 'JD', 'task': 't2'}, {'id': 'JP', 'task': 't3'}, {'id': 'X9'}], 'contracts': [{'producer': 'JP', 'consumers': 'JC, X9'}]})
print(json.dumps({'ids': [a['id'] for a in s['agents']], 'dep': s['agents'][0]['dependsOn'], 'label': d.run_label({'task': 't1', 'agents': []}), 'con': s['contracts'][0]}))
"@
$wv = & $py -X utf8 $wpy (Join-Path $k 'skills/crafty') 2>&1 | Select-Object -Last 1 | ConvertFrom-Json
Expect "wave-brief ids: area-CAT, area-CAT-2, area-PAY, a keyless X9 kept; dependsOn and contracts renamed; label without key / [Type] / Area: ($($wv.ids -join ',') · $($wv.label))" (
  ($wv.ids -join ',') -eq 'area-CAT,area-CAT-2,area-PAY,X9' -and $wv.dep[0] -eq 'area-PAY' -and $wv.con.producer -eq 'area-PAY' -and $wv.con.consumers -eq 'area-CAT, X9' -and $wv.label -eq 'SHOP-CAT-004 public price list for guests')
# tidy: the prep step returns the run id (kitbag.py naming next id tidy); worktree, branch and retro file carry it
$jsT = @'
const { calls, agent } = _mock((prompt, o) => o.label === 'prep' ? { ok: true, record: 'RECORDED', prep: JSON.stringify({ work: 1, groups: 0, sec: 1, steps: [], digest: 'd.md', at: 'x' }), run: 'tidy-0004' } : { applied: [], proposedForApproval: [], rejected: [], report: 'r.md' })
run({ kitDir: 'C:/k' }, agent, _n, _n, null).then(() => { const j = calls.find((c) => /Kind retro/.test(c.prompt)) || { prompt: '' }
 console.log(`tidy-run:${/naming next id tidy/.test(calls[0].prompt) && /-Branch kit\/tidy-0004 -Target main -Name tidy-0004;/.test(j.prompt) && /\/tidy-0004\.md\./.test(j.prompt)}`) }).catch(_err)
'@
Expect-Each (Invoke-Js nm-tidy $jsT (Join-Path $src 'workflows/tidy.js')) 'tidy: N3 run id from the prep step: #' 'tidy-run' -Show 8
# a reset counter never hands out an id live on the board (retro tidy-20261123-01): agent ids at join, run ids at naming next id
$lvBd = TkPath $k board -Create; Remove-Item (TkPath $k naming) -ErrorAction SilentlyContinue
& $J @{ agent = 'rechy-01'; type = 'rechy'; session = 'lv-a'; run = 'rlive-0001'; status = 'working'; joined = (Get-Date).ToString('o'); beat = (Get-Date).ToString('o') } (Join-Path $lvBd 'lv-a.json')
$lvJoin = & $bj @('-Type', 'rechy', '-Run', 'lv-run'); $null = pwsh -NoProfile -File $O board leave -Agent $lvJoin.id; $lvRun = Kb naming next id rlive
Expect "id allocator: rechy-01 and rlive-0001 live on the board -> join gives rechy-02, next id rlive-0002 ($($lvJoin.id), $($lvRun.out))" ($lvJoin.id -eq 'rechy-02' -and $lvRun.out -eq 'rlive-0002')
Remove-TestKit $k
Complete-Tests
