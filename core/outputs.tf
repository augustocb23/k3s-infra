output "k3s_server_ip" {
  description = "Private IP of the K3s Server"
  value       = aws_instance.k3s_core.private_ip
}

output "k3s_public_ip" {
  description = "Public IP to SSH into Core"
  value       = aws_eip.k3s_core_ip.public_ip
}

output "k3s_token" {
  description = "Token for new nodes to join the cluster"
  value       = random_password.k3s_token.result
  sensitive   = true
}
