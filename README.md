# K3s Lab usando AWS Academy (Frugal Architecture)

Este projeto provisiona um cluster Kubernetes (K3s) funcional e resiliente na AWS, projetado especificamente para compatibilidade com o ambiente restrito da AWS Academy e otimização agressiva de custos (arquitetura frugal).

## Visão Geral da Arquitetura

O projeto adota uma arquitetura monolítica a fim de reduzir custos de infraestrutura. A instância Core desempenha múltiplos papéis críticos que, em ambientes corporativos tradicionais, estariam separados:

1. **Control Plane & Database:** O servidor K3s e seu banco de dados de estado rodam na mesma instância. Isso elimina o custo de um banco de dados gerenciado (como RDS), com o trade-off de compartilhar recursos de memória e CPU. Utiliza um volume secundário para garantir a preservação dos dados caso o ambiente precise ser reiniciado.
2. **NAT Instance:** O Core atua como gateway de saída para as subnets privadas, eliminando a necessidade de um NAT Gateway gerenciado pela AWS (uma economia estimada de ~$33/mês).
3. **Bastion Host:** Serve como ponto único de entrada SSH seguro para administração dos workers (nodes).

## Estrutura de Módulos (Terraform)

O projeto utiliza o HCP Terraform (antigo Terraform Cloud) e está dividido em camadas independentes para facilitar a manutenção e o ciclo de vida dos recursos.

### 1. Camada de Networking ([`shared`](./shared/README.md))

Responsável pela fundação da rede.

Provisiona a VPC, Subnets Públicas e Privadas, Internet Gateway e Repositório ECR.
Prepara as tabelas de roteamento para a estratégia de NAT Instance.

### 2. Camada do Control Plane ([`core`](./core/README.md))

Provisiona a instância principal (On-Demand).

Configura o K3s em modo Server, aplica Taints para evitar agendamento de cargas de trabalho de aplicação nesta rede crítica e configura o IP estático privado para garantir a reconexão dos nós em caso de substituição da instância.

Essa instância também provisiona um banco de dados MySQL.
A senha do usuário `root` é gerada e cadastrada no Secrets Manager da AWS.

### 3. Camada de Computação ([`nodes`](./nodes/README.md))

Gerencia o Auto Scaling Group (ASG) de instâncias Spot.

Inclui scripts de "Auto-Join" para conexão automática ao cluster e um daemon de monitoramento (Node Termination Handler) para drenar nós graciosamente antes da interrupção do serviço Spot pela AWS.

## Limitações Conhecidas e Riscos

- **Recursos de Memória (OOM):** Devido ao uso de uma instância `t4g.small` (2GB RAM) para o Core, não foram configurados limites rígidos de conexão para o banco de dados interno. Existe um risco residual de *Out Of Memory* (OOM) caso o cluster escale para muitos nós ou sofra alta carga na API. O Taint `node-role.kubernetes.io/master:NoSchedule` foi aplicado para mitigar este risco, impedindo que aplicações de usuário consumam memória do Control Plane.
- **Ponto único de falha:** Esta arquitetura não possui Alta Disponibilidade (HA) no Control Plane (Single Master). A perda da instância Core resulta em indisponibilidade da API ou do banco de dados.

## Operação e Debug

Alguns comandos úteis (em PowerShell) para acessar e testar as instâncias criadas.

### Acesso SSH ao Core

Utilize a chave `labsuser.pem` fornecida pelo console da AWS Academy.
Copie o IP Público através do console da AWS ou dos outputs do Terraform.

```powershell
ssh -i .\labsuser.pem ubuntu@$corePublicIp
```

### Acesso SSH aos Nodes

Os nodes não têm IP público. Para acessá-los, você deve usar o Core como "pulo" (Jump Host).
Você precisará do IP público do Core e do IP privado do node.

Primeiro envie a chave para o core:

```powershell
scp -i .\labsuser.pem .\labsuser.pem ubuntu@$($corePublicIp):/home/ubuntu/labsuser.pem
```

No terminal do Core, ajuste as permissões da chave e utilize-a para acessar o node:

```bash
chmod 600 labsuser.pem
ssh -i labsuser.pem ubuntu@$NODE_PRIVATE_IP
```

### Acessando logs de inicialização

Durante a criação da instância é executado o script `user_data.sh`.
O log de inicialização/instalação (do Core ou dos nodes) pode ser acessado com o seguinte comando:

```bash
cat /var/log/user-data.log
```

### Acesso ao cluster (`kubectl`)

Baixe o arquivo de configuração do kubernetes (`kube-config`):

```powershell
scp -i .\labsuser.pem ubuntu@$($corePublicIp):/etc/rancher/k3s/k3s.yaml kube-config
```

Altere a URL do servidor para o IP público do Core:

```powershell
(Get-Content .\kube-config) -replace "127.0.0.1", $corePublicIp | Set-Content .\kube-config
```

Altere a variável de ambiente `KUBECONFIG` para o novo arquivo (válido somente para sessão atual):

```powershell
$env:KUBECONFIG = '.\kube-config'
```

### Teste do cluster (Pod Info)

```powershell
helm upgrade --install podinfo podinfo `
  --repo https://stefanprodan.github.io/podinfo `
  --set service.type=ClusterIP `
  --set ingress.enabled=true `
  --set ingress.className=traefik `
  --set ingress.hosts[0].host="" `
  --set ingress.hosts[0].paths[0].path="/" `
  --set ingress.hosts[0].paths[0].pathType="ImplementationSpecific" `
  --set replicaCount=3
```

Acesse o IP público no browser:

```powershell
Start-Process "http://$corePublicIp"
```
