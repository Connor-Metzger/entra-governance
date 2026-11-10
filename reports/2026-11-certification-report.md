# Certification Report — November 2026 Campaign

*Keystone Fuel & Market · Module M3 · Built in a lab tenant (Microsoft Entra ID Governance trial) · Campaign 2026-11-06 → 2026-11-09 · Report 2026-11-09*

Design: `docs/certification-campaign-design.md`. Evidence: `evidence/M3/`.

## 1. Summary

| | R1 PCI Cash Office | R2 StoreOps Admin (2 stages) | R3 Inactive 14 days |
|---|---|---|---|
| People in scope | 5 | 3 | 277 (of 281 group members) |
| Decided | 5 (100%) | Stage 1: 0 (0%) · Stage 2: 3 (100%) | 2 (0.7%) |
| Approved | 4 | 2 | 2 (break-glass) |
| Denied | 1 (20%) | 1 (33%) | 0 |
| Entra recommendation | Deny 5 | No info 3 | Deny 275, Approve 2 |
| Decisions against the recommendation | 4 of 5 | n/a | 0 |
| Removed by auto-apply | **0 of 1** | **0 of 1** | n/a (auto-apply off) |
| Removed by hand after verification | 1 (Avery Castillo) | 1 (Kai Kowalski) | 0 |

**Bottom line:** every requested PCI and privileged assignment was reviewed with a written reason, and both denials were removed, but by hand, about 17 hours after the review closed, because Entra's auto-apply did not remove anyone while reporting "Applied" (F1).

## 2. Decisions

| Review | Employee | Title, location | Decision | Reason given |
|---|---|---|---|---|
| R1 | E00001 Morgan Haddad | Store Manager, Store-007 | Approve | Store Manager, reconciles Store-007 deposits |
| R1 | E00043 Hayden Castillo | Store Manager, Store-034 | Approve | Store Manager at Store-034, reconciles the daily deposit |
| R1 | E00062 Jordan Lindqvist | Store Manager, Store-020 | Approve | Store Manager at Store-020, reconciles the daily deposit |
| R1 | E00032 Jamie Ivanova | Store Associate, Store-005 | Approve | Store-005 has no Store Manager; acting cash office |
| R1 | E00070 Avery Castillo | Store Associate, Store-033 | **Deny** | Cover ended 2026-11-06 |
| R2 | E00049 Logan Tanaka | Systems Administrator | Approve (stage 2) | Systems Administrator on the StoreOps release team |
| R2 | E00011 Marley Achebe | Systems Administrator | Approve (stage 2) | Owns StoreOps Portal configuration |
| R2 | E00015 Kai Kowalski | Service Desk Analyst | **Deny** (stage 2) | Service desk; kiosk rollout ended 2026-11-05 |
| R3 | Emergency Access 01, 02 | Break-glass (no HR ID) | Approve | Break-glass: excluded from dormancy rule |

## 3. Timeline (UTC; ET = UTC−5)

| Time | Event | Evidence |
|---|---|---|
| 11-06 23:28–23:40 | 4 Cash Office and 3 Admin holders seeded with justifications | `request_*.txt` |
| 11-06 23:41 | Reviews created and started; first verify 6/13 (§5), fixed verify 13/13 | `access_reviews_2026-11-06_1842/1847.txt` |
| 11-08 23:47 | R2 stage 1 closed: **0 of 3 decided** (F2); all three moved to stage 2 | `access_reviews_2026-11-08_2124.txt` |
| 11-09 02:22–02:31 | All R1 and R2 decisions made with reasons; break-glass approved in R3; verify 16/16 | `access_reviews_2026-11-08_2131.txt`, `03-r2-stage1-decisions.png`, `04-r1-decisions.png` |
| 11-09 08:00 | All three reviews closed (2.3 days, not 3: §5); R1 and R2 status **Applied** | `access_reviews_2026-11-09_1950.txt` |
| 11-10 00:50 | Verify: every apply result `AppliedWithUnknownFailure`; **Avery still holds Cash Office, Kai still holds Admin** | `person_access_after_review_*.txt` |
| 11-10 ~00:55 | Audit log (Access Reviews): all entries Success. ADD-06 requests: no removal request was ever raised | (checked in the portal) |
| 11-10 ~01:00 | Both assignments removed by hand in the portal | `07-manual-remediation.png` |
| 11-10 01:08 | Verify: both `[expired]`, roles gone; Cash Office 4 holders, Admin 2; 12/12 | `person_access_after_remediation_*.txt`, `requested_packages_config_2026-11-10_0108.txt` |

## 4. Findings

| # | Finding | Risk | Recommendation | Owner |
|---|---|---|---|---|
| **F1** | **Review decisions were not applied.** Status "Applied", audit log all Success, but every decision's apply result was `AppliedWithUnknownFailure` and no removal request reached entitlement management. Avery kept card-settlement access ~17 h after the review closed, Kai kept admin. Likely cause (not confirmed): reviews created with the access reviews API scoped to package assignments, instead of reviews configured in the package's assignment policy. | High (PCI) | Configure package reviews in the assignment policy; after every review, verify each Deny person by person (design §6); remove the same day by hand if needed | IAM engineering |
| F2 | **The manager stage timed out completely.** R2 stage 1: 0 of 3 decided. Logan's Entra manager is an Accounting Manager (E00189) who doesn't know StoreOps; Marley and Kai have no manager, so the fallback had it and missed the 2-day window. Stage 2 caught all three. | Medium | Fix manager data in HR (it routes reviews and approvals); reminders on day 1 and day 2; keep the second stage for privileged access | HR, IAM |
| F3 | **Recommendations were no help.** R1 recommended Deny for all 5 (no sign-ins), R2 had no information. 4 of 5 R1 decisions went against the recommendation, each with a reason. | Medium | Treat recommendations as a hint; never use "take recommendations" for auto-apply unless sign-in data is reliable for that population | IAM |
| F4 | **A justification outlived its reason.** Avery's request said "until 2026-11-06", but the package gives 90 days (requestor can't set an end date: `customSchedule=False`). The review caught it 3 days later. | Medium (PCI) | Let requestors set an end date on ADD-06 so temporary cover ends on the day it should | Director of Store Ops, IAM |
| F5 | **Store-005 has no Store Manager**, so an Associate (Jamie Ivanova) acts as cash office. Same gap as the integration memo (9 of 40 stores without a Store Manager). | Medium | Approved for now with reason; Director of Store Operations to staff or name an acting manager | Director of Store Ops |
| F6 | **Break-glass accounts look dormant by design.** Both were in R3 (no sign-in for 14 days) but Entra recommended Approve (sign-in within its 30-day lookback): two windows, two answers. | Low | Exclude break-glass from dormancy reviews; alert on their sign-ins instead (M6) | IAM |
| F7 | **275 of 277 accounts dormant.** In the lab this is an artifact: synthetic users never sign in. In production this list is the dormant-account worklist. | Info (lab) | Never auto-apply R3; IAM disables after manager confirmation; trend it in M4 | IAM |

**Rule-based PCI access (not reviewed person by person):** 52 people hold BUS-02 Store Manager [PCI] through an HR rule. It is certified by attesting the rule (Director of Store Operations) and the HR data (monthly `-Verify` of all packages against HR: 33/33 on 2026-11-03). This campaign didn't run that attestation; it is scheduled semiannually (design §3).

## 5. Things that broke

| Date | What happened | Cause / fix | Lesson |
|---|---|---|---|
| 11-06 | First `-Verify` 6/13 on correctly configured reviews | Graph stores queries rewritten (adds `/v1.0`, renames `accessPackageAssignments` to `assignments?$filter=(accessPackage/id eq …)`) → compare package/policy/reviewer IDs, not text | Verify config as data, but compare meaning |
| 11-06 | Mock test: stage list sorted as one object | `@(Get-GraphAll …)` nests the returned array → assign first, then wrap | Test with the shapes the real API returns |
| 11-08 | R3 `-Verify` 15/16: Avery Lindqvist and Riley Okafor "missing" | Entra fixes scope at the review start (they were 12 days old); the check used "now" (14+ days) → expected is computed as of the start | Expected and actual must use the same point in time |
| 11-08 | Reviews closed at 03:00 ET Monday, not Monday evening | One-time reviews end at 08:00 UTC on the end date → script adds a day of buffer | Read the actual end time from the instance, don't assume 3×24 h |
| 11-09 | Status "Applied", denied people still had access | See F1 | "Applied" is not "removed": check the person |

## 6. Control mapping

| Framework | Control | Evidence |
|---|---|---|
| PCI DSS v4.0 | 7.2.4: review user accounts and access at least every 6 months | R1 (Cash Office), R2 (Admin): every holder decided with a reason, denials removed |
| PCI DSS v4.0 | 8.2.6: inactive accounts removed or disabled within 90 days | R3 dormant-account review (277 identified; lab artifact, F7) |
| NIST SP 800-53 | AC-2(j) review accounts; AC-6(7) review user privileges; AC-5 separation of duties | R1–R3; SoD on ADD-06 ↔ ADD-01 still enforced at assignment |
| CIS Controls v8 | 5.3 disable dormant accounts; 6.2 establish an access revoking process | R3; design §6 verification and manual remediation |

## 7. Evidence (`evidence/M3/`)

| File | Shows |
|---|---|
| `01-reviews-list.png`, `02-review-email.png` | Campaign launched; reviewer notified |
| `03-r2-stage1-decisions.png`, `04-r1-decisions.png` | Decisions with reasons |
| `07-manual-remediation.png` | Manual removal of a denied assignment |
| `access_reviews_*.txt`, `access_review_decisions_*.csv` | Config checks, scope vs expected, every decision and apply result |
| `person_access_after_review_*`, `person_access_after_remediation_*` | Avery and Kai: still holding after "Applied", removed after remediation |
| `requested_packages_config_2026-11-10_0108.txt` | Cash Office 4 holders, Admin 2, 12/12 |
| `certifier-support-log.csv` | Certifier desk: 8 questions, 6 answered, 2 escalated |
