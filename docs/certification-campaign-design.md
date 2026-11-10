# Certification Campaign Design — Keystone Fuel & Market

*Module M3 · Built in a lab tenant (Microsoft Entra ID Governance trial) · Last updated 2026-11-09*

Results of the first campaign: `reports/2026-11-certification-report.md`. Script: `scripts/create_access_reviews.ps1`.

## 1. What gets certified, and how

Access is certified the way it was granted. Reviewing rule-based access person by person doesn't work: denying Morgan's BUS-02 Store Manager package would only get it re-added by the policy minutes later.

| Access | Granted by | How it's certified | Who decides |
|---|---|---|---|
| Birthright (BR-01..06) and title packages (BUS-01..04, ADD-01) | HR attributes: dynamic groups and automatic package policies | **Attest the rule and the HR data behind it:** is the rule still right for the role, and is the department/title data accurate? | Role owner (role catalog), HR for data |
| Requested: ADD-06 Cash Office [PCI], ADD-07 StoreOps Admin [Privileged] | A person asked; approval; expiry | **Person by person** access review (R1, R2) | PCI owner; manager then IT Director |
| Dormant accounts | Not a grant: accounts nobody uses | **Inactive-users-only review** (R3), read and acted on by IAM, never auto-applied | Managers, IAM fallback |

## 2. The three reviews

| | R1 PCI | R2 Privileged | R3 Inactive |
|---|---|---|---|
| Scope | ADD-06 Cash Office assignments | ADD-07 StoreOps Admin assignments | Org-wide group members with no sign-in for 14 days |
| Reviewers | PCI owner | Stage 1: holder's manager (no manager → fallback). Stage 2: IT Director, sees stage 1 | Holder's manager, fallback IAM |
| Moves to stage 2 | n/a | Approve and Not reviewed (a stage 1 Deny is final) | n/a |
| Justification | Required | Required | Required |
| Recommendations | On | On | On |
| If nobody responds | **Deny** | **Deny** | No change |
| Auto-apply | On | On | **Off** |
| Why | Card data: silence means no | Admin: two independent looks; silence means no | Recommendations depend on sign-in data; a person decides what to disable |

Lab durations: 3 days (R2: 2 + 1). The review actually closes at **08:00 UTC on the end date**, so the script adds one day of buffer (see the report, things that broke).

## 3. Cadence (production)

| Review | Cadence | Duration | Reason |
|---|---|---|---|
| R1 Cash Office | Quarterly | 14 days | PCI DSS 7.2.4 requires 6 months; quarterly matches the 90-day package expiry |
| R2 StoreOps Admin | Quarterly, plus 30-day expiry | 14 days (7 + 7) | Privileged; expiry already forces re-request monthly |
| R3 Dormant accounts | Monthly | 14 days | CIS 5.3: disable dormant accounts after 45 days |
| Rule attestation (BUS-02 etc.) | Semiannual | 30 days | Rules change rarely; HR data quality is checked every month by `-Verify` |

## 4. Reviewer rules

- **Small reviews.** One reviewer, one package, a handful of people. Certifier fatigue starts when a manager gets 400 rows.
- **The recommendation is a hint, not a decision.** Entra recommends Deny when someone hasn't signed in for 30 days. Store staff who only use the POS never sign in to Entra, so the reviewer decides on the job, and writes the reason.
- **Approve only what you understand.** A reviewer who doesn't recognise the access leaves it or denies it and calls the IAM desk; never approves to clear the list.
- **Break-glass accounts are excluded from dormancy rules.** They are unused by design; their sign-ins are alerted on instead.

## 5. Escalation path

| Level | Who | Handles |
|---|---|---|
| 0 | Reviewer (store manager, PCI owner, IT Director) | Decisions, with reasons |
| 1 | IAM analyst (certifier desk) | "What is this access?", how to decide, changing a decision while the review is open, re-requests (`docs/certifier-faq.md`) |
| 2a | HR | Wrong manager, title or department behind the review |
| 2b | IAM engineering + security | A decision that didn't take effect; access still present after a Deny |
| 2c | Role owner / Director of Store Operations | Rule changes; stores without a Store Manager |

## 6. After every review: verify the removal

Entra's review status ("Applied") and the audit log are not proof that access was removed. In the first campaign both said success while the denied people kept their access (report, finding F1). After each review closes:

1. Run `create_access_reviews.ps1 -Verify`: every decision's apply result.
2. For each Deny, run `show_person_access.ps1 -EmployeeId <id>`: the package must be expired and the app role gone.
3. Anything still present → remove it by hand the same day, record it against the review decision, escalate to 2b.

## 7. Lab deviations

- iam.admin is the PCI owner, the IT Director and every fallback reviewer.
- Synthetic users can't sign in: managers never respond, and every recommendation is based on "no sign-in".
- Holders were seeded by admin direct assignment (no approval) so the reviews had people in them.
- Reviews were created with the access reviews API (`/identityGovernance/accessReviews/definitions`), scoped to package assignments. Their decisions were not applied (F1). Production: configure package reviews in the package's assignment policy and still verify removal.
