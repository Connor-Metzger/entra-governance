<#
.SYNOPSIS
    Converts Lifecycle Workflow history CSVs downloaded from the admin center into the
    snapshot run-history schema (same columns as snapshot_T0_..._lcw_runs_sanitized.csv).

.DESCRIPTION
    Why: Graph only returns workflow run results for workflows with activity in the past
    7 days (T1 on 2026-11-11 got none). The admin center keeps up to 30 days and can
    download them, one CSV per workflow, but those files:
      - have no workflow name (only its ID)            -> name from Graph if connected, else from the file name
      - show times in the browser's local time zone    -> converted to UTC with -TimeZoneId
      - show a blank user name for deleted users        -> user ID looked up in the raw snapshots in exports\
      - leave Failed Tasks and Errors blank             -> filled from an earlier run file when the same run is in it
    The output has no object IDs or workflow IDs, so it can go in evidence/.

.EXAMPLE
    .\scripts\convert_lcw_history.ps1 -OutFile evidence\M4.1\snapshot_T1_2026-11-11_lcw_runs_sanitized.csv
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$HistoryDir   = "exports\lcw_history",
    [string[]]$RawSnapshots = @("exports\snapshot_T0_2026-10-27.csv", "exports\snapshot_T1_2026-11-11.csv"),
    [string]$EarlierRuns  = "evidence\M1.4\snapshot_T0_2026-10-27_lcw_runs_sanitized.csv",
    [string]$TimeZoneId   = "America/New_York",
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = "Stop"
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)

# object ID -> employee ID / UPN, from the raw snapshots (they keep object_id; evidence copies don't)
$who = @{}
foreach ($f in $RawSnapshots) {
    if (-not (Test-Path $f)) { Write-Warning "Raw snapshot not found: $f"; continue }
    foreach ($r in Import-Csv $f) { if ($r.object_id) { $who[$r.object_id] = $r } }
}
Write-Host ("People known from raw snapshots: {0}" -f $who.Count)

# workflow ID -> name: Graph if connected, otherwise from the file name (jml-m2-history.csv -> JML-M2)
$wfName = @{}
if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) {
    if (Get-MgContext) {
        try {
            $resp = Invoke-MgGraphRequest GET "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/workflows?`$select=id,displayName"
            foreach ($w in $resp.value) { $wfName[$w.id] = $w.displayName }
        } catch { Write-Warning "Could not read workflow names from Graph; using file names." }
    }
}

$earlier = @(); if (Test-Path $EarlierRuns) { $earlier = @(Import-Csv $EarlierRuns) }
function ToUtc([string]$local) {
    if (-not $local) { return "" }
    $d = [datetime]::ParseExact($local.Trim(), "M/d/yyyy, h:mm tt", [Globalization.CultureInfo]::InvariantCulture)
    return [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($d, "Unspecified"), $tz).ToString("yyyy-MM-ddTHH:mm:00Z")
}
function Status([string]$s) {
    switch ($s) { "Completed" { "completed" } "Completed with errors" { "completedWithErrors" } "Failed" { "failed" }
                  "In progress" { "inProgress" } "Queued" { "queued" } default { $s } }
}

$files = @(Get-ChildItem -Path $HistoryDir -Filter *.csv | Sort-Object Name)
if ($files.Count -eq 0) { throw "No CSV files in $HistoryDir." }
$out = New-Object System.Collections.Generic.List[object]
$unknown = 0
foreach ($file in $files) {
    $rows = @(Import-Csv $file.FullName)
    foreach ($r in $rows) {
        $name = if ($wfName.ContainsKey($r.'Workflow ID')) { $wfName[$r.'Workflow ID'] }
                elseif ($file.BaseName -match '^(jml-[a-z]\d)') {
                    $short = $Matches[1].ToUpper()
                    $full = @($earlier | Where-Object { $_.workflow -like "$short *" } | Select-Object -ExpandProperty workflow -First 1)
                    if ($full.Count) { $full[0] } else { $short }
                } else { $file.BaseName }
        $p = $who[$r.'User ID']
        if (-not $p) { $unknown++ }
        $started = ToUtc $r.'Start Date'
        $row = [ordered]@{
            workflow       = $name
            employee_id    = $(if ($p) { $p.employee_id } else { "" })
            upn            = $(if ($p) { $p.upn } elseif ($r.'User Name') { $r.'User Name' } else { "(unknown)" })
            execution_type = $r.'Workflow Execution Type'
            scheduled_utc  = ""
            started_utc    = $started
            completed_utc  = ToUtc $r.'Completed Date'
            status         = Status $r.Status
            tasks_total    = $r.'Total Tasks Count'
            tasks_failed   = $r.'Failed Tasks Count'
            failed_tasks   = $r.'Failed Tasks'
            failure_reason = $r.Errors
        }
        # Same run in the earlier file (to the minute)? Keep its exact times and failure detail.
        $m = @($earlier | Where-Object { $_.employee_id -eq $row.employee_id -and $_.execution_type -eq $row.execution_type -and
                                         $_.started_utc.Length -ge 16 -and $_.started_utc.Substring(0, 16) -eq $started.Substring(0, 16) -and
                                         ($row.workflow -eq $_.workflow -or $_.workflow -like "$($row.workflow) *") })
        if ($m.Count -eq 1) {
            foreach ($k in "workflow", "scheduled_utc", "started_utc", "completed_utc", "failed_tasks", "failure_reason") { if ($m[0].$k) { $row[$k] = $m[0].$k } }
        } elseif ([int]$row.tasks_failed -gt 0 -and -not $row.failed_tasks) {
            $row.failed_tasks = "(not in portal export: see Workflow history > Tasks)"
        }
        $out.Add([pscustomobject]$row)
    }
    Write-Host ("  {0,-24} {1} run(s)" -f $file.Name, $rows.Count)
}
$out = @($out | Sort-Object started_utc, workflow)
New-Item -ItemType Directory -Path (Split-Path $OutFile) -Force | Out-Null
$out | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("Runs: {0} | completed with errors: {1} | failed tasks: {2} | people not found: {3}" -f $out.Count,
    @($out | Where-Object { $_.status -ne "completed" }).Count, ($out | Measure-Object { [int]$_.tasks_failed } -Sum).Sum, $unknown)
$out | Group-Object workflow | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-34} {1}" -f $_.Name, $_.Count) }
Write-Host "Saved: $OutFile"
