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
  }
}
provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

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

#resource "aws_subnet" "db_subnet" {
#  vpc_id            = aws_vpc.main.id
#  cidr_block        = "10.0.2.0/24"
#  availability_zone = data.aws_availability_zones.available.names[1]
#}

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

resource "aws_security_group_rule" "allow_lambda_to_db" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.lambda_sg.id
}

resource "aws_security_group_rule" "db_to_lambda" {
  type = "egress"
  from_port = 0
  to_port   = 0
  protocol  = "-1"
  security_group_id = aws_security_group.db_sg.id
  source_security_group_id = aws_security_group.db_sg.id
}


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

resource "aws_db_subnet_group" "db_subnet_group" {
  name      = "main"
  subnet_ids = [aws_subnet.lambda_subnet_a.id,aws_subnet.lambda_subnet_b.id]
}

resource "aws_rds_cluster" "aurora-pg" {
  cluster_identifier      = "springboot-aurora-pg"
  engine                  = "aurora-postgresql"
  engine_version          = "15.10"
  master_username         = var.db_username
  master_password         = var.db_password
  database_name                 = var.db_name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.db_subnet_group.name
  skip_final_snapshot     = true
}

resource "aws_rds_cluster_instance" "aurora_pg_write"{
  identifier          = "aurora-pg-write"
    cluster_identifier  = aws_rds_cluster.aurora-pg.id
    instance_class      = "db.serverless"
    engine              = aws_rds_cluster.aurora-pg.engine
    engine_version      = aws_rds_cluster.aurora-pg.engine_version
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

variable "confirm_destroy" {
  type = bool
  default = false
}

resource "null_resource" "cleanup_trigger" {
  triggers = {
    always_run = timestamp()
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "lambda_exec_role_2"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

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