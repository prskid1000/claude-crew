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
$good = @{ key = 'SHOP-CAT-004'; item = 'SHOP-CAT-004.2 add-price-projection'; case = 'SHOP-CAT-004-TC03'; title = 'SHOP-CAT-004 [Feature] Shop — Catalogue: public catalogue'
  doc = 'SHOP-CAT-004 Spec v3 — Public catalogue'; run = 'buildy-20261123-01'; id = 'dec-20261123-02'; agent = 'devy-01'; area = 'area-CAT'; lane = 'lane-02'
  branch = 'feat/SHOP-CAT-004-public-catalogue'; mr = 'feat(web): public catalogue page [SHOP-CAT-004]' }
$bad = @{ key = 'WEB-12'; item = 'SHOP-CAT-004.2'; case = 'T1'; title = '[Feature] Shop — G3 catalogue'; doc = 'T1 testing doc (AI)'; run = 'wave-brief-a051'; id = 'd-20261123-x'
  agent = 'T1@150132'; area = 'X1'; lane = 'rm-kestrel'; branch = 'f/CU-14ab-sort'; mr = 'feat: sort (CU-14ab)' }
$gk = @($good.Keys | Where-Object { (Kb naming check $_ $good[$_]).code -ne 0 }); $bk = @($bad.Keys | Where-Object { (Kb naming check $_ $bad[$_]).code -eq 0 })
Expect "check: 12 standard names pass, 12 ad hoc ones fail (good failing: $($gk -join ','); bad passing: $($bk -join ','))" ($gk.Count -eq 0 -and $bk.Count -eq 0)
$ua = Kb naming check key SHOP-ORD-001; $ub = Kb naming check area area-ORD
Expect 'check: an unregistered AREA is named in the refusal' ($ua.code -eq 1 -and $ua.out -match 'unknown AREA ORD' -and $ub.out -match 'unknown AREA ORD')

# ---- make: names from parts fit their own check
$mt = Kb naming make title key=SHOP-CAT-004 type=Feature product=SHOP area=CAT outcome=public-catalogue; $mb = Kb naming make branch type=feat key=SHOP-CAT-004 'slug=Public catalogue page'
$md = Kb naming make doc key=SHOP-CAT-004 kind=Spec ver=2 'title=Public catalogue'; $mc = Kb naming make case key=SHOP-CAT-004 n=3
Expect "make: title, branch, doc, case ($($mt.out) | $($mb.out))" ($mt.out -eq 'SHOP-CAT-004 [Feature] Shop — Catalogue: public-catalogue' -and $mb.out -eq 'feat/SHOP-CAT-004-public-catalogue-page' -and
  $md.out -eq 'SHOP-CAT-004 Spec v2 — Public catalogue' -and $mc.out -eq 'SHOP-CAT-004-TC03' -and (Kb naming check title $mt.out).code -eq 0 -and (Kb naming check branch $mb.out).code -eq 0)

# ---- rename: a dry-run table, old code -> new key; plan registries for codes not yet in kit.local.json
Set-JsonFile "$wd/plan.json" @{ product = 'SHOP'; areas = @{ ORD = 'Orders' }; items = @(
  @{ code = 'G3'; id = 't-1'; area = 'CAT'; title = '[Feature] Shop — v2 G3 Public catalogue endpoint (api, web)' },
  @{ code = 'G5'; id = 't-2'; area = 'ORD'; title = '[Feature] Shop — v2 G5 Cart held in the browser (web)' },
  @{ code = 'G4'; id = 't-3'; area = 'CAT'; title = '[Feature] Shop — v2 G4 Catalogue blocks (web)' },
  @{ code = 'Z1'; id = 't-4'; area = 'BAD'; title = 'Z1 something' }) }
$rn = Kb naming rename --plan "$wd/plan.json"
Expect "rename: dry-run rows G3 -> SHOP-CAT-001, G5 -> SHOP-ORD-001, G4 -> SHOP-CAT-002, unknown AREA flagged, exit 1 ($($rn.code))" ($rn.code -eq 1 -and
  $rn.out -match '\| G3 \| t-1 \| .* \| SHOP-CAT-001 \| SHOP-CAT-001 \[Feature\] Shop — Catalogue: Public catalogue endpoint \| — \|' -and $rn.out -match '\| G5 \| t-2 \|.*\| SHOP-ORD-001 \|' -and
  $rn.out -match '\| G4 \| t-3 \|.*\| SHOP-CAT-002 \|' -and $rn.out -match 'unknown AREA BAD' -and $rn.out -match 'DRY RUN' -and $rn.out -match 'naming seed SHOP-CAT 2')
$sd = Kb naming seed SHOP-CAT 7; $k4 = Kb naming next key SHOP CAT; $mi = Kb naming make title key=BAD-X-1 product=ZZ area=Q outcome=x; $mn = Kb naming make case key=SHOP-CAT-004 n=abc
Expect "seed: next key after the migrated ones; make refuses a name off the standard (1) or a bad number (2) ($($k4.out) $($mi.code)$($mn.code))" ($sd.code -eq 0 -and $k4.out -eq 'SHOP-CAT-008' -and
  $mi.code -eq 1 -and $mi.out -match 'NAME title' -and $mn.code -eq 2)

# ---- scan: live names (a published doc title) vs the standard
$pub = TkPath $k published -Create; Set-JsonFile (Join-Path $pub 'T1_testing-ai.json') @{ key = 'T1:testing-ai'; title = 'T1 testing doc (AI)' }
$sc = Kb naming scan
Expect "scan: an ad hoc doc title is named with where it lives ($($sc.code))" ($sc.code -eq 1 -and $sc.out -match "WARN NAME published T1:testing-ai: doc 'T1 testing doc \(AI\)'")

# ---- lint: a registry code that is no 2-6 capitals
Set-JsonFile $lc @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ 'cat-1' = 'x' } } }
Set-Content (Join-Path $k "AGENTS.md") "# kit"; $ln = Kb lint $k
Expect 'lint NAME-CONFIG: a lower-case / punctuated area code is a problem' ($ln.out -match "NAME-CONFIG\s+kit.local.json: naming.areas code 'cat-1'")
Remove-TestKit $k
Complete-Tests
