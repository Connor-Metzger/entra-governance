<#
.SYNOPSIS
    Creates the REQUESTED access packages for StoreOps Portal (M2.5): Cash Office (PCI) and Admin.

.DESCRIPTION
    Title-based packages (M2.4) are assigned automatically. These two are different: nobody
    gets them because of their HR data. A person has to ask, give a reason, and be approved,
    and the access expires on its own.

      ADD-06 StoreOps Cash Office  [PCI]
        Who may ask:  members of BR-02 Store Operations Baseline
        Approval:     stage 1 requestor's manager, stage 2 PCI owner; justification required
        Expires:      90 days (re-request; matches the quarterly review)
        Incompatible: ADD-01 POS Refunds (same SoD rule as POS-Refunds <-> SafeCount-Operator:
                      whoever issues refunds must not reconcile the cash)
      ADD-07 StoreOps Admin  [Privileged]
        Who may ask:  members of BR-06 IT Baseline
        Approval:     IT Director; justification required
        Expires:      30 days

    Lab deviation: the PCI owner, the IT Director and the fallback for "no manager in HR" are all
    iam.admin (-ApproverUpn). Synthetic managers can't sign in, so manager approval is shown as
    configuration, not as a live approval.

    Safe to rerun: existing packages and policies are found by name; a policy that differs from
    the design is replaced with PUT.
    -Verify reads everything back from Graph and checks it as data (no counts from HR: these
    packages have no "expected" population, so the checks are on configuration, expiry on every
    assignment, and app role holders = package holders).

    Needs: EntitlementManagement.ReadWrite.All, Group.Read.All, User.Read.All, Application.Read.All.
    Run create_access_packages.ps1 first (catalog + StoreOps Portal resource).

.EXAMPLE
    .\scripts\create_requested_packages.ps1 -DryRun
    .\scripts\create_requested_packages.ps1
    .\scripts\create_requested_packages.ps1 -Verify -EvidenceDir evidence/M2.5
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$CatalogName = "Keystone Store & Fuel Operations",
    [string]$AppName     = "StoreOps Portal",
    [string]$ApproverUpn = "iam.admin@keystonefuellab.onmicrosoft.com",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir = ""
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$em    = "$graph/identityGovernance/entitlementManagement"

# ---------- Design ----------
$defs = @(
    [pscustomobject]@{
        RoleId = "ADD-06"; Name = "ADD-06 StoreOps Cash Office"; Flags = "PCI"
        AppRole = "StoreOps.CashOffice"; RequestorGroup = "BR-02 Store Operations Baseline"
        Stages = @("Manager", "PCI owner"); Expiry = "P90D"; Incompatible = @("ADD-01 POS Refunds")
        Description = "REQUESTED. Card settlement and deposit reconciliation (PCI). Store Operations staff ask; manager + PCI owner approve; " +
                      "expires after 90 days. Incompatible with ADD-01 POS Refunds (SoD). Owner: Director of Store Operations. Review: Quarterly."
    }
    [pscustomobject]@{
        RoleId = "ADD-07"; Name = "ADD-07 StoreOps Admin"; Flags = "Privileged"
        AppRole = "StoreOps.Admin"; RequestorGroup = "BR-06 IT Baseline"
        Stages = @("IT Director"); Expiry = "P30D"; Incompatible = @()
        Description = "REQUESTED. StoreOps Portal configuration (privileged). IT staff ask; IT Director approves; expires after 30 days. " +
                      "Owner: IT Director. Review: Quarterly."
    }
)
$stageText = @{
    "Manager"     = "requestor's manager (no manager in HR -> fallback approver)"
    "PCI owner"   = "PCI owner (lab: $ApproverUpn)"
    "IT Director" = "IT Director (lab: $ApproverUpn)"
}
Write-Host "Catalog: $CatalogName"
foreach ($d in $defs) {
    Write-Host ("  {0}  [{1}]" -f $d.Name, $d.Flags)
    Write-Host ("    grants {0} : {1} | who may ask: {2} | expires: {3}" -f $AppName, $d.AppRole, $d.RequestorGroup, $d.Expiry)
    for ($i = 0; $i -lt $d.Stages.Count; $i++) { Write-Host ("    approval stage {0}: {1}" -f ($i + 1), $stageText[$d.Stages[$i]]) }
    Write-Host ("    incompatible with: {0}" -f $(if ($d.Incompatible.Count) { $d.Incompatible -join ", " } else { "(none)" }))
}
if ($DryRun) { Write-Host "DRY RUN - nothing changed."; return }
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

# ---------- Graph helpers (same as create_access_packages.ps1) ----------
function Invoke-Graph([string]$Method, [string]$Uri, $Body) {
    if ($null -ne $Body) {
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    }
    return Invoke-MgGraphRequest -Method $Method -Uri $Uri
}
function Get-All([string]$Uri) {
    $out = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-Graph GET $Uri
        foreach ($v in @($resp.value)) { if ($null -ne $v) { $out.Add($v) } }
        $Uri = $resp.'@odata.nextLink'
    }
    return , $out
}
function F([string]$f) { return [uri]::EscapeDataString($f) }
function Get-One([string]$Uri, [string]$What) {
    $all = Get-All $Uri
    if ($all.Count -gt 1) { throw "More than one $What matched. Rename or delete the duplicate, then rerun." }
    if ($all.Count -eq 1) { return $all[0] }
    return $null
}
function Get-Package($Catalog, [string]$Name) {
    $all = Get-All "$em/accessPackages?`$filter=$(F "displayName eq '$Name'")&`$expand=catalog"
    $mine = @($all | Where-Object { $_.catalog.id -eq $Catalog.id })
    if ($mine.Count -gt 1) { throw "More than one access package named '$Name' in the catalog." }
    if ($mine.Count -eq 1) { return $mine[0] }
    return $null
}

$catalog = Get-One "$em/catalogs?`$filter=$(F "displayName eq '$($CatalogName -replace "'", "''")'")" "catalog"
if (-not $catalog) { throw "Catalog '$CatalogName' not found. Run create_access_packages.ps1 first." }
$sp = Get-One "$graph/servicePrincipals?`$filter=$(F "displayName eq '$AppName'")&`$select=id,displayName,appRoles" "enterprise app"
if (-not $sp) { throw "Enterprise app '$AppName' not found. Run register_storeops_app.ps1 first." }
$approver = Get-One "$graph/users?`$filter=$(F "userPrincipalName eq '$ApproverUpn'")&`$select=id,userPrincipalName" "user"
if (-not $approver) { throw "Approver '$ApproverUpn' not found." }
$groupId = @{}
foreach ($gName in @($defs.RequestorGroup | Select-Object -Unique)) {
    $g = Get-One "$graph/groups?`$filter=$(F "displayName eq '$gName'")&`$select=id,displayName" "group"
    if (-not $g) { throw "Group '$gName' not found. Run create_dynamic_groups.ps1 first." }
    $groupId[$gName] = $g.id
}

function New-Stage([string]$Kind) {
    $single = [ordered]@{ "@odata.type" = "#microsoft.graph.singleUser"; userId = $approver.id; description = $stageText[$Kind] }
    if ($Kind -eq "Manager") {
        $primary  = @( [ordered]@{ "@odata.type" = "#microsoft.graph.requestorManager"; managerLevel = 1 } )
        $fallback = @( $single )
    } else { $primary = @( $single ); $fallback = @() }
    [ordered]@{
        durationBeforeAutomaticDenial = "P2D"          # stores run 24/7: an unanswered request is denied after 2 days
        isApproverJustificationRequired = $true
        isEscalationEnabled = $false
        durationBeforeEscalation = "PT0S"
        primaryApprovers = $primary
        fallbackPrimaryApprovers = $fallback
        escalationApprovers = @()
        fallbackEscalationApprovers = @()
    }
}
function New-PolicyBody($d, [string]$PackageId) {
    [ordered]@{
        displayName = "Request: $($d.RequestorGroup) | $($d.Stages -join ' + ') | $($d.Expiry)"
        description = "Requested access. Justification required. Approval: $($d.Stages -join ', then '). Expires after $($d.Expiry)."
        allowedTargetScope = "specificDirectoryUsers"
        specificAllowedTargets = @( [ordered]@{
            "@odata.type" = "#microsoft.graph.groupMembers"; groupId = $groupId[$d.RequestorGroup]; description = $d.RequestorGroup } )
        expiration = [ordered]@{ type = "afterDuration"; duration = $d.Expiry }
        requestorSettings = [ordered]@{
            enableTargetsToSelfAddAccess = $true; enableTargetsToSelfUpdateAccess = $false; enableTargetsToSelfRemoveAccess = $true
            allowCustomAssignmentSchedule = $false
            enableOnBehalfRequestorsToAddAccess = $false; enableOnBehalfRequestorsToUpdateAccess = $false
            enableOnBehalfRequestorsToRemoveAccess = $false; onBehalfRequestors = @() }
        requestApprovalSettings = [ordered]@{
            isApprovalRequiredForAdd = $true; isApprovalRequiredForUpdate = $true
            isRequestorJustificationRequired = $true
            stages = @($d.Stages | ForEach-Object { New-Stage $_ }) }
        accessPackage = @{ id = $PackageId }
    }
}
# Policy as read back from Graph -> one comparable line (used by build and -Verify)
function Format-Policy($p) {
    $stages = @($p.requestApprovalSettings.stages | ForEach-Object {
        $pa = @($_.primaryApprovers | ForEach-Object { if ($_.'@odata.type' -match 'requestorManager') { "manager" } elseif ($_.userId -eq $approver.id) { "approver" } else { "other" } }) -join "+"
        $fb = @($_.fallbackPrimaryApprovers | ForEach-Object { if ($_.userId -eq $approver.id) { "approver" } else { "other" } }) -join "+"
        "[$pa/fallback:$(if ($fb) { $fb } else { '-' })/justify:$($_.isApproverJustificationRequired)]" })
    $targets = @($p.specificAllowedTargets | ForEach-Object { if ($_.'@odata.type' -match 'groupMembers') { "group:$($_.groupId)" } else { $_.'@odata.type' } }) -join ","
    "scope=$($p.allowedTargetScope) targets=$targets auto=$([bool]$p.automaticRequestSettings) " +
    "approval=$($p.requestApprovalSettings.isApprovalRequiredForAdd) reqJustify=$($p.requestApprovalSettings.isRequestorJustificationRequired) " +
    "stages=$($stages -join '') expiry=$($p.expiration.type):$($p.expiration.duration) selfAdd=$($p.requestorSettings.enableTargetsToSelfAddAccess) " +
    "onBehalf=$($p.requestorSettings.enableOnBehalfRequestorsToAddAccess) customSchedule=$($p.requestorSettings.allowCustomAssignmentSchedule)"
}
function Get-DesignLine($d) {
    $stages = @($d.Stages | ForEach-Object { if ($_ -eq "Manager") { "[manager/fallback:approver/justify:True]" } else { "[approver/fallback:-/justify:True]" } }) -join ""
    "scope=specificDirectoryUsers targets=group:$($groupId[$d.RequestorGroup]) auto=False approval=True reqJustify=True " +
    "stages=$stages expiry=afterDuration:$($d.Expiry) selfAdd=True onBehalf=False customSchedule=False"
}

# ---------- Verify mode ----------
if ($Verify) {
    $users = Get-All "$graph/users?`$select=id,employeeId,displayName&`$top=999"
    $emp = @{}; foreach ($u in $users) { $emp[$u.id] = if ($u.employeeId) { $u.employeeId } else { "(no employeeId)" } }
    $assignedTo = Get-All "$graph/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$top=999"
    $stamp = (Get-Date).ToUniversalTime()
    $lines = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[object]
    $lines.Add("Requested access packages read back from Graph, $($stamp.ToString('yyyy-MM-dd HH:mm')) UTC. Catalog: $($catalog.displayName)")
    $lines.Add("Lab approver (PCI owner, IT Director, no-manager fallback): $ApproverUpn")
    foreach ($d in $defs) {
        $lines.Add("")
        $lines.Add("$($d.Name)  [$($d.Flags)]")
        $pkg = Get-Package $catalog $d.Name
        if (-not $pkg) { $checks.Add([pscustomobject]@{ Check = "$($d.Name): package exists"; Pass = $false }); $lines.Add("  MISSING"); continue }
        $full = Invoke-Graph GET "$em/accessPackages/$($pkg.id)?`$expand=resourceRoleScopes(`$expand=role,scope),assignmentPolicies"
        $policies = @($full.assignmentPolicies | ForEach-Object { Invoke-Graph GET "$em/assignmentPolicies/$($_.id)" })
        $resources = @($full.resourceRoleScopes | ForEach-Object { $_.role.displayName })
        $wantRoleId = (@($sp.appRoles) | Where-Object { $_.value -eq $d.AppRole }).id
        $resOk = ($full.resourceRoleScopes.Count -eq 1 -and @($full.resourceRoleScopes)[0].role.originId -eq $wantRoleId)
        $have = if ($policies.Count -eq 1) { Format-Policy $policies[0] } else { "" }
        $want = Get-DesignLine $d
        $incompat = Get-All "$em/accessPackages/$($pkg.id)/incompatibleAccessPackages"
        $incNames = @($incompat | ForEach-Object { $_.displayName } | Sort-Object)
        $asg = Get-All "$em/assignments?`$filter=$(F "accessPackage/id eq '$($pkg.id)'")&`$expand=target"
        $delivered = @($asg | Where-Object { $_.state -eq "delivered" })
        $maxEnd = $stamp.Add([Xml.XmlConvert]::ToTimeSpan($d.Expiry)).AddDays(1)
        $noExpiry = @($delivered | Where-Object { -not $_.schedule.expiration.endDateTime -or ([datetime]$_.schedule.expiration.endDateTime).ToUniversalTime() -gt $maxEnd })
        $pkgHolders = @($delivered | ForEach-Object { $emp[$_.target.objectId] } | Sort-Object -Unique)
        $roleHolders = @($assignedTo | Where-Object { $_.appRoleId -eq $wantRoleId } | ForEach-Object {
            if ($_.principalType -eq "User") { $emp[$_.principalId] } else { "group:$($_.principalDisplayName)" } } | Sort-Object -Unique)
        $holdersOk = (($pkgHolders -join ",") -eq ($roleHolders -join ","))

        $lines.Add("  Resources:    $($resources -join ', ')")
        $lines.Add("  Policies:     $($policies.Count)")
        $lines.Add("  Policy:       $have")
        $lines.Add("  Incompatible: $(if ($incNames.Count) { $incNames -join ', ' } else { '(none)' })")
        $lines.Add("  Delivered:    $($delivered.Count)$(if ($asg.Count -gt $delivered.Count) { " (other states: $(@($asg | Where-Object { $_.state -ne 'delivered' } | ForEach-Object { $_.state }) -join ', '))" })")
        foreach ($a in $delivered) {
            $end = if ($a.schedule.expiration.endDateTime) { ([datetime]$a.schedule.expiration.endDateTime).ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + "Z" } else { "NO EXPIRY" }
            $lines.Add("    $($emp[$a.target.objectId]) $($a.target.displayName): expires $end")
        }
        $lines.Add("  $AppName $($d.AppRole) held by: $(if ($roleHolders.Count) { $roleHolders -join ', ' } else { '(none)' })")

        $checks.Add([pscustomobject]@{ Check = "$($d.Name): exactly 1 policy, requested (not automatic)"; Pass = ($policies.Count -eq 1 -and -not $policies[0].automaticRequestSettings) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): policy = design (who may ask, $($d.Stages.Count) approval stage(s), justification, $($d.Expiry) expiry)"; Pass = ($have -eq $want) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): grants only $($d.AppRole)"; Pass = $resOk })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): incompatible = $(if ($d.Incompatible.Count) { $d.Incompatible -join ', ' } else { '(none)' })"; Pass = (($incNames -join ",") -eq (($d.Incompatible | Sort-Object) -join ",")) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): every delivered assignment expires within $($d.Expiry) ($($delivered.Count) checked)"; Pass = ($noExpiry.Count -eq 0) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): $($d.AppRole) holders = package holders ($($pkgHolders.Count)), no groups"; Pass = $holdersOk })
        if ($have -ne $want) { $lines.Add("  Design:       $want") }
    }
    $lines.Add("")
    foreach ($c in $checks) { $lines.Add(("[{0}] {1}" -f $(if ($c.Pass) { "PASS" } else { "FAIL" }), $c.Check)) }
    $failed = @($checks | Where-Object { -not $_.Pass }).Count
    $lines.Add($(if ($failed) { "$failed of $($checks.Count) check(s) FAILED." } else { "All $($checks.Count) checks passed." }))
    # Object IDs (group, approver) are needed to compare, but must not reach evidence
    $safe = @($lines | ForEach-Object { $_ -replace "group:[0-9a-f-]{36}", "group:<id>" })
    $safe | ForEach-Object { Write-Host $_ }
    if ($EvidenceDir) {
        New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
        $out = Join-Path $EvidenceDir "requested_packages_config_$($stamp.ToString('yyyy-MM-dd_HHmm')).txt"
        $safe | Set-Content -Path $out -Encoding UTF8
        Write-Host "Saved: $out"
    }
    return
}

# ---------- Build ----------
$appRes = Get-One "$em/catalogs/$($catalog.id)/resources?`$filter=$(F "originId eq '$($sp.id)'")&`$expand=scopes" "catalog resource"
if (-not $appRes) { throw "'$AppName' is not a resource in '$CatalogName'. Run create_access_packages.ps1 first." }
$pkgByName = @{}
foreach ($d in $defs) {
    $pkg = Get-Package $catalog $d.Name
    if ($pkg) { Write-Host "Unchanged package   $($d.Name)" }
    else {
        $pkg = Invoke-Graph POST "$em/accessPackages" ([ordered]@{ displayName = $d.Name; description = $d.Description; catalog = @{ id = $catalog.id } })
        Write-Host "Created package     $($d.Name)"
    }
    $pkgByName[$d.Name] = $pkg
    $full = Invoke-Graph GET "$em/accessPackages/$($pkg.id)?`$expand=resourceRoleScopes(`$expand=role,scope),assignmentPolicies"

    # Resource role: the app role
    $roleOriginId = (@($sp.appRoles) | Where-Object { $_.value -eq $d.AppRole }).id
    if (-not $roleOriginId) { throw "App role '$($d.AppRole)' not found on '$AppName'." }
    if (@($full.resourceRoleScopes | ForEach-Object { $_.role.originId }) -contains $roleOriginId) { Write-Host "  unchanged role    $AppName ($($d.AppRole))" }
    else {
        $roles = Get-All "$em/catalogs/$($catalog.id)/resourceRoles?`$filter=$(F "(originSystem eq 'AadApplication' and resource/id eq '$($appRes.id)')")&`$expand=resource"
        $role = @($roles | Where-Object { $_.originId -eq $roleOriginId })
        if ($role.Count -ne 1) { throw "Resource role '$($d.AppRole)' not found in the catalog." }
        $role = $role[0]; $scope = @($appRes.scopes)[0]
        Invoke-Graph POST "$em/accessPackages/$($pkg.id)/resourceRoleScopes" ([ordered]@{
            role = [ordered]@{
                id = $role.id; displayName = $role.displayName; description = $role.description
                originSystem = $role.originSystem; originId = $role.originId
                resource = [ordered]@{ id = $appRes.id; originId = $appRes.originId; originSystem = $appRes.originSystem } }
            scope = [ordered]@{ id = $scope.id; originId = $scope.originId; originSystem = $scope.originSystem } }) | Out-Null
        Write-Host "  added role        $AppName ($($d.AppRole))"
    }

    # Request policy
    $body = New-PolicyBody $d $pkg.id
    $policies = @($full.assignmentPolicies | ForEach-Object { Invoke-Graph GET "$em/assignmentPolicies/$($_.id)" })
    if ($policies.Count -gt 1) { throw "$($d.Name) has $($policies.Count) policies. Keep one, then rerun." }
    if ($policies.Count -eq 0) {
        Invoke-Graph POST "$em/assignmentPolicies" $body | Out-Null
        Write-Host "  created policy    $($body.displayName)"
    } elseif ((Format-Policy $policies[0]) -ne (Get-DesignLine $d)) {
        Invoke-Graph PUT "$em/assignmentPolicies/$($policies[0].id)" $body | Out-Null
        Write-Host "  updated policy    $($body.displayName)"
    } else { Write-Host "  unchanged policy  $($body.displayName)" }
}

# Incompatible packages (after all packages exist)
foreach ($d in $defs) {
    $pkg = $pkgByName[$d.Name]
    $have = @((Get-All "$em/accessPackages/$($pkg.id)/incompatibleAccessPackages") | ForEach-Object { $_.displayName })
    foreach ($name in $d.Incompatible) {
        if ($have -contains $name) { Write-Host "  unchanged SoD     $($d.Name) x $name"; continue }
        $other = Get-Package $catalog $name
        if (-not $other) { throw "Incompatible package '$name' not found in the catalog." }
        Invoke-Graph POST "$em/accessPackages/$($pkg.id)/incompatibleAccessPackages/`$ref" @{ "@odata.id" = "$em/accessPackages/$($other.id)" } | Out-Null
        Write-Host "  added SoD         $($d.Name) x $name"
    }
}
Write-Host "Done. Run with -Verify to read the configuration back."
