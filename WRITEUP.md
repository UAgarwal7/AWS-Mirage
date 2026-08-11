# Metadata Mirage — SSRF to AWS Administrator, and the One Flag That Stops It

> Draft to reconcile against your existing ~80%. Structured on the IMDSv2
> before/after; the privesc-to-admin section (5) and the root-cause section (7)
> are the parts that were missing. Merge, don't wholesale-replace — keep your
> own gotchas.

## 1. Summary

A single unauthenticated SSRF in a link-preview endpoint escalates, with no
further vulnerabilities, to full AWS administrator. The path is entirely
misconfiguration: a server-side fetch with no allow-list, an instance that
still accepts IMDSv1, and an instance role that looks scoped but carries one
catastrophic IAM permission. The entire chain is defeated by enforcing IMDSv2 —
a single instance-metadata flag — which is the point of the lab: the fix is
smaller than the bug.

## 2. The environment

Everything is Terraform (`make deploy`). A `t3.micro` runs a Flask app whose
`/fetch?url=` endpoint issues a server-side `GET` to any URL it is handed, with
no filtering. The instance profile carries a customer-managed policy that reads,
on paper, like an ordinary app role: `s3:ListAllMyBuckets`, `s3:GetObject`,
`cloudwatch:PutMetricData` — plus `iam:CreatePolicyVersion` and
`iam:SetDefaultPolicyVersion` scoped to that same policy. IMDSv1 is allowed by
default (`http_tokens = optional`).

## 3. SSRF to instance credentials

The metadata service lives at the link-local address `169.254.169.254`. Because
the app fetches attacker-controlled URLs server-side, pointing it at
`/latest/meta-data/iam/security-credentials/` returns the role name, and one
path deeper returns the role's temporary credentials. IMDSv1 asks for nothing
in return — a bare `GET` is enough — so a basic SSRF is sufficient. Exporting
those three values and calling `sts get-caller-identity` confirms the pivot:
requests now run as the instance role.

## 4. Blind escalation: the role that cannot even read itself

Acting as the instance role, the natural next move is to read the attached
policy and see what it grants. That fails: both `iam:ListAttachedRolePolicies`
and `iam:GetPolicy` return `AccessDenied`. The role is scoped so tightly it
cannot even enumerate its own permissions. This is not a blocker. Writing a new
policy version does not require reading the existing one, so the escalation goes
ahead blind — the attacker overwrites a policy they were never allowed to read.
A separate boundary check — `iam list-users` — is also denied, which is worth
recording: at this point the role is genuinely not an administrator. The lesson
is sharper for the denial: a role that cannot even read its own permissions is
still one write away from admin.

## 5. Privilege escalation to administrator

`CreatePolicyVersion` publishes a new version of a customer-managed policy;
`SetDefaultPolicyVersion` makes it live. Because the policy is attached to the
role wielding these permissions, the role can rewrite its own grants. One call
publishes a `{ "Effect": "Allow", "Action": "*", "Resource": "*" }` document as
the new default. After a brief propagation wait, the same `iam list-users` that
was denied moments earlier succeeds. The scoped app role is now an
administrator, reached with one SSRF and one IAM call.

The reason this is a *primitive* and not a curiosity: it only works on
customer-managed policies — AWS-managed policies cannot be versioned — which is
why the lab ships its own policy rather than attaching `IAMFullAccess`. That
distinction is the whole lesson. `IAMFullAccess` would have made the escalation
tautological ("it had admin, so it got admin"). A single, narrow-looking,
self-referential permission is the realistic misconfiguration, and it is
indistinguishable from a benign app role until you read it closely.

## 6. The fix: enforce IMDSv2

`make harden` flips `enforce_imdsv2` to `true`, setting `http_tokens =
required` as an in-place metadata update. IMDSv2 is session-oriented: a client
must first `PUT` to obtain a token and then present it on the `GET`. A basic
SSRF can only issue the `GET`. Re-running the identical attack, step 3 now
returns nothing — the credential theft fails, and with no credentials there is
no pivot, no enumeration, and no privesc. The rest of the misconfiguration
(the over-broad role, the unfiltered fetch) is still present, but the chain
never reaches it. That is the honest framing for the before/after: IMDSv2 does
not fix the app or the role; it severs the link that turns an app bug into an
account compromise.

## 7. Root cause: broken access control, cloud and IoT

The escalation is not a memory bug or a parser trick. It is broken access
control: a principal holding a permission over a resource it should not be able
to rewrite. That is the same failure I demonstrated in the MQTT broker lab,
where an unscoped `#` subscription and missing per-tenant ACLs let one tenant
read and publish across the whole namespace — up to sending an unlock command
to another tenant's command topic. Different protocol, identical root cause:
authorization boundaries that were assumed rather than enforced. In AWS the
boundary is an IAM policy that grants one permission too many; in MQTT it is a
topic ACL that was never written. Least privilege is the same control in both,
and both labs are really one argument: the exploitable gap is almost never the
exotic vulnerability — it is the boundary nobody scoped.

## 8. Reproduce

```
make deploy      # vulnerable
make attack      # SSRF -> creds -> pivot -> blind privesc -> admin
make harden      # IMDSv2 required, in place
make attack      # dead at credential theft
make destroy
```

Intentionally vulnerable; isolated throwaway account only. See `NOTICE.md`.
