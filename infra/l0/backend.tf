terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "securedocs-tfstate-920042984462"
    key    = "L0/terraform.tfstate"
    region = "ap-southeast-2"

    encrypt = true

    # Terraform 1.10+ locks via S3 conditional writes. No DynamoDB table.
    use_lockfile = true

    # Workspace prefixes the key automatically:
    #   dev -> env:/dev/L0/terraform.tfstate
    # Never run in the "default" workspace — it writes to the bare key at the
    # bucket root, which belongs to no environment.
  }
}
