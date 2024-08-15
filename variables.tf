variable "lariat_api_key" {
  type = string
}

variable "lariat_application_key" {
  type = string
}

variable "lariat_sink_aws_access_key_id" {
  type = string
}

variable "lariat_sink_aws_secret_access_key" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "target_s3_buckets" {
  type = list(string)
}

variable "target_glue_database_tables" {
  type = map(list(string))
}

variable "iceberg_agent_config_bucket" {
  type = string
  default = "lariat-iceberg-default-config"
}

variable "lariat_vendor_tag_aws" {
  type = string
  default = ""
}

variable "lariat_ecr_image_name" {
  type = string
  default = "lariat-iceberg-agent"
}
