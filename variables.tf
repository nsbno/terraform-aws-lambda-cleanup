variable "n_versions_to_keep" {
  type    = number
  default = 10
}

variable "cron_expression" {
  description = "The cron expression for the schedule. Default is each day."
  type        = string
  default     = "cron(0 0 * * ? *)"
}
