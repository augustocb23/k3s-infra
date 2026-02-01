#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update

echo "--- Starting Core configuration ---"

# 1. IP Forwarding
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

# 2. K3s (Server Mode)
PRIVATE_IP=$(hostname -I | awk '{print $1}')
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/public-ipv4)

curl -sfL https://get.k3s.io | K3S_TOKEN="${k3s_token}" sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-name k3s-core \
  --tls-san "$PRIVATE_IP" \
  --tls-san "$PUBLIC_IP"

echo "--- K3s installed ---"

# 3. MySQL
# Mount database volume
# attached as /dev/sdf on AWS appears as /dev/nvme1n1 on T4g instances
DISK_DEVICE="/dev/nvme1n1"

while [ ! -b $DISK_DEVICE ]; do echo "Waiting for disk..."; sleep 2; done

if [ -z "$(blkid $DISK_DEVICE)" ]; then
  echo "New disk detected. Formatting ext4..."
  mkfs.ext4 $DISK_DEVICE
fi

mkdir -p /var/lib/mysql
echo "$DISK_DEVICE /var/lib/mysql ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

# Install MySQL server
apt-get install -y mysql-server
sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

echo "--- MySQL installed ---"
