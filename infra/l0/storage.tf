# ---------------------------------------------------------------------------
# The document bucket.
#
# L0, not L1: uploaded documents are DATA. The cluster is rebuilt nightly and
# the bucket must not notice. Same reasoning as ECR and the Secrets Manager
# entry - anything a user would be upset to lose lives in the layer that is
# never destroyed.
#
# Costs nothing while empty. S3 bills per GB stored and per request.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "documents" {
  # S3 bucket names are globally unique across every AWS account on earth, so
  # the account id is appended. "securedocs-dev-documents" was taken years ago
  # by someone you will never meet.
  bucket = "securedocs-${local.environment}-documents-${data.aws_caller_identity.current.account_id}"

  tags = local.common_tags
}

# Four switches, all defaulting to OFF at the account level for historical
# reasons. This is the resource whose absence produces the "company leaks N
# million records from an open S3 bucket" headline.
#
# Note what it does: it grants nothing. It removes the ABILITY to grant public
# access later. Someone adding a public bucket policy next year gets an error
# instead of a breach.
resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true # reject new public ACLs
  block_public_policy     = true # reject new public bucket policies
  ignore_public_acls      = true # ignore any public ACL already set
  restrict_public_buckets = true # block even cross-account authenticated access
}

# Versioning: every overwrite and delete keeps the previous bytes.
#
# The real reason is not "oops I deleted it". It is ransomware and compromised
# credentials: with versioning off, one leaked key with s3:PutObject can
# overwrite every document in place and there is nothing to restore from.
#
# A delete becomes a "delete marker" - the object disappears from listings but
# the data is still there. Costs storage for every version kept, which is what
# a lifecycle rule would trim later.
resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest.
#
# S3 has encrypted every new object by default since January 2023, so this is
# not switching anything on. It states the intent explicitly, which is what an
# auditor and a Checkov scan both look for - "encrypted because someone decided
# so" rather than "encrypted because the default happened to be right".
#
# SSE-S3 (AES256), not SSE-KMS. KMS adds per-request cost and a second thing
# that can deny you access; it earns its place when you need an audit trail of
# every decrypt or a key you can revoke. Documents in a portfolio project do
# not. Naming the choice is the point.
resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Consumed by L1, which builds the api's IAM policy around this exact ARN.
output "documents_bucket" {
  value = aws_s3_bucket.documents.id
}

output "documents_bucket_arn" {
  value = aws_s3_bucket.documents.arn
}
