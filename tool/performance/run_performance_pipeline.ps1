param(
  [ValidateSet("pr", "nightly", "investigative")]
  [string]$Profile = "pr",
  [ValidateSet("quick", "nightly")]
  [string]$SoakLevel = "",
  [switch]$IncludeSoak,
  [int]$TargetTimeoutSeconds = 0,
  [switch]$ExportOtlp,
  [switch]$EmitVisualArtifacts,
  [string]$ArtifactRoot = "",
  [int]$MaxFailedVisualCases = 0
)

$script = Join-Path $PSScriptRoot "run_performance_pipeline.py"
$args = @(
  "--profile", $Profile
)
if ($SoakLevel -ne "") {
  $args += @("--soak-level", $SoakLevel)
}
if ($TargetTimeoutSeconds -gt 0) {
  $args += @("--target-timeout-seconds", $TargetTimeoutSeconds)
}
if ($IncludeSoak) {
  $args += "--include-soak"
}
if ($ExportOtlp) {
  $args += "--export-otlp"
}
if ($EmitVisualArtifacts) {
  $args += "--emit-visual-artifacts"
}
if ($ArtifactRoot -ne "") {
  $args += @("--artifact-root", $ArtifactRoot)
}
$args += @("--max-failed-visual-cases", $MaxFailedVisualCases)

python $script @args
