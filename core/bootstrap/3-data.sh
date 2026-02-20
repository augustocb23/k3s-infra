# Mount backup volume
# attached as /dev/sdf on AWS appears as /dev/nvme1n1 on T4g instances
DISK_DEVICE="/dev/nvme1n1"
MOUNT_POINT="/mnt/data"

while [ ! -b $DISK_DEVICE ]; do log INFO "Waiting for disk..."; sleep 2; done

if [ -z "$(blkid $DISK_DEVICE)" ]; then
  log INFO "New disk detected. Formatting ext4..."
  mkfs.ext4 $DISK_DEVICE
fi

mkdir -p $MOUNT_POINT
echo "$DISK_DEVICE $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a

mkdir -p $MOUNT_POINT/mysql
mkdir -p $MOUNT_POINT/k3s-backup

log INFO "Disk mounted at $MOUNT_POINT"
