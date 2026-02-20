mkdir -p /var/lib/mysql
echo "$MOUNT_POINT/mysql /var/lib/mysql none bind 0 0" >> /etc/fstab
mount -a

apt-get install -y mysql-server
sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql

mysql -e "CREATE DATABASE IF NOT EXISTS kubernetes;"
mysql -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASSWORD';"
mysql -e "ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$DB_PASSWORD';"
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASSWORD'; FLUSH PRIVILEGES;"

cat <<EOF > /root/.my.cnf
[client]
user=root
password=$DB_PASSWORD
EOF
chmod 600 /root/.my.cnf
