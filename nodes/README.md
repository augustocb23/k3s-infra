# Módulo Nodes (Worker Nodes & Auto Scaling)

* [Arquitetura de Escala](#arquitetura-de-escala)
* [Configuração e Bootstrapping](#configura%C3%A7%C3%A3o-e-bootstrapping)
* [Estratégia de Custos (Spot)](#estrat%C3%A9gia-de-custos-spot)

Este módulo é responsável por provisionar a capacidade computacional (os "músculos") do cluster. Ele gerencia o ciclo de vida dos **Worker Nodes**, onde os Pods e containers das aplicações são efetivamente executados.

A infraestrutura foi desenhada para ser **efêmera, elástica e de baixo custo**, utilizando agressivamente Instâncias Spot da AWS gerenciadas por um Auto Scaling Group inteligente.

## Arquitetura de Escala

Os recursos são definidos em [`main.tf`](./main.tf)

### Auto Scaling Group (ASG)

Diferente do Core (que é uma instância única "pet"), os Nodes são tratados como "cattle" (gado).

* **Elasticidade:** O ASG monitora a saúde das instâncias e repõe automaticamente nós terminados pela AWS.
* **Localização:** Os nós são provisionados exclusivamente nas **Subnets Privadas**, garantindo que não sejam acessíveis diretamente da internet.

### Launch Template

Define o padrão de configuração das máquinas virtuais.

* **Imagem:** Ubuntu (Arquitetura x86_64/AMD64). Optou-se por x86 nesta camada para garantir maior disponibilidade de tipos de instância Spot antigos (`t2`, `t3`) e compatibilidade total com containers Docker.
* **Segurança:** O Security Group permite tráfego irrestrito dentro da VPC (comunicação com Core e outros Nodes) e saída para internet via NAT Instance (Core).

## Configuração e Bootstrapping

A inicialização é feita via `user_data`, codificado em Base64 no Launch Template.

### 1. Integração com Core

O script de inicialização ([`user_data_node.sh`](https://www.google.com/search?q=./user_data_node.sh)) recebe dinamicamente dois parâmetros vitais vindos do Terraform State do módulo Core:

1. **K3s URL:** O endpoint da API do Kubernetes (`https://<CORE_PRIVATE_IP>:6443`).
2. **K3s Token:** A senha compartilhada do cluster (recuperada de um *Output Sensitive* do Terraform).

### 2. Instalação do Agente

O script executa a instalação do K3s em modo **Agent**.

* O nó se registra automaticamente no Control Plane.
* A validação do certificado SSL é feita utilizando o Token compartilhado, permitindo comunicação segura mesmo com certificados auto-assinados (graças à configuração SAN no Core).

## Estratégia de Custos (Spot)

Esta é a camada onde ocorre a maior economia do projeto. Utilizamos uma **Mixed Instances Policy** para garantir que o cluster nunca fique sem máquinas, mesmo pagando até 90% menos.

### Diversificação de Instâncias

O ASG está configurado para tentar obter os seguintes tipos, na ordem de prioridade/custo:

1. `t3.small` / `t3a.small` (Preferencial)
2. `t3.medium` / `t3a.medium` (Fallback - Maior capacidade se as smalls acabarem)
3. `t2.small` (Legado - Alta disponibilidade em regiões antigas)

### Estratégia de Alocação

Utilizamos a estratégia `price-capacity-optimized`.
A AWS escolhe automaticamente o tipo de instância que oferece o menor preço **dentre aquelas com maior probabilidade de não serem interrompidas** no momento. Isso reduz drasticamente a chance de um Node ser desligado no meio de uma operação.
