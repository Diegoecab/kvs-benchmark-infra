data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_ami" "ubuntu" {
  count       = var.runner_ami_id == null && var.ubuntu_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  runner_count = 3
  runner_ami   = coalesce(var.runner_ami_id, var.ubuntu_ami_id, try(data.aws_ami.ubuntu[0].id, null))
  common_tags = merge(var.tags, {
    ManagedBy = "Terraform"
    Purpose   = "Distributed KVS benchmark"
    RunId     = var.run_id
  })
}

check "prebaked_ami_is_explicit" {
  assert {
    condition     = var.runner_bootstrap_mode != "prebaked" || var.runner_ami_id != null
    error_message = "prebaked mode requires an explicitly pinned promoted AMI ID."
  }
}

resource "aws_dynamodb_table" "benchmark" {
  name           = "${var.run_id}-kvs"
  billing_mode   = "PROVISIONED"
  read_capacity  = 500
  write_capacity = 500
  hash_key       = "pk"
  range_key      = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "${var.run_id}-kvs" })
}

resource "aws_s3_bucket" "evidence" {
  bucket        = "${var.run_id}-kvs-evidence-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
  tags          = merge(local.common_tags, { Name = "${var.run_id}-kvs-evidence" })
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_security_group" "runner" {
  name        = "${var.run_id}-runner"
  description = "No-ingress security group for distributed KVS benchmark runners"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${var.run_id}-runner" })
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.runner.id
  description       = "HTTPS for AWS APIs, package repositories, and the pinned image registry"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.runner.id
  description       = "DNS to the existing VPC resolver"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.runner.id
  description       = "DNS fallback to the existing VPC resolver"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = data.aws_vpc.selected.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "ntp" {
  security_group_id = aws_security_group.runner.id
  description       = "NTP to the Amazon Time Sync Service"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  cidr_ipv4         = "169.254.169.123/32"
}

data "aws_iam_policy_document" "runner_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.run_id}-runner"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "benchmark_data" {
  statement {
    sid    = "BenchmarkTableData"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem"
    ]
    resources = [aws_dynamodb_table.benchmark.arn]
  }

  statement {
    sid    = "EvidenceBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [aws_s3_bucket.evidence.arn]
  }

  statement {
    sid    = "PublishEvidence"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.evidence.arn}/results/*"]
  }
}

resource "aws_iam_role_policy" "benchmark_data" {
  name   = "${var.run_id}-benchmark-data"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.benchmark_data.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.run_id}-runner"
  role = aws_iam_role.runner.name
  tags = local.common_tags
}

resource "aws_instance" "runner" {
  count             = local.runner_count
  ami               = local.runner_ami
  instance_type     = "t3.micro"
  availability_zone = var.availability_zone
  subnet_id         = var.subnet_id
  # The temporary address prevents cloud-init from racing the EIP association.
  # The EIP below becomes the stable source identity before readiness is checked.
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  monitoring                  = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud-init/runner.yaml.tftpl", {
    bootstrap_mode = var.runner_bootstrap_mode
    region         = var.region
    run_id         = var.run_id
    runner_image   = var.runner_image
    runner_index   = count.index + 1
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 16
  }

  lifecycle {
    precondition {
      condition     = data.aws_subnet.selected.vpc_id == var.vpc_id
      error_message = "subnet_id must belong to vpc_id."
    }
    precondition {
      condition     = data.aws_subnet.selected.availability_zone == var.availability_zone
      error_message = "subnet_id must be in availability_zone."
    }
  }

  depends_on = [aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.benchmark_data]

  tags = merge(local.common_tags, {
    Name       = "${var.run_id}-aws-runner-${format("%02d", count.index + 1)}"
    Target     = "aws"
    RunnerType = "kvs-benchmark"
    Source     = format("source-%02d", count.index + 1)
  })
}

resource "aws_eip" "runner" {
  count  = local.runner_count
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name   = "${var.run_id}-aws-runner-${format("%02d", count.index + 1)}"
    Source = format("source-%02d", count.index + 1)
  })
}

resource "aws_eip_association" "runner" {
  count         = local.runner_count
  allocation_id = aws_eip.runner[count.index].id
  instance_id   = aws_instance.runner[count.index].id
}
