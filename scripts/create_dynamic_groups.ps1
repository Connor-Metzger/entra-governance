<#
.SYNOPSIS
    Creates one dynamic security group per birthright role in the role catalog (M1.2).

.DESCRIPTION
    Source of truth for WHICH groups exist: data/role_catalog_design.csv (layer = Birthright).
    Source of truth for WHO is in them: HR attributes on each user (department), evaluated by Entra.

    Every rule also requires:
      user.employeeId -ne null      -> only HR-sourced people (admin and break-glass accounts excluded)
      user.accountEnabled -eq true  -> a disabled leaver drops out automatically

    Safe to rerun: existing groups (matched by display name) get their rule updated if it changed.

    -Verify compares live member counts with the counts HR says they should have.

.EXAMPLE
    .\scripts\create_dynamic_groups.ps1 -DryRun
    .\scripts\create_dynamic_groups.ps1
    .\scripts\create_dynamic_groups.ps1 -Verify -EvidenceDir evidence/M1.2
#>
[CmdletBinding()]
param(
    [string]$CatalogFile = "data/role_catalog_design.csv",
    [string]$HrFile      = "data/t0/hr_feed.csv",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir = ""
)
$ErrorActionPreference = "Stop"

$guard = '(user.employeeId -ne null) -and (user.accountEnabled -eq true)'

# ---------- 1. Build group definitions from the catalog ----------
$catalog = Import-Csv -Path $CatalogFile -Encoding UTF8 | Where-Object { $_.layer -eq "Birthright" }
$hrActive = @(Import-Csv -Path $HrFile -Encoding UTF8 | Where-Object { $_.status -eq "Active" })

$defs = foreach ($r in $catalog) {
    $values = @($r.assign_values -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($values[0] -eq "*") {
        $rule = $guard + ' -and (user.userType -eq "Member")'
        $expected = $hrActive.Count
    } elseif ($values.Count -eq 1) {
        $rule = '(user.department -eq "' + $values[0] + '") -and ' + $guard
        $expected = @($hrActive | Where-Object { $_.department -eq $values[0] }).Count
    } else {
        $list = ($values | ForEach-Object { '"' + $_ + '"' }) -join ","
        $rule = '(user.department -in [' + $list + ']) -and ' + $guard
        $expected = @($hrActive | Where-Object { $values -contains $_.department }).Count
    }
    [pscustomobject]@{
        RoleId      = $r.role_id
        DisplayName = "$($r.role_id) $($r.role_name)"
        MailNick    = ($r.role_id).ToLower()
        Description = "Birthright (dynamic). Owner: $($r.owner). Source: role catalog $($r.role_id). Review: $($r.review_cycle)."
        Rule        = $rule
        Expected    = $expected
    }
}

Write-Host ("Birthright roles in catalog: {0}" -f @($defs).Count)
foreach ($d in $defs) { Write-Host ("  {0,-34} expect {1,3}  rule: {2}" -f $d.DisplayName, $d.Expected, $d.Rule) }

if ($DryRun) { Write-Host "DRY RUN - nothing changed."; return }
if (-not (Get-MgContext)) { throw "Not connected. Run Connect-MgGraph first." }

# ---------- 2. Verify mode: compare live membership with HR ----------
if ($Verify) {
    $rows = foreach ($d in $defs) {
        $g = Get-MgGroup -Filter "displayName eq '$($d.DisplayName)'" -Property "id,displayName"
        if (-not $g) { $actual = "missing" }
        else { $actual = @(Get-MgGroupMember -GroupId $g.Id -All).Count }
        [pscustomobject]@{
            role_id = $d.RoleId; group = $d.DisplayName
            expected_from_hr = $d.Expected; actual_members = $actual
            match = ($actual -eq $d.Expected)
        }
    }
    Write-Host ("{0,-34} {1,8} {2,8}  {3}" -f "Group", "HR says", "Entra", "Match")
    foreach ($x in $rows) { Write-Host ("{0,-34} {1,8} {2,8}  {3}" -f $x.group, $x.expected_from_hr, $x.actual_members, $x.match) }
    $bad = @($rows | Where-Object { -not $_.match }).Count
    if ($bad -eq 0) { Write-Host "All groups match HR." }
    else { Write-Host "$bad group(s) differ. If just created, membership may still be processing - check again in a few minutes." }
    if ($EvidenceDir) {
        New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
        $out = Join-Path $EvidenceDir ("group_counts_{0}.csv" -f (Get-Date -Format "yyyy-MM-dd_HHmm"))
        $rows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
        Write-Host "Saved: $out"
    }
    return
}

# ---------- 3. Create or update groups ----------
foreach ($d in $defs) {
    $g = Get-MgGroup -Filter "displayName eq '$($d.DisplayName)'" -Property "id,displayName,membershipRule"
    if ($g) {
        if ($g.MembershipRule -eq $d.Rule) { $action = "Unchanged" }
        else {
            Update-MgGroup -GroupId $g.Id -BodyParameter @{ membershipRule = $d.Rule; description = $d.Description }
            $action = "Updated"
        }
    } else {
        $body = @{
            displayName                   = $d.DisplayName
            description                   = $d.Description
            mailEnabled                   = $false
            mailNickname                  = $d.MailNick
            securityEnabled               = $true
            groupTypes                    = @("DynamicMembership")
            membershipRule                = $d.Rule
            membershipRuleProcessingState = "On"
        }
        New-MgGroup -BodyParameter $body | Out-Null
        $action = "Created"
    }
    Write-Host ("{0,-10} {1}" -f $action, $d.DisplayName)
}
Write-Host "Done. Membership is calculated in the background: check each group's Overview page, then run with -Verify."
