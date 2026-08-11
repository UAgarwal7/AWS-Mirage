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
