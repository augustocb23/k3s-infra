data "terraform_remote_state" "shared" {
  backend = "remote"

  config = {
    organization = "augustocb23"
    workspaces = {
      name = "k3s-shared"
    }
  }
}

data "terraform_remote_state" "core" {
  backend = "remote"

  config = {
    organization = "augustocb23"
    workspaces = {
      name = "k3s-core"
    }
  }
}
