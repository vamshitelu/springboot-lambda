variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "ap-south-1"
}
variable "db_username" {
  description = "The username for the database"
  type        = string
  default     = "postgres"
}
variable "db_password" {
  description = "The password for the database"
  type        = string
  default     = "password123"
}
variable "db_name" {
  type = string
  default = "testdb"
}
variable lambda_function_name{
  default = "springboot-lambda"
}
variable lambda_s3_bucket_name {
  default = "springboot-lambda-bucket"
}
variable lambda_s3_object_key {
  default = "app-lambda-package.zip"
}
