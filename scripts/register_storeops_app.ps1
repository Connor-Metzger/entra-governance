<#
.SYNOPSIS
    Registers the StoreOps Portal enterprise app with app roles, requires assignment,
    and assigns the Associate role to the Store Operations birthright group (M1.4).

.DESCRIPTION
    What it builds (safe to rerun: existing objects are updated, never duplicated):
      1. App registration "StoreOps Portal" (single tenant) with 5 app roles.
      2. Enterprise app (service principal) with:
           - Assignment required = Yes   -> nobody signs in unless assigned a role
           - Visible in Enterprise applications (tag WindowsAzureActiveDirectoryIntegratedApp)
           - Notes = business owner, data classification, how each role is granted
      3. One assignment: group "BR-02 Store Operations Baseline" -> role Associate.
         Shift Lead / Store Manager come from access packages in M2.4,
         Cash Office (PCI) / Admin are REQUESTED access packages in M2.5.
         They stay unassigned here on purpose.

    Entra "Owners" of an app can change its configuration, so they are technical owners
    (IAM). The business owner, who decides who should have access, is recorded in Notes.

    -Verify reads the configuration back from Graph and checks it as data.
    Uses Invoke-MgGraphRequest, so no extra Graph module is needed.

    Needs scopes: Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, Group.Read.All

.EXAMPLE
    .\scripts\register_storeops_app.ps1 -DryRun
    .\scripts\register_storeops_app.ps1
    .\scripts\register_storeops_app.ps1 -Verify -EvidenceDir evidence/M1.4
#>
[CmdletBinding()]
param(
    [string]$DisplayName    = "StoreOps Portal",
    [string]$AssociateGroup = "BR-02 Store Operations Baseline",
    [string]$BusinessOwner  = "Director of Store Operations",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir    = ""
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"

# ---------- Role design (source: docs/role-catalog.md) ----------
$roles = @(
    [pscustomobject]@{ Value = "StoreOps.Associate";    Name = "Associate"
        Desc = "View own schedule, timeclock and training. All Store Operations staff."
        GrantedBy = "Group BR-02 (birthright, automatic from HR department)"; Assign = $AssociateGroup }
    [pscustomobject]@{ Value = "StoreOps.ShiftLead";    Name = "Shift Lead"
        Desc = "Shift handover and refund approval queue for the shift lead's store."
        GrantedBy = "Access package, automatic by job title (BUS-01 + ADD-01), M2.4"; Assign = "" }
    [pscustomobject]@{ Value = "StoreOps.StoreManager"; Name = "Store Manager"
        Desc = "Scheduling admin, inventory approval and safe counts for the manager's store."
        GrantedBy = "Access package, automatic by job title (BUS-02, PCI-flagged), M2.4"; Assign = "" }
    [pscustomobject]@{ Value = "StoreOps.CashOffice";   Name = "Cash Office (PCI)"
        Desc = "Card settlement and deposit reconciliation reports. PCI scope."
        GrantedBy = "REQUESTED access package: manager + PCI owner approval, quarterly review, M2.5"; Assign = "" }
    [pscustomobject]@{ Value = "StoreOps.Admin";        Name = "Admin"
        Desc = "Application configuration. Privileged."
        GrantedBy = "REQUESTED access package: IT Director approval, quarterly review, M2.5"; Assign = "" }
)
$notes = "Business owner: $BusinessOwner. Technical owner: IAM Team. Data: store schedules, " +
         "timeclock, cash and card settlement (PCI for Cash Office). Assignment required. " +
         "Associate = BR-02 group; Shift Lead / Store Manager = access packages by title; " +
         "Cash Office / Admin = requested access packages only. See docs/integration-analysis-storeops.md."

Write-Host "App: $DisplayName  |  Business owner: $BusinessOwner"
Write-Host ("{0,-22} {1,-18} {2}" -f "Role value", "Display name", "Granted by")
foreach ($r in $roles) { Write-Host ("{0,-22} {1,-18} {2}" -f $r.Value, $r.Name, $r.GrantedBy) }
if ($DryRun) { Write-Host "DRY RUN - nothing changed."; return }
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

function Invoke-Graph([string]$Method, [string]$Uri, $Body) {
    if ($null -ne $Body) {
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    }
    return Invoke-MgGraphRequest -Method $Method -Uri $Uri
}
function Get-First([string]$Uri) {
    $resp = Invoke-Graph GET $Uri
    if ($resp.value -and @($resp.value).Count -gt 1) { throw "More than one object matched: $Uri" }
    if ($resp.value) { return @($resp.value)[0] }
    return $null
}
function F([string]$f) { return [uri]::EscapeDataString($f) }

# ---------- Read current state ----------
$app = Get-First "$graph/applications?`$filter=$(F "displayName eq '$DisplayName'")&`$select=id,appId,displayName,appRoles,notes"
$sp  = $null
if ($app) { $sp = Get-First "$graph/servicePrincipals?`$filter=$(F "appId eq '$($app.appId)'")&`$select=id,appId,appRoles,appRoleAssignmentRequired,tags,notes" }
$group = Get-MgGroup -Filter "displayName eq '$AssociateGroup'" -Property "id,displayName"
if (-not $group) { throw "Group '$AssociateGroup' not found. Run create_dynamic_groups.ps1 first." }

# ---------- Verify mode: read back and check as data ----------
if ($Verify) {
    if (-not $app -or -not $sp) { throw "'$DisplayName' is not registered yet. Run without -Verify first." }
    $assigned = @((Invoke-Graph GET "$graph/servicePrincipals/$($sp.id)/appRoleAssignedTo").value)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("StoreOps Portal configuration read back from Graph, $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC")
    $lines.Add("Assignment required: $($sp.appRoleAssignmentRequired)")
    $lines.Add("Listed in Enterprise applications: $(@($sp.tags) -contains 'WindowsAzureActiveDirectoryIntegratedApp')")
    $lines.Add("Notes: $($sp.notes)")
    $lines.Add("")
    $lines.Add(("{0,-18} {1,-22} {2,-8} {3,-34} {4}" -f "Role", "Value", "Enabled", "Assigned to", "Effective users"))
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roles) {
        $def = @($sp.appRoles) | Where-Object { $_.value -eq $r.Value }
        $mine = @($assigned | Where-Object { $def -and $_.appRoleId -eq $def.id })
        $users = 0
        foreach ($a in $mine) {
            if ($a.principalType -eq "Group") { $users += @(Get-MgGroupMember -GroupId $a.principalId -All).Count } else { $users += 1 }
        }
        $to = if ($mine.Count) { ($mine | ForEach-Object { $_.principalDisplayName }) -join ", " } else { "(none)" }
        $lines.Add(("{0,-18} {1,-22} {2,-8} {3,-34} {4}" -f $r.Name, $r.Value, [bool]($def -and $def.isEnabled), $to, $users))
        $want = if ($r.Assign) { $r.Assign } else { "(none)" }
        $checks.Add([pscustomobject]@{ Check = "$($r.Name) role exists and assigned to $want"; Pass = [bool]$def -and ($to -eq $want) })
    }
    $checks.Insert(0, [pscustomobject]@{ Check = "Assignment required = Yes"; Pass = [bool]$sp.appRoleAssignmentRequired })
    $checks.Add([pscustomobject]@{ Check = "No direct user assignments"; Pass = -not ($assigned | Where-Object { $_.principalType -ne "Group" }) })
    $lines.Add("")
    foreach ($c in $checks) { $lines.Add(("[{0}] {1}" -f $(if ($c.Pass) { "PASS" } else { "FAIL" }), $c.Check)) }
    $failed = @($checks | Where-Object { -not $_.Pass }).Count
    $lines.Add($(if ($failed) { "$failed check(s) FAILED" } else { "All $($checks.Count) checks passed." }))
    $lines | ForEach-Object { Write-Host $_ }
    if ($EvidenceDir) {
        New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
        $out = Join-Path $EvidenceDir "storeops_app_config.txt"
        $lines | Set-Content -Path $out -Encoding UTF8
        Write-Host "Saved: $out"
    }
    return
}

# ---------- 1. App registration + app roles ----------
$existingRoles = @(); if ($app) { $existingRoles = @($app.appRoles) }
$roleBody = foreach ($r in $roles) {
    $old = $existingRoles | Where-Object { $_.value -eq $r.Value }
    [ordered]@{
        id                 = $(if ($old) { $old.id } else { [guid]::NewGuid().ToString() })   # keep IDs: assignments point at them
        value              = $r.Value
        displayName        = $r.Name
        description        = $r.Desc
        allowedMemberTypes = @("User")      # "User" also covers group assignment
        isEnabled          = $true
    }
}
# Roles in Entra that are no longer in the design are kept, not deleted (deleting would break assignments)
$extra = @($existingRoles | Where-Object { $_.value -notin $roles.Value })
foreach ($x in $extra) { Write-Warning "Role '$($x.value)' exists in Entra but not in this script; left unchanged." }
$allRoles = @($roleBody) + $extra

if (-not $app) {
    $app = Invoke-Graph POST "$graph/applications" ([ordered]@{
        displayName = $DisplayName; signInAudience = "AzureADMyOrg"; appRoles = $allRoles; notes = $notes })
    Write-Host "Created   app registration '$DisplayName' with $(@($roleBody).Count) app roles"
} else {
    $missing = @($roles | Where-Object { $_.Value -notin $existingRoles.value }).Count
    Invoke-Graph PATCH "$graph/applications/$($app.id)" ([ordered]@{ appRoles = $allRoles; notes = $notes }) | Out-Null
    Write-Host "Updated   app registration '$DisplayName' ($missing role(s) added)"
}

# ---------- 2. Enterprise app (service principal) ----------
$tags = @("WindowsAzureActiveDirectoryIntegratedApp")
if (-not $sp) {
    # A new app registration can take a few seconds to replicate before its service principal can be created
    for ($try = 1; $try -le 6 -and -not $sp; $try++) {
        try {
            $sp = Invoke-Graph POST "$graph/servicePrincipals" ([ordered]@{
                appId = $app.appId; appRoleAssignmentRequired = $true; tags = $tags; notes = $notes })
        } catch {
            if ($try -eq 6) { throw }
            Write-Host "  waiting for the app registration to replicate (try $try of 6)..."
            Start-Sleep -Seconds 5
        }
    }
    Write-Host "Created   enterprise app (assignment required = Yes)"
} else {
    $allTags = @(@($sp.tags) + $tags | Select-Object -Unique)    # keep any tags already there
    Invoke-Graph PATCH "$graph/servicePrincipals/$($sp.id)" ([ordered]@{
        appRoleAssignmentRequired = $true; tags = $allTags; notes = $notes }) | Out-Null
    Write-Host "Updated   enterprise app (assignment required = Yes)"
}

# ---------- 3. Assign Associate to the birthright group ----------
$associateId = ($roleBody | Where-Object { $_.value -eq "StoreOps.Associate" }).id
$assigned = @((Invoke-Graph GET "$graph/servicePrincipals/$($sp.id)/appRoleAssignedTo").value)
if ($assigned | Where-Object { $_.principalId -eq $group.Id -and $_.appRoleId -eq $associateId }) {
    Write-Host "Unchanged '$AssociateGroup' -> Associate"
} else {
    Invoke-Graph POST "$graph/servicePrincipals/$($sp.id)/appRoleAssignedTo" ([ordered]@{
        principalId = $group.Id; resourceId = $sp.id; appRoleId = $associateId }) | Out-Null
    Write-Host "Assigned  '$AssociateGroup' -> Associate"
}
Write-Host "Done. Run with -Verify to read the configuration back."
