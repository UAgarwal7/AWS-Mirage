# Metadata Mirage

A reproducible AWS lab that chains a web-app **SSRF** into **instance
credential theft** and then into **full administrator** via a single IAM
privilege-escalation primitive — and shows the one-line fix that kills the
whole chain.

> ⚠️ Intentionally vulnerable. Deploy only in an isolated throwaway AWS
> account. Read [`NOTICE.md`](./NOTICE.md) first.

## The finding

A naive link-preview endpoint (`/fetch?url=`) will fetch any URL server-side
with no allow-list. Because the instance still allows **IMDSv1**, an attacker
points that SSRF at `169.254.169.254` and reads the instance role's temporary
credentials. Those creds look narrowly scoped — some S3 reads, a CloudWatch
put — but the role also holds `iam:CreatePolicyVersion` on the very policy
attached to it. One API call rewrites that policy to `*:*`, and the scoped app
role becomes an administrator.

## Layout

```
metadata-mirage/
├── app/app.py                  # the intentionally vulnerable Flask SSRF app
├── terraform/                  # the whole environment as code
│   ├── main.tf                 # VPC data, AMI, SG, IAM (the trap), EC2 (+IMDS toggle)
│   ├── variables.tf            # region, enforce_imdsv2, allowed_cidr, app_port
│   ├── outputs.tf              # ip / role / policy arn (fed into the attack)
│   └── user_data.sh.tftpl      # boots the app as a systemd service
├── attack/attack.sh            # the full offensive chain
├── Makefile                    # deploy / attack / harden / destroy
└── NOTICE.md
```

## Prerequisites

- `terraform` >= 1.5
- `aws` CLI, configured for a **throwaway** account (`aws configure`)
- `jq`, `curl`
- `asciinema` if you are recording the demo
- A region with a **default VPC** (fresh accounts have one)

## Quickstart

```bash
# 1. edit terraform/variables.tf: set allowed_cidr to YOUR_IP/32
make deploy      # stand up the vulnerable lab (IMDSv1 allowed)
make attack      # SSRF -> creds -> pivot -> enumerate -> privesc-to-admin
make harden      # flip to IMDSv2-required, in place
make attack      # same attack, now dead at the credential-theft step
make destroy     # tear it all down
make clean       # remove local terraform state (after destroy)
```

## The attack chain (`make attack`)

1. **SSRF → role name.** `/fetch?url=http://169.254.169.254/.../security-credentials/`
   returns the instance role name.
2. **SSRF → credentials.** Same trick one path deeper returns the role's
   temporary `AccessKeyId` / `SecretAccessKey` / `Token`.
3. **Pivot.** Export the stolen creds; `sts get-caller-identity` confirms you
   are now the instance role.
4. **Enumerate.** List the role's attached policies and read the default
   version — revealing the `CreatePolicyVersion` grant on its own policy.
5. **Boundary check.** `iam list-users` is denied — not admin yet.
6. **Privesc.** `create-policy-version` rewrites the attached policy to `*:*`
   and sets it default.
7. **Boundary check.** `iam list-users` now succeeds — full admin.

## Before / after: the whole defense is one flag

`enforce_imdsv2` (in `variables.tf`) flips the instance metadata options
between `http_tokens = "optional"` (IMDSv1 allowed) and `"required"`
(IMDSv2 enforced). `make harden` sets it to `true` as an **in-place** update —
the box is not rebuilt.

With IMDSv2 required, the attacker's plain `GET` to the metadata endpoint is
rejected (v2 requires a `PUT` to obtain a session token first, which a basic
SSRF cannot do). Step 2 returns nothing and the chain dies before any creds
are stolen — no pivot, no enumeration, no privesc.

## Why the primitive works

`iam:CreatePolicyVersion` lets a principal publish a new version of a
**customer-managed** policy and make it the default. If that policy is attached
to the principal itself, the principal can grant itself anything. It only
works on customer-managed policies — you cannot version an AWS-managed policy,
which is exactly why the lab ships its own. This is the least-privilege lesson:
a role that looks scoped can be one permission away from admin.

## Gotchas

- **Set `allowed_cidr` to your `/32`.** The default `0.0.0.0/0` exposes an
  intentionally vulnerable box to the whole internet.
- **Policy versions cap at 5.** A fresh lab has one or two; if you re-run the
  privesc many times you may hit the limit and need to delete an old version.
- **Default VPC required.** The lab reuses it rather than building networking,
  which keeps teardown clean. Accounts with the default VPC deleted need a
  small `main.tf` change.
- **`make harden` uses a `-var` flag**, so a later bare `make deploy` reverts
  to the vulnerable state. That is intentional — deploy = vulnerable,
  harden = fixed.
- **Propagation.** IAM is eventually consistent; the script sleeps briefly
  after the privesc before re-checking.

## Teardown

`make destroy` removes everything Terraform created (EC2, SG, role, policy,
instance profile). Because the lab builds no VPC and tags every resource with
`Project = metadata-mirage`, you can confirm a clean account by filtering on
that tag. Then `make clean` clears local state.
