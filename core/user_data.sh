#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update
TOTAL_STEPS=5

echo
echo "--- Starting Core configuration ---"
echo

# 1. IP Forwarding
echo "--- [1/$TOTAL_STEPS] Configuring NAT... ---"
echo

# Enable packet forwarding in the Kernel
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Install iptables-services
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt-get install -y iptables-persistent

# Configure Masquerade (NAT) for all outgoing traffic on the main interface
INTERFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
netfilter-persistent save

echo "--- NAT configured ---"
echo

echo "--- [2/$TOTAL_STEPS] Configuring Swap... ---"

# create a swapfile with 2GB
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# persist in fstab to return after reboot
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# adjust the "aggressiveness" of swap usage (only if really necessary)
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf

echo "--- Swap configured ---"
echo

# 3. Mount data disk
echo "--- [3/$TOTAL_STEPS] Configuring data storage... ---"
echo

# Mount backup volume
# attached as /dev/sdf on AWS appears as /dev/nvme1n1 on T4g instances
DISK_DEVICE="/dev/nvme1n1"
MOUNT_POINT="/mnt/data"

while [ ! -b $DISK_DEVICE ]; do echo "Waiting for disk..."; sleep 2; done

if [ -z "$(blkid $DISK_DEVICE)" ]; then
  echo "New disk detected. Formatting ext4..."
  mkfs.ext4 $DISK_DEVICE
fi

mkdir -p $MOUNT_POINT
echo "$DISK_DEVICE $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

mkdir -p $MOUNT_POINT/mysql
mkdir -p $MOUNT_POINT/k3s-backup

echo "--- Data storage configured ---"
echo

# 4. MySQL
echo "--- [4/$TOTAL_STEPS] Installing MySQL... ---"
echo

mkdir -p /var/lib/mysql
echo "$MOUNT_POINT/mysql /var/lib/mysql none bind 0 0" >> /etc/fstab
mount -a

apt-get install -y mysql-server
sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

mysql -e "CREATE DATABASE IF NOT EXISTS kubernetes;"
mysql -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${db_password}'; FLUSH PRIVILEGES;"

cat <<EOF > /root/.my.cnf
[client]
user=root
password=${db_password}
EOF
chmod 600 /root/.my.cnf

echo "--- MySQL installed ---"
echo

# 5. K3s (Server Mode)
echo "--- [5/$TOTAL_STEPS] Installing k3s server... ---"
echo

# restore identity from backup (if exists)
BACKUP_DIR="$MOUNT_POINT/k3s-backup"
K3S_DIR="/var/lib/rancher/k3s/server"

if [ -d "$BACKUP_DIR/tls" ] && [ -d "$BACKUP_DIR/cred" ]; then
  echo "Identity backup found. Restoring..."
  
  mkdir -p $K3S_DIR
  mkdir -p $K3S_DIR/tls
  cp -r $BACKUP_DIR/tls/* $K3S_DIR/tls/
  
  mkdir -p $K3S_DIR/cred
  cp -r $BACKUP_DIR/cred/* $K3S_DIR/cred/
  
  cp $BACKUP_DIR/token $K3S_DIR/token
  chmod 600 $K3S_DIR/token
  
  echo "Identity backup restored."
else
  echo "No backup found. Proceeding with fresh setup..."
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
curl -sfL https://get.k3s.io | K3S_TOKEN="${k3s_token}" sh -s - server \
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
until kubectl get node k3s-core > /dev/null 2>&1; do echo "Waiting for k3s..."; sleep 2; done

echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

echo "Installing AWS Node Termination Handler..."
helm install aws-node-termination-handler aws-node-termination-handler \
  --repo https://aws.github.io/eks-charts \
  --namespace kube-system \
  --set enableSpotInterruptionDraining=true \
  --set deleteKubernetesNode=true \
  --set nodeSelector.lifecycle=spot \
  --set daemonset.tolerations[0].operator=Exists

echo "--- K3s installed ---"
echo
