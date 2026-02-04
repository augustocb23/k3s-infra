#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update
TOTAL_STEPS=6

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

# 6. Poor Man's Autoscaler
echo "--- [6/$TOTAL_STEPS] Configuring autoscaler... ---"
echo

echo "Installing AWS CLI..."
apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

echo "Creating autoscaler script..."
cat <<'EOF' > /usr/local/bin/simple-scaler.sh
#!/bin/bash

ASG_NAME="${asg_name}"
LOG_FILE="/var/log/k3s-scaler.log"

# check for NotReady nodes and remove them if missing in AWS (janitor)
CLEANUP_DONE=0
NOT_READY_NODES=$(kubectl get nodes --no-headers | grep "NotReady" | awk '{print $1}')
for NODE in $NOT_READY_NODES; do
    echo "$(date) - [WARN] Node $NODE is NotReady. Checking if it still exists..." >> $LOG_FILE
    
    INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE.ec2.internal" "Name=instance-state-name,Values=running,pending" --query "Reservations[0].Instances[0].State.Name" --output text)
    if [ "$INSTANCE_STATE" == "None" ] || [ -z "$INSTANCE_STATE" ]; then
        echo "$(date) - [INFO] Node '$NODE' is NotReady in K8s and MISSING. Deleting node..." >> $LOG_FILE
        kubectl delete node $NODE > /dev/null 2>&1
    else
        echo "$(date) - [INFO] Node $NODE is NotReady but still exists (State: $INSTANCE_STATE). Waiting for recovery." >> $LOG_FILE
    fi
done

if [ "$CLEANUP_DONE" -eq 1 ]; then
    echo "$(date) - [INFO] Janitor finished. Waiting up for Scheduler to rebalance..." >> $LOG_FILE
    
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o name | \
    xargs -r kubectl wait --for=condition=PodScheduled --timeout=15s > /dev/null 2>&1
    
    echo "$(date) - [INFO] Rebalancing wait finished." >> $LOG_FILE
fi

# scale up if there are pending pods
PENDING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$PENDING_PODS" -gt 0 ]; then
    echo "$(date) - [INFO] Detected $PENDING_PODS pending pods. Checking capacity..." >> $LOG_FILE
    CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)
    MAX_SIZE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].MaxSize" --output text)
    
    if [ "$CURRENT_CAPACITY" == "None" ] || [ -z "$CURRENT_CAPACITY" ]; then
        echo "$(date) - [ERROR] Could not read ASG '$ASG_NAME'. Check permissions or naming." >> $LOG_FILE
        exit 1
    fi

    if [ "$CURRENT_CAPACITY" -lt "$MAX_SIZE" ]; then
        NEW_CAPACITY=$((CURRENT_CAPACITY + 1))
        echo "$(date) - [INFO] Scaling up from $CURRENT_CAPACITY to $NEW_CAPACITY..." >> $LOG_FILE
        
        aws autoscaling set-desired-capacity --auto-scaling-group-name $ASG_NAME --desired-capacity $NEW_CAPACITY
        
        if [ $? -eq 0 ]; then
             echo "$(date) - [SUCCESS] Scaling command sent." >> $LOG_FILE
        else
             echo "$(date) - [ERROR] Failed to send scaling command." >> $LOG_FILE
        fi
        exit 0
    else
        echo "$(date) - [WARN] Max node limit ($MAX_SIZE) reached. Cannot scale up." >> $LOG_FILE
        exit 0
    fi
else
    echo "$(date) - [INFO] Cluster healthy. No pending pods." >> $LOG_FILE
fi

# scale down if nodes are underutilized
echo "$(date) - [INFO] Checking for underutilized nodes..." >> $LOG_FILE
CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)

if [ "$CURRENT_CAPACITY" -le 1 ]; then
    echo "$(date) - [INFO] Only one node present. Skipping scale down." >> $LOG_FILE >> $LOG_FILE
    exit 0
fi

NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | grep -v "master" | awk '{print $1}')
for NODE in $NODES; do
    NON_SYSTEM_PODS=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$NODE --no-headers | grep -v "kube-system" | grep -v "Completed" | grep -v "Terminating" | wc -l)

    if [ "$NON_SYSTEM_PODS" -eq 0 ]; then
        echo "$(date) - [INFO] Node '$NODE' appears empty (0 application pods). Preparing to terminate..." >> $LOG_FILE
        kubectl cordon $NODE
        
        INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE.ec2.internal" --query "Reservations[0].Instances[0].InstanceId" --output text)
        if [ -z "$INSTANCE_ID" ]; then
            echo "$(date) - [ERROR] Could not resolve Instance ID for node $NODE. Skipping." >> $LOG_FILE
            kubectl uncordon $NODE
            continue
        fi

        echo "$(date) - [INFO] Terminating instance '$INSTANCE_ID' (node '$NODE') and decrementing capacity..." >> $LOG_FILE
        aws autoscaling terminate-instance-in-auto-scaling-group --instance-id $INSTANCE_ID --should-decrement-desired-capacity > /dev/null
        
        if [ $? -eq 0 ]; then
            echo "$(date) - [SUCCESS] Scale down command sent for '$INSTANCE_ID'. Removing node '$NODE' from cluster." >> $LOG_FILE
            kubectl delete node $NODE > /dev/null 2>&1
            exit 0 # Only kill one node per execution cycle for safety
        else
            echo "$(date) - [ERROR] Failed to terminate instance. Uncordoning node." >> $LOG_FILE
            kubectl uncordon $NODE
        fi
    fi
done
EOF

chmod +x /usr/local/bin/simple-scaler.sh
echo "* * * * * root /usr/local/bin/simple-scaler.sh" >> /etc/crontab

echo "--- Autoscaler configured ---"
echo
