<#
.SYNOPSIS
    Creates the PCI mover workflow (M2.5): on a department change, remove Cash Office (PCI) and
    StoreOps Admin (privileged) at once, with no 15-day handover.

.DESCRIPTION
    JML-M1 gives every mover a 15-day handover: their access packages are removed 15 days after
    the department change, so they can finish work in their old team. That window is wrong for
    PCI and privileged access. A cashier who moved to Fuel Operations has no reason to reach card
    settlement for another two weeks.

    This script adds a SECOND mover workflow with the same trigger (department change) and scope
    (companyName = Keystone Fuel & Market), and two tasks:
        Remove access package assignment for user -> ADD-06 StoreOps Cash Office [PCI]
        Remove access package assignment for user -> ADD-07 StoreOps Admin [Privileged]
    Both tasks have continueOnError = true, so one failing task doesn't stop the other.
    M1 stays as it is: it still notifies the manager and handles everything else on day 15.

    Why "any department change" is the right trigger: only Store Operations (BR-02) may request
    Cash Office and only IT (BR-06) may request Admin. Anyone who changes department while holding
    one of them has left the team that justified it.

    Lifecycle Workflows run on the tenant schedule (lab: every hour), so removal happens at the
    next run after the HR load, not to the second. -RunNowFor starts the workflow on demand for one
    person (a fallback; the test uses the scheduled run as evidence).

    Safe to rerun: the workflow is found by name. If it exists and matches the design, nothing
    changes. If it differs, the script stops and tells you; it never edits a live workflow.
    -Verify reads the configuration back from Graph and checks it as data, then checks the OUTCOME:
    every holder of ADD-06 is in Store Operations, every holder of ADD-07 is in Information
    Technology. Run history of this workflow goes into the evidence file (names and employee IDs
    only, no object IDs).

    Needs: LifecycleWorkflows.ReadWrite.All, EntitlementManagement.Read.All, User.Read.All.
    Run create_requested_packages.ps1 first (ADD-06 and ADD-07 must exist).

.EXAMPLE
    .\scripts\create_pci_mover_workflow.ps1 -DryRun
    .\scripts\create_pci_mover_workflow.ps1
    .\scripts\create_pci_mover_workflow.ps1 -Verify -EvidenceDir evidence/M2.5
    .\scripts\create_pci_mover_workflow.ps1 -RunNowFor E00034
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$WorkflowName = "JML-M2 PCI access removal on move",
    [string]$CatalogName  = "Keystone Store & Fuel Operations",
    [string]$ScopeRule    = "(companyName eq 'Keystone Fuel & Market')",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$RunNowFor    = "",
    [string]$EvidenceDir  = ""
)
$ErrorActionPreference = "Stop"
$graph  = "https://graph.microsoft.com/v1.0"
$em     = "$graph/identityGovernance/entitlementManagement"
$wfBase = "$graph/identityGovernance/lifecycleWorkflows/workflows"
$removePackageTaskId = "4a0b64f2-c7ec-46ba-b117-18f262946c50"   # built-in "Remove access package assignment for user"
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }
function F([string]$f) { return [uri]::EscapeDataString($f) }

function Get-GraphAll([string]$Uri) {
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri
        foreach ($v in $resp.value) { $items.Add($v) }
        $Uri = $resp.'@odata.nextLink'
    }
    return ,($items.ToArray())
}

# ---------- Design ----------
# Department = the only department allowed to hold the package (its requestor group's department)
$design = @(
    [pscustomobject]@{ Package = "ADD-06 StoreOps Cash Office"; Flag = "PCI";        Department = "Store Operations";       MustHaveHolders = $true }
    [pscustomobject]@{ Package = "ADD-07 StoreOps Admin";       Flag = "Privileged"; Department = "Information Technology"; MustHaveHolders = $false }
)

Write-Host "Workflow: $WorkflowName"
Write-Host "  category mover | trigger: department changes | scope: $ScopeRule | runs on the tenant schedule"
foreach ($d in $design) {
    Write-Host ("  task: remove {0} [{1}] at once (continue on error) | allowed holders: {2}" -f $d.Package, $d.Flag, $d.Department)
}

# ---------- Resolve packages ----------
foreach ($d in $design) {
    $p = @((Invoke-MgGraphRequest GET "$em/accessPackages?`$filter=$(F "displayName eq '$($d.Package)'")&`$expand=catalog").value |
        Where-Object { $_.catalog.displayName -eq $CatalogName })
    if ($p.Count -ne 1) { throw "Package '$($d.Package)': $($p.Count) found in '$CatalogName' (expected 1). Run create_requested_packages.ps1 first." }
    $d | Add-Member -NotePropertyName Id -NotePropertyValue $p[0].id -Force
}
$nameById = @{}; foreach ($d in $design) { $nameById[$d.Id] = $d.Package }

$tasks = @(foreach ($d in $design) {
    [ordered]@{
        continueOnError  = $true
        displayName      = "Remove $($d.Package)"
        description      = "$($d.Flag): removed at the department change, no 15-day handover (JML 7.4)"
        isEnabled        = $true
        taskDefinitionId = $removePackageTaskId
        arguments        = @(@{ name = "accessPackageId"; value = $d.Id })
    }
})
$body = [ordered]@{
    category            = "mover"
    displayName         = $WorkflowName
    description         = "PCI and privileged access packages are removed at the next run after a department change. JML-M1 handles the manager email and the 15-day removal of everything else."
    isEnabled           = $true
    isSchedulingEnabled = $true
    executionConditions = [ordered]@{
        "@odata.type" = "#microsoft.graph.identityGovernance.triggerAndScopeBasedConditions"
        scope   = [ordered]@{ "@odata.type" = "#microsoft.graph.identityGovernance.ruleBasedSubjectSet"; rule = $ScopeRule }
        trigger = [ordered]@{ "@odata.type" = "#microsoft.graph.identityGovernance.attributeChangeTrigger"; triggerAttributes = @(@{ name = "department" }) }
    }
    tasks = $tasks
}

# Compare a workflow read from Graph with the design; returns one row per check
function Test-Config($wf, $wfTasks) {
    $c = New-Object System.Collections.Generic.List[object]
    $ec = $wf.executionConditions
    $trigAttrs = @($ec.trigger.triggerAttributes | ForEach-Object { $_.name })
    $c.Add([pscustomobject]@{ Check = "Category mover, enabled, scheduling on"; Pass = ($wf.category -eq "mover" -and $wf.isEnabled -and $wf.isSchedulingEnabled) })
    $c.Add([pscustomobject]@{ Check = "Trigger = attribute change on department only"; Pass = ($ec.trigger.'@odata.type' -like "*attributeChangeTrigger" -and $trigAttrs.Count -eq 1 -and $trigAttrs[0] -eq "department") })
    $c.Add([pscustomobject]@{ Check = "Scope rule = $ScopeRule"; Pass = ($ec.scope.rule -eq $ScopeRule) })
    $c.Add([pscustomobject]@{ Check = "Exactly $($design.Count) tasks"; Pass = (@($wfTasks).Count -eq $design.Count) })
    foreach ($d in $design) {
        $t = @($wfTasks | Where-Object { $_.taskDefinitionId -eq $removePackageTaskId -and
                @($_.arguments | Where-Object { $_.name -eq "accessPackageId" -and $_.value -eq $d.Id }).Count -eq 1 })
        $c.Add([pscustomobject]@{ Check = "Task removes $($d.Package), enabled, continue on error"; Pass = ($t.Count -eq 1 -and $t[0].isEnabled -and $t[0].continueOnError) })
    }
    return $c.ToArray()
}

# ---------- Find or create ----------
$allWf = Get-GraphAll "$wfBase`?`$select=id,displayName"
$existing = @($allWf | Where-Object { $_.displayName -eq $WorkflowName })
if ($existing.Count -gt 1) { throw "$($existing.Count) workflows named '$WorkflowName'. Delete the extra one in the portal and rerun." }
$wfId = if ($existing.Count -eq 1) { $existing[0].id } else { $null }

if (-not $Verify -and -not $RunNowFor) {
    if ($DryRun) {
        Write-Host ""
        Write-Host $(if ($wfId) { "DRY RUN: workflow exists; would compare it with the design." } else { "DRY RUN: would create the workflow. Nothing changed." })
        return
    }
    if ($wfId) {
        $wf = Invoke-MgGraphRequest GET "$wfBase/$wfId"
        $wfTasks = Get-GraphAll "$wfBase/$wfId/tasks"
        $bad = @(Test-Config $wf $wfTasks | Where-Object { -not $_.Pass })
        if ($bad.Count) {
            $bad | ForEach-Object { Write-Host "  DIFFERS: $($_.Check)" }
            throw "Workflow '$WorkflowName' exists but differs from the design. Delete it in the portal (Lifecycle workflows > Workflows) and rerun. This script never edits a live workflow."
        }
        Write-Host ""
        Write-Host "Workflow already exists and matches the design. Nothing changed."
    } else {
        $new = Invoke-MgGraphRequest -Method POST -Uri $wfBase -Body ($body | ConvertTo-Json -Depth 10) -ContentType "application/json"
        Write-Host ""
        Write-Host "Created '$($new.displayName)'. It runs on the tenant schedule. Next: -Verify."
    }
    return
}

if (-not $wfId) { throw "Workflow '$WorkflowName' not found. Run the script without -Verify first." }

# ---------- Run on demand (fallback) ----------
if ($RunNowFor) {
    $u = @((Invoke-MgGraphRequest GET "$graph/users?`$filter=$(F "employeeId eq '$RunNowFor'")&`$select=id,displayName").value)
    if ($u.Count -ne 1) { throw "$RunNowFor : $($u.Count) users found (expected 1)." }
    Invoke-MgGraphRequest -Method POST -Uri "$wfBase/$wfId/activate" -Body (@{ subjects = @(@{ id = $u[0].id }) } | ConvertTo-Json -Depth 4) -ContentType "application/json" | Out-Null
    Write-Host "Started '$WorkflowName' on demand for $RunNowFor $($u[0].displayName). Check -Verify in a few minutes."
    return
}

# ---------- Verify ----------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("PCI mover workflow verification, {0} UTC" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm"))
$wf = Invoke-MgGraphRequest GET "$wfBase/$wfId"
$wfTasks = Get-GraphAll "$wfBase/$wfId/tasks"
$checks = New-Object System.Collections.Generic.List[object]
foreach ($c in (Test-Config $wf $wfTasks)) { $checks.Add($c) }

$lines.Add("")
$lines.Add("Workflow: $($wf.displayName) | category $($wf.category) | enabled $($wf.isEnabled) | scheduling $($wf.isSchedulingEnabled)")
$lines.Add("  Trigger: attribute change on " + (@($wf.executionConditions.trigger.triggerAttributes | ForEach-Object { $_.name }) -join ", "))
$lines.Add("  Scope:   $($wf.executionConditions.scope.rule)")
foreach ($t in @($wfTasks | Sort-Object executionSequence)) {
    $pkgId = @($t.arguments | Where-Object { $_.name -eq "accessPackageId" } | ForEach-Object { $_.value })
    $pkgName = if ($pkgId.Count -and $nameById.ContainsKey($pkgId[0])) { $nameById[$pkgId[0]] } else { "(other package)" }
    $lines.Add(("  Task {0}: {1} -> {2} | enabled {3} | continue on error {4}" -f $t.executionSequence, $t.displayName, $pkgName, $t.isEnabled, $t.continueOnError))
}

# Outcome: holders of each package must be in the allowed department
$userCache = @{}
function Get-Person([string]$id) {
    if (-not $userCache.ContainsKey($id)) {
        try { $userCache[$id] = Invoke-MgGraphRequest GET "$graph/users/$id`?`$select=employeeId,displayName,department,jobTitle,officeLocation" }
        catch { $userCache[$id] = @{ employeeId = "(deleted)"; displayName = ""; department = ""; jobTitle = ""; officeLocation = "" } }
    }
    return $userCache[$id]
}
$lines.Add("")
foreach ($d in $design) {
    $asg = Get-GraphAll "$em/assignments?`$filter=$(F "accessPackage/id eq '$($d.Id)' and state eq 'delivered'")&`$expand=target"
    $people = @(foreach ($a in $asg) {
        $p = Get-Person $a.target.objectId
        [pscustomobject]@{ EmployeeId = $p.employeeId; Name = $p.displayName; Department = $p.department; Title = $p.jobTitle
                           Location = $p.officeLocation; Expires = "$($a.schedule.expiration.endDateTime)" }
    })
    $outside = @($people | Where-Object { $_.Department -ne $d.Department })
    $lines.Add("$($d.Package) [$($d.Flag)]: $($people.Count) holder(s), allowed department '$($d.Department)', outside it: $($outside.Count)")
    foreach ($p in ($people | Sort-Object EmployeeId)) {
        $lines.Add(("  {0} {1} | {2} | {3} | {4} | expires {5}{6}" -f $p.EmployeeId, $p.Name, $p.Title, $p.Department, $p.Location, $p.Expires,
            $(if ($p.Department -ne $d.Department) { "  <-- OUTSIDE" } else { "" })))
    }
    $label = "$($d.Package): no holder outside $($d.Department) ($($people.Count) checked)"
    $pass = ($outside.Count -eq 0) -and (-not $d.MustHaveHolders -or $people.Count -gt 0)
    $checks.Add([pscustomobject]@{ Check = $label; Pass = $pass })
}

# Run history of this workflow
$runs = Get-GraphAll "$wfBase/$wfId/userProcessingResults"
$lines.Add("")
$lines.Add("Runs of this workflow: $(@($runs).Count)")
foreach ($r in (@($runs) | Sort-Object { [string]$_.startedDateTime })) {
    $p = if ($r.subject) { Get-Person $r.subject.id } else { @{ employeeId = "(unknown)"; displayName = "" } }
    $lines.Add(("  {0} {1} | {2} | started {3} | completed {4} | {5} | tasks {6}, failed {7}" -f $p.employeeId, $p.displayName,
        $r.workflowExecutionType, $r.startedDateTime, $r.completedDateTime, $r.processingStatus, $r.totalTasksCount, $r.failedTasksCount))
    $tr = Get-GraphAll "$wfBase/$wfId/userProcessingResults/$($r.id)/taskProcessingResults?`$expand=task"
    foreach ($t in $tr) {
        $lines.Add(("      {0}: {1}{2}" -f $(if ($t.task) { $t.task.displayName } else { "(task)" }), $t.processingStatus,
            $(if ($t.failureReason) { " | " + $t.failureReason } else { "" })))
    }
}

$lines.Add("")
$lines.Add("Checks:")
foreach ($c in $checks) { $lines.Add(("  [{0}] {1}" -f $(if ($c.Pass) { "PASS" } else { "FAIL" }), $c.Check)) }
$passed = @($checks | Where-Object Pass).Count
$lines.Add("Result: $passed / $($checks.Count) passed")
$lines | ForEach-Object { Write-Host $_ }

if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $out = Join-Path $EvidenceDir ("pci_mover_workflow_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HHmm"))
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host "Evidence: $out"
}
