# AWS API Gateway (HTTP API) done right:
# custom domain -> authorizer -> throttled route -> Lambda backend,
# with JSON access logging and X-Ray tracing.
#
# Usage:
#   terraform init
#   terraform apply -var="domain_name=api.example.com" \
#                   -var="certificate_arn=arn:aws:acm:..."

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for the API"
  type        = string
  default     = "ap-southeast-1"
}

variable "domain_name" {
  description = "Custom domain, e.g. api.example.com (must have a Route 53 hosted zone)"
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the custom domain (must be in us-east-1 for edge, or regional)"
  type        = string
}

# ---------------------------------------------------------------------------
# 1. The HTTP API
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = "orders-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://app.example.com"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }
}

# ---------------------------------------------------------------------------
# 2. Backend Lambda: POST /orders
# ---------------------------------------------------------------------------
data "archive_file" "orders" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/orders"
  output_path = "${path.module}/orders.zip"
}

resource "aws_lambda_function" "orders" {
  function_name = "orders-api-handler"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.orders.output_path
  timeout       = 10 # keep well under the 30s gateway cap

  tracing_config { mode = "Active" } # X-Ray

  environment {
    variables = { LOG_LEVEL = "info" }
  }
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "orders" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orders.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

# ---------------------------------------------------------------------------
# 3. Lambda authorizer: runs BEFORE the backend on protected routes
# ---------------------------------------------------------------------------
data "archive_file" "authorizer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/authorizer"
  output_path = "${path.module}/authorizer.zip"
}

resource "aws_lambda_function" "authorizer" {
  function_name = "orders-api-authorizer"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  filename      = data.archive_file.authorizer.output_path
  timeout       = 5
}

resource "aws_lambda_permission" "allow_apigw_auth" {
  statement_id  = "AllowAPIGatewayAuth"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/authorizers/*"
}

resource "aws_apigatewayv2_authorizer" "jwt_lambda" {
  api_id                            = aws_apigatewayv2_api.main.id
  authorizer_type                   = "REQUEST"
  name                              = "bearer-authorizer"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  authorizer_result_ttl_in_seconds  = 300 # cache allow decisions; keep deny TTLs short
  identity_sources                  = ["$request.header.Authorization"]
}

# ---------------------------------------------------------------------------
# 4. Routes: protected write, open read
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_route" "create_order" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /orders"
  target             = "integrations/${aws_apigatewayv2_integration.orders.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt_lambda.id

  # Per-route throttling: the expensive route gets its own seatbelt.
  # (Stage-level defaults below catch everything else.)
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.orders.id}"
  # No authorizer: load-balancer / uptime checks stay unauthenticated.
}

# ---------------------------------------------------------------------------
# 5. Stage: throttling + JSON access logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/orders-api"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # Stage-level guardrails: absorb spikes before they hit Lambda.
  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
      latency        = "$context.integrationLatency"
      authorizerErr  = "$context.authorizer.error"
    })
  }
}

# ---------------------------------------------------------------------------
# 6. Custom domain: api.example.com
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_domain_name" "custom" {
  domain_name = var.domain_name
  domain_name_configuration {
    certificate_arn = var.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "custom" {
  api_id      = aws_apigatewayv2_api.main.id
  domain_name = aws_apigatewayv2_domain_name.custom.id
  stage       = aws_apigatewayv2_stage.default.id
}

# ---------------------------------------------------------------------------
# 7. Least-privilege execution role (logs + X-Ray only)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "orders-api-lambda-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "logs-and-tracing"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/orders-api*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

output "api_endpoint" {
  description = "Invoke URL of the $default stage"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "custom_domain" {
  description = "Custom domain target — point your Route 53 alias here"
  value       = aws_apigatewayv2_domain_name.custom.domain_name_configuration[0].target_domain_name
}
