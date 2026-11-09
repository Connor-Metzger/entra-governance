<#
.SYNOPSIS
    Creates the M3 certification campaign: three one-time access reviews, and reads them back.

.DESCRIPTION
    R1 PCI         ADD-06 StoreOps Cash Office holders. Reviewer: PCI owner. Justification required.
                   3 days. If the reviewer doesn't respond: DENY (silence = no card access). Auto-apply on.
    R2 Privileged  ADD-07 StoreOps Admin holders, two stages.
                   Stage 1 (2 days): the holder's manager; no manager in Entra -> fallback reviewer.
                   Approve and Not reviewed go on to stage 2; Deny stops there.
                   Stage 2 (1 day): IT Director, sees stage 1 decisions. Default DENY, auto-apply on.
    R3 Inactive    Members of the org-wide group who haven't signed in for -InactiveDays (default 14).
                   Reviewers: managers, fallback reviewer. 3 days. No default decision, auto-apply OFF:
                   synthetic users never sign in, so recommendations would remove almost everyone.

    Why requested packages and not the automatic ones: BUS-02 Store Manager is granted by an HR rule.
    Denying Morgan in a review would remove the package and the policy would add it straight back.
    Rule-based access is certified by attesting the rule and the HR data (see the certification report);
    requested access is certified person by person.

    Lab deviation: PCI owner, IT Director and fallback reviewer are all -ReviewerUpn (iam.admin).
    Synthetic managers can't sign in, so manager stages run out as "Not reviewed".

    Safe to rerun: reviews are found by name; an existing review that differs from the design stops the
    script (it never edits a live review). -Verify checks configuration as data, then each review's
    instance: status, who is in scope against what is expected, and every decision (names and employee
    IDs only, no object IDs). Decisions don't exist until a review starts ("start time could vary a few
    hours"): those checks show WAIT, not FAIL.

    Needs: AccessReview.ReadWrite.All, EntitlementManagement.Read.All, Group.Read.All, User.Read.All,
    AuditLog.Read.All (last sign-in, for the R3 expected list).

.EXAMPLE
    .\scripts\create_access_reviews.ps1 -DryRun
    .\scripts\create_access_reviews.ps1
    .\scripts\create_access_reviews.ps1 -Verify -EvidenceDir evidence/M3
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ReviewerUpn  = "iam.admin@keystonefuellab.onmicrosoft.com",
    [string]$CatalogName  = "Keystone Store & Fuel Operations",
    [string]$OrgGroupName = "Keystone Fuel & Market",
    [int]$InactiveDays    = 14,
    [string]$Campaign     = "2026-11",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$EvidenceDir  = ""
)
$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$em    = "$graph/identityGovernance/entitlementManagement"
$ar    = "$graph/identityGovernance/accessReviews/definitions"
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
# Graph dates can arrive as DateTime (any Kind), DateTimeOffset or ISO string: always return UTC
function ToUtc($d) {
    if (-not $d) { return $null }
    if ($d -is [DateTimeOffset]) { return $d.UtcDateTime }
    if ($d -is [DateTime]) { return $(if ($d.Kind -eq [DateTimeKind]::Unspecified) { [DateTime]::SpecifyKind($d, [DateTimeKind]::Utc) } else { $d.ToUniversalTime() }) }
    return ([DateTimeOffset]::Parse([string]$d, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}
function Get-Package([string]$name) {
    $p = @((Invoke-MgGraphRequest GET "$em/accessPackages?`$filter=$(F "displayName eq '$name'")&`$expand=catalog,assignmentPolicies").value |
        Where-Object { $_.catalog.displayName -eq $CatalogName })
    if ($p.Count -ne 1) { throw "Package '$name': $($p.Count) found in '$CatalogName' (expected 1)." }
    $pol = @($p[0].assignmentPolicies)
    if ($pol.Count -ne 1) { throw "Package '$name' has $($pol.Count) policies (expected 1)." }
    return [pscustomobject]@{ Name = $name; Id = $p[0].id; PolicyId = $pol[0].id; CatalogId = $p[0].catalog.id }
}

# ---------- Resolve ----------
$rev = Invoke-MgGraphRequest GET "$graph/users/$(F $ReviewerUpn)?`$select=id,displayName,userPrincipalName"
$add06 = Get-Package "ADD-06 StoreOps Cash Office"
$add07 = Get-Package "ADD-07 StoreOps Admin"
$org = @((Invoke-MgGraphRequest GET "$graph/groups?`$filter=$(F "displayName eq '$OrgGroupName'")&`$select=id,displayName,groupTypes").value)
if ($org.Count -ne 1) { throw "Group '$OrgGroupName': $($org.Count) found (expected 1)." }
$org = $org[0]

$startDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
function OneTime([int]$days) {
    return [ordered]@{ pattern = $null; range = [ordered]@{ type = "numbered"; numberOfOccurrences = 0; recurrenceTimeZone = $null
        # Entra ends a one-time review at 08:00 UTC on endDate (seen live: started 11-06 23:41 UTC, ended 11-09 08:00 UTC,
        # 2.3 days instead of 3). One extra day guarantees at least $days full days.
        startDate = $startDate; endDate = ([datetime]$startDate).AddDays($days + 1).ToString("yyyy-MM-dd") } }
}
function PkgScope($p) {
    return [ordered]@{ "@odata.type" = "#microsoft.graph.accessReviewQueryScope"; queryType = "MicrosoftGraph"
        query = "/identityGovernance/entitlementManagement/accessPackageAssignments?`$filter=(accessPackageId eq '$($p.Id)' and assignmentPolicyId eq '$($p.PolicyId)' and catalogId eq '$($p.CatalogId)')" }
}
$userRef    = @([ordered]@{ query = "/users/$($rev.id)"; queryType = "MicrosoftGraph" })
$managerRef = @([ordered]@{ query = "./manager"; queryType = "MicrosoftGraph"; queryRoot = "decisions" })

# ---------- Design ----------
$design = @(
    [pscustomobject]@{ Key = "R1"; Name = "M3 R1 PCI: ADD-06 Cash Office ($Campaign)"; Days = 3; Package = $add06
        Summary = "ADD-06 Cash Office holders | reviewer: PCI owner | 3 days | no response: Deny | auto-apply on"
        Body = [ordered]@{
            displayName = "M3 R1 PCI: ADD-06 Cash Office ($Campaign)"
            descriptionForAdmins = "PCI certification of Cash Office (card settlement) access. Silence = remove."
            descriptionForReviewers = "Approve only if this person reconciles deposits at their store now. Give the reason. Not sure = Deny."
            scope = PkgScope $add06
            reviewers = $userRef
            settings = [ordered]@{ mailNotificationsEnabled = $true; reminderNotificationsEnabled = $true; justificationRequiredOnApproval = $true
                defaultDecisionEnabled = $true; defaultDecision = "Deny"; instanceDurationInDays = 3; autoApplyDecisionsEnabled = $true
                recommendationsEnabled = $true; recurrence = (OneTime 3) }
        } }
    [pscustomobject]@{ Key = "R2"; Name = "M3 R2 Privileged: ADD-07 StoreOps Admin, 2 stages ($Campaign)"; Days = 3; Package = $add07
        Summary = "ADD-07 Admin holders | stage 1 (2 d): manager, fallback $($rev.displayName) | stage 2 (1 d): IT Director | no response: Deny | auto-apply on"
        Body = [ordered]@{
            displayName = "M3 R2 Privileged: ADD-07 StoreOps Admin, 2 stages ($Campaign)"
            descriptionForAdmins = "Privileged certification: manager, then IT Director. Silence = remove."
            descriptionForReviewers = "Approve only if this person administers StoreOps Portal now. Give the reason."
            scope = PkgScope $add07
            stageSettings = @(
                [ordered]@{ stageId = "1"; durationInDays = 2; recommendationsEnabled = $true
                    decisionsThatWillMoveToNextStage = @("NotReviewed", "Approve"); reviewers = $managerRef; fallbackReviewers = $userRef }
                [ordered]@{ stageId = "2"; dependsOn = @("1"); durationInDays = 1; recommendationsEnabled = $true; reviewers = $userRef }
            )
            settings = [ordered]@{ mailNotificationsEnabled = $true; reminderNotificationsEnabled = $true; justificationRequiredOnApproval = $true
                defaultDecisionEnabled = $true; defaultDecision = "Deny"; instanceDurationInDays = 3; autoApplyDecisionsEnabled = $true
                decisionHistoriesForReviewersEnabled = $true; recurrence = (OneTime 3) }
        } }
    [pscustomobject]@{ Key = "R3"; Name = "M3 R3 Inactive $InactiveDays d: $OrgGroupName ($Campaign)"; Days = 3; Package = $null
        Summary = "$OrgGroupName members with no sign-in for $InactiveDays days | managers, fallback $($rev.displayName) | 3 days | no default | auto-apply OFF"
        Body = [ordered]@{
            displayName = "M3 R3 Inactive $InactiveDays d: $OrgGroupName ($Campaign)"
            descriptionForAdmins = "Dormant-account review. Results are read, not auto-applied (synthetic users never sign in)."
            descriptionForReviewers = "This person hasn't signed in for $InactiveDays days. Approve if they still work here and need the group."
            scope = [ordered]@{ "@odata.type" = "#microsoft.graph.accessReviewInactiveUsersQueryScope"; inactiveDuration = "P$($InactiveDays)D"
                query = "/groups/$($org.id)/transitiveMembers"; queryType = "MicrosoftGraph" }
            reviewers = $managerRef
            fallbackReviewers = $userRef
            settings = [ordered]@{ mailNotificationsEnabled = $true; reminderNotificationsEnabled = $true; justificationRequiredOnApproval = $true
                defaultDecisionEnabled = $false; defaultDecision = "None"; instanceDurationInDays = 3; autoApplyDecisionsEnabled = $false
                recommendationsEnabled = $true; recurrence = (OneTime 3) }
        } }
)

Write-Host "Campaign $Campaign | reviewer / fallback / PCI owner / IT Director (lab): $($rev.userPrincipalName)"
foreach ($d in $design) { Write-Host ("  {0}  {1}" -f $d.Key, $d.Name); Write-Host ("      {0}" -f $d.Summary) }

# Graph rewrites queries when it stores them: adds /v1.0 (or /beta), renames accessPackageAssignments to
# assignments?$filter=(accessPackage/id eq ...), appends /microsoft.graph.user. Compare meaning (IDs), not text.
function NQ([string]$q) { return ($q -replace '^/(v1\.0|beta)(?=/)', '') }
function Has([string]$q, [string]$id) { return ($q -match [regex]::Escape($id)) }
# Configuration checks on a definition read back from Graph
function Test-Definition($d, $def) {
    $c = New-Object System.Collections.Generic.List[object]
    $s = $def.settings
    $oneTime = ($s.recurrence.range.type -eq "numbered" -and [int]$s.recurrence.range.numberOfOccurrences -eq 0 -and -not $s.recurrence.pattern)
    $c.Add([pscustomobject]@{ Check = "$($d.Key): one-time, justification required, mail + reminders on"; Pass = ($oneTime -and $s.justificationRequiredOnApproval -and $s.mailNotificationsEnabled -and $s.reminderNotificationsEnabled) })
    switch ($d.Key) {
        "R1" {
            $c.Add([pscustomobject]@{ Check = "R1: scope = ADD-06 assignments"; Pass = ((Has $def.scope.query $add06.Id) -and (Has $def.scope.query $add06.PolicyId) -and -not (Has $def.scope.query $add07.Id)) })
            $c.Add([pscustomobject]@{ Check = "R1: reviewer = PCI owner only"; Pass = (@($def.reviewers).Count -eq 1 -and (NQ @($def.reviewers)[0].query) -eq "/users/$($rev.id)") })
            $c.Add([pscustomobject]@{ Check = "R1: 3 days, no response = Deny, auto-apply on, recommendations on"; Pass = ([int]$s.instanceDurationInDays -eq 3 -and $s.defaultDecisionEnabled -and $s.defaultDecision -eq "Deny" -and $s.autoApplyDecisionsEnabled -and $s.recommendationsEnabled) })
        }
        "R2" {
            $st = @($def.stageSettings | Sort-Object { [int]$_.stageId })
            $s1 = $st | Where-Object { $_.stageId -eq "1" }; $s2 = $st | Where-Object { $_.stageId -eq "2" }
            $c.Add([pscustomobject]@{ Check = "R2: scope = ADD-07 assignments"; Pass = ((Has $def.scope.query $add07.Id) -and (Has $def.scope.query $add07.PolicyId) -and -not (Has $def.scope.query $add06.Id)) })
            $c.Add([pscustomobject]@{ Check = "R2: stage 1 = manager (fallback reviewer), 2 days, Approve + Not reviewed move on"; Pass = ($st.Count -eq 2 -and $s1 -and
                @($s1.reviewers)[0].query -eq "./manager" -and (NQ @($s1.fallbackReviewers)[0].query) -eq "/users/$($rev.id)" -and [int]$s1.durationInDays -eq 2 -and
                (@($s1.decisionsThatWillMoveToNextStage) -join ",") -eq "NotReviewed,Approve") })
            $c.Add([pscustomobject]@{ Check = "R2: stage 2 = IT Director after stage 1, 1 day"; Pass = ($s2 -and @($s2.dependsOn) -contains "1" -and (NQ @($s2.reviewers)[0].query) -eq "/users/$($rev.id)" -and [int]$s2.durationInDays -eq 1) })
            $c.Add([pscustomobject]@{ Check = "R2: no response = Deny, auto-apply on, stage 2 sees stage 1"; Pass = ($s.defaultDecisionEnabled -and $s.defaultDecision -eq "Deny" -and $s.autoApplyDecisionsEnabled -and $s.decisionHistoriesForReviewersEnabled) })
        }
        "R3" {
            $c.Add([pscustomobject]@{ Check = "R3: scope = inactive $InactiveDays d members of $OrgGroupName"; Pass = ($def.scope.'@odata.type' -like "*accessReviewInactiveUsersQueryScope" -and $def.scope.inactiveDuration -eq "P$($InactiveDays)D" -and @("/groups/$($org.id)/transitiveMembers", "/groups/$($org.id)/transitiveMembers/microsoft.graph.user") -contains (NQ $def.scope.query)) })
            $c.Add([pscustomobject]@{ Check = "R3: reviewers = managers, fallback reviewer"; Pass = (@($def.reviewers)[0].query -eq "./manager" -and (NQ @($def.fallbackReviewers)[0].query) -eq "/users/$($rev.id)") })
            $c.Add([pscustomobject]@{ Check = "R3: 3 days, no default decision, auto-apply OFF"; Pass = ([int]$s.instanceDurationInDays -eq 3 -and -not $s.defaultDecisionEnabled -and -not $s.autoApplyDecisionsEnabled) })
        }
    }
    return $c.ToArray()
}

# ---------- Find or create ----------
$all = Get-GraphAll "$ar`?`$select=id,displayName,status"
foreach ($d in $design) {
    $found = @($all | Where-Object { $_.displayName -eq $d.Name })
    if ($found.Count -gt 1) { throw "$($found.Count) reviews named '$($d.Name)'. Delete the extra one in the portal and rerun." }
    $d | Add-Member -NotePropertyName Id -NotePropertyValue $(if ($found.Count) { $found[0].id } else { $null }) -Force
}

if (-not $Verify) {
    $failed = 0
    Write-Host ""
    foreach ($d in $design) {
        if ($d.Id) {
            $bad = @(Test-Definition $d (Invoke-MgGraphRequest GET "$ar/$($d.Id)") | Where-Object { -not $_.Pass })
            if ($bad.Count) {
                $bad | ForEach-Object { Write-Host "  DIFFERS: $($_.Check)" }
                throw "$($d.Key) exists but differs from the design. Delete it (Identity Governance > Access reviews) and rerun. This script never edits a live review."
            }
            Write-Host "$($d.Key): exists and matches the design. Nothing changed."
        } elseif ($DryRun) {
            Write-Host "$($d.Key): DRY RUN, would create '$($d.Name)' (start $startDate, ends after $($d.Days) days)."
        } else {
            try {
                $new = Invoke-MgGraphRequest -Method POST -Uri $ar -Body ($d.Body | ConvertTo-Json -Depth 12) -ContentType "application/json"
                Write-Host "$($d.Key): created '$($new.displayName)', status $($new.status)."
            } catch {
                $failed++
                $msg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                Write-Host "$($d.Key): NOT CREATED. Graph said: $msg"
            }
        }
    }
    if ($failed) { throw "$failed review(s) not created (see above). The others were created; rerunning creates only the missing ones." }
    if (-not $DryRun) { Write-Host ""; Write-Host "Reviews start within a few hours of creation. Next: -Verify (rerun until every review shows InProgress)." }
    return
}

# ---------- Verify ----------
$lines  = New-Object System.Collections.Generic.List[string]
$checks = New-Object System.Collections.Generic.List[object]
$rows   = New-Object System.Collections.Generic.List[object]
$userCache = @{}
function Get-Person([string]$id) {
    if (-not $id) { return @{ employeeId = ""; displayName = "(none)"; userPrincipalName = "" } }
    if (-not $userCache.ContainsKey($id)) {
        try { $userCache[$id] = Invoke-MgGraphRequest GET "$graph/users/$id`?`$select=employeeId,displayName,userPrincipalName,jobTitle,department,officeLocation" }
        catch { $userCache[$id] = @{ employeeId = "(deleted)"; displayName = ""; userPrincipalName = "" } }
    }
    return $userCache[$id]
}
function Label([string]$id) {
    $p = Get-Person $id
    $e = if ($p.employeeId) { $p.employeeId } else { "(no HR ID)" }
    return "$e $($p.displayName)"
}
function Reviewer($by) {
    if (-not $by -or -not $by.id -or $by.id -eq "00000000-0000-0000-0000-000000000000") { return "-" }
    return $(if ($by.id -eq $rev.id) { $rev.displayName } else { Label $by.id })
}
function Add-Decisions([string]$review, [string]$stage, $items) {
    foreach ($x in $items) {
        $p = Get-Person $x.principal.id
        $rows.Add([pscustomobject]@{ review = $review; stage = $stage; employee_id = $p.employeeId; name = $p.displayName
            job_title = $p.jobTitle; location = $p.officeLocation; recommendation = $x.recommendation; decision = $x.decision
            reviewed_by = (Reviewer $x.reviewedBy); reviewed_utc = $(if ($x.reviewedDateTime -and (ToUtc $x.reviewedDateTime).Year -gt 1) { (ToUtc $x.reviewedDateTime).ToString("yyyy-MM-ddTHH:mmZ") } else { "" })
            justification = $x.justification; apply_result = $x.applyResult })
    }
}

$lines.Add("Access review campaign $Campaign, read back from Graph {0} UTC" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm"))
$lines.Add("Reviewer / fallback / PCI owner / IT Director (lab): $($rev.userPrincipalName)")
$wait = 0
foreach ($d in $design) {
    $lines.Add("")
    $lines.Add("$($d.Key) $($d.Name)")
    if (-not $d.Id) { $checks.Add([pscustomobject]@{ Check = "$($d.Key): exists"; Pass = $false }); $lines.Add("  NOT FOUND"); continue }
    $def = Invoke-MgGraphRequest GET "$ar/$($d.Id)"
    $lines.Add("  $($d.Summary)")
    $lines.Add("  Definition status: $($def.status)")
    foreach ($c in (Test-Definition $d $def)) { $checks.Add($c) }

    # Entra fixes the scope when the review STARTS: compute expected as of the instance start
    $inst = Get-GraphAll "$ar/$($d.Id)/instances"   # assign first: @(Get-GraphAll ...) would nest the array
    $inst = @($inst)
    $started = ($inst.Count -gt 0 -and @("InProgress", "Completing", "Completed", "Applying", "Applied", "AutoReviewing", "AutoReviewed") -contains $inst[0].status)
    $asOf = if ($started) { ToUtc $inst[0].startDateTime } else { (Get-Date).ToUniversalTime() }
    $unsure = @()

    # Expected people in scope
    if ($d.Package) {
        $asg = Get-GraphAll "$em/assignments?`$filter=$(F "accessPackage/id eq '$($d.Package.Id)' and state eq 'delivered'")&`$expand=target"
        $expected = @($asg | ForEach-Object { $_.target.objectId })
    } else {
        $since = $asOf.AddDays(-$InactiveDays)
        try {
            $memIds = Get-GraphAll "$graph/groups/$($org.id)/transitiveMembers/microsoft.graph.user?`$select=id&`$top=999"
            $memIds = @($memIds | ForEach-Object { $_.id })
            $allUsers = Get-GraphAll "$graph/users?`$select=id,createdDateTime,signInActivity"   # signInActivity is read from /users
            $mem = @($allUsers | Where-Object { $memIds -contains $_.id })
            $expected = New-Object System.Collections.Generic.List[string]
            $unsureL  = New-Object System.Collections.Generic.List[string]
            foreach ($m in $mem) {
                if ((ToUtc $m.createdDateTime) -gt $since) { continue }   # too new on the start date
                $last = @($m.signInActivity.lastSignInDateTime, $m.signInActivity.lastNonInteractiveSignInDateTime) | Where-Object { $_ } |
                    ForEach-Object { ToUtc $_ } | Sort-Object -Descending | Select-Object -First 1
                if (-not $last -or $last -le $since) { $expected.Add($m.id) }
                elseif ($last -gt $asOf) { $unsureL.Add($m.id) }          # signed in after the start: can't tell what Entra saw
            }
            $expected = $expected.ToArray(); $unsure = $unsureL.ToArray()
            $young = @($mem | Where-Object { (ToUtc $_.createdDateTime) -gt $since })
            $lines.Add(("  Group members: {0} | as of review start {1} | created in the {2} days before (never in scope): {3} | expected inactive: {4} | signed in after the start (not compared): {5}" -f
                $mem.Count, $asOf.ToString("yyyy-MM-dd HH:mm 'UTC'"), $InactiveDays, $young.Count, $expected.Count, $unsure.Count))
            foreach ($x in $unsure) { $lines.Add("    signed in after start: $(Label $x)") }
            foreach ($y in $young) { $lines.Add("    too new: $(Label $y.id)") }
        } catch { $expected = $null; $lines.Add("  Expected list unavailable (needs AuditLog.Read.All): $($_.Exception.Message)") }
    }

    if (-not $started) {
        $wait++
        $lines.Add("  Instance: $(if ($inst.Count) { $inst[0].status } else { 'not created yet' }). WAIT: decisions appear once the review starts (up to a few hours).")
        continue
    }
    $i = $inst[0]
    $lines.Add(("  Instance: {0} | start {1} | end {2}" -f $i.status, (ToUtc $i.startDateTime).ToString("yyyy-MM-dd HH:mm 'UTC'"), (ToUtc $i.endDateTime).ToString("yyyy-MM-dd HH:mm 'UTC'")))
    $dec = Get-GraphAll "$ar/$($d.Id)/instances/$($i.id)/decisions"
    if ($d.Key -eq "R2") {
        $stages = Get-GraphAll "$ar/$($d.Id)/instances/$($i.id)/stages"
        $stages = @($stages | Sort-Object { ToUtc $_.startDateTime })
        $n = 0
        foreach ($s in $stages) {
            $n++
            $sd = Get-GraphAll "$ar/$($d.Id)/instances/$($i.id)/stages/$($s.id)/decisions"
            $lines.Add(("  Stage {0}: {1} | {2} -> {3} | {4} decision item(s)" -f $n, $s.status, (ToUtc $s.startDateTime).ToString("MM-dd HH:mm"), (ToUtc $s.endDateTime).ToString("MM-dd HH:mm 'UTC'"), @($sd).Count))
            Add-Decisions $d.Key "$n" $sd
        }
    } else {
        Add-Decisions $d.Key "" $dec
    }

    $inScope = @($dec | ForEach-Object { $_.principal.id } | Sort-Object -Unique)
    if ($null -ne $expected) {
        $missing = @($expected | Where-Object { $inScope -notcontains $_ })
        $extra   = @($inScope  | Where-Object { $expected -notcontains $_ -and $unsure -notcontains $_ })
        $notCompared = @($inScope | Where-Object { $unsure -contains $_ }).Count
        $lines.Add(("  In scope: {0} | expected: {1}{2}{3}{4}" -f $inScope.Count, $expected.Count, $(if ($notCompared) { " (+$notCompared signed in after the start, not compared)" } else { "" }),
            $(if ($missing.Count) { " | missing: " + (($missing | ForEach-Object { Label $_ }) -join ", ") } else { "" }),
            $(if ($extra.Count) { " | unexpected: " + (($extra | ForEach-Object { Label $_ }) -join ", ") } else { "" })))
        $checks.Add([pscustomobject]@{ Check = "$($d.Key): people in scope = expected ($($expected.Count))"; Pass = ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $expected.Count -gt 0) })
    }
    $tally = $dec | Group-Object { $_.decision } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }
    $reco  = $dec | Group-Object { $_.recommendation } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }
    $lines.Add("  Decisions: $($tally -join ', ') | recommendations: $($reco -join ', ')")
    if ($d.Key -ne "R3") {
        foreach ($r in ($rows | Where-Object review -eq $d.Key)) {
            $lines.Add(("    {0}{1} {2} | {3} | {4} | recommended {5} | {6} by {7}{8}{9}" -f $(if ($r.stage) { "[stage $($r.stage)] " } else { "" }), $r.employee_id, $r.name, $r.job_title, $r.location,
                $r.recommendation, $r.decision, $r.reviewed_by, $(if ($r.justification) { " | `"$($r.justification)`"" } else { "" }), $(if ($r.apply_result -and $r.apply_result -ne "New") { " | applied: $($r.apply_result)" } else { "" })))
        }
    } else {
        $noHr = @($rows | Where-Object { $_.review -eq "R3" -and -not $_.employee_id })
        $lines.Add("  Accounts with no HR ID in scope (admin, break-glass): $($noHr.Count)")
        foreach ($r in $noHr) { $lines.Add("    $($r.name) | recommended $($r.recommendation) | $($r.decision)") }
    }
}

$lines.Add("")
$lines.Add("Checks:")
foreach ($c in $checks) { $lines.Add(("  [{0}] {1}" -f $(if ($c.Pass) { "PASS" } else { "FAIL" }), $c.Check)) }
$passed = @($checks | Where-Object Pass).Count
$lines.Add("Result: $passed / $($checks.Count) passed$(if ($wait) { ", $wait review(s) not started yet (WAIT, rerun later)" })")
$lines | ForEach-Object { Write-Host $_ }

if ($EvidenceDir) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $ts = Get-Date -Format "yyyy-MM-dd_HHmm"
    $out = Join-Path $EvidenceDir "access_reviews_$ts.txt"
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host "Saved: $out"
    if ($rows.Count) {
        $csv = Join-Path $EvidenceDir "access_review_decisions_$ts.csv"
        $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        Write-Host "Saved: $csv"
    }
}
