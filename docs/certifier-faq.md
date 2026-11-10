# Certifier FAQ — Keystone Fuel & Market Access Reviews

*Module M3 · For store managers, the PCI owner and the IT Director · Last updated 2026-11-09*

You've been asked to confirm who should keep access. Each review is small: a handful of people. Decide each one on the job they do **now**, and write the reason in one line.

**Where:** https://myaccess.microsoft.com → Access reviews. **Help:** the IAM desk (questions in `evidence/M3/certifier-support-log.csv`).

## Deciding

**The review recommends "Deny" for everyone. Should I follow it?**
No. The recommendation is based on Entra sign-ins in the last 30 days. Store staff use the POS, not Entra, so it says Deny for almost everyone. Decide on the job: does this person do the work this access is for, today?

**What do I write as the reason?**
What the person does that needs it, and where: "Store Manager, reconciles Store-020 deposits". For a deny: why it's no longer needed: "Cover ended 2026-11-06".

**I don't recognise this access, or this person.**
Don't approve it. Leave it or deny it and call the IAM desk. For Cash Office and Admin, silence means removal; that's on purpose.

**I got a review for someone I don't manage.**
Your name is on their HR record as manager. Don't approve; tell the IAM desk, and we ask HR to fix the record. In two-stage reviews, the second reviewer decides.

**I made the wrong decision. Can I change it?**
Yes, while the review is open: open it again and change the decision and reason. After it closes, ask the IAM desk to remove the access and we record your reason.

## After a decision

**I denied someone. When does their access end?**
When the review closes. IAM then checks that the access is actually gone, person by person, and removes anything left by hand the same day. If you still see it working after that, tell the IAM desk at once.

**Someone lost access they still need.**
They request it again at myaccess with the new reason and an end date. Cash Office goes to their manager, then the PCI owner. IAM can't re-grant it by hand, and nobody shares an account.

## The dormant-account review (R3)

**Someone on leave shows as inactive. Will they lose access if I ignore it?**
No. This review never removes anyone automatically. Approve with "On leave until <date>" so IAM doesn't follow it up.

**Emergency Access 01 and 02 show as inactive. Remove them?**
No. They're break-glass accounts, unused by design, for when normal admin sign-in fails. Approve with "Break-glass: excluded from dormancy rule".

## What you're not asked to review

Store Manager, Shift Lead, Fuel Technician and other title-based access comes from HR job titles, automatically. If someone's title is wrong, that's an HR fix: the access follows the title within the hour. The Director of Store Operations attests those rules twice a year.
