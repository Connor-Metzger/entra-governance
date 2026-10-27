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
    "Should have" = HR status Active AND hire date/time has passed AND leave date/time
    has not passed. Dates use the same local times as load_users.ps1 (hire 03:00,
    leave 23:00 Eastern), so a pre-hire or a leaver past their last day isn't counted.

.EXAMPLE
    .\scripts\create_dynamic_groups.ps1 -DryRun
    .\scripts\create_dynamic_groups.ps1
    .\scripts\create_dynamic_groups.ps1 -Verify -EvidenceDir evidence/M1.2
    .\scripts\create_dynamic_groups.ps1 -HrFile exports\hr_m13_s2.csv -DryRun -AsOfUtc 2026-10-31T09:00:00Z
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$CatalogFile = "data/role_catalog_design.csv",
    [string]$HrFile      = "data/t0/hr_feed.csv",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir = "",
    [string]$TimeZoneId     = "Eastern Standard Time",   # same as load_users.ps1
    [string]$HireTimeLocal  = "03:00",
    [string]$LeaveTimeLocal = "23:00",
    [string]$AsOfUtc        = ""                        # default: now. e.g. 2026-10-31T09:00:00Z to preview a date
)
$ErrorActionPreference = "Stop"
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
if ($AsOfUtc) {
    $nowUtc = [DateTime]::Parse($AsOfUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
} else { $nowUtc = [DateTime]::UtcNow }

function ConvertTo-UtcFromLocal([string]$Date, [string]$Time) {
    # Same conversion as load_users.ps1: local store date + time -> UTC (DST-aware)
    $local = [DateTime]::ParseExact("$Date $Time", "yyyy-MM-dd HH:mm",
        [Globalization.CultureInfo]::InvariantCulture)
    return [TimeZoneInfo]::ConvertTimeToUtc($local, $tz)
}

$guard = '(user.employeeId -ne null) -and (user.accountEnabled -eq true)'

# ---------- 1. Build group definitions from the catalog ----------
$catalog = Import-Csv -Path $CatalogFile -Encoding UTF8 | Where-Object { $_.layer -eq "Birthright" }
$hrRows = @(Import-Csv -Path $HrFile -Encoding UTF8 | Where-Object { $_.status -eq "Active" })

# Who should be in a birthright group right now: started, and not past their last day
$notStarted = @(); $pastLeave = @(); $hrActive = @()
foreach ($row in $hrRows) {
    $hireUtc = ConvertTo-UtcFromLocal $row.hire_date $HireTimeLocal
    $leaveUtc = $null
    if (-not [string]::IsNullOrWhiteSpace($row.termination_date)) {
        $leaveUtc = ConvertTo-UtcFromLocal $row.termination_date $LeaveTimeLocal
    }
    if ($hireUtc -gt $nowUtc)                 { $notStarted += $row }
    elseif ($leaveUtc -and $leaveUtc -le $nowUtc) { $pastLeave += $row }
    else                                      { $hrActive += $row }
}

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
Write-Host ("HR Active rows: {0} | Not started yet: {1} | Past leave date: {2} | Expected in groups: {3}  (as of {4})" -f `
    $hrRows.Count, $notStarted.Count, $pastLeave.Count, $hrActive.Count, $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"))
foreach ($r in $notStarted) { Write-Host ("  excluded {0} {1} {2}: hire date {3} not reached" -f $r.employee_id, $r.first_name, $r.last_name, $r.hire_date) }
foreach ($r in $pastLeave)  { Write-Host ("  excluded {0} {1} {2}: last day {3} has passed" -f $r.employee_id, $r.first_name, $r.last_name, $r.termination_date) }
if (@($defs).Count -eq 0) { throw "No birthright roles found in '$CatalogFile'. Wrong file? (Use -HrFile <path> for an HR file.)" }
if ($hrActive.Count -eq 0) { throw "No employees in force found in '$HrFile' (check the file and -AsOfUtc)." }
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
