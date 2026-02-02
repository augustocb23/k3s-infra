# Módulo Shared (Networking Base & VPC)

* [Recursos de Rede](#recursos-de-rede)
* [Estratégia de Subnets](#estrat%C3%A9gia-de-subnets)
* [Outputs (Interface)](#outputs-interface)

Este módulo é a **camada de fundação** (Layer 0) da infraestrutura.
Ele é responsável por provisionar a **Virtual Private Cloud (VPC)** e toda a topologia de rede física onde os recursos computacionais (Core e Nodes) serão alocados.

Diferente dos outros módulos, este módulo **não possui instâncias EC2**. Ele apenas prepara o terreno ("encanamento") para que os outros módulos possam consumir redes seguras e organizadas.

## Recursos de Rede

Os recursos são definidos via Terraform e garantem o isolamento e conectividade básica.

### VPC (Virtual Private Cloud)

* Cria uma rede isolada na região `us-east-1` (padrão da AWS Academy).
* **CIDR Block:** `10.0.0.0/16` (65.536 IPs), permitindo ampla expansão para subnets futuras.
* **DNS:** Habilita suporte a DNS Hostnames e Resolution, essencial para a comunicação interna do Kubernetes.

### Conectividade Externa (Internet Gateway)

* Provisiona um **Internet Gateway (IGW)** e o anexa à VPC.
* Cria uma **Route Table Pública** (`public_rt`) que direciona o tráfego `0.0.0.0/0` para o IGW.

## Estratégia de Subnets

Utilizamos uma estratégia de "Tiering" (Camadas) para maximizar segurança e reduzir custos.

### 1. Subnets Públicas (`10.0.0.0/24`, `10.0.1.0/24`, ...)

Hospedar recursos que *precisam* ser acessíveis diretamente da internet ou que atuam como Gateway.

* **Módulo Core:** O Control Plane reside aqui para atuar como Bastion Host e NAT Instance.
* **Roteamento:** Acesso direto à internet via Internet Gateway.

### 2. Subnets Privadas (`10.0.100.0/24`, `10.0.101.0/24`, ...)

Hospedar a carga de trabalho (Workloads) protegida. Nenhuma conexão entra aqui diretamente.

* **Módulo Nodes:** Os Worker Nodes (Spot) rodam aqui para segurança máxima.

* **Roteamento (A Mágica da Economia):**
* Estas subnets **não** possuem rota para a internet inicialmente.
* Uma **Route Table Privada** (`private_rt`) é criada vazia.
* O módulo `core` (em outra etapa) injeta uma rota `0.0.0.0/0` apontando para a instância Core (NAT Instance), economizando o custo de um NAT Gateway gerenciado.

## Outputs (Interface)

Este módulo exporta dados críticos via `terraform_remote_state` para serem consumidos pelos módulos `core` e `nodes`.

| Output                   | Descrição                                 | Consumidor                         |
|--------------------------|-------------------------------------------|------------------------------------|
| `vpc_id`                 | ID da VPC criada.                         | Todos                              |
| `vpc_cidr_block`         | O range de IP da rede principal.          | Security Groups                    |
| `public_subnets`         | Lista de IDs das subnets públicas.        | Módulo Core                        |
| `public_subnets_azs`     | Lista de Zonas de Disponibilidade usadas. | Persistência (EBS)                 |
| `private_subnets`        | Lista de IDs das subnets privadas.        | Módulo Nodes (ASG)                 |
| `private_route_table_id` | ID da tabela de rotas privada.            | Módulo Core (para injeção de rota) |
