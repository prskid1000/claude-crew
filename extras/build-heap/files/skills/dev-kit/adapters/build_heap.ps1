#Requires -Version 7
# build-heap (extra): heap caps for the JVM (Maven, Gradle) and Node builds dev.ps1 gate starts: the learned peak x 1.25 (no
# history: gate.startHeapGB.<maven|gradle|node>), at least gate.heapMinGB; an inherited -Xmx / --max-old-space-size is replaced.
# Dot-sourced from skills/dev-kit/adapters/; Invoke-Gate calls both functions.
function Get-GateHeap([string]$Kind, [double[]]$Peaks, [double]$NeedGB, [double]$Need) {
  $tool = if ($Kind -in 'android-build', 'android-test', 'gradle') { 'gradle' } elseif ($Kind -like 'maven*') { 'maven' }
          elseif ($Kind -in 'ng-test', 'web-build', 'js-test', 'tsc-lint', 'typecheck', 'rn-bundle', 'e2e') { 'node' }
  if (-not $tool) { return $null }
  if (-not $env:GRADLE_OPTS) { $env:GRADLE_OPTS = '-Dorg.gradle.workers.max=4' }
  $minGB = [double](Get-KitSetting 'gate.heapMinGB' 4)
  $start = [double](Get-KitSetting "gate.startHeapGB.$tool" @{ gradle = 12; maven = 8; node = 4 }[$tool])
  $peakMax = ($Peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum
  # G1 free-ratios let the learned peak fall
  $heap = if ($Peaks.Count -ge 2) { [int][math]::Ceiling($peakMax * 1.25) } else { $start }
  $heap = [math]::Min([math]::Max($start, 8), [math]::Max($minGB, $heap))
  if ($NeedGB -le 0 -and $Peaks.Count -lt 2) { $Need = [math]::Max($Need, $heap + 0.5) }   # no history: the heap can fill up
  # a smaller heap thrashes in GC
  $floor = if ($Peaks.Count -ge 2) { [math]::Min($heap, [math]::Max($minGB, [int][math]::Ceiling($peakMax * 1.1))) } else { $minGB }
  [pscustomobject]@{ tool = $tool; heap = $heap; floor = $floor; need = $Need }
}
# sets the env a cap of $GB needs; returns the command (Gradle takes it as a -D: it overrides org.gradle.jvmargs)
function Set-GateHeap([string]$Tool, [int]$GB, [string]$Cmd) {
  $g1 = '-XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000'
  if ($Tool -eq 'maven') { $env:MAVEN_OPTS = "$(([string]$env:MAVEN_OPTS -replace '-Xm[xs]\S+|-XX:\+Use\w+GC|-XX:MaxMetaspaceSize=\S+', '' -replace '\s+', ' ').Trim()) -Xmx${GB}g -XX:MaxMetaspaceSize=512m $g1".Trim() }
  if ($Tool -eq 'node') { $env:NODE_OPTIONS = "$(([string]$env:NODE_OPTIONS -replace '--max-old-space-size=\d+', '' -replace '\s+', ' ').Trim()) --max-old-space-size=$($GB * 1024)".Trim() }
  if ($Tool -eq 'gradle' -and $Cmd -notmatch 'org\.gradle\.jvmargs') {
    $Cmd = ([regex]'(gradlew(\.bat)?|\bgradle)(?=\s|$)').Replace($Cmd, "`$1 `"-Dorg.gradle.jvmargs=-Xmx${GB}g -XX:MaxMetaspaceSize=1g $g1 -Dfile.encoding=UTF-8`"", 1)
  }
  $Cmd
}
