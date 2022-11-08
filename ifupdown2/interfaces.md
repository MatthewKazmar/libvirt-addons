# Interfaces file for Libvirt hosts

## ifupdown2
[ifupdown2](https://github.com/CumulusNetworks/ifupdown2) is available in the apt repo on Debian and perhaps others. Ubuntu has to build with the Makefile.

## Blocker
Running ifup -a after making a modification to the config, such as VLAN tagging, removes the KVM interfaces from the bridge. Restarting the VM fixes the issue. Restarting Libvirt may also fix the issue.

## Custom eventually?
I like the idea of being able to configure both Libvirt VM vids and the network itself from the same source of truth. Ideally, I could leave the default Ubuntu netplan config with a single admin IP then build the other config around it, perhaps as a network started Libvirt hook.

## Core requirements
- a config file that can be shared between hosts. ifdown2 supports [Mako Templates]([https://github.com/CumulusNetworks/ifupdown2](https://www.makotemplates.org/) (really Python), so its easy.
- configuration of a VLAN-aware bridge directly with no helpers.
- configuration of a multi-vid static vtep with connectivity to all hosts.

ifupdown2 checks the above boxes nicely.

## Challenges
Using host IPs on vlan-aware bridges is not clear from the documentation. Some documentation suggests using a veth pair, which is just ugly and less performant. After some experimentation, its too easy.
- For host IPs with a VLAN tag, create VLAN interfaces with the bridge as the vlan-raw-device. This is identical to configuring an ethernet NIC.
- For host IPs without a VLAN tag/native, its the same as a non-VLAN aware bridge. Add the IP to the Bridge device.
