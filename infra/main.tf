# --- Remote state -----------------------------------------------------------
# Local state is fine for an exercise, but for a real deployment state should
# live somewhere shared and locked so multiple engineers/CI runs can't stomp
# on each other. Example (fill in your own bucket/table and uncomment):
#
# terraform {
#   backend "s3" {
#     bucket         = "your-tfstate-bucket"
#     key            = "orders-api/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "your-tfstate-lock-table"
#     encrypt        = true
#   }
# }

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Variables ---------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name, used for tagging and naming."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short name used to prefix/tag resources."
  type        = string
  default     = "orders-api"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet the API instance runs in."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets the RDS instance runs in (needs at least 2 AZs for a DB subnet group)."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.3.0/24"]
}

variable "availability_zones" {
  description = "AZs to spread the private subnets across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH/admin ports. Set this to your own IP/VPN range, never 0.0.0.0/0."
  type        = string
  default     = "203.0.113.0/32" # placeholder — replace with a real, narrow CIDR
}

variable "instance_type" {
  description = "EC2 instance type for the API host."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID for the API instance."
  type        = string
  default     = "ami-0abcdef1234567890" # placeholder — replace with a current AMI for your region
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_password" {
  description = "Master password for the orders RDS instance."
  type        = string
  sensitive   = true
  # No default on purpose — must be supplied via TF_VAR_db_password or a
  # gitignored *.tfvars file, never committed to source.
}

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# --- Networking ---------------------------------------------------------------
# Everything below used to rely on the account's default VPC. That's fine for
# a quick demo, but production infra should own its own VPC/subnets so it
# isn't affected by changes to (or removal of) the account default.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${var.project_name}-public" })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, { Name = "${var.project_name}-private-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_db_subnet_group" "orders_db" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.tags, { Name = "${var.project_name}-db-subnet-group" })
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "api_sg" {
  name        = "${var.project_name}-api-sg"
  description = "Access for the API host"
  vpc_id      = aws_vpc.main.id

  # SSH restricted to an admin CIDR instead of the entire internet.
  # Prefer AWS SSM Session Manager over SSH entirely where possible.
  ingress {
    description = "Admin SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "App traffic"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # app traffic is meant to be public; kept open intentionally
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-api-sg" })
}

resource "aws_security_group" "db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "Access for the RDS instance — only from the API host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from API host only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project_name}-db-sg" })
}

# --- IAM ------------------------------------------------------------------
# Gives the instance a way to authenticate to AWS (e.g. SSM, CloudWatch logs)
# without embedding long-lived credentials on the box.

resource "aws_iam_role" "api_instance_role" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

# Enables AWS Systems Manager Session Manager as a keyless alternative to SSH.
resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.api_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "api_instance_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.api_instance_role.name
}

# --- Compute ---------------------------------------------------------------

resource "aws_instance" "api" {
  ami                    = var.ami_id
  instance_type          = var.instance_type # small Flask API doesn't need 16 vCPU / 64GB RAM
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.api_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.api_instance_profile.name

  root_block_device {
    volume_type = "gp3" # gp3 is cheaper and faster than gp2 at the same size
    volume_size = 20    # 500GB was never going to be used by this app
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # enforce IMDSv2, blocks a common SSRF-to-credential-theft path
  }

  tags = merge(local.tags, { Name = "${var.project_name}-instance" })
}

# --- Database ---------------------------------------------------------------

resource "aws_db_instance" "orders_db" {
  engine                  = "postgres"
  instance_class          = var.db_instance_class # db.m5.2xlarge was massive overkill for this workload
  allocated_storage       = 20
  username                = "admin"
  password                = var.db_password
  storage_encrypted       = true
  backup_retention_period = 7
  multi_az                = false # multi-AZ roughly doubles RDS cost; turn on only if uptime SLA needs it
  publicly_accessible     = false
  skip_final_snapshot     = true # acceptable for this dev/test exercise; would be false for real prod data
  db_subnet_group_name    = aws_db_subnet_group.orders_db.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]

  tags = local.tags
}

# --- Outputs ---------------------------------------------------------------

output "instance_public_ip" {
  description = "Public IP of the API instance."
  value       = aws_instance.api.public_ip
}

output "instance_id" {
  description = "ID of the API EC2 instance."
  value       = aws_instance.api.id
}

output "db_endpoint" {
  description = "Connection endpoint for the RDS instance."
  value       = aws_db_instance.orders_db.endpoint
  sensitive   = true
}

output "vpc_id" {
  description = "ID of the VPC these resources were created in."
  value       = aws_vpc.main.id
}
