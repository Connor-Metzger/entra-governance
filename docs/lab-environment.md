# Lab Environment — Keystone Fuel & Market (fictional)

> Build sheet for the Microsoft Entra lab tenant used in this project.
> All identities are synthetic. This is a personal lab tenant, not a production environment.
> Never write passwords, tenant IDs, or recovery codes in this file.

---

## 1. Tenant

| Item | Value |
|---|---|
| Fictional organization | Keystone Fuel & Market |
| Initial domain | keystonefuellab |
| Backup domain choice (if taken) | kfmgovlab |
| Contact email for trials and billing | Personal lab Gmail (never shown in screenshots) |
| Creation route | Decided in M1.1 after checking current Microsoft trial offers |
| Created on | <!-- FILL in M1.1 --> |

**Why the name matters:** the initial `.onmicrosoft.com` domain appears in every UPN, screenshot, and export, and it can't easily be changed later. A company-style name keeps the portfolio looking like a real organization and keeps your personal name out of evidence. It must never imitate a real company, including the employer you are applying to.

---

## 2. Account plan

| Account | Purpose | Role | MFA method | Used for |
|---|---|---|---|---|
| Setup account (created at sign-up) | Tenant owner | Global Administrator | Microsoft Authenticator | Licensing and trials only |
| `iam.admin@<domain>` | Day-to-day lab administration | Global Administrator during the build (see deviation below) | Microsoft Authenticator | All build work in M1–M5 |
| `bg-emergency01@<domain>` | Break-glass #1 | Global Administrator, **permanent active** | Passkey (phishing-resistant) | Emergencies only |
| `bg-emergency02@<domain>` | Break-glass #2 | Global Administrator, **permanent active** | Passkey, stored separately from #1 | Emergencies only |
| 300 synthetic users | Store and corporate employees from the HR feed | None (standard users) | n/a | Lifecycle, roles, reviews |
| 3–5 synthetic reviewer users | Managers and app owners who act as certifiers | None | n/a | M3 access reviews |

**Known deviation from least privilege:** in production, daily admins would hold narrower roles (for example, Identity Governance Administrator, User Administrator, Lifecycle Workflows Administrator) and activate Global Administrator just-in-time through PIM. In this lab, `iam.admin` keeps Global Administrator during the build to avoid permission dead-ends. Real daily admin rules would include System Administrator, Identity Administrator, or Active Directory Engineer

---

## 3. Break-glass (emergency access) design

**What they are:** two cloud-only accounts that can still sign in when everything else fails. Examples include an MFA service outage, a misconfigured Conditional Access policy that locks out every admin, or the only admin leaving the company.

| Control | Design | Why |
|---|---|---|
| Count | Two accounts | If one credential is lost or fails, the other still works |
| Domain | `.onmicrosoft.com`, cloud-only | Works even if a custom domain or on-premises sync breaks |
| Role | Global Administrator, permanent active (not PIM-eligible) | PIM activation could itself depend on the system that is broken |
| MFA | Phishing-resistant passkey, a different method from daily admins | Still satisfies Microsoft's mandatory admin MFA, without depending on a phone |
| Conditional Access | Members of group `EmergencyAccess`, excluded from blocking policies | A bad policy can't lock out the accounts meant to fix it |
| Ownership | Not tied to one person's phone or personal details | Usable by any authorized admin in an emergency |
| Storage | lab = password manager entries kept separate from each other; production = credentials and keys in separate fireproof safes | |
| Monitoring | Alert on **any** sign-in by either account | Every use must be a drill or a real emergency, never routine |
| Monitoring in this lab | Weekly manual review of sign-in logs for both acounts; automated Log Analytics alert planned as a stretch goal (Requires Azure Subscription) | |
| Testing | Sign in with each account at least every 90 days and after admin changes | Proves the accounts still work before you need them |

If a 24/7 retailer experiences a complete administrative lockout at 2:00 AM on a Saturday with zero break-glass accounts, operational chaos will instantly ripple across both physical stores and digital platforms.

---

## 4. Licenses and trials log

| Product | Start | End | Reminder set? | Notes |
|---|---|---|---|---|
| Prerequisite license (Entra ID P1 or bundle that includes it) | | | | Decided in M1.1 |
| Microsoft Entra ID Governance trial | | | | Needs tenant with prerequisite; one trial per tenant |
| ServiceNow PDI | 2026-10-14 | n/a | Weekly login | Release: Australia. Reclaim-eligible after 90 days + 10 days without login |

**Rule:** export all evidence (screenshots, CSV exports, workflow configs) at least one week before any trial end date.

---

## 5. Sanitizing rules for this tenant

Before any screenshot or export goes into `evidence/`:

- [ ] Tenant ID blurred or cropped
- [ ] Contact email and profile pictures blurred
- [ ] Break-glass account names are OK to show; their credentials and passkey details are not
- [ ] No IP addresses from sign-in logs
- [ ] `gitleaks dir . -v` returns no leaks

---

## 6. Framework mapping

| Control | How this design addresses it |
|---|---|
| NIST SP 800-53 AC-2 (Account Management) | Every account type has a defined purpose, role, and owner |
| NIST SP 800-53 AC-6(5) (Privileged Accounts) | Privileged accounts are separate from standard users and limited in number |
| PCI DSS v4.0 8.4.1 (MFA for admin access into the CDE) | All admin accounts, including break-glass, use MFA |
| CIS Controls v8 5.4 (Restrict admin privileges to dedicated admin accounts) | Admin work happens only in dedicated admin accounts |
