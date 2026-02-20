# restore identity from backup (if exists)
BACKUP_DIR="$MOUNT_POINT/k3s-backup"
K3S_DIR="/var/lib/rancher/k3s/server"

if [ -d "$BACKUP_DIR/tls" ] && [ -d "$BACKUP_DIR/cred" ]; then
  log INFO "Identity backup found. Restoring..."
  
  mkdir -p $K3S_DIR
  mkdir -p $K3S_DIR/tls
  cp -r $BACKUP_DIR/tls/* $K3S_DIR/tls/
  
  mkdir -p $K3S_DIR/cred
  cp -r $BACKUP_DIR/cred/* $K3S_DIR/cred/
  
  cp $BACKUP_DIR/token $K3S_DIR/token
  chmod 600 $K3S_DIR/token
  
  log INFO "Identity backup restored."
else
  log INFO "No backup found. Proceeding with fresh setup..."
  rm -rf $K3S_DIR/tls $K3S_DIR/cred $K3S_DIR/token
fi

# configure Traefik
mkdir -p /var/lib/rancher/k3s/server/manifests
cat <<EOF > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      annotations:
        # Allow the LoadBalancer (svclb) to run on Master nodes
        "svccontroller.k3s.cattle.io/tolerations": '[{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]'
EOF

# get instance metadata
PRIVATE_IP=$(hostname -I | awk '{print $1}')
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)

# install k3s server
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-name k3s-core \
  --tls-san "$PRIVATE_IP" \
  --tls-san "$PUBLIC_IP" \
  --node-taint node-role.kubernetes.io/master=true:NoSchedule \
  --kubelet-arg="fail-swap-on=false" \
  --datastore-endpoint="mysql://root:${db_password}@tcp(127.0.0.1:3306)/kubernetes"

mkdir -p $BACKUP_DIR/tls $BACKUP_DIR/cred
cp -r -u /var/lib/rancher/k3s/server/tls/* $BACKUP_DIR/tls/
cp -r -u /var/lib/rancher/k3s/server/cred/* $BACKUP_DIR/cred/
cp -u /var/lib/rancher/k3s/server/token $BACKUP_DIR/token

# install addons
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get node k3s-core > /dev/null 2>&1; do log INFO "Waiting for k3s..."; sleep 2; done

log INFO "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

log INFO "Installing AWS Node Termination Handler..."
helm install aws-node-termination-handler aws-node-termination-handler \
  --repo https://aws.github.io/eks-charts \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set deleteKubernetesNode=true \
  --set nodeSelector.lifecycle=spot \
  --set daemonset.tolerations[0].operator=Exists
