resource "random_password" "db_root_pass" {
  length  = 20
  special = true

  override_special = "_%@"
}

resource "aws_secretsmanager_secret" "db_secret" {
  name        = "k3s-db-${var.env}"
  description = "Root password for K3s database"

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_secret_value" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    username = "root"
    password = random_password.db_root_pass.result
    host     = aws_instance.k3s_core.private_ip
    port     = 3306
  })
}
