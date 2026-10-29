<#
.SYNOPSIS
    Creates the title-based business roles as Entra access packages with automatic
    assignment policies (M2.4).

.DESCRIPTION
    What it builds (safe to rerun: existing objects are found by name and reused):
      1. One stand-in security group per entitlement, named ENT-<entitlement>
         (lab deviation: the POS, inventory and fuel apps don't exist, so a group stands in
         for "has this entitlement"). Membership is managed ONLY by the access packages.
      2. Catalog "Keystone Store & Fuel Operations" with those groups and the StoreOps Portal
         enterprise app (from register_storeops_app.ps1) as resources.
      3. One access package per role in -RoleIds, holding the role's entitlement groups and,
         for BUS-02 / ADD-01, the StoreOps Portal app role.
      4. One AUTOMATIC assignment policy per package. Rule = HR department AND job title
         AND the in-force guard (employeeId set, account enabled). Entra adds the assignment
         when someone matches and removes it, with no grace period, when they stop matching.

    Which roles, titles and entitlements: data/role_catalog_design.csv (same file as M1.2).
    Department is added here because job titles alone are not enough
    (E00004 is in Fuel Operations but still titled "Store Associate").
    Rules use attributes only, never memberOf (memberOf rules are quarantined from 2026-11-03).

    -Verify reads everything back from Graph and checks it as data:
      - each package has exactly one automatic policy with the expected rule, auto-remove on, no grace
      - delivered assignments match HR, person by person (missing / unexpected employee IDs)
      - each ENT- group and each StoreOps app role holds exactly the people HR says
      - people with a matching title in the wrong department hold no package
    "Expected" = HR Active AND hire time passed AND leave time not passed (same as create_dynamic_groups.ps1).

    Needs scopes: EntitlementManagement.ReadWrite.All, Group.ReadWrite.All, User.Read.All,
                  Application.Read.All (+ Groups Administrator or Global Administrator role
                  to add groups to a catalog, Identity Governance Administrator to create
                  automatic policies).

.EXAMPLE
    .\scripts\create_access_packages.ps1 -HrFile exports\hr_m13_s2.csv -DryRun
    .\scripts\create_access_packages.ps1 -HrFile exports\hr_m13_s2.csv
    .\scripts\create_access_packages.ps1 -HrFile exports\hr_m13_s2.csv -Verify -EvidenceDir evidence/M2.4
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$CatalogFile = "data/role_catalog_design.csv",
    [string]$HrFile      = "data/t0/hr_feed.csv",
    [string]$CatalogName = "Keystone Store & Fuel Operations",
    [string[]]$RoleIds   = @("BUS-01", "BUS-02", "ADD-01", "BUS-03", "BUS-04"),
    [string]$AppName     = "StoreOps Portal",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir = "",
    [string]$TimeZoneId     = "Eastern Standard Time",   # same as load_users.ps1
    [string]$HireTimeLocal  = "03:00",
    [string]$LeaveTimeLocal = "23:00",
    [string]$AsOfUtc        = ""                        # default: now
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$em    = "$graph/identityGovernance/entitlementManagement"

# ---------- Design decisions not in the role catalog file ----------
# Department each title-based role is limited to (title alone is not enough: see E00004)
$roleDepartment = @{
    "BUS-01" = "Store Operations"; "BUS-02" = "Store Operations"; "ADD-01" = "Store Operations"
    "BUS-03" = "Fuel Operations";  "BUS-04" = "Fuel Operations"
}
# StoreOps Portal app role each package also grants (see docs/integration-analysis-storeops.md)
$roleAppRole = @{ "BUS-02" = "StoreOps.StoreManager"; "ADD-01" = "StoreOps.ShiftLead" }

# ---------- 1. Who should have what, according to HR ----------
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
if ($AsOfUtc) {
    $nowUtc = [DateTime]::Parse($AsOfUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
} else { $nowUtc = [DateTime]::UtcNow }
function ConvertTo-UtcFromLocal([string]$Date, [string]$Time) {
    $local = [DateTime]::ParseExact("$Date $Time", "yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
    return [TimeZoneInfo]::ConvertTimeToUtc($local, $tz)
}
$hrInForce = @(Import-Csv -Path $HrFile -Encoding UTF8 | Where-Object {
    if ($_.status -ne "Active") { return $false }
    if ((ConvertTo-UtcFromLocal $_.hire_date $HireTimeLocal) -gt $nowUtc) { return $false }
    if ($_.termination_date -and (ConvertTo-UtcFromLocal $_.termination_date $LeaveTimeLocal) -le $nowUtc) { return $false }
    return $true
})
if ($hrInForce.Count -eq 0) { throw "No employees in force found in '$HrFile' (check the file and -AsOfUtc)." }

$guard = '(user.employeeId -ne null) -and (user.accountEnabled -eq true)'
$catalogRows = @(Import-Csv -Path $CatalogFile -Encoding UTF8)
$defs = foreach ($id in $RoleIds) {
    $r = $catalogRows | Where-Object { $_.role_id -eq $id }
    if (-not $r) { throw "Role '$id' not found in '$CatalogFile'." }
    if ($r.assignment -ne "Automatic" -or $r.assign_by -ne "job_title") { throw "Role '$id' is not an automatic title-based role." }
    $dept = $roleDepartment[$id]
    if (-not $dept) { throw "No department set for '$id' in `$roleDepartment." }
    $titles = @($r.assign_values -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $titleRule = if ($titles.Count -eq 1) { '(user.jobTitle -eq "' + $titles[0] + '")' }
                 else { '(user.jobTitle -in [' + (($titles | ForEach-Object { '"' + $_ + '"' }) -join ",") + '])' }
    $flags = @(); if ($r.pci_scope -eq "Yes") { $flags += "PCI" }; if ($r.privileged -eq "Yes") { $flags += "Privileged" }
    $expected = @($hrInForce | Where-Object { $_.department -eq $dept -and $titles -contains $_.job_title })
    [pscustomobject]@{
        RoleId       = $id
        Name         = "$id $($r.role_name)"
        Description  = "Automatic: HR department '$dept' + job title ($($titles -join ', ')). Owner: $($r.owner). " +
                       "Review: $($r.review_cycle).$(if ($flags) { ' Flags: ' + ($flags -join ', ') + '.' }) Source: docs/role-catalog.md"
        Department   = $dept
        Titles       = $titles
        Rule         = "(user.department -eq `"$dept`") -and $titleRule -and $guard"
        Entitlements = @($r.entitlements -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        AppRole      = $roleAppRole[$id]
        Flags        = ($flags -join ", ")
        Expected     = $expected
    }
}
# Right title, wrong department (e.g. E00004): must hold none of these packages
$allTitles = @($defs | ForEach-Object { $_.Titles } | Select-Object -Unique)
$wrongDept = @($hrInForce | Where-Object {
    $p = $_
    $allTitles -contains $p.job_title -and
    -not @($defs | Where-Object { $_.Department -eq $p.department -and $_.Titles -contains $p.job_title }).Count })

Write-Host ("HR in force: {0} people (as of {1})" -f $hrInForce.Count, $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
Write-Host ("Catalog: {0}" -f $CatalogName)
foreach ($d in $defs) {
    Write-Host ("  {0,-30} expect {1,3}  grants {2}{3}" -f $d.Name, $d.Expected.Count, (($d.Entitlements | ForEach-Object { "ENT-$_" }) -join ", "),
        $(if ($d.AppRole) { ", app role $($d.AppRole)" } else { "" }))
    Write-Host ("  {0,-30} rule: {1}" -f "", $d.Rule)
}
foreach ($p in $wrongDept) {
    Write-Host ("  excluded {0} {1} {2}: title '{3}' but department '{4}'" -f $p.employee_id, $p.first_name, $p.last_name, $p.job_title, $p.department)
}
if ($DryRun) { Write-Host "DRY RUN - nothing changed."; return }
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

# ---------- Graph helpers ----------
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
function Get-Catalog { Get-One "$em/catalogs?`$filter=$(F "displayName eq '$($CatalogName -replace "'", "''")'")" "catalog" }
function Get-Package($Catalog, [string]$Name) {
    $all = Get-All "$em/accessPackages?`$filter=$(F "displayName eq '$Name'")&`$expand=catalog"
    $mine = @($all | Where-Object { $_.catalog.id -eq $Catalog.id })
    if ($mine.Count -gt 1) { throw "More than one access package named '$Name' in the catalog." }
    if ($mine.Count -eq 1) { return $mine[0] }
    return $null
}

$entNames = @($defs | ForEach-Object { $_.Entitlements } | Select-Object -Unique)
$sp = Get-One "$graph/servicePrincipals?`$filter=$(F "displayName eq '$AppName'")&`$select=id,displayName,appRoles" "enterprise app"
if (-not $sp -and @($defs | Where-Object { $_.AppRole }).Count) { throw "Enterprise app '$AppName' not found. Run register_storeops_app.ps1 first." }

# ---------- 2. Verify mode ----------
if ($Verify) {
    $catalog = Get-Catalog
    if (-not $catalog) { throw "Catalog '$CatalogName' not found. Run without -Verify first." }
    $users = Get-All "$graph/users?`$select=id,employeeId&`$top=999"
    $empById = @{}; foreach ($u in $users) { $empById[$u.id] = $u.employeeId }
    # Where-Object drops nulls: piping an empty result ($null) into ForEach-Object still runs it once
    function To-EmpIds($objectIds) { @($objectIds | Where-Object { $_ } | ForEach-Object { if ($empById[$_]) { $empById[$_] } else { "(no employeeId)" } } | Sort-Object -Unique) }
    function Short([string[]]$Ids) { if ($Ids.Count -le 10) { $Ids -join ", " } else { (($Ids | Select-Object -First 10) -join ", ") + " ... and $($Ids.Count - 10) more" } }
    function Diff-Ids([string[]]$Expected, [string[]]$Actual) {
        [pscustomobject]@{
            Missing    = @($Expected | Where-Object { $_ -and $Actual -notcontains $_ })     # $_ -and: skip the $null an empty list pipes in
            Unexpected = @($Actual | Where-Object { $_ -and $Expected -notcontains $_ })
        }
    }
    $stamp = (Get-Date).ToUniversalTime()
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Access packages read back from Graph, $($stamp.ToString('yyyy-MM-dd HH:mm')) UTC. HR file: $(Split-Path $HrFile -Leaf), in force: $($hrInForce.Count)")
    $lines.Add("Catalog: $($catalog.displayName) (state: $($catalog.state))")
    $groupById = @{}; $entGroup = @{}
    foreach ($ent in $entNames) {
        $g = Get-One "$graph/groups?`$filter=$(F "displayName eq 'ENT-$ent'")&`$select=id,displayName" "group"
        if ($g) { $groupById[$g.id] = "ENT-$ent"; $entGroup[$ent] = $g }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $checks = New-Object System.Collections.Generic.List[object]
    $holders = @{}       # employeeId -> packages held (for the wrong-department check)
    foreach ($d in $defs) {
        $pkg = Get-Package $catalog $d.Name
        if (-not $pkg) {
            $checks.Add([pscustomobject]@{ Check = "$($d.Name): package exists"; Pass = $false }); continue
        }
        $full = Invoke-Graph GET "$em/accessPackages/$($pkg.id)?`$expand=resourceRoleScopes(`$expand=role,scope),assignmentPolicies"
        $policies = @($full.assignmentPolicies | ForEach-Object { Invoke-Graph GET "$em/assignmentPolicies/$($_.id)" })
        $auto = @($policies | Where-Object { $_.automaticRequestSettings })
        $rule = if ($auto.Count -eq 1) { @($auto[0].specificAllowedTargets)[0].membershipRule } else { "" }
        $ars  = if ($auto.Count -eq 1) { $auto[0].automaticRequestSettings } else { $null }
        $grace = if ($ars -and $ars.gracePeriodBeforeAccessRemoval) { $ars.gracePeriodBeforeAccessRemoval } else { "none" }
        $resources = @($full.resourceRoleScopes | ForEach-Object {
            if ($_.role.originSystem -eq "AadGroup") { $groupById[$_.scope.originId] ?? $_.role.originId }
            else { "$AppName : $($_.role.displayName)" } })
        $assign = Get-All "$em/assignments?`$filter=$(F "accessPackage/id eq '$($pkg.id)'")&`$expand=target"
        $delivered = @($assign | Where-Object { $_.state -eq "delivered" })
        $pending   = @($assign | Where-Object { $_.state -in @("delivering", "partiallyDelivered") })
        $failedDel = @($assign | Where-Object { $_.state -eq "deliveryFailed" })
        $actualIds = To-EmpIds ($delivered | ForEach-Object { $_.target.objectId })
        foreach ($e in $actualIds) { if (-not $holders[$e]) { $holders[$e] = @() }; $holders[$e] += $d.RoleId }
        $diff = Diff-Ids ($d.Expected.employee_id) $actualIds
        $match = ($diff.Missing.Count -eq 0 -and $diff.Unexpected.Count -eq 0)
        $rows.Add([pscustomobject]@{
            package = $d.Name; flags = $d.Flags; policies = $policies.Count; automatic = $auto.Count
            rule_matches_design = ($rule -eq $d.Rule)
            auto_remove = [bool]($ars -and $ars.removeAccessWhenTargetLeavesAllowedTargets); grace = $grace
            resources = $resources.Count; expected_from_hr = $d.Expected.Count; delivered = $delivered.Count
            in_progress = $pending.Count; delivery_failed = $failedDel.Count
            missing = ($diff.Missing -join ";"); unexpected = ($diff.Unexpected -join ";"); match = $match
        })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): exactly 1 policy, automatic, rule = design"; Pass = ($policies.Count -eq 1 -and $auto.Count -eq 1 -and $rule -eq $d.Rule) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): auto-remove on, no grace period"; Pass = ([bool]($ars -and $ars.removeAccessWhenTargetLeavesAllowedTargets) -and $grace -in @("none", "PT0S", "P0D")) })
        $wantRes = $d.Entitlements.Count + [int][bool]$d.AppRole
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): $wantRes resource role(s)"; Pass = ($resources.Count -eq $wantRes) })
        $checks.Add([pscustomobject]@{ Check = "$($d.Name): assignments match HR ($($d.Expected.Count))"; Pass = $match })
        $lines.Add("")
        $lines.Add("$($d.Name)$(if ($d.Flags) { "  [$($d.Flags)]" })")
        $lines.Add("  Rule:      $rule")
        $lines.Add("  Remove when out of scope: $([bool]($ars -and $ars.removeAccessWhenTargetLeavesAllowedTargets))   Grace: $grace")
        $lines.Add("  Resources: $($resources -join ', ')")
        $lines.Add("  HR says $($d.Expected.Count), delivered $($delivered.Count), in progress $($pending.Count), failed $($failedDel.Count)" +
            $(if ($diff.Missing.Count) { "; missing: $(Short $diff.Missing)" } else { "" }) +
            $(if ($diff.Unexpected.Count) { "; unexpected: $(Short $diff.Unexpected)" } else { "" }))
    }

    # The access actually landed: entitlement groups and app roles hold exactly the expected people
    $lines.Add("")
    $lines.Add(("{0,-40} {1,8} {2,8}  {3}" -f "Resource", "HR says", "Entra", "Match"))
    foreach ($ent in $entNames) {
        $want = @($defs | Where-Object { $_.Entitlements -contains $ent } | ForEach-Object { $_.Expected.employee_id } | Sort-Object -Unique)
        $g = $entGroup[$ent]
        $have = if ($g) { To-EmpIds ((Get-All "$graph/groups/$($g.id)/members?`$select=id&`$top=999").id) } else { @() }
        $ok = $g -and ((Diff-Ids $want $have).Missing.Count + (Diff-Ids $want $have).Unexpected.Count) -eq 0
        $gd = Diff-Ids $want $have
        $lines.Add(("{0,-40} {1,8} {2,8}  {3}{4}{5}" -f "ENT-$ent", $want.Count, $(if ($g) { $have.Count } else { "missing" }), $ok,
            $(if ($gd.Missing.Count) { "  missing: $(Short $gd.Missing)" }), $(if ($gd.Unexpected.Count) { "  unexpected: $(Short $gd.Unexpected)" })))
        $checks.Add([pscustomobject]@{ Check = "Group ENT-$ent holds exactly HR's $($want.Count)"; Pass = [bool]$ok })
    }
    if ($sp) {
        $appAssigned = Get-All "$graph/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$top=999"
        foreach ($d in @($defs | Where-Object { $_.AppRole })) {
            $roleDef = @($sp.appRoles) | Where-Object { $_.value -eq $d.AppRole }
            $mine = @($appAssigned | Where-Object { $roleDef -and $_.appRoleId -eq $roleDef.id })
            $groupsAssigned = @($mine | Where-Object { $_.principalType -ne "User" }).Count
            $have = To-EmpIds (@($mine | Where-Object { $_.principalType -eq "User" }).principalId)
            $want = @($d.Expected.employee_id)
            $ok = $groupsAssigned -eq 0 -and ((Diff-Ids $want $have).Missing.Count + (Diff-Ids $want $have).Unexpected.Count) -eq 0
            $lines.Add(("{0,-40} {1,8} {2,8}  {3}" -f "$AppName : $($d.AppRole)", $want.Count, $have.Count, $ok))
            $checks.Add([pscustomobject]@{ Check = "App role $($d.AppRole) holds exactly HR's $($want.Count), no groups"; Pass = [bool]$ok })
        }
    }

    # Right title, wrong department: must hold none of these packages
    $lines.Add("")
    $lines.Add("Matching title, other department (must hold no package): $($wrongDept.Count)")
    $leak = 0
    foreach ($p in $wrongDept) {
        $held = if ($holders.ContainsKey($p.employee_id)) { @($holders[$p.employee_id]) } else { @() }
        if ($held.Count) { $leak++ }
        $lines.Add(("  {0} {1}, {2}: holds {3}" -f $p.employee_id, $p.job_title, $p.department, $(if ($held.Count) { $held -join ", " } else { "none" })))
    }
    $checks.Add([pscustomobject]@{ Check = "Wrong-department title matches hold no package ($($wrongDept.Count) checked)"; Pass = ($leak -eq 0 -and $wrongDept.Count -gt 0) })

    $lines.Add("")
    foreach ($c in $checks) { $lines.Add(("[{0}] {1}" -f $(if ($c.Pass) { "PASS" } else { "FAIL" }), $c.Check)) }
    $failed = @($checks | Where-Object { -not $_.Pass }).Count
    $lines.Add($(if ($failed) { "$failed of $($checks.Count) check(s) FAILED. New or changed policies take several minutes (sometimes longer) to process: check again before investigating." }
                 else { "All $($checks.Count) checks passed." }))
    $lines | ForEach-Object { Write-Host $_ }
    if ($EvidenceDir) {
        New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
        $ts = $stamp.ToString("yyyy-MM-dd_HHmm")
        $txt = Join-Path $EvidenceDir "access_packages_config_$ts.txt"
        $csv = Join-Path $EvidenceDir "access_packages_$ts.csv"
        $lines | Set-Content -Path $txt -Encoding UTF8
        $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        Write-Host "Saved: $txt"
        Write-Host "Saved: $csv"
    }
    return
}

# ---------- 3. Stand-in entitlement groups ----------
$groupIds = @{}
foreach ($ent in $entNames) {
    $name = "ENT-$ent"
    $g = Get-One "$graph/groups?`$filter=$(F "displayName eq '$name'")&`$select=id,displayName" "group"
    if ($g) { Write-Host "Unchanged group     $name" }
    else {
        $g = Invoke-Graph POST "$graph/groups" ([ordered]@{
            displayName = $name; mailEnabled = $false; securityEnabled = $true
            mailNickname = ("ent-" + ($ent.ToLower() -replace '[^a-z0-9]', '-'))
            description = "Lab stand-in for entitlement $ent. Membership managed by access packages only (catalog '$CatalogName'). Do not add members by hand."
        })
        Write-Host "Created group       $name"
    }
    $groupIds[$ent] = $g.id
}

# ---------- 4. Catalog ----------
$catalog = Get-Catalog
if ($catalog) { Write-Host "Unchanged catalog   $CatalogName" }
else {
    $catalog = Invoke-Graph POST "$em/catalogs" ([ordered]@{
        displayName = $CatalogName; isExternallyVisible = $false; state = "published"
        description = "Title-based store and fuel roles (role catalog BUS-01..04, ADD-01). Business owners: Director of Store Operations, Fuel Operations Director. Technical owner: IAM Team." })
    Write-Host "Created catalog     $CatalogName"
}

# ---------- 5. Resources in the catalog ----------
function Get-CatalogResource([string]$OriginId) {
    Get-One "$em/catalogs/$($catalog.id)/resources?`$filter=$(F "originId eq '$OriginId'")&`$expand=scopes" "catalog resource"
}
function Add-CatalogResource([string]$OriginId, [string]$OriginSystem, [string]$Label) {
    $res = Get-CatalogResource $OriginId
    if ($res) { Write-Host "Unchanged resource  $Label"; return $res }
    Invoke-Graph POST "$em/resourceRequests" ([ordered]@{
        requestType = "adminAdd"; catalog = @{ id = $catalog.id }
        resource = [ordered]@{ originId = $OriginId; originSystem = $OriginSystem } }) | Out-Null
    for ($try = 1; $try -le 6; $try++) {
        $res = Get-CatalogResource $OriginId
        if ($res) { Write-Host "Added resource      $Label"; return $res }
        Write-Host "  waiting for '$Label' to appear in the catalog (try $try of 6)..."
        Start-Sleep -Seconds 5
    }
    throw "'$Label' was requested but did not appear in the catalog. Rerun the script in a minute."
}
$catRes = @{}
foreach ($ent in $entNames) { $catRes[$ent] = Add-CatalogResource $groupIds[$ent] "AadGroup" "ENT-$ent" }
if ($sp -and @($defs | Where-Object { $_.AppRole }).Count) { $catRes["__app"] = Add-CatalogResource $sp.id "AadApplication" $AppName }

function Get-ResourceRole($Res, [string]$OriginSystem, [string]$RoleOriginId) {
    $roles = Get-All "$em/catalogs/$($catalog.id)/resourceRoles?`$filter=$(F "(originSystem eq '$OriginSystem' and resource/id eq '$($Res.id)')")&`$expand=resource"
    $role = @($roles | Where-Object { $_.originId -eq $RoleOriginId })
    if ($role.Count -ne 1) { throw "Resource role '$RoleOriginId' not found in the catalog." }
    return $role[0]
}

# ---------- 6. Access packages, resource roles, automatic policies ----------
foreach ($d in $defs) {
    $pkg = Get-Package $catalog $d.Name
    if ($pkg) { Write-Host "Unchanged package   $($d.Name)" }
    else {
        $pkg = Invoke-Graph POST "$em/accessPackages" ([ordered]@{
            displayName = $d.Name; description = $d.Description; catalog = @{ id = $catalog.id } })
        Write-Host "Created package     $($d.Name)"
    }
    $full = Invoke-Graph GET "$em/accessPackages/$($pkg.id)?`$expand=resourceRoleScopes(`$expand=role,scope),assignmentPolicies"
    $haveRoles = @($full.resourceRoleScopes | ForEach-Object { $_.role.originId })

    $wanted = @(foreach ($ent in $d.Entitlements) {
        [pscustomobject]@{ Res = $catRes[$ent]; System = "AadGroup"; RoleOriginId = "Member_$($groupIds[$ent])"; Label = "ENT-$ent (Member)" } })
    if ($d.AppRole) {
        $appRoleId = (@($sp.appRoles) | Where-Object { $_.value -eq $d.AppRole }).id
        if (-not $appRoleId) { throw "App role '$($d.AppRole)' not found on '$AppName'." }
        $wanted += [pscustomobject]@{ Res = $catRes["__app"]; System = "AadApplication"; RoleOriginId = $appRoleId; Label = "$AppName ($($d.AppRole))" }
    }
    foreach ($w in $wanted) {
        if ($haveRoles -contains $w.RoleOriginId) { Write-Host "  unchanged role    $($w.Label)"; continue }
        $role  = Get-ResourceRole $w.Res $w.System $w.RoleOriginId
        $scope = @($w.Res.scopes)[0]
        Invoke-Graph POST "$em/accessPackages/$($pkg.id)/resourceRoleScopes" ([ordered]@{
            role = [ordered]@{
                id = $role.id; displayName = $role.displayName; description = $role.description
                originSystem = $role.originSystem; originId = $role.originId
                resource = [ordered]@{ id = $w.Res.id; originId = $w.Res.originId; originSystem = $w.Res.originSystem } }
            scope = [ordered]@{ id = $scope.id; originId = $scope.originId; originSystem = $scope.originSystem } }) | Out-Null
        Write-Host "  added role        $($w.Label)"
    }

    # Policy last, so the first assignments already include every resource
    $body = [ordered]@{
        displayName = "Automatic: $($d.Department) / $($d.Titles -join ', ')"
        description = "Assigned and removed automatically from HR department + job title. No grace period."
        allowedTargetScope = "specificDirectoryUsers"
        specificAllowedTargets = @( [ordered]@{
            "@odata.type" = "#microsoft.graph.attributeRuleMembers"
            description = "HR in force, $($d.Department), $($d.Titles -join ' or ')"
            membershipRule = $d.Rule } )
        automaticRequestSettings = [ordered]@{
            requestAccessForAllowedTargets = $true
            removeAccessWhenTargetLeavesAllowedTargets = $true }   # no gracePeriodBeforeAccessRemoval = removed at once
        accessPackage = @{ id = $pkg.id }
    }
    $policies = @($full.assignmentPolicies | ForEach-Object { Invoke-Graph GET "$em/assignmentPolicies/$($_.id)" })
    $auto = @($policies | Where-Object { $_.automaticRequestSettings })
    if ($policies.Count -gt $auto.Count) { Write-Warning "$($d.Name) has $($policies.Count - $auto.Count) non-automatic policy(ies); left unchanged. -Verify will flag it." }
    if ($auto.Count -gt 1) { throw "$($d.Name) has $($auto.Count) automatic policies. Keep one (Microsoft: one automatic policy per package), then rerun." }
    if ($auto.Count -eq 0) {
        Invoke-Graph POST "$em/assignmentPolicies" $body | Out-Null
        Write-Host "  created policy    $($body.displayName)"
    } elseif (@($auto[0].specificAllowedTargets)[0].membershipRule -ne $d.Rule -or
              -not $auto[0].automaticRequestSettings.removeAccessWhenTargetLeavesAllowedTargets) {
        Invoke-Graph PUT "$em/assignmentPolicies/$($auto[0].id)" $body | Out-Null
        Write-Host "  updated policy    $($body.displayName)"
    } else { Write-Host "  unchanged policy  $($body.displayName)" }
}
Write-Host "Done. Assignments are processed in the background (several minutes or more): then run with -Verify."
