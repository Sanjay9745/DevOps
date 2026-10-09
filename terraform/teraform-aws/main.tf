
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get the latest Amazon Linux 2023 AMI
data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Find the default VPC
data "aws_vpc" "default" {
  default = true
}

# Find default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Create security group
resource "aws_security_group" "ec2_sg" {
  name_prefix = "terraform-ec2-"
  description = "Security group for Terraform EC2"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "terraform-ec2-sg"
  }
}

# Allow SSH from your IP only
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.ec2_sg.id

  cidr_ipv4   = var.ssh_cidr
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  description = "SSH access from trusted IP"
}

# Allow outbound IPv4 traffic
resource "aws_vpc_security_group_egress_rule" "outbound" {
  security_group_id = aws_security_group.ec2_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

# Create EC2 instance
resource "aws_instance" "my_ec2" {
  ami           = data.aws_ssm_parameter.amazon_linux.value
  instance_type = var.instance_type
  key_name      = var.key_name

  subnet_id = sort(data.aws_subnets.default.ids)[0]

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  associate_public_ip_address = true

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name        = "Terraform-EC2"
    Environment = "Development"
  }
}
