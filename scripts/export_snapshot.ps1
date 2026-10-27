<#
.SYNOPSIS
    Exports a point-in-time snapshot of the Keystone tenant: users, birthright group
    membership and Lifecycle Workflow run history (T0 / T1 share this schema).

.DESCRIPTION
    Two files per snapshot:
      snapshot_<Label>_<date>.csv           one row per HR-sourced user (has employeeId)
      snapshot_<Label>_<date>_lcw_runs.csv  one row per Lifecycle Workflow run per user

    Raw files go to exports/ (gitignored: they contain object IDs).
    With -EvidenceDir, sanitized copies (no object IDs) go to evidence/<module>/.

    Hire and leave dates are exported as full UTC timestamps (the workflow triggers),
    so a T1 snapshot can be compared field by field with T0.

    Needs: User.Read.All (or ReadWrite), User-LifeCycleInfo.Read.All, Group.Read.All,
    LifecycleWorkflows.Read.All.

.EXAMPLE
    .\scripts\export_snapshot.ps1 -Label T0 -EvidenceDir evidence/M1.4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Label,
    [string]$ExportDir    = "exports",
    [string]$EvidenceDir  = "",
    [string]$GroupPrefix  = "BR-"     # birthright groups (M1.2)
)
$ErrorActionPreference = "Stop"
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

function Format-Utc($d) {
    # Graph returns UTC. Accepts DateTime (any Kind), DateTimeOffset or an ISO string.
    if (-not $d) { return "" }
    if ($d -is [DateTimeOffset]) { $dt = $d.UtcDateTime }
    elseif ($d -is [DateTime] -and $d.Kind -eq [DateTimeKind]::Unspecified) { $dt = [DateTime]::SpecifyKind($d, [DateTimeKind]::Utc) }
    else { $dt = ([datetime]$d).ToUniversalTime() }
    return $dt.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Read every page of a Graph collection (Invoke-MgGraphRequest returns one page at a time)
function Get-GraphAll([string]$Uri) {
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri
        foreach ($v in $resp.value) { $items.Add($v) }
        $Uri = $resp.'@odata.nextLink'
    }
    return ,($items.ToArray())   # a plain array (a List of hashtables breaks @())
}

# ---------- 1. Users ----------
$props = "id,displayName,userPrincipalName,employeeId,department,jobTitle,officeLocation," +
         "employeeType,employeeHireDate,employeeLeaveDateTime,accountEnabled,createdDateTime"
$users = @(Get-MgUser -All -Property $props -ExpandProperty manager)

$idToEmp = @{}; $idToUpn = @{}
foreach ($u in $users) { $idToEmp[$u.Id] = $u.EmployeeId; $idToUpn[$u.Id] = $u.UserPrincipalName }

# ---------- 2. Birthright group membership ----------
Write-Host "Birthright groups:"
$groups = @(Get-MgGroup -Filter "startswith(displayName,'$GroupPrefix')" -All -Property "id,displayName" |
    Sort-Object DisplayName)
$memberOf = @{}   # user id -> list of role ids (BR-01, BR-02...)
foreach ($g in $groups) {
    $roleId = ($g.DisplayName -split " ")[0]
    $members = @(Get-MgGroupMember -GroupId $g.Id -All)
    Write-Host ("  {0,-34} {1,4} members" -f $g.DisplayName, $members.Count)
    foreach ($m in $members) {
        if (-not $memberOf.ContainsKey($m.Id)) { $memberOf[$m.Id] = New-Object System.Collections.Generic.List[string] }
        $memberOf[$m.Id].Add($roleId)
    }
}

$rows = foreach ($u in $users | Where-Object { $_.EmployeeId } | Sort-Object EmployeeId) {
    $mgrEmp = $null
    if ($u.Manager -and $u.Manager.Id) { $mgrEmp = $idToEmp[$u.Manager.Id] }
    [pscustomobject]@{
        object_id           = $u.Id
        employee_id         = $u.EmployeeId
        upn                 = $u.UserPrincipalName
        display_name        = $u.DisplayName
        department          = $u.Department
        job_title           = $u.JobTitle
        office_location     = $u.OfficeLocation
        employee_type       = $u.EmployeeType
        hire_datetime_utc   = Format-Utc $u.EmployeeHireDate
        leave_datetime_utc  = Format-Utc $u.EmployeeLeaveDateTime
        account_enabled     = $u.AccountEnabled
        manager_employee_id = $mgrEmp
        birthright_groups   = $(if ($memberOf.ContainsKey($u.Id)) { ($memberOf[$u.Id] | Sort-Object) -join ";" } else { "" })
    }
}

# ---------- 3. Lifecycle Workflow run history ----------
# L2 deletes leavers, and Get-MgUser no longer returns them. Look them up in the
# recycle bin so their runs still show an employee ID.
try {
    $deleted = Get-GraphAll "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?`$select=id,employeeId,userPrincipalName"
    foreach ($d in $deleted) {
        if (-not $idToEmp.ContainsKey($d.id)) { $idToEmp[$d.id] = $d.employeeId; $idToUpn[$d.id] = "$($d.userPrincipalName) (deleted)" }
    }
} catch { Write-Warning "Could not read deleted users: $($_.Exception.Message)" }

$workflows = Get-GraphAll "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/workflows?`$select=id,displayName"
$wfBase = "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/workflows"
$runs = foreach ($wf in $workflows) {
    $results = Get-GraphAll "$wfBase/$($wf.id)/userProcessingResults"
    foreach ($r in $results) {
        $subjectId = if ($r.subject) { $r.subject.id } else { $null }
        $failedTasks = ""; $failureReason = ""
        if ([int]$r.failedTasksCount -gt 0) {
            $tasks = Get-GraphAll "$wfBase/$($wf.id)/userProcessingResults/$($r.id)/taskProcessingResults?`$expand=task"
            $bad = @($tasks | Where-Object { $_.processingStatus -eq "failed" })
            $failedTasks   = ($bad | ForEach-Object { if ($_.task) { $_.task.displayName } else { "(task name not returned)" } }) -join "; "
            $failureReason = ($bad | ForEach-Object { $_.failureReason }) -join "; "
        }
        [pscustomobject]@{
            workflow       = $wf.displayName
            workflow_id    = $wf.id
            run_id         = $r.id
            user_object_id = $subjectId
            employee_id    = $(if ($subjectId -and $idToEmp.ContainsKey($subjectId)) { $idToEmp[$subjectId] } else { "" })
            upn            = $(if ($subjectId -and $idToUpn.ContainsKey($subjectId)) { $idToUpn[$subjectId] } else { "(unknown)" })
            execution_type = $r.workflowExecutionType
            scheduled_utc  = Format-Utc $r.scheduledDateTime
            started_utc    = Format-Utc $r.startedDateTime
            completed_utc  = Format-Utc $r.completedDateTime
            status         = $r.processingStatus
            tasks_total    = $r.totalTasksCount
            tasks_failed   = $r.failedTasksCount
            failed_tasks   = $failedTasks
            failure_reason = $failureReason
        }
    }
}
$runs = @($runs | Sort-Object started_utc, workflow)

# ---------- 4. Write files ----------
$date = Get-Date -Format "yyyy-MM-dd"
New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
$rawUsers = Join-Path $ExportDir "snapshot_${Label}_$date.csv"
$rawRuns  = Join-Path $ExportDir "snapshot_${Label}_${date}_lcw_runs.csv"
$rows | Export-Csv -Path $rawUsers -NoTypeInformation -Encoding UTF8
$runs | Export-Csv -Path $rawRuns -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host ("Users in tenant: {0} | HR-sourced: {1} | enabled: {2} | with a leave date: {3} | in a birthright group: {4}" -f `
    $users.Count, @($rows).Count, @($rows | Where-Object account_enabled).Count,
    @($rows | Where-Object leave_datetime_utc).Count, @($rows | Where-Object birthright_groups).Count)
Write-Host ("Workflows: {0} | Runs: {1}" -f @($workflows).Count, $runs.Count)
$runs | Group-Object workflow, status | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-40} {1}" -f $_.Name, $_.Count) }
$runs | Where-Object upn -eq "(unknown)" | ForEach-Object { Write-Warning "Run in '$($_.workflow)' has no matching user (object $($_.user_object_id))" }
Write-Host "Raw users:          $rawUsers"
Write-Host "Raw run history:    $rawRuns"

if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $cleanUsers = Join-Path $EvidenceDir "snapshot_${Label}_${date}_sanitized.csv"
    $cleanRuns  = Join-Path $EvidenceDir "snapshot_${Label}_${date}_lcw_runs_sanitized.csv"
    $rows | Select-Object * -ExcludeProperty object_id | Export-Csv -Path $cleanUsers -NoTypeInformation -Encoding UTF8
    $runs | Select-Object * -ExcludeProperty workflow_id, run_id, user_object_id |
        Export-Csv -Path $cleanRuns -NoTypeInformation -Encoding UTF8
    Write-Host "Sanitized users:    $cleanUsers"
    Write-Host "Sanitized runs:     $cleanRuns"
}
