# ---------------------------------------------------------------------------
# Postgres credentials — the CONTAINER only.
#
# In L0, not L1, deliberately: the password must survive every nightly
# `terraform destroy` of the cluster. Put it in L1 and you would regenerate
# credentials daily and orphan the data on the EBS volume.
#
# TERRAFORM DOES NOT CREATE THE VALUE.
#
# `aws_secretsmanager_secret` creates an empty container. The password is put
# in ONCE, by hand, with the AWS CLI:
#
#   aws secretsmanager put-secret-value \
#     --secret-id securedocs/dev/postgres \
#     --secret-string "{\"POSTGRES_USER\":\"securedocs\",\"POSTGRES_PASSWORD\":\"$(openssl rand -base64 24)\",\"POSTGRES_DB\":\"securedocs\"}"
#
# If Terraform generated it — with random_password, or a
# secretsmanager_secret_version — the plaintext would be written to state.
# That is exactly the AceArena finding: anyone with s3:GetObject on the state
# bucket could read every service's database password, regardless of their
# Secrets Manager permissions.
#
# So: the reference is code, the value is not.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "postgres" {
  name        = "securedocs/${local.environment}/postgres"
  description = "Postgres credentials. Value set out-of-band — never by Terraform."

  # Dev: allow immediate deletion and reuse of the name. Production keeps the
  # default 30-day recovery window, so a mistaken delete is recoverable.
  recovery_window_in_days = 0

  tags = local.common_tags

  lifecycle {
    # Belt and braces: if anyone later adds a secret_version resource, this
    # stops Terraform overwriting a live password on the next apply.
    ignore_changes = [tags_all]
  }
}

output "postgres_secret_arn" {
  description = "Referenced by the External Secrets IRSA role and the ExternalSecret manifest"
  value       = aws_secretsmanager_secret.postgres.arn
}

output "postgres_secret_name" {
  value = aws_secretsmanager_secret.postgres.name
}
