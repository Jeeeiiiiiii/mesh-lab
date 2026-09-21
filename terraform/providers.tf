terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Every AWS call is redirected at the local emulator. The `endpoints` block is
# the only thing separating this from a real AWS deploy -- remove it and the
# same configuration targets a real account.
provider "aws" {
  region     = var.region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  # After DeleteLoadBalancer the provider polls DescribeNetworkInterfaces
  # until the NLB's ENIs are gone. Floci returns a 500 on that call (its ENI
  # `description` filter is broken), the SDK retries 25 times with growing
  # backoff, and destroy sits for half an hour on one resource. With few
  # retries the call fails fast, the provider logs a warning, and moves on.
  # Against a real account the default is the safer choice.
  max_retries = 2

  endpoints {
    ec2         = var.endpoint_url
    eks         = var.endpoint_url
    iam         = var.endpoint_url
    sts         = var.endpoint_url
    elbv2       = var.endpoint_url
    autoscaling = var.endpoint_url
  }
}
