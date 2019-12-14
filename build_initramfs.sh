#!/bin/bash

# Initramfs for dedicated server with disk setup like this:
# RAID (MDADM) -> LUKS -> LVM -> Root
#
# This will provide a dropbear ssh server which you can use to unlock the encrypted partition after assembling the RAID
# Afterwards it will enable the lvm volumes, mount the root volume and continue booting
# The OpenSSL HOST Keys have to be in the PEM format. Regenerate it with: 
# ssh-keygen -f /etc/ssh/ssh_host_ecdsa_key -t ecdsa -m PEM
# ssh-keygen -f /etc/ssh/ssh_host_rsa_key -t rsa -m PEM
# ssh-keygen -f /etc/ssh/ssh_host_dsa_key -t dsa -m PEM

cleanup_and_exit() {
    echo "Cleaning up..."
    rm -rf "${BUILD_DIR}"
    exit 1
}

set -e

trap cleanup_and_exit 0

OUTPUT_FILE="/boot/initramfs.img"

NIC="eth0"
IP="134.96.00.00"
NETMASK="255.255.255.224"
GATEWAY="134.46.00.00"

SSH_PORT="22"
SSH_AUTHORIZED_KEYS_PATH="/root/.ssh/authorized_keys"
SSH_HOST_ECDSA_KEY="/etc/ssh/ssh_host_ecdsa_key"
SSH_HOST_RSA_KEY="/etc/ssh/ssh_host_rsa_key"
LVM_ROOT_VOL="Vol/root"
LVM_ROOT_MAPPER="Vol-root"
LUKS_ROOT_MAPPER="raid"

BINS="/sbin/cryptsetup /usr/sbin/dropbear /sbin/lvm /sbin/mdadm"
BUSYBOX_HOST_PATH="/bin/busybox"

BUILD_DIR=$(mktemp -d)

echo "Building in ${BUILD_DIR}"

mkdir -p ${BUILD_DIR}/{run/cryptsetup,proc,dev,dev/pts,etc/dropbear,sbin,lib64,var/log,mnt/root,usr/sbin,usr/lib64,root,root/.ssh,bin,sys}

if [ ! -f $BUSYBOX_HOST_PATH ]; then
    echo "Busybox not found at ${BUSYBOX_HOST_PATH}"
    cleanup_and_exit
fi

cp -a ${BUSYBOX_HOST_PATH} ${BUILD_DIR}/bin/busybox

cp -a ${SSH_AUTHORIZED_KEYS_PATH} ${BUILD_DIR}/root/.ssh/authorized_keys
dropbearconvert openssh dropbear ${SSH_HOST_ECDSA_KEY} ${BUILD_DIR}/etc/dropbear/dropbear_ecdsa_host_key
dropbearconvert openssh dropbear ${SSH_HOST_RSA_KEY} ${BUILD_DIR}/etc/dropbear/dropbear_rsa_host_key

# These libs are required by dropbear. Otherwise login will not work and you will google for half an our to find out why
cp /lib64/libnss_compat.so.2 ${BUILD_DIR}/lib64/
cp /lib64/libnss_files.so.2 ${BUILD_DIR}/lib64/

# libgcc is required for unlocking the crypt root
cp -a /usr/lib/gcc/x86_64-pc-linux-gnu/$(gcc --version | grep ^gcc | sed 's/^.* //g')/libgcc* ${BUILD_DIR}/lib64/

echo "root:x:0:0:root:/root:/bin/sh" > ${BUILD_DIR}/etc/passwd
echo "root:*:::::::" > ${BUILD_DIR}/etc/shadow
echo "root:x:0:root" > ${BUILD_DIR}/etc/group
echo "/bin/sh" > ${BUILD_DIR}/etc/shells
chmod 640 ${BUILD_DIR}/etc/shadow

cat << EOF > ${BUILD_DIR}/etc/nsswitch.conf
passwd: files
shadow: files
group:  files
EOF

for FILE in $BINS; do
    if [ ! -f $FILE ]; then
        echo "Binary {$FILE} does not exists!"
        cleanup_and_exit
    fi
    
    echo "Copying ${FILE} to ${BUILD_DIR}/sbin"
    cp -a ${FILE} ${BUILD_DIR}/sbin

    echo "Copying libs"
    lddtree --copy-to-tree ${BUILD_DIR} ${FILE}
done

cat << EOF > ${BUILD_DIR}/init
#!bin/busybox sh

resuce_shell() {
    echo "Error occured. Dropping to rescue shell"
    exec sh
}

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir /dev/pts
mount -t devpts none /dev/pts

touch /var/log/lastlog

/bin/busybox --install -s

ifconfig ${NIC} ${IP} netmask ${NETMASK}
route add default gw ${GATEWAY}

sleep 1
clear

dropbear -p ${SSH_PORT} || rescue_shell

mdadm --assemble --scan || rescue_shell
clear

echo "Please unlock the root disk..."
echo "Press s to drop to a shell"

while [ ! -e /dev/mapper/${LUKS_ROOT_MAPPER} ]; do
    sleep 1
    read -t 0.5 -n 1 -s INPUT
    if [ "\${INPUT}" == "s" ]; then
        exec sh
    fi
done

lvm vgscan --mknodes || rescue_shell
lvm lvchange -a ly ${LVM_ROOT_VOL} || rescue_shell
lvm vgscan --mknodes || rescue_shell

mount -o ro /dev/mapper/${LVM_ROOT_MAPPER} /mnt/root || rescue_shell

killall dropbear
sleep 1

umount /dev/pts
umount /dev
umount /proc
umount /sys

echo "Switching root..."

exec switch_root /mnt/root /sbin/init || rescue_shell
EOF

chmod +x ${BUILD_DIR}/init

cat << EOF > ${BUILD_DIR}/root/unlock
#!/bin/sh

for x in \$(cat /proc/cmdline); do
    case "\${x}" in 
        crypt_root=*)
            CRYPT_ROOT=\${x#*=}
        ;;
    esac
done

echo "Unlocking \${CRYPT_ROOT} and mapping to /dev/mapper/${LUKS_ROOT_MAPPER}"

/sbin/cryptsetup luksOpen \$(findfs \${CRYPT_ROOT}) ${LUKS_ROOT_MAPPER}

echo "Bye bye!"
EOF

chmod +x ${BUILD_DIR}/root/unlock

pushd ${BUILD_DIR}
find . -print0 | cpio --null --create --verbose --format=newc | gzip --best > ${OUTPUT_FILE}
popd

echo "Success! ${OUTPUT_FILE} created!"
