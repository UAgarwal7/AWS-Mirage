# Claude Code — reconcile README + WRITEUP with the recorded demo

## Context
The recorded demo (`mirage-demo.cast`) shows the instance role being **denied**
when it tries to read its own policy — `iam:ListAttachedRolePolicies` and
`iam:GetPolicy` both return `AccessDenied` — and then escalating **blind** via
`iam:CreatePolicyVersion`, which needs no read. The docs currently describe the
opposite (enumerating / reading the policy to reveal the grant). Fix the docs to
match the demo.

## Scope — docs only
- Edit ONLY `README.md` and `WRITEUP.md`.
- Do NOT change any `.tf` file, the attack script, or the IAM policy. Do NOT add
  any read/list permission to the role. The role's inability to read itself is
  correct and intentional — do not "fix" it.

## The reframing to apply
The role is so tightly scoped it cannot even enumerate its own permissions — yet
one write permission it does hold (`CreatePolicyVersion` on its own attached
policy) escalates it to administrator. Writing a new policy version does not
require reading the existing one, so the escalation happens **blind**. This is a
*stronger* least-privilege lesson than "read the policy to find the grant," so
lean into it — do not frame it as a limitation.

## README.md
In the "attack chain" list, step 4 currently says to list the role's attached
policies and read the default version to reveal the grant. Replace it with a
step reflecting reality: the role attempts to enumerate its own policies and is
**denied**, which does not matter because the next step (writing a new policy
version) needs no read. Keep the step numbering intact.

## WRITEUP.md
Section 4 ("Enumeration: the role that looks scoped") is written for the
read-the-policy path. Rewrite it around blind escalation: acting as the role,
the attacker tries to read the attached policy and is denied on `GetPolicy` /
`ListAttachedRolePolicies`; this is not a blocker, because `CreatePolicyVersion`
overwrites the policy without reading it. Add one sentence making the
least-privilege point explicit — a role that cannot even read its own
permissions is still one write away from admin. Leave sections 5–7 unchanged
(the privesc mechanism, the IMDSv2 fix, and the broken-access-control tie are
all still accurate).

## After editing
Re-read both files end to end and confirm no remaining sentence claims the role
successfully reads, enumerates, or inspects its own policy. Commit with a
message like: `docs: match blind-privesc reality of the recorded demo`.