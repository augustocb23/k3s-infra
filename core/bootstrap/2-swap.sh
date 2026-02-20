log INFO "Configuring swap with 2GB..."

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
