#!/bin/bash
# Assume libvirt is installed, ready.

apt -y install python3-pyroute2 python3-xmltodict

cp /deployment/libvirtbridge/network /etc/libvirt/hooks/.

chown -R libvirt-qemu:libvirt-qemu /etc/libvirt/hooks
chmod -R ug+rw /etc/libvirt/hooks
chmod +x /etc/libvirt/hooks/network

systemctl restart libvirtd

echo " network netlink dgram," > /etc/apparmor.d/local/usr.sbin.libvirtd
systemctl restart apparmor
