locals {
  authorizer_list = [
    for key, value in var.routes :
    value["authorizer_key"] if lookup(value, "authorizer_key", "") != ""
  ]
  integration_lambda_list = [
    for key, value in var.routes :
    value["lambda_key"] if lookup(value, "lambda_key", "") != ""
  ]
  authorizer_keys = {
    for k in distinct(local.authorizer_list) :
    k => ""
  }
  integration_keys = {
    for k in distinct(local.integration_lambda_list) :
    k => ""
  }
  routes = {
    for key, value in var.routes : trimprefix(key, "/") => {
      method         = lookup(value, "method", "ANY")
      authorizer_key = lookup(value, "authorizer_key", "")
      lambda_key     = lookup(value, "lambda_key", "")
      proxy_url      = lookup(value, "proxy_url", "")
      type           = lookup(value, "type", "AWS_PROXY")
      path_params    = regexall("(?:{)([A-Za-z][_A-Za-z0-9]+)(?:[+]?})", key)
      path_part      = reverse(split("/", key))[0]
      parent_path    = length(split("/", key)) == 1 ? "" : substr(key, 1, length(key)-(length(reverse(split("/", key))[0])) - 2)
      headers        = lookup(value, "headers", "")
    }
  }
  route_resources = {
    "1" = { for key, value in local.level_1_routes : key => aws_api_gateway_resource.rest_api_route_1d_resource[key].id }
    "2" = { for key, value in local.level_2_routes : key => aws_api_gateway_resource.rest_api_route_2d_resource[key].id }
    "3" = { for key, value in local.level_3_routes : key => aws_api_gateway_resource.rest_api_route_3d_resource[key].id }
    "4" = { for key, value in local.level_4_routes : key => aws_api_gateway_resource.rest_api_route_4d_resource[key].id }
    "5" = { for key, value in local.level_5_routes : key => aws_api_gateway_resource.rest_api_route_5d_resource[key].id }
  }
  level_1_routes = { for key, value in local.routes : key => value if length(split("/", key)) == 1 && key != "" }
  level_2_routes = { for key, value in local.routes : key => value if length(split("/", key)) == 2 }
  level_3_routes = { for key, value in local.routes : key => value if length(split("/", key)) == 3 }
  level_4_routes = { for key, value in local.routes : key => value if length(split("/", key)) == 4 }
  level_5_routes = { for key, value in local.routes : key => value if length(split("/", key)) == 5 }
  redeployment_hash = var.redeployment_hash != "" ? var.redeployment_hash : sha1(jsonencode([
    var.name,
    aws_api_gateway_resource.rest_api_route_1d_resource,
    aws_api_gateway_resource.rest_api_route_2d_resource,
    aws_api_gateway_resource.rest_api_route_3d_resource,
    aws_api_gateway_resource.rest_api_route_4d_resource,
    aws_api_gateway_resource.rest_api_route_5d_resource,
    aws_api_gateway_method.rest_api_route_method,
    aws_api_gateway_integration.rest_api_route_integration,
    aws_api_gateway_authorizer.authorizer,
  ]))
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "apigateway.amazonaws.com",
        "cloudwatch.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "invocation_role" {
  name = "${var.name}-apigateway-auth-invocation-role"
  path = "/"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "invocation_policy" {
  count = length(local.authorizer_list) > 0 ? 1 : 0

  name = "${var.name}-apigateway-authorization-invocation-policy"
  role = aws_iam_role.invocation_role.id

  policy = jsonencode({
    "Version" = "2012-10-17",
    "Statement" = [
      {
        "Action" = "lambda:InvokeFunction",
        "Effect" = "Allow",
        "Resource" = [
          for key in distinct(local.authorizer_list) : var.lambdas[key]["function_arn"]
        ]
      }
    ]
  })
}

resource "aws_api_gateway_authorizer" "authorizer" {
  for_each = local.authorizer_keys

  name        = "api-authorizer-${each.key}"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  type        = lookup(var.lambdas[each.key], "authorizer_type", "TOKEN")
  # authorizer_uri looks funny because of https://github.com/hashicorp/terraform-provider-aws/issues/26619
  authorizer_uri                   = replace(var.lambdas[each.key]["function_invoke_arn"], "/\\:\\d{1,3}\\/invocations/", "/invocations")
  authorizer_credentials           = aws_iam_role.invocation_role.arn
  identity_source                  = lookup(var.lambdas[each.key], "identity_source", "method.request.header.X-Auth-Token")
  authorizer_result_ttl_in_seconds = parseint(lookup(var.lambdas[each.key], "authorizer_result_ttl_in_seconds", "900"), 10)
}
# END

# API_GATEWAY
resource "aws_lambda_permission" "lambda_invoke_permission" {
  for_each = var.lambdas

  statement_id  = "allow-${var.name}-apigateway-invoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value["function_name"]
  principal     = "apigateway.amazonaws.com"

  # The /*/*/* part allows invocation from any stage, method and resource path
  # within API Gateway REST API.
  source_arn = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/*/*"
}

resource "aws_api_gateway_rest_api" "rest_api" {
  name        = var.name
  description = var.description

  endpoint_configuration {
    types = [var.endpoint_type]
  }

  tags = var.tags
}

# routes
resource "aws_api_gateway_resource" "rest_api_route_1d_resource" {
  for_each = local.level_1_routes

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = each.value["path_part"]
}

resource "aws_api_gateway_resource" "rest_api_route_2d_resource" {
  for_each = local.level_2_routes

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_route_1d_resource[each.value["parent_path"]].id
  path_part   = each.value["path_part"]
}

resource "aws_api_gateway_resource" "rest_api_route_3d_resource" {
  for_each = local.level_3_routes

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_route_2d_resource[each.value["parent_path"]].id
  path_part   = each.value["path_part"]
}

resource "aws_api_gateway_resource" "rest_api_route_4d_resource" {
  for_each = local.level_4_routes

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_route_3d_resource[each.value["parent_path"]].id
  path_part   = each.value["path_part"]
}

resource "aws_api_gateway_resource" "rest_api_route_5d_resource" {
  for_each = local.level_5_routes

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_resource.rest_api_route_4d_resource[each.value["parent_path"]].id
  path_part   = each.value["path_part"]
}

resource "aws_api_gateway_method" "rest_api_route_method" {
  for_each = local.routes

  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = each.key == "" ? aws_api_gateway_rest_api.rest_api.root_resource_id : local.route_resources[tostring(length(split("/", each.key)))][each.key]

  http_method   = each.value["method"]
  authorization = each.value["authorizer_key"] == "" ? "NONE" : "CUSTOM"
  authorizer_id = (
    each.value["authorizer_key"] == ""
    ? null
    : aws_api_gateway_authorizer.authorizer[each.value["authorizer_key"]].id
  )
  request_parameters = {
    for name in each.value["path_params"] : "method.request.path.${name[0]}" => true
  }
}

resource "aws_api_gateway_integration" "rest_api_route_integration" {
  for_each = local.routes

  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = each.key == "" ? aws_api_gateway_rest_api.rest_api.root_resource_id : local.route_resources[length(split("/", each.key))][each.key]
  http_method             = aws_api_gateway_method.rest_api_route_method[each.key].http_method
  integration_http_method = each.value["lambda_key"] != "" ? "POST" : each.value["method"]
  type                    = each.value["type"]
  uri = (
    each.value["lambda_key"] != ""
    ? replace(var.lambdas[each.value["lambda_key"]]["function_invoke_arn"], "/\\:\\d{1,3}\\/invocations/", "/invocations")
    : each.value["proxy_url"]
  )
  cache_key_parameters = []
  request_parameters = merge({
    for name in each.value["path_params"] : "integration.request.path.${name[0]}" => "method.request.path.${name[0]}"
  }, {
    for header_pair in split(";", each.value["headers"]) : "integration.request.header.${split("=", header_pair)[0]}" => "'${split("=", header_pair)[1]}'" if length(regexall(".*=.*", header_pair)) > 0
  })
  request_templates = {}
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    redeployment = local.redeployment_hash
  }
  stage_description = local.redeployment_hash

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "api-gateway-logs" {
  name              = "/aws/apigateway/${aws_api_gateway_rest_api.rest_api.id}/${var.stage_name}"
  retention_in_days = var.log_retention_in_days
  tags              = var.tags
}

resource "aws_api_gateway_stage" "stage" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = var.stage_name

  variables = {
    STAGE_NAME = var.stage_name
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api-gateway-logs.arn
    format = jsonencode(
      {
        domainName   = "$context.domainName"
        method       = "$context.httpMethod"
        path         = "$context.path"
        ip           = "$context.identity.sourceIp"
        requestId    = "$context.requestId"
        requestTime  = "$context.requestTime"
        status       = "$context.status"
        errorMessage = "$context.error.message"
        xRayTraceId  = "$context.xrayTraceId"
      }
    )
  }

  xray_tracing_enabled = true
  tags                 = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_api_gateway_method_settings" "settings" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = aws_api_gateway_stage.stage.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

resource "aws_iam_role" "log_role" {
  count = var.set_cloudwatch_role && var.apigateway_cloudwatch_role_arn == "" ? 1 : 0

  name               = "${var.name}-apigateway-log-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

# Attach AmazonAPIGatewayPushToCloudWatchLogs policy to API Gateway role to allow it to write logs
resource "aws_iam_role_policy_attachment" "attach_cloudwatch_logging" {
  count = var.set_cloudwatch_role && var.apigateway_cloudwatch_role_arn == "" ? 1 : 0

  role       = aws_iam_role.log_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "api_gateway_account" {
  count = var.set_cloudwatch_role ? 1 : 0

  cloudwatch_role_arn = (
    var.apigateway_cloudwatch_role_arn != ""
    ? var.apigateway_cloudwatch_role_arn
    : aws_iam_role.log_role[0].arn
  )
}
