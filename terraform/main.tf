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
