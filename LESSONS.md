# Lessons — Keystone Entra Governance Program

Pacing: check in before each lesson, extra-detailed steps. Resume from the first unchecked item.

## Progress

### M0 — Pre-trial prep
- [x] M0.1 Repo and data foundation (2026-10-14 — verify passed: 1641 assignments, answer key ignored, no leaks)
- [x] M0.2 Lab email alias, ServiceNow PDI request, lab environment plan (tenant creation moved to M1.1 to protect the trial clock)

### M2 Part A — Role mining (pre-trial)
- [x] M2.1 Build the user × entitlement matrix
- [x] M2.2 Similarity clustering and candidate roles
- [x] M2.3a Test role catalog design against T0 access (coverage, SoD, answer key)
- [x] M2.3b Write docs/role-catalog.md for role owners

### M1 — Identity foundation & lifecycle management
- [x] M1.1 Activate Governance trial; load HR feed with Graph PowerShell (2026-10-21 — 276 users loaded + 220 manager links, rerun = 276 updated / 0 created; 56 manager data-quality issues logged for HR)
- [x] M1.2 Dynamic groups (attribute-based birthright) (2026-10-21 — 6 birthright groups generated from the role catalog, all match HR (276/158/17/36/17/34); portal-built Store-007 location group (7); mover test E00004 Store Ops→Fuel Ops moved BR-02→BR-03 with no manual step, then reverted)
- [ ] M1.3 Lifecycle Workflows: joiner, mover, leaver
- [ ] M1.4 Snapshot T0 + integration analysis memo (StoreOps Portal)

### M2 Part B — Access packages
- [ ] M2.4 Catalog, birthright auto-assignment packages
- [ ] M2.5 Requested packages, approvals, expiry, incompatible packages

### M3 — Certifications
- [ ] M3.1 PCI access package review (recommendations, auto-apply)
- [ ] M3.2 Multi-stage privileged role review + inactive-users-only review
- [ ] M3.3 Certifier support desk + certification report

### M4 — Trend reporting
- [ ] M4.1 Snapshot T1 export
- [ ] M4.2 KPI and anomaly notebook
- [ ] M4.3 Governance trend report + escalation table

### M5 — Policy, SOPs, ServiceNow, on-call
- [ ] M5.1 IAM Access Control Policy + request workflow
- [ ] M5.2 SOPs + end-user guide
- [ ] M5.3 ServiceNow catalog item + 6 incidents
- [ ] M5.4 Triage runbook + escalation matrix

### M6 — Privileged access (optional stretch)
- [ ] M6.1 PIM just-in-time activation
- [ ] M6.2 Break-glass accounts + alert

## Things that broke

| Date | Lesson | What broke | Root cause | Fix | Interview story? |
|---|---|---|---|---|---|
| 2026-10-14 | M0.1 | Generator run failed: "No such file or directory" | Script was still in Downloads, not in `scripts\`; Python resolves paths relative to the current folder | Moved file with `Move-Item`, confirmed with `Get-ChildItem -Recurse`, reran | Minor — shows checking the working directory before debugging the tool |

| 2026-10-14 | M2.1 | gitleaks reported 30 leaks incl. a private key | `gitleaks dir` scans all files and ignores .gitignore; findings were in .venv (third-party packages + Tornado's public test key) | Triaged: all in ignored folder, none staged → false positives. Switched to scanning only what Git tracks | Yes — triaging scanner findings |

| 2026-10-20 | M1.1 | Break-glass #1 created as bg-emergency@ instead of bg-emergency01@ | Typo during manual creation; naming standard not checked | Renamed UPN in Entra, updated password manager | Yes: naming standards matter because scripts, alerts and evidence key on the name. Manual creation is error-prone, which is why the 276 users get loaded by script |
| 2026-10-20 | M1.1 | Business Premium trial gave 1 seat, not the 25 that guides describe | Microsoft changed the trial offer ("with Copilot", 1 license) | Moved the seat from owner to iam.admin; P1 still unlocks tenant-wide | Yes: always verify vendor terms on the live screen, not blog posts |

| 2026-10-21 | M1.1 | Get-InstalledModule found no Microsoft.Graph modules | Terminal was Windows PowerShell 5.1 with the built-in PowerShellGet 1.0.0.1, which fails to install from PSGallery; modules are per PowerShell version | Installed PowerShell 7, set it as VS Code's default terminal, reinstalled modules | Yes: read the file path in an error. It told me which PowerShell was running before I touched the code |

| 2026-10-21 | M1.2 | -Verify reported "All groups match HR" after checking 0 groups | HR file path passed without -HrFile bound positionally to -CatalogFile; script treated "nothing checked" as a pass | Script now requires named parameters and fails on 0 roles/0 employees; deleted the empty evidence file | Yes: a control that passes on empty input is worse than none. Always check the count of what was checked, not just the result |

## Concept notes (from check questions)

- **M0.1:** A leaver with an enabled account is a *true positive* ("terminated user with active access"), not a false positive. Deleting a committed secret does not remove it from Git history: rotate the secret first, then purge history. Seeds make the T0→T1 comparison reproducible.

- **M2.1:** Roles are templates copied to every future holder — mining from orphan/leaver access bakes errors in. High prevalence ≠ appropriate (sensitive/PCI access stays a requested, approved, reviewed role). Sparse matrix ≠ least privilege, but it means a few roles can cover many people. Department is too coarse: Store Ops = 3 jobs with different POS access.

- **M2.2:** Jaccard = shared ÷ total access. Threshold 0.4 = bend in the coverage curve; looser merges creator/approver jobs and hides outliers. Mined roles copy today's mistakes → SoD-check every role (CR-03 HR had edit+approve). Fix variation with layering (base role + add-on), not more roles. IAM recommends, business role owner decides. Rank risk by attacker impact: Server-Admin on a store manager > POS-Cashier.

- **M2.3a:** Catalog = 6 birthright + 15 business + 5 add-on. Automatic when HR title proves need + low impact (Refunds); Requested when per-person justification is required (PCI CDE, privileged). Today's 100% ≠ need. Roles shrink decisions (1472→242), they don't remove review — auto-assignment is only as good as HR data. Store tools outside Store Ops = mover gap → fix in M1.3 mover workflow. Answer-key score is partly circular → say "synthetic dataset, seeded answer key."

- **M2.3b:** Urgency = impact × exposure, not effort (Server-Admin on a store account = immediate even for 1 person). Findings format: found / why / action (end with fixing the cause) / named decision owner / due + reason / control. Default-to-remove when managers don't answer. Saying "no" isn't enough — offer a safe alternative (time-limited add-on without the conflicting entitlement).

- **M1.1:** Tenant ≠ subscription ≠ license. Governance depends on P1: if the prerequisite lapses, governance stops even with trial days left, so track the earliest end date in the chain. Break-glass is for identity emergencies (MFA outage, bad CA policy, sole admin gone), not business emergencies. It's safe because of its controls: two accounts, sealed credentials, an alert on any sign-in, tested every 90 days.

- **M1.1 (dates):** Graph stores employeeHireDate in UTC; the portal shows local time, so a 2019-06-13 hire displays as 6/12/2019 8:00 PM Eastern. Same moment. Lifecycle Workflows evaluate in UTC, so check this in M1.3.

- **M1.1 (HR load):** Match on employeeId, not UPN. A name change on UPN matching creates a duplicate + orphan. IAM never guesses or fixes HR data in Entra (the next load overwrites it); log it and send it to HR as one data-quality report. 56/276 (20%) have no valid manager, so their manager-based reviews would go nowhere. 29 Store Managers report to Shift Leads (synthetic data, treated as an HR DQ finding → M4 metric).

- **M1.2:** Dynamic group = ABAC rule assigning an RBAC role. The guard (employeeId ≠ null, enabled) keeps the 4 admin/break-glass accounts out and drops leavers. Mover test moved birthright only: job-title access (POS-Cashier) and direct grants (item 6.3, 24/107) don't move → M1.3 + M2. PCI is never birthright (PCI DSS req 7: approved by need). employeeType isn't rule-supported → copy to extensionAttribute1 from HR (28 contractors). A check that passes on 0 items isn't a check.