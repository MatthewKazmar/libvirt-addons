#!/usr/bin/python3
# Deploys an updated Ubuntu image with some base packages.

import sys, argparse, ipaddress, libvirt, pycdlib, requests, re, subprocess
import hashlib, os, rados, rbd, shutil
#from io import BytesIO
from google.cloud import secretmanager
import google_crc32c

DEPLOYROOT='/deployment/ubuntu-base'
USERHASH_ID='' # Google Secrets Manager ID; hash of user password
ROOTPUBLIC_ID='' # Google Secrets Manager ID; Public key of root account

#########################################################################
# Check for existing RBD image
#########################################################################
def checkRbd(name):
  cluster = rados.Rados(conffile='/etc/ceph/ceph.conf')
  cluster.connect()
  ioctx = cluster.open_ioctx('libvirt-pool')
  rbd_instance = rbd.RBD()
  images = rbd_instance.list(ioctx)

  if name in images:
    return True
  else:
    return False

#########################################################################
# SHA 256 hash
#########################################################################
def sha256sum(path):
    h  = hashlib.sha256()
    b  = bytearray(128*1024)
    mv = memoryview(b)
    with open(path, 'rb', buffering=0) as f:
        while n := f.readinto(mv):
            h.update(mv[:n])
    return h.hexdigest()

#########################################################################
# Get latest ubuntu
#########################################################################
def getUbuntu():

  ubuntuPath = f'{DEPLOYROOT}/ubuntu-latest.qcow2'
  downloadNeeded = True
  if os.path.exists(ubuntuPath):
    # Check if the current is downloaded.
    # Get hash
    print("Checking Ubuntu hash.")
    url = 'https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS'
    r = requests.get(url, allow_redirects=True)
    p = re.compile('([0-9a-f]{64}) .jammy-server-cloudimg-amd64-disk-kvm.img')
    webHash = p.findall(r.text)[0]
    print(f' Web hash: {webHash}')

    # Get hash of current file
    fileHash = sha256sum(ubuntuPath)
    print(f' File hash: {fileHash}')

    if fileHash == webHash:
      downloadNeeded = False

  if downloadNeeded:
    print("Downloading latest Ubuntu.")
    url = 'http://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img'
    r = requests.get(url, allow_redirects=True)
    open(f'{DEPLOYROOT}/ubuntu-latest.qcow2', 'wb').write(r.content)

  return ubuntuPath

#########################################################################
# Get Secret - retrieve secret from Google Secret Manager
#########################################################################
def getSecret(secretId):
  """
  Access the payload for the given secret version if one exists. The version
  can be a version number as a string (e.g. "5") or an alias (e.g. "latest").
  """

  # Create the Secret Manager client.
  client = secretmanager.SecretManagerServiceClient()

  # Access the secret version.
  try:
    response = client.access_secret_version(request={"name": secretId})
  except Exception as e:
    print(f'Trying to get secret with URI {secretId}.\n{e}')
    sys.exit(1)

  # Verify payload checksum.
  crc32c = google_crc32c.Checksum()
  crc32c.update(response.payload.data)
  if response.payload.data_crc32c != int(crc32c.hexdigest(), 16):
      print(f"Secret with URI {secretId} is corrupt.")
      sys.exit(1)

  return response.payload.data.decode()

#########################################################################
# Build CloudInit
#########################################################################
def buildCloudInit(name, ipcidr):

  # Conversions
  ip = str(ipcidr)
  defaultGw = str(ipcidr.network[1])
  seedPath = f'{DEPLOYROOT}/{name}'
  seedImg = f'{seedPath}/seed.img'

  # Get credentials
  userHash = getSecret(USERHASH_ID)
  rootPublic = getSecret(ROOTPUBLIC_ID)

  # Create and mount VFAT
  if not os.path.exists(seedPath):
    print(f'Create dir {seedPath}.')
    os.mkdir(f'{seedPath}')

  print(f'Create sparse file {seedImg}.')
  myfile = open(seedImg, 'wb')
  myfile.truncate(2048000)
  myfile.close()

  cmd = f'mkfs.vfat -n CIDATA {seedImg}'
  print(f'Running cmd: {cmd}')
  subprocess.run(cmd.split(' '))

  cmd = f'mount -t vfat {seedImg} /mnt'
  print(f'Running cmd: {cmd}')
  subprocess.run(cmd.split(' '))

  # New ISO
  #iso = pycdlib.PyCdlib()
  #iso.new(vol_ident='cidata', interchange_level=3, joliet=True, rock_ridge='1.09')

  # Cloud Init Cfg/user-data
  # Probably change the username
  userData = f"""#cloud-config
hostname: {name}
manage_etc_hosts: true
users:
  - name: mattk
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: users, admin
    lock_passwd: false
    passwd: {userHash}
  - name: root
    ssh_authorized_keys:
      - {rootPublic}
ssh_pwauth: true
disable_root: false
disable_root_opts: ""
packages:
  - qemu-guest-agent
  - frr
  - plocate
  - bridge-utils
  - nfs-common
  - nfs-kernel-server
package_upgrade: true
package_reboot_if_required: true"""
  # Write out
  print(f"Adding user-data to {seedImg}.")
  myfile = open('/mnt/user-data',"w")
  myfile.write(userData)
  myfile.close()

  # Netplan
  # Probably change the details
  networkConfig = f"""network:
  version: 2
  ethernets:
    enp1s0:
      addresses:
      - {ip}
      nameservers:
        addresses:
        - 192.168.255.3
        - 192.168.255.2
        - 192.168.255.5
        search:
        - kazmar.org
      routes:
        - to: 0.0.0.0/0
          via: {defaultGw}"""
  # Write out
  print(f"Adding network-config to {seedImg}.")
  myfile = open('/mnt/network-config',"w")
  myfile.write(networkConfig)
  myfile.close()

  # Metadata
  metaData = """{
"instance-id": "iid-local01".
"dsmode": "local"
}"""

  # Write out
  print(f'Adding meta-data to {seedImg}.')
  myfile = open('/mnt/meta-data',"w")
  myfile.write(metaData)
  myfile.close()

  # Unmount VFAT
  cmd = 'umount -l /mnt'
  print(f'Running cmd: {cmd}')
  subprocess.run(cmd.split(' '))

  # Fix permissions
  print('Assigning permissions to libvirt-qemu:libvirt-qemu for seed.img.')
  shutil.chown(seedPath, user='libvirt-qemu', group='libvirt-qemu')
  shutil.chown(seedImg, user='libvirt-qemu', group='libvirt-qemu')

  # # Add to iso
  # iso.add_fp(BytesIO(bytes(userData, 'utf-8')), len(userData), '/USERDATA.;1', rr_name="user-data", joliet_path="/user-data")
  # iso.add_fp(BytesIO(bytes(networkConfig, 'utf-8')), len(networkConfig), '/NETWORKCONFIG.;1', rr_name="network-config", joliet_path="/network-config")
  # iso.add_fp(BytesIO(bytes(metaData, 'utf-8')), len(metaData), '/METADATA.;1', rr_name="meta-data", joliet_path="/meta-data")

  # # Write out and close
  # iso.write(isoPath)
  # iso.close()

  return seedImg

#########################################################################
# Deploy VM: Define, start, autostart
#########################################################################
def buildDomainXml(name, seedImg, portgroup):

  pgXml = f' portgroup="{portgroup}"'

  return f"""
<domain type="kvm">
  <name>{name}</name>
  <metadata><libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0"><libosinfo:os id="http://ubuntu.com/ubuntu/22.04"/></libosinfo:libosinfo></metadata>
  <memory>4194304</memory>
  <currentMemory>4194304</currentMemory>
  <vcpu>2</vcpu>
  <os><type arch="x86_64" machine="q35">hvm</type><boot dev="hd"/></os>
  <features><acpi/><apic/></features>
  <cpu mode="host-passthrough"/>
  <clock offset="utc"><timer name="rtc" tickpolicy="catchup"/><timer name="pit" tickpolicy="delay"/><timer name="hpet" present="no"/></clock>
  <pm><suspend-to-mem enabled="no"/><suspend-to-disk enabled="no"/></pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='network' device='disk'><driver name='qemu' type='raw'/><auth username='libvirt'><secret type='ceph' usage='client.libvirt secret'/></auth><source protocol='rbd' name='libvirt-pool/{name}'><host name='captures' port='6789'/><host name='plastic' port='6789'/><host name='filling' port='6789'/></source><target dev="vda" bus="virtio"/></disk>
    <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seedImg}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
    <controller type="usb" model="qemu-xhci" ports="15"/>
    <interface type="network"><source network="br0"{pgXml}/><model type="virtio"/></interface>
    <console type="pty"/>
    <channel type="unix"><source mode="bind"/><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
    <input type="tablet" bus="usb"/>
    <graphics type="vnc" port="-1" listen="0.0.0.0"/>
    <video><model type="vga"/></video>
    <memballoon model="virtio"/>
    <rng model="virtio"><backend model="random">/dev/urandom</backend></rng>
  </devices>
</domain>"""

#########################################################################
# Main
#########################################################################

# Command line arguments
flags = argparse.ArgumentParser(description = "# Deploys an updated Ubuntu image with some base packages.")
flags.add_argument('--name', '-n', dest='name', action='store', required=True, help='Name of VM.')
flags.add_argument('--ip', '-i', dest='ip', action='store', required=True, help='The VM''s IP in CIDR notation.')
flags.add_argument('--vlan', '-v', dest='vlan', action='store', required=False, help='VM''s VLAN name.')
flags.add_argument('--host', dest='host', action='store', required=False, help='Host to install VM on.')
args = flags.parse_args()
argsDict = vars(args)

name = argsDict['name']
ipcidr = ipaddress.IPv4Interface(argsDict['ip'])
host = argsDict['host']
portgroup = argsDict['vlan']

#Connect to Libvirt
if host == None:
  uri = 'qemu:///system'
else:
  uri = 'qemu+ssh://{host}/system'

try:
    conn = libvirt.open(uri)
except libvirt.libvirtError as e:
    print('Failed to open connection to KVM.')
    print(repr(e))
    sys.exit(1)

# Check if Domain is defined.
domains = conn.listAllDomains(0)
for domain in domains:
  if name == domain.name():
    print(f'Domain {name} exists. Please undefine and destroy before trying again.')
    sys.exit(1)

# Check RBD
if checkRbd(name):
  print(f'RBD image for {name} exists. Please remove before trying this.')
  sys.exit(1)

# Cloud Init
seedImg = buildCloudInit(name, ipcidr)
print(f'Cloud-init VFAT created at: {seedImg}')

# VM/Domain XML
domainXml = buildDomainXml(name, seedImg, portgroup)

# Get Ubuntu latest
ubuntuPath = getUbuntu()

# Copy to rbd
cmd = f'qemu-img convert -O raw {ubuntuPath} rbd:libvirt-pool/{name} -p'
print(f'Running cmd:\n  {cmd}\n This could take a moment.\n')
subprocess.run(cmd.split(' '))

#Connect to Libvirt
try:
    conn = libvirt.open(uri)
except libvirt.libvirtError as e:
    print('Failed to open connection to KVM.')
    print(repr(e))
    sys.exit(1)

# Deploy VM
try:
  dom = conn.defineXMLFlags(domainXml, 0)
except libvirt.libvirtError as e:
  print(f'Failed to create domain {name} from an XML definition.\n{e}')
  sys.exit(1)

if dom.create() < 0:
  print(f'Can''t boot domain {name}.')
  sys.exit(1)

dom.setAutostart(1)

print(f'All done deploying Ubuntu domain {name}.')

# Done, close
conn.close()
