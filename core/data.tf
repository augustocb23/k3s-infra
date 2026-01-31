data "terraform_remote_state" "shared" {
  backend = "remote"

  config = {
    organization = "augustocb23"
    workspaces = {
      name = "k3s-shared"
    }
  }
}
