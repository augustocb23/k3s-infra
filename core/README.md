# Módulo Core (Control Plane & Serviços)

- [Recursos Criados](#recursos-criados)
- [Decisões de Arquitetura](#decisões-de-arquitetura)
- [Bootstrapping](#bootstrapping)
- [Acesso e Utilização](#acesso-e-utilização)

Este módulo é responsável por provisionar o "cérebro" da infraestrutura. Ele centraliza os serviços persistentes e de gerenciamento, atuando como Control Plane do Kubernetes, Gateway de Internet para a rede privada e servidor de Banco de Dados.

A infraestrutura foi desenhada para operar dentro das restrições e custos reduzidos da AWS Academy, utilizando arquitetura ARM64.

## Recursos Criados

Os recursos são definidos via Terraform e agrupados por função.

### Instância Principal ([`main.tf`](./main.tf))

Define a máquina virtual central do cluster (`k3s-core`).
Utiliza a família `t4g.small` (ARM64, 2 vCPU, 2GB RAM), que oferece a melhor relação performance/custo para sustentar o Control Plane e o Banco de Dados simultaneamente.

* **Elastic IP (EIP):** Um endereço IP estático público é alocado e associado à instância. Isso garante que o apontamento de DNS (Registro.br) não quebre caso a instância precise ser recriada.
* **NAT Instance:** A verificação de origem/destino (`source_dest_check`) é desabilitada na interface de rede. Isso permite que a instância atue como roteador, permitindo que os nós de processamento (nas subnets privadas) acessem a internet através dela.
* **Persistência de Dados:** Um volume EBS adicional (`gp3`) é criado e anexado à instância para garantir que os dados do banco não sejam perdidos se a máquina precisar ser recriada.
* **Consulta de Roles**: O projeto utiliza *Data Sources* para buscar o `LabInstanceProfile` existente, garantindo que a instância tenha permissões para interagir com a API da AWS (necessário para o Cloud Provider do K3s e acesso ao ECR) sem tentar criar Roles novas, o que é bloqueado no ambiente de laboratório da AWS Academy.

### Gerenciamento de Segredos ([`secrets.tf`](./secrets.tf))

Gera e armazena credenciais sensíveis de forma segura, evitando *hardcoded secrets* no código.

* **Senha do Banco:** Utiliza o provider `random` para gerar uma senha forte para o usuário `root` do MySQL.
* **AWS Secrets Manager:** A senha gerada é armazenada imediatamente no cofre da AWS.
* **Injeção Segura:** A senha é recuperada pelo Terraform e injetada no script de inicialização (`user_data`) apenas em tempo de execução.

### Integração de Rede ([`data.tf`](./data.tf))

Lê o *Remote State* do módulo `shared`.
O Core consome as informações da VPC e das Subnets Públicas criadas anteriormente, garantindo que o volume EBS seja criado na mesma Zona de Disponibilidade (AZ) da instância.

## Bootstrapping

A configuração do sistema operacional é realizada automaticamente via `cloud-init` ([`user_data.sh`](./user_data.sh)).

### 1. Roteamento (NAT)

O script configura regras de `iptables` para mascarar (Masquerade) o tráfego de saída. Isso efetivamente transforma a instância em um Gateway NAT gratuito para os nós privados.

### 2. Banco de Dados (MySQL 8)

O script detecta o volume EBS secundário (identificado como `/dev/nvme1n1` na arquitetura Nitro/ARM), formata-o como `ext4` (apenas na primeira execução) e o monta em `/var/lib/mysql`. Isso desacopla o ciclo de vida dos dados do ciclo de vida da computação.

Após a montagem, instala o servidor MySQL nativamente no Host.

* Configurado para aceitar conexões externas (`0.0.0.0`), permitindo acesso pelos Pods dos Worker Nodes.
* A autenticação é configurada utilizando a senha gerada pelo Terraform.

### 3. Kubernetes (K3s Server)

Instala a distribuição K3s em modo Server.

* **Traefik Ingress:** Mantém-se o Ingress Controller padrão ativado. Ele escuta nas portas `80` e `443` do Host, gerenciando automaticamente certificados SSL e roteamento de subdomínios.
* **TLS SAN:** O certificado da API do cluster é gerado contemplando o IP Privado (VPC), o IP Público (EIP) e o `localhost`.

## Decisões de Arquitetura

### Por que MySQL Nativo?

Rodar o banco de dados fora do Kubernetes, diretamente no OS, simplifica a gestão de volumes e evita que o banco de dados seja despejado (evicted) em momentos de pressão de memória no cluster, garantindo maior estabilidade para a aplicação.

Porém, executar o banco de dados como um recurso a parte (RDS ou instância externa) aumentaria significativamente os custos da aplicação.

## Acesso e Utilização

### Conexão SSH

A instância é protegida e requer a chave `vockey` fornecida pelo laboratório ou acesso via SSM.

```bash
ssh -i labsuser.pem ubuntu@<ELASTIC_IP>

```

### Configuração de DNS

Crie uma entrada do tipo **A** no seu provedor de domínio apontando para o Elastic IP gerado.

* Host: `@` ou `*`
* Valor: `<ELASTIC_IP_OUTPUT>`
