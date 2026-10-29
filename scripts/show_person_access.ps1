<#
.SYNOPSIS
    Shows what one or more people hold in Entra and where each item comes from (M2.4).

.DESCRIPTION
    For each employee ID it reads back from Graph:
      - HR attributes as Entra has them (department, job title, location, enabled)
      - birthright groups (BR-*)        -> granted by dynamic group rules (M1.2)
      - access package assignments      -> granted by automatic policies (M2.4)
      - entitlement groups (ENT-*)      -> filled only by access packages
      - StoreOps Portal app roles       -> Associate via BR-02 group, others via access packages
    Use it to prove a single person's access before/after an HR change, and later (M3)
    to answer a reviewer's "why does this person have this?".
    Prints names only: no object IDs or tenant IDs, so the output can go into evidence/.

.EXAMPLE
    .\scripts\show_person_access.ps1 -EmployeeId E00013,E00006
    .\scripts\show_person_access.ps1 -EmployeeId E00013,E00006 -EvidenceDir evidence/M2.4 -Label after
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string[]]$EmployeeId,
    [string]$AppName     = "StoreOps Portal",
    [string]$EvidenceDir = "",
    [string]$Label       = ""
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

function Get-All([string]$Uri) {
    $out = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri
        foreach ($v in @($resp.value)) { if ($null -ne $v) { $out.Add($v) } }
        $Uri = $resp.'@odata.nextLink'
    }
    return , $out
}
function F([string]$f) { return [uri]::EscapeDataString($f) }

# Get-All returns one List: assign it to a variable before piping (piping the List sends it as ONE object)
$sp = Get-All "$graph/servicePrincipals?`$filter=$(F "displayName eq '$AppName'")&`$select=id,appRoles"
$roleName = @{}
if ($sp.Count -eq 1) { foreach ($r in @($sp[0].appRoles)) { $roleName[$r.id] = $r.value } }

$stamp = (Get-Date).ToUniversalTime()
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Access read back from Graph, $($stamp.ToString('yyyy-MM-dd HH:mm')) UTC$(if ($Label) { " ($Label)" })")

foreach ($e in $EmployeeId) {
    $lines.Add("")
    $u = Get-All "$graph/users?`$filter=$(F "employeeId eq '$e'")&`$select=id,displayName,department,jobTitle,officeLocation,accountEnabled"
    if ($u.Count -ne 1) { $lines.Add("$e : $($u.Count) users found (expected 1)"); continue }
    $u = $u[0]
    $lines.Add(("{0} {1} | {2} | {3} | {4} | enabled {5}" -f $e, $u.displayName, $u.department, $u.jobTitle, $u.officeLocation, $u.accountEnabled))

    $memberOf = Get-All "$graph/users/$($u.id)/memberOf/microsoft.graph.group?`$select=displayName&`$top=999"
    $groups = @($memberOf | ForEach-Object { $_.displayName } | Sort-Object)
    $br  = @($groups | Where-Object { $_ -like "BR-*" })
    $ent = @($groups | Where-Object { $_ -like "ENT-*" })
    $lines.Add("  Birthright groups:  $(if ($br.Count) { $br -join ', ' } else { 'none' })")

    try {
        $asg = Get-All "$graph/identityGovernance/entitlementManagement/assignments?`$filter=$(F "target/objectId eq '$($u.id)'")&`$expand=accessPackage"
        $pk = @($asg | ForEach-Object { "$($_.accessPackage.displayName) [$($_.state)]" } | Sort-Object)
        $lines.Add("  Access packages:    $(if ($pk.Count) { $pk -join ', ' } else { 'none' })")
    } catch {
        $lines.Add("  Access packages:    (could not read: $($_.Exception.Message))")
    }
    $lines.Add("  Entitlement groups: $(if ($ent.Count) { $ent -join ', ' } else { 'none' })")

    $allAr = Get-All "$graph/users/$($u.id)/appRoleAssignments"
    $ar = @($allAr | Where-Object { $sp.Count -eq 1 -and $_.resourceId -eq $sp[0].id })
    $roles = @($ar | ForEach-Object { if ($roleName[$_.appRoleId]) { $roleName[$_.appRoleId] } else { "(default access)" } } | Sort-Object -Unique)
    # appRoleAssignments on a user lists direct assignments only; Associate comes through the BR-02 group
    $viaGroup = if ($br -like "BR-02*") { " + StoreOps.Associate via BR-02 group" } else { "" }
    $lines.Add("  $AppName roles: $(if ($roles.Count) { $roles -join ', ' } else { 'none direct' })$viaGroup")
}

$lines | ForEach-Object { Write-Host $_ }
if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $name = "person_access_$(if ($Label) { "$($Label)_" })$($stamp.ToString('yyyy-MM-dd_HHmm')).txt"
    $out = Join-Path $EvidenceDir $name
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host "Saved: $out"
}
