data "aws_caller_identity" "current" {}

# Reads L0's outputs straight out of S3.
#
# `workspace` is MANDATORY and does not inherit. It defaults to "default", so
# without this line L1 (running in the dev workspace) would read L0's state from
# the bare bucket-root key instead of env:/dev/L0/... — either failing, or
# silently wiring itself into whatever infrastructure that stray state describes.
data "terraform_remote_state" "l0" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket = "securedocs-tfstate-920042984462"
    key    = "L0/terraform.tfstate"
    region = "ap-southeast-2"
  }
}
