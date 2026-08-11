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
