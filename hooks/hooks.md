# Hooks

I've only written network for now.

## qemu
I'm considering a qemu hook to write out the domain xml to backup when the VM starts. This will ensure new VM config is backed up and all changes captured.

## network
In the initial version, the script assigns VLAN Tags to Libvirt Network ports.

### Use
1. Copy the network script to /etc/libvirt/hooks.
   - chown libvirt-qemu:libvirt-qemu network
   - chmod +x network
2. Restart Libvirt; systemctl restart libvirtd.
3. Make sure apparmor is allowing libvirt to use network netlink dgram.
   - Add **network netlink dgram,** to /etc/apparmor.d/local/usr.sbin.libvirtd.
   - Restart apparmor; systemctl restart apparmor
4. Create a Libirt network per the below.
```
<network>
  <name>br0</name>
  <forward mode='bridge'/>
  <bridge name='br0'/>
  <portgroup name = 'server-3'/>
  <portgroup name = 'dmz-4'/>
  <portgroup name = 'kubernetes-45'/>
  <portgroup name = 'zerotier-46'/>
</network>
```
   - Networks are defined as <name>-vid.
   - All networks are currently single vid. I'll add code and definition to support custom trunks if I require it someday.
   - No need to define an all-vid Trunk. The script will accept "all" and "trunk" in the Domain XML portgroup.
   - No need to define a default vid. The script will interpret a missing portgroup in the Domain XML as do-nothing.
   - Remember that Libvirt won't actually update a running Network.
      - Use the virsh update feature to add a PG on the fly.
      - Use the bridge vlan add command to add the vlan tag manually to the bridge port.\
5. Modify your domain XML to include the portgroup.
   - You only need to specify the vid's name, per the network definition.
   - In this example, I'm adding this NIC to portgroup Zerotier, which corresponds to VID 46 in the network definition.
```
    <interface type='bridge'>
      <mac address='52:54:00:e2:55:89'/>
      <source network='br0' portgroup='zerotier' portid='b36305d6-51d9-4f2c-9dfd-57405992ba29' bridge='br0'/>
      <target dev='vnet26'/>
      <model type='virtio'/>
      <link state='up'/>
      <alias name='net0'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
```
6. Start your VM/Domain to run the hook.
7. Verify with the command **bridge vlan show**. The last entry for vnet26 corresponds to my VM.
```
port              vlan-id  
eno1              1 PVID Egress Untagged
                  13
                  64
docker0           1 PVID Egress Untagged
bond1             11
                  65
vxlan0            3
                  4
                  45
                  46
br0               1 PVID Egress Untagged
                  64
                  65
vnet26            46 PVID Egress Untagged
```

### Challenges in coding
In the [Libvirt hook documentation](https://libvirt.org/hooks.html#etc-libvirt-hooks-network), it says about port-created:
> Later, when network is started and there's an interface from a domain to be plugged into the network, the hook script is called as:
> /etc/libvirt/hooks/network network_name port-created begin -
   
On my initial read, it seemed straightforward. The port is created, which means its added to the bridge. Right? No. The network and port XML shows up as expected but there is no evidence of the MAC address on the system until *after* the script exits. In my opinion, this isn't *port-created*, its *pre-port-creation*. No matter.

The root of the problem is that there is no way to update a bridge port that doesn't exist. Secondary, Libvirt will simply block *until it considers the script finished* so we can't simply wait for the port to appear on the bridge. Or can we?

How does Libvirt consider a hook script to be finished?
1. The script process has to return 0.
2. stdout/stderr need to end.
   
If we can achieve those two items in our script without actually quiting our script, then Libvirt will resume and create the bridge port and we can modify the port.

#### return 0
This part effectively detaches the script from the calling process, Libvirt. It feels a bit hacky but is quite effective.
```
try:
  pid = os.fork()
  if pid > 0:
    # Parent script must die.
    sys.exit(0)
  os.setsid()
except Exception as e:
  logging.debug(e)
  sys.exit(1)
```
os.fork() effectively duplicates the script. Two copies running. The parent (original script, called by Libvirt) has PID > 0 *and is attached to Libvirt*. The child has 0 and is set to be independent with the os.setsid() call. So kill the parent script, libvirt gets a return 0. Now we have a detached child that can wait for Libvirt to create the bridge port.

#### close out stdout/stderr
With the fork/setsid, it doesn't feel like this is necessary anymore but I haven't tested yet.

This is straight forward. Close the streams and file descriptors.
```
try:
  sys.stdout.close()
  sys.stderr.close()
  os.close(1)
  os.close(2)
except Exception as e:
  logging.debug(e)
  sys.exit(1)
```
