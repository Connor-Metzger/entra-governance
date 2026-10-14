# Keystone Fuel \& Market — Identity Lifecycle \& Role Governance Program

### Built in Microsoft Entra ID Governance · Portfolio project #3

> \*\*Target role:\*\* IAM Governance \& Compliance Analyst — Sheetz (24/7 convenience + fuel retail, PCI-DSS)
> \*\*Role type:\*\* Primary = Governance / IGA analyst · Secondary = IAM operations / support (on-call duty)
> \*\*Plan created:\*\* 2026-10-14 · \*\*Target:\*\* apply by 2026-12-01 · \*\*Status:\*\* Kickoff complete — next: Lesson M0.1

\---

## 1\. Why this project (and why it doesn't overlap)

This is "Phase 2" of the same fictional company used in `access-risk-analyzer`. Keystone's IAM team proved its risk with spreadsheets and Python; now leadership has bought Entra ID Governance and asked the team to **move the program onto a real IGA platform**: automate joiner/mover/leaver, mine roles from the messy access data, run certifications natively, report trends, and write the policies and on-call runbooks that make it operable 24/7.

One company across projects = one coherent interview story: *"I found the problems (project 1), then I built the platform controls that stop them recurring (project 3)."*

|Capability|IAM-Access-Review-Governance-Lab|access-risk-analyzer|**This project**|
|-|-|-|-|
|Platform|Excel / Word|Python, Jira|**Microsoft Entra ID Governance**, Graph PowerShell, ServiceNow|
|Scale|10 users, 7 apps|200 HR / 206 accounts|300 HR identities, \~1,600 assignments, loaded into a real tenant|
|Access certification|Manual spreadsheet review|Scripted manager packets + rubber-stamp metrics|**Native Entra Access Reviews**: recommendations, auto-apply, multi-stage, privileged-role review — plus certifier help-desk role|
|Roles|10 hand-written roles|—|**Data-driven role mining** (similarity clustering) → **access packages** with birthright auto-assignment|
|Lifecycle (JML)|—|Detects leavers *after the fact*|**Lifecycle Workflows** that prevent the gap (joiner / mover / leaver)|
|Analytics|Risk summary sheet|Point-in-time findings, 5 types|**Trend \& KPI reporting across two snapshots** from live platform exports|
|Integration analysis|—|—|**App-onboarding analysis memo** for senior engineers|
|Policy|—|—|**IAM Access Control Policy** + request workflow|
|SOPs / training|Access-review SOP|Manager job aid|Leaver SOP, app-onboarding SOP, **end-user "My Access" guide**|
|Ticketing / on-call|—|Jira remediation tickets|**ServiceNow** catalog item + **6 worked after-hours incidents**, runbook, escalation matrix|

**Rule for this project:** don't rebuild finding detection or packet generation — reuse `access-risk-analyzer` outputs as the "before" picture and link to it.

\---

## 2\. JD mapping table

|#|JD line (short)|Req / Pref|Core concept an interviewer will probe|Lab evidence|Module|
|-|-|-|-|-|-|
|1|Generate and perform routine access certifications; maintain certification processes and flows|Duty|Review scoping, reviewer selection, decision helpers, auto-apply vs manual remediation, certifier fatigue, privileged reviews|3 configured Entra access reviews + results exports + campaign design doc|M3|
|1b|Initial technical resource to certifiers; escalate as needed|Duty|Tier-1 certifier support, escalation boundaries|Certifier FAQ + support log (8 questions, 2 escalated)|M3|
|2|Analyze user/access data; trends, risks, anomalies; reports; escalate|Duty|Trend vs snapshot, KPI design, drift (access outside roles), failed deprovisioning|`reports/governance-trend-report.md` with T0→T1 metrics + escalation table|M4|
|3|Role management: role mining, role definitions, access control structure optimization|Duty|Birthright vs requested, Jaccard similarity, role coverage, role explosion, entitlement reduction|`notebooks/role\_mining.ipynb`, role catalog, access packages, before/after metrics|M2|
|4|Collaborate with stakeholders; analyze IAM integrations; give seniors supporting artifacts|Duty|Authoritative source, attribute mapping, provisioning method, app owner responsibilities|`docs/integration-analysis-storeops.md`|M1|
|5|Document and refine IAM policies and workflows|Duty|Least privilege, review cadence, SoD, exceptions, emergency access|`docs/policy/iam-access-control-policy.md` + Mermaid request workflow|M5|
|6|SOPs, workflows, diagrams, end-user training, job aids|Duty|Writing for non-technical readers|2 SOPs, end-user guide, JML diagram|M1, M5|
|7|IAM implementation / deployment / documentation projects|Duty|App onboarding into governance, phased rollout|App onboarded into a governed access package, runbook|M1, M2|
|8|Evening/weekend on-call support (24/7/365)|Duty|Triage, severity, SLA, after-hours escalation, compromised-account response|ServiceNow ticket export (6 incidents), triage runbook, escalation matrix|M5|
|Q1|1 yr IAM + exposure to IAM governance platforms (SailPoint, Saviynt, Okta, **Entra**…)|**Required**|—|Entra ID Governance used throughout; README "SailPoint translation" table|All|
|Q2|Least privilege, access control models, lifecycle management|**Required**|RBAC vs ABAC (dynamic groups), JML|M1 lifecycle workflows + M2 RBAC|M1, M2|
|Q3|ServiceNow / Jira|Pref|—|ServiceNow PDI (Jira already shown in project 1)|M5|
|Q4|NIST, ISO, CIS, PCI-DSS|Pref|Control mapping|Framework table in every module README|All|
|Q5|IAM / governance certification|Pref|—|Security+ (in progress) — see §7|—|

**Out of scope (with reason):** none — every duty is covered.

**Platforms the lab can't cover:** SailPoint, Saviynt, ForgeRock, Ping. Interview prep will include a "how this maps" table (e.g., Entra access package ≈ SailPoint access profile/role; Lifecycle Workflows ≈ SailPoint lifecycle events; access review ≈ certification campaign).

### ATS keywords (use exactly as written in README, resume, LinkedIn)

access certifications · certification processes · role management · role mining · role definitions · access control structure optimization · user and access data · trends, risks, and anomalies · generate reports · IAM policies and standards · least privilege · access control models · lifecycle management · IAM governance · IAM integrations · standard operating procedures (SOPs) · workflows · diagrams · end-user training materials · job aids · Entra · ServiceNow · Jira · NIST · PCI-DSS · CIS · on call

\---

## 3\. Capstone scenario

**Keystone Fuel \& Market** — fictional 24/7 convenience and fuel chain, central PA.

* **300 HR identities** (store associates, store managers, fuel ops, distribution, corporate finance, HR, IT) across stores + corporate
* High turnover, part-time staff, frequent store-to-store moves → JML is the core pain
* **PCI-DSS scope:** POS admin, cash office, payment back-office entitlements
* **The ask from the CISO:** "Our last review found terminated users still active and managers rubber-stamping. Use Entra ID Governance to fix the process, not just the symptoms — and make it supportable at 2 a.m."

**Data:** generated with the skill's generator (seeded, repeatable):

```bash
python scripts/generate\_identities.py --users 300 --out data/t0 --seed 2026 --as-of 2026-10-14 --movers-pct 0.1 --excess-pct 0.08
```

Test run produced: 316 directory accounts, 1,641 entitlement assignments, 27 movers with residual access, 24 SoD conflicts, 27 dormant, 12 orphaned, 8 leavers still active. `ground\_truth.json` stays out of view until analysis is done.

\---

## 4\. Modules

Total estimate: **\~42 hours**. Trial-aware order: the Governance trial clock only starts at M1, so the Python mining and documentation drafts happen before it.

### M0. Pre-trial prep (≈4 h) — no license needed

* Create repo, `.gitignore`, `.env.example`, folder layout
* Generate `data/t0`; draft role-mining notebook against the CSVs (M2 part A)
* Create lab tenant + break-glass account; ServiceNow PDI requested

### M1. Identity foundation \& lifecycle management (≈9 h) — JD 4, 6, 7, Q2

**Build**

* Bulk-load the HR feed into Entra with Microsoft Graph PowerShell (script, not clicks); employee attributes (`department`, `employeeHireDate`, `employeeLeaveDateTime`, `employeeId`) set from HR
* Dynamic groups by department/location (attribute-based birthright — compare RBAC vs ABAC)
* **Lifecycle Workflows:** Joiner (pre-hire: generate Temporary Access Pass, notify manager), Mover (department change → remove old dept access, notify), Leaver (on last day: disable account, remove from all groups/access packages, revoke sessions; +7 days delete)
* Onboard one fictional app ("StoreOps Portal", enterprise app with app roles) into governance

**Deliverables**

* `scripts/load\_users.ps1`, `scripts/export\_snapshot.ps1`
* `docs/jml-process.md` (Mermaid diagram) + 3 scenario write-ups with before/after screenshots
* `docs/integration-analysis-storeops.md` — authoritative source, attribute mapping, provisioning method, app roles, owner, PCI scope, review cadence, open risks. Written as a memo to a senior engineer.

### M2. Role mining \& role catalog → access packages (≈11 h) — JD 3, 7, Q2

**Build**

* **Part A (pre-trial, Python):** user × entitlement binary matrix → Jaccard similarity clustering → candidate roles; separate birthright (≥90% of a department) from requested; measure role coverage and leftover direct assignments
* **Part B (Entra):** create catalog "Store Operations"; implement top roles as access packages:

  * Birthright packages with **auto-assignment policies** (by department attribute)
  * Requested packages (e.g., "Cash Office – PCI") with manager approval, business justification, 180-day expiry
  * Incompatible-package setting for 1–2 SoD pairs
* Re-export and compare

**Deliverables**

* `notebooks/role\_mining.ipynb` (renders on GitHub)
* `docs/role-catalog.md` — role name, owner, entitlements, assignment rule, PCI flag
* Before/after: direct assignments, # distinct entitlement combos, % users fully covered by roles, entitlement reduction %

### M3. Certification program in Entra Access Reviews (≈7 h) — JD 1, 1b

**Build** three reviews, each solving a different problem:

1. **Quarterly PCI access package review** — manager reviewers, *inactive-user recommendations* on, justification required, **auto-apply** denials
2. **Multi-stage privileged role review** (PIM-eligible admin roles) — stage 1 resource owner, stage 2 IAM team
3. **Inactive-users-only review** of vendor/guest accounts (Governance-only feature — show why scoping reduces certifier fatigue)
* Act as reviewers (lab test users), make decisions, confirm auto-apply removed access
* Run a **certifier support desk**: log 8 realistic certifier questions ("I don't recognize this access", "my employee moved stores", "the review says the person is inactive but they're on leave"), answer 6, escalate 2 with reasons

**Deliverables**

* `docs/certification-campaign-design.md` (scope, cadence, reviewers, fallback reviewers, escalation path)
* `reports/q4-certification-report.md` (skill template) — completion %, deny rate, items auto-removed
* `docs/certifier-faq.md` + `evidence/M3/certifier-support-log.csv`
* README section: **"Scripted vs native certifications"** — what project 1 did in Python vs what Entra does, trade-offs

### M4. Governance trend \& anomaly reporting (≈7 h) — JD 2

**Build**

* `scripts/export\_snapshot.ps1` pulls users (with `signInActivity`), group/access package assignments, access review decisions, and Lifecycle Workflow run history via Graph
* Snapshot **T0** (after M1 load, before roles) and **T1** (after M2–M3)
* Python report of KPIs and anomalies:

  * % of access granted through roles vs direct assignment
  * Dormant accounts T0 → T1; mover residual access T0 → T1
  * Leaver time-to-disable (target: same day, PCI 8.2.5); failed workflow runs
  * **Drift:** assignments made outside access packages after T1
  * Review completion rate, deny rate, overdue reviewers

**Deliverables**

* `notebooks/governance\_trends.ipynb`, charts in `reports/img/`
* `reports/governance-trend-report.md` — one-page executive summary, KPI table, escalation table (finding → owner → severity → due date)

### M5. Policy, SOPs, ServiceNow \& on-call (≈10 h) — JD 5, 6, 8, Q3

**Build**

* **ServiceNow PDI:** access request catalog item; 6 incidents worked end-to-end with work notes, priority, SLA:

  1. 2:10 a.m. Saturday — store manager locked out, store can't open the cash office
  2. Suspected compromised associate account (impossible travel) → revoke sessions, reset, escalate to SecOps
  3. Leaver workflow failed — terminated cashier still enabled
  4. Certifier can't see assigned review before deadline
  5. Sunday request: new store opening needs 12 associates provisioned by Monday 5 a.m.
  6. Break-glass account sign-in alert
* Docs (written for non-technical readers):

  * `docs/policy/iam-access-control-policy.md` — least privilege, RBAC, review cadence, SoD, exceptions, emergency access
  * `docs/workflows/access-request.md` — Mermaid request/approval flow
  * `docs/sop/sop-process-leaver.md`, `docs/sop/sop-onboard-app-to-governance.md` (skill SOP template)
  * `docs/training/how-to-request-access-myaccess.md` — end-user guide with screenshots
  * `docs/oncall/triage-runbook.md` + `escalation-matrix.md`

**Deliverables:** ServiceNow export in `evidence/M5/`, all docs above

\---

## 5\. Framework mapping (cite in every module README)

|Control|What the lab demonstrates|Module|
|-|-|-|
|PCI DSS 8.2.4 / NIST AC-2 / ISO 5.16|Accounts created/modified/removed from HR events|M1|
|PCI DSS 8.2.5 / NIST AC-2(3) / CIS 6.2|Leaver workflow disables same day; measured in M4|M1, M4|
|PCI DSS 8.2.6 / CIS 5.3|Inactive-user recommendations + dormant trend|M3, M4|
|PCI DSS 7.2.4 / NIST AC-2(j), AC-6(7)|Recurring access reviews incl. privileged roles|M3|
|PCI DSS 7.2.1–7.2.3 / NIST AC-6 / CIS 6.8|Role catalog and access packages (least privilege)|M2|
|NIST AC-5 / ISO 5.3|Incompatible access packages for SoD pairs|M2|
|NIST AC-6(5) / PCI 8.4.1|Privileged role review, PIM-eligible roles|M3|
|NIST AU-6 / PCI 10.2|Audit + workflow history reporting|M4|
|NIST AC-1 / PCI 7.1.1, 8.1.1|Policy and SOPs documented|M5|

Confirm control wording against current official versions before publishing.

\---

## 6\. Stack (checked 2026-10-14)

|Layer|Choice|Notes|
|-|-|-|
|IGA platform|Microsoft Entra ID + **ID Governance trial**|Lifecycle Workflows, auto-assignment policies, inactive-only reviews need ID Governance — P2 alone isn't enough. Trial requires a tenant that already has a prerequisite license (e.g., Entra ID P1) and has never trialed Governance; length is shown at activation — **record the end date below**.|
|Fallback if trials won't activate|midPoint (open-source IGA) in Docker|Real roles + certifications; resume still names an IGA platform|
|Automation|Microsoft Graph PowerShell SDK|Scripted so the lab can be rebuilt after the trial|
|Analytics|Python 3.11, pandas, Jupyter, matplotlib|Reuse your venv habits from project 1|
|Ticketing|ServiceNow PDI|PDIs can be reclaimed if ≥90 days old with no direct instance login in 10 days — log in weekly and export tickets as you go|
|Diagrams|Mermaid|Renders on GitHub|
|Secret scanning|gitleaks + bandit|You already use bandit — keep it|

Known gotchas: Microsoft 365 Developer Program sandboxes are frequently unavailable to new members, and Entra trial activation on Azure free subscriptions is a common forum complaint — budget an hour for tenant setup and use the midPoint fallback rather than losing a week.

**Trial dates:** Governance trial start \_\_\_\_ · end \_\_\_\_ · PDI created 10-14-26

\---

## 7\. Kickoff answers (fill in / confirm)

Recorded 2026-10-14.

|Question|Answer|
|-|-|
|Starting level|Some IAM (2 portfolio projects, A.S. Cybersecurity, Network+, studying Security+)|
|Hours per week|\~15 on average (about 2 h per workday; varies with 3–5 workday weeks)|
|Target application date|**December 1, 2026** (\~7 weeks, \~100 h available vs \~42 h planned → \~40% buffer)|
|Budget|Under $50, held in reserve: only spend if a free trial won't activate (e.g., one month of a P1 prerequisite license for the admin account). Verify prices before buying.|
|Platform priority|Entra ID Governance (fallback: midPoint)|
|Ticketing tool|ServiceNow PDI (Jira already shown in project 1)|
|Certification goal|Security+ first; SC-300 later (exam fee exceeds this budget)|
|Pacing|**Check in before each lesson** — preview the lesson, learner confirms, then build|

**Schedule (Oct 14 → Dec 1, \~15 h/week)**

|Week|Dates|Work|
|-|-|-|
|1|Oct 14–20|M0 prep + M2 Part A (Python role mining). Request ServiceNow PDI.|
|2|Oct 21–27|Activate Governance trial (record end date) · M1 lifecycle + snapshot T0|
|3|Oct 28–Nov 3|M2 Part B (access packages) · M3 certifications|
|4|Nov 4–10|Snapshot T1 · M4 trend report · **export all evidence before trial ends**|
|5|Nov 11–17|M5 policy, SOPs, ServiceNow, on-call|
|6|Nov 18–24|Optional stretch M6 (below) · README polish · resume + LinkedIn|
|7|Nov 25–Dec 1|Full interview prep + mock interview · buffer for slipped weeks (Thanksgiving) · apply|

**Optional stretch M6 — Privileged access (≈6 h):** PIM just-in-time activation with approval for Entra admin roles, two break-glass accounts with a sign-in alert, and a privileged-access review. Not a listed duty, but it deepens M3's privileged review and M5's break-glass incident. Do it only if weeks 1–5 land on time.

\---

## 8\. Repo layout

```
keystone-entra-governance/
├── PROJECT.md            ← this file
├── LESSONS.md            ← lesson checklist + "Things that broke"
├── README.md             ← recruiter-readable, updated after every module
├── data/t0, data/t1      ← synthetic only
├── scripts/              ← generate\_identities.py, load\_users.ps1, export\_snapshot.ps1
├── notebooks/            ← role\_mining.ipynb, governance\_trends.ipynb
├── reports/              ← certification report, trend report, img/
├── docs/
│   ├── jml-process.md, integration-analysis-storeops.md, role-catalog.md
│   ├── certification-campaign-design.md, certifier-faq.md
│   ├── policy/, workflows/, sop/, training/, oncall/
└── evidence/M1 … M5/     ← sanitized screenshots and exports
```

\---

## 9\. Progress

* \[x] Phase 0 — kickoff answers recorded (2026-10-14)
* \[ ] Phase 1 — scope locked (M1–M5 core, M6 optional)
* \[ ] M0 prep
* \[ ] M1 build · learn · publish
* \[ ] M2 build · learn · publish
* \[ ] M3 build · learn · publish
* \[ ] M4 build · learn · publish
* \[ ] M5 build · learn · publish
* \[ ] Phase 5 — full interview prep + mock interview

