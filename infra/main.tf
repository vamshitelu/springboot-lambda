terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.8.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.2"
    }
  }
}
provider "aws" {
  region = var.aws_region
}

#-------------------------
# Networking
#-------------------------
resource "aws_vpc" "main"  {
  cidr_block = "10.0.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

#Lambda subnets
resource "aws_subnet" "lambda_subnet_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}
resource "aws_subnet" "lambda_subnet_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
}

#DB subnets (different CIDRs to avoid conflit)
resource "aws_subnet" "db_subnet_a" {
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.10.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "db_subnet_b" {
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.11.0/24"
    availability_zone = data.aws_availability_zones.available.names[1]
}

#-------------------------
# Security Groups
#-------------------------
resource "aws_security_group" "lambda_sg" {
  name        = "lambda_sg"
  description = "Security group for Lambda function"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "db_sg" {
  name        = "db_sg"
  description = "Security group for database"
  vpc_id      = aws_vpc.main.id
}

# Allow Lambda to talk to the database
resource "aws_security_group_rule" "allow_lambda_to_db" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.lambda_sg.id
}

# Allow DB Engine
#resource "aws_security_group_rule" "db_to_lambda" {
#  type = "egress"
#  from_port = 0
#  to_port   = 0
#  protocol  = "-1"
#  security_group_id = aws_security_group.db_sg.id
#  cidr_blocks = ["0.0.0.0/0"]
#}

#--------------------------
#SSM Parameter for DB creds
#---------------------------
resource "aws_ssm_parameter" "db_username" {
  name  = "/db/postgres/username"
  type  = "String"
  value = var.db_username
  overwrite = true
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/db/postgres/password"
  type  = "SecureString"
  value = var.db_password
  overwrite = true
}

#--------------------------
# DB Subnet Group and RDS Cluster
#--------------------------
resource "aws_db_subnet_group" "db_subnet_group" {
  name      = "main-db-subnet-group"
  subnet_ids = [aws_subnet.db_subnet_a.id,aws_subnet.db_subnet_b.id]
}

#--------------------------
# RDS Aurora PostgreSQL Serverless Cluster
#--------------------------
resource "aws_rds_cluster" "aurora-pg" {
  cluster_identifier      = "springboot-aurora_pg"
  engine                  = "aurora-postgresql"
  engine_version          = "15.5"
  master_username         = var.db_username
  master_password         = var.db_password
  database_name           = var.db_name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.db_subnet_group.name
  skip_final_snapshot     = true

  #Serverless configuration
  serverlessv2_scaling_configuration {
    max_capacity = 2
    min_capacity = 1
  }
}

resource "aws_rds_cluster_instance" "aurora_pg_write"{
  identifier          = "aurora-pg-instance"
    cluster_identifier  = aws_rds_cluster.aurora-pg.id
    instance_class      = "db.serverless"
    engine              = aws_rds_cluster.aurora-pg.engine
    engine_version      = aws_rds_cluster.aurora-pg.engine_version
}

#------------------------------
# Lambda Role & policy
#------------------------------
#data "aws_iam_policy_document" "lambda_assume_role" {
#  statement {
#    actions = ["sts:AssumeRole"]
#    principals {
#      type        = "Service"
#      identifiers = ["lambda.amazonaws.com"]
#    }
#  }
#}

#---------------------------------
# IAMRole for Lambda
#----------------------------------
resource "aws_iam_role" "lambda_exec_role"{
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}
#resource "aws_iam_role" "lambda_exec_role" {
#  name               = "lambda_exec_role"
#  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
#}

#Attachbasic execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

#Policy to read DB creds from SSM
resource "aws_iam_role_policy" "lambda_ssm_policy" {
  name = "lambda_ssm_policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersHistory"]
        Resource = [
          aws_ssm_parameter.db_username.arn,
          aws_ssm_parameter.db_password.arn
        ]
      }
    ]
  })
}
#------------------------------
#Create S3 Bucket for Lambda
#------------------------------
resource "aws_s3_bucket" "springboot_lambda_bucket" {
  bucket = var.lambda_s3_bucket_name
  force_destroy = true
  tags = {
    Name        = "Springboot Lambda Bucket"
    Environment = "dev"
  }
}

resource "aws_s3_account_public_access_block" "lambda_bucket_block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#------------------------------
# Upload Lambda package to S3
#------------------------------
resource "aws_s3_bucket_object" "lambda_package" {
  bucket = aws_s3_bucket.springboot_lambda_bucket.id
  key    = var.lambda_s3_object_key

  source = "${path.module}/../target/springboot-lambda-1.0-SNAPSHOT.jar" # Update with the actual path to your Lambda package
  etag   = filemd5("${path.module}/../target/springboot-lambda-1.0-SNAPSHOT.jar") # Ensure this matches the file path
}

#------------------------------
# Lambda Function
#------------------------------
resource "aws_lambda_function" "spring_boot_lambda" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "com.vsoft.StreamLambdaHandler::handleRequest"
  runtime       = "java21"
  s3_bucket     = var.lambda_s3_bucket_name
  s3_key        = var.lambda_s3_object_key
  memory_size = 1024
  timeout     = 30
  vpc_config {
    subnet_ids         = [aws_subnet.lambda_subnet_a.id,aws_subnet.lambda_subnet_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  environment {
    variables = {
      DB_USERNAME = aws_ssm_parameter.db_username.name
      DB_PASSWORD = aws_ssm_parameter.db_password.name
      DB_NAME     = var.db_name
      DB_ENDPOINT = aws_rds_cluster.aurora-pg.endpoint

    }
  }
}
#------------------------------
# API Gateway -> Lambda Proxy
#------------------------------
resource "aws_api_gateway_rest_api" "springboot_api" {
  name = "springboot-api"
    description = "Proxy+ API for Spring Boot Lambda"
}

# create proxy resource {proxy+}
resource "aws_api_gateway_resource" "proxy" {
  parent_id   = aws_api_gateway_rest_api.springboot_api.root_resource_id
  path_part   = "{proxy+}"
  rest_api_id = aws_api_gateway_rest_api.springboot_api.id
}

#API method on proxy
resource "aws_api_gateway_method" "proxy_method" {
  rest_api_id   = aws_api_gateway_rest_api.springboot_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

#Integration with Lambda
resource "aws_api_gateway_integration" "proxy_integration" {
  rest_api_id = aws_api_gateway_rest_api.springboot_api.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.spring_boot_lambda.invoke_arn
}

# Root ANY method(for "/")
resource "aws_api_gateway_method" "root_any" {
  rest_api_id   = aws_api_gateway_rest_api.springboot_api.id
  resource_id   = aws_api_gateway_rest_api.springboot_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

# Integration for root ANY method
resource "aws_api_gateway_integration" "root_integration" {
  http_method = aws_api_gateway_method.root_any.http_method
  resource_id = aws_api_gateway_rest_api.springboot_api.root_resource_id
  rest_api_id = aws_api_gateway_rest_api.springboot_api.id
  type        = "AWS_PROXY"
  integration_http_method = "POST"
    uri         = aws_lambda_function.spring_boot_lambda.invoke_arn
}

#Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spring_boot_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # The source ARN for the API Gateway
  source_arn = "${aws_api_gateway_rest_api.springboot_api.execution_arn}/*/*"
}

# Deployment for API Gateway
resource "aws_api_gateway_deployment" "springboot_deployment" {
  depends_on = [
    aws_api_gateway_integration.proxy_integration,
    aws_api_gateway_integration.root_integration
  ]
  rest_api_id = aws_api_gateway_rest_api.springboot_api.id
  stage_name  = "dev"
}

output "api_url" {
  value = "https://${aws_api_gateway_rest_api.springboot_api.id}.execute-api.${var.aws_region}.amazonaws.com/dev"
}

output "db_writer_endpoint"{
  value = aws_rds_cluster.aurora-pg.endpoint
}

output "db_reader_endpoint" {
  value = aws_rds_cluster.aurora-pg.reader_endpoint
}