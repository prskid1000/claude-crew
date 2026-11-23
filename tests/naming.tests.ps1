#Requires -Version 7
<#
naming.tests.ps1: the naming standard (kitbag.py naming): keys from the PRODUCT / AREA registry, sequential counters, every name kind
checked, names made from parts, the rename dry run (old code -> new key), NAME-CONFIG lint.
Usage: pwsh -NoProfile -File <kit>/tests/naming.tests.ps1 (or tests/kit-tests.ps1 -Area naming).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/kitbag_naming.py')
$k = New-TestKit naming; $KB = Join-Path $k 'skills/bossy/kitbag.py'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd | Out-Null
function Kb { $o = & $py -X utf8 $KB @args 2>&1 | Out-String; [pscustomobject]@{ out = $o.Trim(); code = $LASTEXITCODE } }
$lc = Join-Path $k 'skills/crafty/kit.local.json'
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue'; PAY = 'Payments' } } }

# ---- keys: sequential per PRODUCT-AREA, zero-padded; an unknown code refused
$k1 = Kb naming next key SHOP CAT; $k2 = Kb naming next key SHOP CAT; $k3 = Kb naming next key SHOP PAY; $kx = Kb naming next key SHOP XYZ
Expect "next key: SHOP-CAT-001, -002, SHOP-PAY-001; an unknown AREA refused ($($kx.code))" ($k1.out -eq 'SHOP-CAT-001' -and $k2.out -eq 'SHOP-CAT-002' -and $k3.out -eq 'SHOP-PAY-001' -and
  $kx.code -ne 0 -and $kx.out -match 'unknown AREA XYZ')
$i1 = Kb naming next id buildy; $i2 = Kb naming next id buildy
Expect 'next id: <kind>-<YYYYMMDD>-<nn>, counted per day' ($i1.out -match '^buildy-\d{8}-01$' -and $i2.out -match '^buildy-\d{8}-02$')

# ---- check: every kind, good and bad
$good = @{ key = 'SHOP-CAT-004'; item = 'SHOP-CAT-004.2 add-price-projection'; case = 'SHOP-CAT-004-TC03'; title = 'SHOP-CAT-004 [Feature] Catalogue: public page'
  doc = 'SHOP-CAT-004 Spec v3 — Public catalogue'; run = 'buildy-20261123-01'; id = 'dec-20261123-02'; agent = 'devy-01'; area = 'area-CAT'; lane = 'lane-02'
  branch = 'feat/SHOP-CAT-004-public-catalogue'; mr = 'feat(web): public catalogue page [SHOP-CAT-004]' }
$bad = @{ key = 'WEB-12'; item = 'SHOP-CAT-004.2'; case = 'T1'; title = '[Feature] Shop — G3 catalogue'; doc = 'T1 testing doc (AI)'; run = 'wave-brief-a051'; id = 'd-20261123-x'
  agent = 'T1@150132'; area = 'X1'; lane = 'rm-kestrel'; branch = 'f/CU-14ab-sort'; mr = 'feat: sort (CU-14ab)' }
$gk = @($good.Keys | Where-Object { (Kb naming check $_ $good[$_]).code -ne 0 }); $bk = @($bad.Keys | Where-Object { (Kb naming check $_ $bad[$_]).code -eq 0 })
Expect "check: 12 standard names pass, 12 ad hoc ones fail (good failing: $($gk -join ','); bad passing: $($bk -join ','))" ($gk.Count -eq 0 -and $bk.Count -eq 0)
$ua = Kb naming check key SHOP-ORD-001; $ub = Kb naming check area area-ORD
Expect 'check: an unregistered AREA is named in the refusal' ($ua.code -eq 1 -and $ua.out -match 'unknown AREA ORD' -and $ub.out -match 'unknown AREA ORD')

# ---- make: names from parts fit their own check
$mt = Kb naming make title key=SHOP-CAT-004 type=Feature product=SHOP area=CAT 'outcome=Shop catalogue public page (api, web)'; $mb = Kb naming make branch type=feat key=SHOP-CAT-004 'slug=Public catalogue page'
$md = Kb naming make doc key=SHOP-CAT-004 kind=Spec ver=2 'title=Public catalogue'; $mc = Kb naming make case key=SHOP-CAT-004 n=3
Expect "make: title, branch, doc, case ($($mt.out) | $($mb.out))" ($mt.out -eq 'SHOP-CAT-004 [Feature] Catalogue: public page' -and $mb.out -eq 'feat/SHOP-CAT-004-public-catalogue-page' -and
  $md.out -eq 'SHOP-CAT-004 Spec v2 — Public catalogue' -and $mc.out -eq 'SHOP-CAT-004-TC03' -and (Kb naming check title $mt.out).code -eq 0 -and (Kb naming check branch $mb.out).code -eq 0)

# ---- DUP-WORDS: a name never repeats its product, a leading area / type word, a repo list (owner 2026-11-23)
$dups = @(@('title', 'SHOP-CAT-001 [Feature] Shop — Catalogue: Public catalogue'), @('title', 'SHOP-CAT-001 [Feature] Catalogue: Catalogue blocks'),
  @('title', 'SHOP-CAT-001 [Feature] Catalogue: page (api, web)'), @('branch', 'feat/SHOP-CAT-004-shop-page'), @('mr', 'feat(web): Shop page [SHOP-CAT-004]'),
  @('doc', 'SHOP-CAT-004 Spec v3 — Spec of the page'), @('item', 'SHOP-CAT-004.2 catalogue-price'))
$dupMiss = @($dups | Where-Object { $r = Kb naming check $_[0] $_[1]; $r.code -ne 1 -or $r.out -notmatch 'DUP-WORDS' } | ForEach-Object { $_[1] })
$dupOk = Kb naming check title 'SHOP-CAT-001 [Feature] Catalogue: Public catalogue (was G3)'
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
  $rn.out -match '\| G3 \| t-1 \| .* \| SHOP-CAT-001 \| SHOP-CAT-001 \[Feature\] Catalogue: Public catalogue endpoint \(was G3\) \| — \|' -and $rn.out -match '\| G5 \| t-2 \|.*\| SHOP-ORD-001 \|' -and
  $rn.out -match '\| G4 \| t-3 \|.*\| SHOP-CAT-002 \|' -and $rn.out -match 'unknown AREA BAD' -and $rn.out -match 'DRY RUN' -and $rn.out -match 'naming seed SHOP-CAT 2' -and
  $rn.out -match '\| G9 \| t-5 \|.*\| SHOP-PAY-003 \| SHOP-PAY-003 \[Feature\] Payments: refunds \(was G9\) \| old title DUP-WORDS')
$sd = Kb naming seed SHOP-CAT 7; $k4 = Kb naming next key SHOP CAT; $mi = Kb naming make title key=BAD-X-1 product=ZZ area=Q outcome=x; $mn = Kb naming make case key=SHOP-CAT-004 n=abc
Expect "seed: next key after the migrated ones; make refuses a name off the standard (1) or a bad number (2) ($($k4.out) $($mi.code)$($mn.code))" ($sd.code -eq 0 -and $k4.out -eq 'SHOP-CAT-008' -and
  $mi.code -eq 1 -and $mi.out -match 'NAME title' -and $mn.code -eq 2)

# ---- tracker create: every new task keyed and named by naming make (spec area; a free-text bug: the parent's key); update keeps a live key
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $env:KIT_TRACKER_TYPE = 'none'
$tSpec = @{ kind = 'Feature'; title = 'Shop catalogue blocks (web)'; area = 'CAT'; list = 'L1'; problem = 'No blocks.'; goal = 'Blocks on pages.'; items = @(@{ code = 'A1'; desc = 'grid' }); acceptance = @('grid shows') } | ConvertTo-Json -Compress -Depth 5
$tDry = pwsh -NoProfile -File $D tracker render -Spec $tSpec 2>$null | ConvertFrom-Json; $tNew = pwsh -NoProfile -File $D tracker create -Spec $tSpec 2>$null | ConvertFrom-Json
$tBug = pwsh -NoProfile -File $D tracker create -Key qa-fx-naming-1 -List L1 -Parent $tNew.id -Name 'Shop: crash on save' -Description 'd' 2>$null | ConvertFrom-Json; $tBug = pwsh -NoProfile -File $D tracker view $tBug.id 2>$null | ConvertFrom-Json
$tUpd = pwsh -NoProfile -File $D tracker update $tNew.id -Spec (@{ title = 'Catalogue blocks and nav' } | ConvertTo-Json -Compress) 2>$null | ConvertFrom-Json
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
  $tTyped.name -eq 'SHOP-CAT-011 [Feature] Catalogue: typed key' -and (pwsh -NoProfile -File $D tracker view $tTyped.id 2>$null | ConvertFrom-Json).list -eq 'L2' -and "$tArea" -eq 'True|False|False')
Remove-Item Env:KIT_TRACKER_TYPE
Expect "keyed task: MR title, commit subject, doc title (v per changed round), branch (fix/ for a bug, the tracker tag kept); no key: -Branch needed ($tMr | $tCm | $tDoc | $($tBr -join ' | '))" (
  $tMr -eq 'feat(web): grid page [SHOP-CAT-009]' -and $tCm -eq 'feat(web): grid page [SHOP-CAT-009]' -and $tDoc -eq 'SHOP-CAT-009 Testing goals v2 — blocks and nav' -and
  @($tBr)[0] -match '^fix/SHOP-CAT-010-local-\d+-crash-on-save$' -and "$tBr" -match 'REFUSED .*no kit key')
Expect "tracker: render previews <P>-<A>-000, create allocates; a bug under it takes the parent's key; update keeps it ($($tDry.name) | $($tNew.name) | $($tBug.name) | $($tUpd.name))" (
  $tDry.name -eq 'SHOP-CAT-000 [Feature] Catalogue: blocks' -and $tNew.name -eq 'SHOP-CAT-009 [Feature] Catalogue: blocks' -and $tBug.name -match '^SHOP-CAT-010 \[Bug\] Catalogue: crash on save$' -and $tUpd.name -eq 'SHOP-CAT-009 [Feature] Catalogue: blocks and nav')

# ---- standard flags (-Mr -Lane -TimeoutSeconds -Resume): the old names keep working one version; stamps: one helper per use
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$fr = Px $O decide record -Gate deploy -Item fx -Mr 'api!8' -Question q -Answer y -Source askuser | Out-String; $fw = Px $O decide check -Gate deploy -Mrs 'grp/api!8' | Out-String
$fl = foreach ($ff in 'skills/bossy/bossy.ps1', 'skills/crafty/crafty.ps1', 'skills/pokey/pokey.ps1', 'skills/phoney/phoney.ps1', 'skills/bossy/adapters/deploys.ps1') {
  $fa = [Management.Automation.Language.Parser]::ParseFile((Join-Path $src $ff), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.ParameterAst] }, $true)
  $fstd = @{ Mrs = 'Mr'; Lanes = 'Lane'; TimeoutSec = 'TimeoutSeconds'; Takeover = 'Resume' }   # a block that has the standard name already keeps the old one
  @($fa | Where-Object { ($fo = $_.Name.VariablePath.UserPath) -in $fstd.Keys -and -not ($_.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }) -and
    $fstd[$fo] -notin @($_.Parent.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } | ForEach-Object { "$ff $($_.Name)" }) }
$fs = pwsh -NoProfile -Command ". '$(Lib)'; Get-KitStamp file ([datetime]'2026-11-23T10:05:06Z'); Get-KitStamp stored ([datetime]'2026-11-23T10:05:06.5Z')"
Expect "flags: -Mr records, -Mrs finds it; every -Mrs / -Lanes / -TimeoutSec / -Takeover has its standard alias ($($fl -join ', ')); stamps ($($fs -join ' '))" ($fr -match 'RECORDED' -and $fw -match 'WORD ' -and
  -not @($fl).Count -and $fs[0] -eq '20261123-100506' -and $fs[1] -eq '2026-11-23T10:05:06.500Z')

# ---- scan: live names (a published doc title) vs the standard
$pub = TkPath $k published -Create; Set-JsonFile (Join-Path $pub 'T1_testing-ai.json') @{ key = 'T1:testing-ai'; title = 'T1 testing doc (AI)' }
$sc = Kb naming scan
Expect "scan: an ad hoc doc title is named with where it lives ($($sc.code))" ($sc.code -eq 1 -and $sc.out -match "WARN NAME published T1:testing-ai: doc 'T1 testing doc \(AI\)'")

# ---- lint: a registry code that is no 2-6 capitals
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ 'cat-1' = 'x' } } }
Set-Content (Join-Path $k "AGENTS.md") "# kit"; $ln = Kb lint $k
Expect 'lint NAME-CONFIG: a lower-case / punctuated area code is a problem' ($ln.out -match "NAME-CONFIG\s+kit.local.json: naming.areas code 'cat-1'")
Set-Content "$lc.bak" '{}'; Set-Content "$lc.bak-20261123-100506" '{}'; $lw = Kb lint $k --warn
Expect "lint --warn: NAME-BACKUP for a backup off <file>.bak-<yyyyMMdd-HHmmss>, the standard one passes; NAME-FILE for a snake_case .ps1 (not counted: exit $($lw.code))" (
  $lw.out -match 'WARN NAME-BACKUP skills/crafty/kit.local.json.bak:' -and $lw.out -notmatch 'NAME-BACKUP \S+\.bak-20261123-100506' -and $lw.out -match 'WARN NAME-FILE\s+skills/crafty/adapters/task_items.ps1')
Remove-TestKit $k
Complete-Tests
