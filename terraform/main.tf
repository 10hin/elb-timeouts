terraform {
  required_version = "1.9.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Purpose     = local.project_name
      ProjectName = local.project_name
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  cidr_block_all = "0.0.0.0/0"

  elb_aws_account_id = "582318560864"

  project_name   = "elb-timeouts"
  aws_region     = data.aws_region.current.name
  aws_account_id = data.aws_caller_identity.current.account_id
}

module "network" {
  source = "./network/"
}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${local.project_name}-logs-${local.aws_account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.bucket
  policy = data.aws_iam_policy_document.allow_to_elb_delivery_logs.json
}
data "aws_iam_policy_document" "allow_to_elb_delivery_logs" {
  statement {
    sid = "AllowToELBDeliveryLogs"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.elb_aws_account_id}:root"]
    }
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.alb_logs.arn}/${local.access_log_prefix}/AWSLogs/${local.aws_account_id}/*",
      "${aws_s3_bucket.alb_logs.arn}/${local.connection_logs_prefix}/AWSLogs/${local.aws_account_id}/*",
    ]
  }
}

resource "aws_security_group" "alb" {
  name   = "${local.project_name}-alb"
  vpc_id = module.network.vpc_id
}

locals {
  access_log_prefix      = "access-logs"
  connection_logs_prefix = "connection-logs"
}
resource "aws_lb" "this" {
  name               = "${local.project_name}-main"
  internal           = true
  load_balancer_type = "application"
  security_groups = [
    aws_security_group.alb.id,
  ]
  subnets = [
    for subnet_key, subnet in module.network.subnets :
    subnet.id
    if subnet.tags_all["Access"] == "private"
  ]
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    enabled = true
    prefix  = local.access_log_prefix
  }
  connection_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    enabled = true
    prefix  = local.connection_logs_prefix
  }
  depends_on = [
    aws_s3_bucket_policy.alb_logs,
  ]
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_target_group" "this" {
  vpc_id   = module.network.vpc_id
  port     = 80
  protocol = "HTTP"
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.app.id
  port             = 80
}

resource "aws_security_group" "app" {
  vpc_id = module.network.vpc_id
}

resource "aws_iam_role" "app" {
  name               = "${local.project_name}-app"
  assume_role_policy = data.aws_iam_policy_document.allow_assume_by_instance.json
}
data "aws_iam_policy_document" "allow_assume_by_instance" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy" "AmazonSSMManagedInstanceCore" {
  name = "AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "allow_using_sessionmanager_to_instance" {
  role       = aws_iam_role.app.name
  policy_arn = data.aws_iam_policy.AmazonSSMManagedInstanceCore.arn
}

resource "aws_iam_instance_profile" "app" {
  name = aws_iam_role.app.name
  role = aws_iam_role.app.name
}

data "aws_ssm_parameter" "al2_ami_id" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}
resource "aws_instance" "app" {
  ami           = data.aws_ssm_parameter.al2_ami_id.value
  instance_type = "t3.micro"
  subnet_id = [
    for subnet in module.network.subnets :
    subnet.id
    if subnet.tags["Access"] == "private"
  ][0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
}


# Security Group Rules

locals {
  security_group_rules = [
    {
      name   = "app_to_alb"
      source = aws_security_group.app.id
      destination = {
        type  = "security_group"
        value = aws_security_group.alb.id
      }
      port        = 80
      ip_protocol = "tcp"
    },
    {
      name   = "alb_to_app"
      source = aws_security_group.alb.id
      destination = {
        type  = "security_group"
        value = aws_security_group.app.id
      }
      port        = 80
      ip_protocol = "tcp"
    },
    {
      name   = "app_to_443/tcp"
      source = aws_security_group.app.id
      destination = {
        type  = "ipv4_cidr_block"
        value = local.cidr_block_all
      }
      port        = 443
      ip_protocol = "tcp"
    },
  ]
}

resource "aws_vpc_security_group_egress_rule" "sg_dest" {
  for_each = {
    for sg_dest_rule in local.security_group_rules :
    sg_dest_rule.name => sg_dest_rule
    if sg_dest_rule.destination.type == "security_group"
  }

  security_group_id            = each.value.source
  ip_protocol                  = each.value.ip_protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.destination.value
}

resource "aws_vpc_security_group_ingress_rule" "sg_dest" {
  for_each = {
    for sg_dest_rule in local.security_group_rules :
    sg_dest_rule.name => sg_dest_rule
    if sg_dest_rule.destination.type == "security_group"
  }

  security_group_id            = each.value.destination.value
  ip_protocol                  = each.value.ip_protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.source
}

resource "aws_vpc_security_group_egress_rule" "ipv4_cidr_dest" {
  for_each = {
    for sg_dest_rule in local.security_group_rules :
    sg_dest_rule.name => sg_dest_rule
    if sg_dest_rule.destination.type == "ipv4_cidr_block"
  }

  security_group_id = each.value.source
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.destination.value
}

resource "aws_route53_zone" "vpc_internal" {
  name = "vpc.internal"
  vpc {
    vpc_id = module.network.vpc_id
  }
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.vpc_internal.zone_id
  name    = "app.vpc.internal"
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}

resource "aws_s3_bucket" "athena_result" {
  bucket        = "${local.project_name}-athena-results-${local.aws_account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "athena_result" {
  bucket = aws_s3_bucket.athena_result.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_athena_database" "log_search" {
  name   = "${replace(local.project_name, "-", "_")}_log_search"
  bucket = aws_s3_bucket.athena_result.bucket
}

resource "aws_glue_catalog_table" "access_log" {
  name          = "alb_access_logs"
  database_name = aws_athena_database.log_search.name
  owner         = "hadoop"
  parameters = {
    EXTERNAL                       = "TRUE"
    "projection.day.format"        = "yyyy/MM/dd"
    "projection.day.interval"      = "1"
    "projection.day.interval.unit" = "DAYS"
    "projection.day.range"         = "2022/01/01,NOW"
    "projection.day.type"          = "date"
    "projection.enabled"           = "true"
    "storage.location.template"    = "s3://${aws_s3_bucket.alb_logs.bucket}/${local.access_log_prefix}/AWSLogs/${local.aws_account_id}/elasticloadbalancing/${local.aws_region}/$${day}"
  }
  retention  = 0
  table_type = "EXTERNAL_TABLE"
  partition_keys {
    name = "day"
    type = "string"
  }
  storage_descriptor {
    additional_locations      = []
    bucket_columns            = []
    compressed                = false
    input_format              = "org.apache.hadoop.mapred.TextInputFormat"
    location                  = "s3://${aws_s3_bucket.alb_logs.bucket}/${local.access_log_prefix}/AWSLogs/${local.aws_account_id}/elasticloadbalancing/${local.aws_region}"
    number_of_buckets         = -1
    output_format             = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    parameters                = {}
    stored_as_sub_directories = false
    columns {
      name       = "type"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "time"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "elb"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "client_ip"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "client_port"
      parameters = {}
      type       = "int"
    }
    columns {
      name       = "target_ip"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "target_port"
      parameters = {}
      type       = "int"
    }
    columns {
      name       = "request_processing_time"
      parameters = {}
      type       = "double"
    }
    columns {
      name       = "target_processing_time"
      parameters = {}
      type       = "double"
    }
    columns {
      name       = "response_processing_time"
      parameters = {}
      type       = "double"
    }
    columns {
      name       = "elb_status_code"
      parameters = {}
      type       = "int"
    }
    columns {
      name       = "target_status_code"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "received_bytes"
      parameters = {}
      type       = "bigint"
    }
    columns {
      name       = "sent_bytes"
      parameters = {}
      type       = "bigint"
    }
    columns {
      name       = "request_verb"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "request_url"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "request_proto"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "user_agent"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "ssl_cipher"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "ssl_protocol"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "target_group_arn"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "trace_id"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "domain_name"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "chosen_cert_arn"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "matched_rule_priority"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "request_creation_time"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "actions_executed"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "redirect_url"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "lambda_error_reason"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "target_port_list"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "target_status_code_list"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "classification"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "classification_reason"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "conn_trace_id"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "unknown_fiedls"
      parameters = {}
      type       = "string"
    }
    ser_de_info {
      name = null
      parameters = {
        "input.regex"          = "([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \"([^ ]*) (.*) (- |[^ ]*)\" \"([^\"]*)\" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ([-.0-9]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^ ]*)\" \"([^\\s]+?)\" \"([^\\s]+)\" \"([^ ]*)\" \"([^ ]*)\" ?([^ ]*)?( .*)?"
        "serialization.format" = "1"
      }
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
    }
    skewed_info {
      skewed_column_names               = []
      skewed_column_value_location_maps = {}
      skewed_column_values              = []
    }
  }
}

resource "aws_glue_catalog_table" "connection_log" {
  name          = "alb_connection_logs"
  database_name = aws_athena_database.log_search.name
  owner         = "hadoop"
  parameters = {
    EXTERNAL                       = "TRUE"
    "projection.day.format"        = "yyyy/MM/dd"
    "projection.day.interval"      = "1"
    "projection.day.interval.unit" = "DAYS"
    "projection.day.range"         = "2022/01/01,NOW"
    "projection.day.type"          = "date"
    "projection.enabled"           = "true"
    "storage.location.template"    = "s3://${aws_s3_bucket.alb_logs.bucket}/${local.connection_logs_prefix}/AWSLogs/${local.aws_account_id}/elasticloadbalancing/${local.aws_region}/$${day}"
  }
  retention  = 0
  table_type = "EXTERNAL_TABLE"
  partition_keys {
    name = "day"
    type = "string"
  }
  storage_descriptor {
    additional_locations      = []
    bucket_columns            = []
    compressed                = false
    input_format              = "org.apache.hadoop.mapred.TextInputFormat"
    location                  = "s3://${aws_s3_bucket.alb_logs.bucket}/${local.connection_logs_prefix}/AWSLogs/${local.aws_account_id}/elasticloadbalancing/${local.aws_region}"
    number_of_buckets         = -1
    output_format             = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    parameters                = {}
    stored_as_sub_directories = false
    columns {
      name       = "time"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "client_ip"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "client_port"
      parameters = {}
      type       = "int"
    }
    columns {
      name       = "listener_port"
      parameters = {}
      type       = "int"
    }
    columns {
      name       = "tls_protocol"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "tls_cipher"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "tls_handshake_latency"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "leaf_client_cert_subect"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "leaf_client_cert_validity"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "leaf_client_cert_serial_number"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "tls_verify_status"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "conn_trace_id"
      parameters = {}
      type       = "string"
    }
    columns {
      name       = "unknown_fiedls"
      parameters = {}
      type       = "string"
    }
    ser_de_info {
      name = null
      parameters = {
        "input.regex"          = "([^ ]*) ([^ ]*) ([0-9]*) ([0-9]*) ([A-Za-z0-9.-]*) ([^ ]*) ([-.0-9]*) \"([^\"]*)\" ([^ ]*) ([^ ]*) ([^ ]*) ?([^ ]*)?( .*)?"
        "serialization.format" = "1"
      }
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
    }
    skewed_info {
      skewed_column_names               = []
      skewed_column_value_location_maps = {}
      skewed_column_values              = []
    }
  }
}
