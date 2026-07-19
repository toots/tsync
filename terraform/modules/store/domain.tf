# Optional vanity domain for share links. Everything here is gated on
# var.custom_domain: leave it null and the store serves off the raw Lambda
# Function URL with no API Gateway, no cert, and no DNS to manage.
#
# DNS is intentionally NOT created here — it works with any provider (Route 53,
# Cloudflare, a registrar, …). After apply you add two records by hand:
#   1. the acm_validation_records CNAME, so ACM issues the cert
#   2. a CNAME from custom_domain -> custom_domain_target
# Both are exposed as outputs. See README > Custom domain.

locals {
  domain_enabled = var.custom_domain == null ? 0 : 1
}

resource "aws_acm_certificate" "share" {
  count             = local.domain_enabled
  domain_name       = var.custom_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Waits until ACM reports the cert issued. With external DNS, apply blocks here
# until you add the validation CNAME; it then completes on its own.
resource "aws_acm_certificate_validation" "share" {
  count           = local.domain_enabled
  certificate_arn = aws_acm_certificate.share[0].arn
}

resource "aws_apigatewayv2_api" "share" {
  count         = local.domain_enabled
  name          = "tsync-share-${var.name}"
  protocol_type = "HTTP"
}

# Payload format 2.0 gives the handler event.rawPath + queryStringParameters,
# same shape as the Function URL, so the Python handler is unchanged.
resource "aws_apigatewayv2_integration" "share" {
  count                  = local.domain_enabled
  api_id                 = aws_apigatewayv2_api.share[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.share.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "share" {
  count     = local.domain_enabled
  api_id    = aws_apigatewayv2_api.share[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.share[0].id}"
}

resource "aws_apigatewayv2_stage" "share" {
  count       = local.domain_enabled
  api_id      = aws_apigatewayv2_api.share[0].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  count         = local.domain_enabled
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.share.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.share[0].execution_arn}/*/*"
}

resource "aws_apigatewayv2_domain_name" "share" {
  count       = local.domain_enabled
  domain_name = var.custom_domain

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.share[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "share" {
  count       = local.domain_enabled
  api_id      = aws_apigatewayv2_api.share[0].id
  domain_name = aws_apigatewayv2_domain_name.share[0].id
  stage       = aws_apigatewayv2_stage.share[0].id
}
