resource "aws_route" "private_nat_gateway" {
  route_table_id = data.terraform_remote_state.shared.outputs.private_route_table_id

  destination_cidr_block = "0.0.0.0/0"

  network_interface_id = aws_instance.k3s_core.primary_network_interface_id
}
