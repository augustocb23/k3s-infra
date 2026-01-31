#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- Starting Core configuration ---"

# 1. IP Forwarding
# Enable packet forwarding in the Kernel
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Install iptables-services
apt-get update && apt-get install -y iptables-persistent

# Configure Masquerade (NAT) for all outgoing traffic on the main interface
INTERFACE=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE

netfilter-persistent save

echo "--- NAT configured ---"

# 2. K3s (Server Mode)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" sh -

echo "--- K3s installed ---"

# 3. MySQL
apt-get install -y mysql-server
sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${db_password}';"
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

echo "--- MySQL installed ---"
