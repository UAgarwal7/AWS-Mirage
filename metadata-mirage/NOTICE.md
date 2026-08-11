# ⚠️ INTENTIONALLY VULNERABLE — READ BEFORE DEPLOYING

This repository stands up a **deliberately insecure** AWS environment for
security education and demonstration. It is designed to be attacked.

**It intentionally creates:**

- A public-facing web app with an unauthenticated **SSRF** endpoint that will
  fetch link-local metadata targets on an attacker's behalf.
- An EC2 instance with **IMDSv1 allowed** by default, so that SSRF can reach
  the instance metadata service.
- An instance role carrying a **privilege-escalation primitive**
  (`iam:CreatePolicyVersion` + `iam:SetDefaultPolicyVersion` on its own
  attached policy), which allows escalation to **full administrator**.

**Do not:**

- Deploy this in a shared, production, or otherwise real AWS account.
- Deploy it in an account that holds anything you care about.
- Leave it running. Run `make destroy` as soon as you are done.
- Expose it broadly — set `allowed_cidr` to your own `/32`, not `0.0.0.0/0`.

**Do:**

- Use a **fresh, isolated, throwaway account** dedicated to this lab.
- Tear down (`make destroy`) and verify the account is clean afterward.

You are responsible for anything you stand up with this code.
