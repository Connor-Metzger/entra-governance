# IAM Access Control Policy — Keystone Fuel & Market

*Version 1.0 · 2026-11-12 · Owner: IT Director (policy), IAM Team (operation) · Next review: 2027-11-12 or after any major change · Built in a lab environment (Microsoft Entra ID Governance)*

## 1. Purpose and scope

This policy says who may have access to Keystone systems, how they get it, how long they keep it, and how we prove it. It applies to every Keystone employee and every account in the Keystone directory (Microsoft Entra ID), and to every application connected to it, including the StoreOps Portal and the systems that handle payment card data (PCI scope).

**How to read this policy.** Each rule has a status:
- **Implemented**: built and tested, with evidence in the repository.
- **Partial**: built, but a test found a weakness.
- **Gap**: not yet in place. The fix, owner and due date are in `reports/governance-trend-report.md` (G1–G8).

## 2. Who owns what

| Role | Owns | Does not own |
|---|---|---|
| **HR** | The truth about people: hire date, department, job title, manager, last day. The directory copies it every night | Access decisions |
| **Role owners** (Director of Store Operations, Fuel Operations Director, Controller, HR Director, IT Director) | What each role grants and who may request add-ons for their area. Approve role changes; attest the role rules | Running the system |
| **Managers** | First approval of requested access for their people; first-stage reviews | Approving their own access |
| **PCI owner** | Final approval and review of payment card access (Cash Office) | Store staffing |
| **IAM Team** | Building and running the controls, evidence, monitoring, escalation. Recommends; does not decide business access | HR data, business decisions |
| **Employees** | Asking only for what their job needs; never sharing a login | — |

**HR is the authoritative source.** Nobody corrects a department, title, manager or date in the directory by hand. A wrong record is fixed in HR and flows through the next nightly load. *(Implemented: `scripts/load_users.ps1`; docs/jml-process.md §1)*

## 3. Least privilege: three layers of access

Access is granted by job, never by copying another person's access.

| Layer | Example | How it is granted | Status |
|---|---|---|---|
| **Birthright**: everyone in a department | BR-02 Store Operations Baseline | Automatically, from the HR department (dynamic group) | Implemented: 6 groups, all match HR (`evidence/final-2026-11-12/group_counts_*.csv`) |
| **Role**: everyone with a job title | BUS-02 Store Manager, ADD-01 POS Refunds | Automatically, from department + title (access package with an automatic policy); removed automatically when the job changes | Implemented: 5 packages, 33/33 checks; 0 of 409 title grants outside the rule (trend report §2) |
| **Requested**: sensitive access a person must ask for | ADD-06 Cash Office [PCI], ADD-07 StoreOps Admin [Privileged] | Requested with a reason, approved, and expires on its own | Implemented: 12/12 checks (`requested_packages_config_*.txt`) |

Rules:
3.1 **No direct grants.** Access to a connected system comes only through a birthright group, a role package or a requested package. *(Implemented: drift check found 0 grants without a package at T1, and caught 2 of 2 planted ones; `notebooks/governance_trends.ipynb` §4)*
3.2 **Rules check department and title together.** A title alone is not enough (Rowan Kowalski: "Store Associate" in Fuel Operations). *(Implemented: every package rule)*
3.3 **"Has it" is not "needs it".** Payment card and admin access is never granted by job title alone: it is requested per person. *(Implemented: ADD-06, ADD-07)*

## 4. Joiners, movers and leavers

| Event | Standard | Status |
|---|---|---|
| **Joiner** | Account created disabled before the start date. A one-time temporary access pass goes to the manager 7 days before, valid only from 03:00 ET on day one. Account enabled at 03:00 ET on day one | Implemented: Avery and Riley enabled 37 min after start (trend report §2). Partial: the pass fails when HR has no manager (Riley, G5) |
| **Mover** | Birthright and role access follow the new department and title automatically. **Payment card and admin access is removed at the next hourly run after a department change**. Other requested access gets a 15-day handover | Implemented for PCI and admin: Finley 32 min (JML-M2). **Gap:** the 15-day handover removal has never worked (G4) |
| **Leaver** | **HR enters every termination by the end of the employee's last shift.** At 23:00 ET on the last day the account is disabled, sessions revoked, and all groups, packages and Teams removed. Deleted 7 days later (restorable for 30 days if HR made an error) | Workflow implemented: Logan 4/4 tasks, deleted on day 7. **Gap:** HR entry deadline not yet agreed (G2: Logan entered the next morning, 11.6 h exposure) |
| **Involuntary termination** | IAM disables the account immediately on HR's call, without waiting for the workflow | Gap: runbook in M5.4 (G2) |
| **Re-enabling a leaver** | Never. A former employee who needs a pay stub or tax form gets it from HR, not through their old account. A rehire gets a new joiner process | Implemented: the HR load never re-enables (tested: `evidence/M1.3/logan_after_resync.txt`) |

## 5. Separation of duties (SoD)

5.1 No one may hold two duties that together let them commit and hide a fraud. Keystone's SoD rules:

| Duty A | Duty B | Risk |
|---|---|---|
| POS Refunds (ADD-01) | Cash Office / SafeCount (ADD-06) | Issue a refund to your own card, then reconcile the cash that would show it |
| Create vendor payments | Approve vendor payments | Pay yourself |
| Create a vendor | Approve payment to it | Pay a fake vendor |
| Create purchase orders | Approve purchase orders | Buy without oversight |
| Edit employee records | Approve payroll | Pay a fake employee |
| Directory administration | Access review administration | Grant access and hide it from review |

5.2 SoD is enforced **when access is requested**, not only found afterwards. *(Implemented for refunds ↔ Cash Office: Alex Larsen's request was blocked, `InvalidRequestSODCheck`; `evidence/M2.5/request_E00013_ADD-06_*.txt`. The other five pairs are designed out of the role catalog: 22 conflicts → 0, docs/role-catalog.md.)*
5.3 The block is currently one-way (Cash Office checks refunds, not the reverse). *(Partial: docs/access-packages.md 8.5)*

## 6. Access reviews

| What | Reviewer | Cadence | No response means | Status |
|---|---|---|---|---|
| Cash Office (PCI), per person | PCI owner | **Quarterly** (PCI DSS requires at least every 6 months) | Remove | Implemented: R1, 5 of 5 decided with reasons |
| StoreOps Admin (privileged), per person | Manager, then IT Director | **Quarterly**, and the access expires every 30 days | Remove | Implemented: R2, 3 of 3 decided |
| Dormant accounts (no sign-in for 14 days) | Manager | Monthly | Nothing: never removed automatically | Implemented: R3 |
| Role rules (who a role covers) | Role owner | Semiannual for PCI or privileged roles; annual for birthright | — | Designed (docs/certification-campaign-design.md §3); not yet run |

Rules:
6.1 **Decide on the job, not the recommendation.** Entra's recommendations are based on sign-ins, and store staff don't sign in to Entra. Every decision needs a written reason. *(Implemented in reviewer guidance: docs/certifier-faq.md; G7)*
6.2 **A review is finished when the access is gone, not when the tool says "Applied".** IAM checks every Deny person by person within one business day of the review closing and removes anything left by hand. *(Implemented as a manual check; the automatic removal failed: G1)*
6.3 Nobody reviews their own access.

## 7. Privileged and emergency access

7.1 Admin access to Keystone applications (ADD-07 StoreOps Admin) is requested, approved by the IT Director, and expires after 30 days. *(Implemented)*
7.2 Day-to-day admins use narrow roles and activate higher roles only when needed. *(Gap in the lab: iam.admin holds Global Administrator; docs/lab-environment.md)*
7.3 **Break-glass accounts.** Two emergency accounts exist for when normal admin sign-in fails. They are excluded from automation and dormancy rules, use phishing-resistant sign-in stored separately, and **every sign-in raises an alert and an incident**. Each use is recorded against the named person who used it. *(Partial: accounts and exclusions in place; sign-in alert planned in M5.4, the lab's MFA setup is a documented deviation)*

## 8. Exceptions

8.1 An exception is any access that doesn't fit a role or a requested package rule, for example **Jamie Ivanova (Store Associate) holding Cash Office at Store-005, because Store-005 has no Store Manager**.
8.2 Every exception has: a named person, a business reason, an approver who owns the business risk (the role owner, not IAM), **an end date no more than 30 days away**, and an entry in the exception register.
8.3 At the end date the exception ends, unless the owner re-approves it with a new reason and a new end date (again at most 30 days). An exception that keeps renewing is a sign the role design or staffing needs fixing, and IAM raises it with the role owner.
8.4 Exceptions never cover shared accounts or SoD conflicts in PCI scope.

*(Partial: Jamie's access is approved with a reason and expires after 90 days; the 30-day exception end date and register are new with this policy, G6.)*

## 9. Individual accounts only

9.1 Every person uses their own account. **Logins are never shared**, including to cover a shift, open the cash office or reach a report. Every action must trace back to one person.
9.2 PCI DSS 8.2.2 allows shared or generic accounts only in exceptional cases with strict controls. Keystone is stricter: the only generic accounts are the two break-glass accounts (section 7.3).
9.3 Asking someone for their login, or giving yours, is a policy violation and is reported to the manager and IAM.

## 10. Monitoring and failures

10.1 Every lifecycle workflow run with a failed task raises an alert to the IAM queue, which is worked as an incident. *(Gap: no alert today; Finley's failed run went unnoticed for 9 days, G3)*
10.2 Until the alert exists, IAM checks workflow run history every business day and exports it weekly (the directory keeps only 7 days of run results).
10.3 Monthly, IAM compares access to HR (`-Verify` scripts and the governance notebook) and reports trends and anomalies to role owners (`reports/governance-trend-report.md`).

## 11. Enforcement and review

- Violations are handled by the employee's manager with HR. Access involved is suspended while it is investigated.
- This policy is reviewed every year, after an audit finding, or when a control it describes changes. The status labels are updated each time.

## 12. Control mapping

| Framework | Control | Sections |
|---|---|---|
| PCI DSS v4.0.1 | 7.1.1 / 8.1.1 policies documented, kept up to date, in use, known | Whole policy |
| PCI DSS v4.0.1 | 7.2.1–7.2.2 access by job classification, least privilege | 3 |
| PCI DSS v4.0.1 | 7.2.4 review user access at least every 6 months | 6 |
| PCI DSS v4.0.1 | 8.2.2 shared and generic accounts only by exception | 7.3, 9 |
| PCI DSS v4.0.1 | 8.2.5 terminated users' access revoked immediately | 4 |
| PCI DSS v4.0.1 | 8.2.6 inactive accounts removed or disabled within 90 days | 6 |
| PCI DSS v4.0.1 | 10.7.2 failures of critical security controls detected, alerted, addressed | 10 |
| NIST SP 800-53 | AC-1 policy; AC-2 account management; AC-5 separation of duties; AC-6 least privilege | 1–9 |
| CIS Controls v8 | 5.3 disable dormant accounts; 5.4 restrict admin privileges; 6.1 / 6.2 granting and revoking | 4, 6, 7 |

## 13. Gap register

| # | Gap | Policy section | Owner | Due |
|---|---|---|---|---|
| G1 | Review removals don't apply on their own | 6.2 | IAM engineering | 2026-11-25 |
| G2 | HR termination deadline not agreed; no immediate-disable runbook | 4 | HR + IAM | 2026-11-25 |
| G3 | No alert on failed workflow runs | 10.1 | IAM operations | 2026-11-25 |
| G4 | 15-day mover handover removal has never worked | 4 | IAM engineering | 2026-12-14 |
| G5 | Missing and wrong manager records | 2, 4 | HR | 2026-12-14 |
| G6 | Cash Office exception at Store-005; exception register and 30-day end dates | 8 | Director of Store Operations | 2026-12-14 |
| — | Break-glass sign-in alert | 7.3 | IAM | M5.4 |
| — | One-way SoD block | 5.3 | IAM + Director of Store Operations | 2026-12-14 |
