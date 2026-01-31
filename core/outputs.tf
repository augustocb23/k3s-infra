output "k3s_server_ip" {
  description = "Private IP of the K3s Server"
  value       = aws_instance.k3s_core.private_ip
}

output "k3s_public_ip" {
  description = "Public IP to SSH into Core"
  value       = aws_instance.k3s_core.public_ip
}

output "k3s_token_cmd" {
  description = "Command to get the node token (run via SSH)"
  value       = "ssh ubuntu@${aws_instance.k3s_core.public_ip} 'sudo cat /var/lib/rancher/k3s/server/node-token'"
}
