# Ubuntu deploy

I got tired of having to click through the Ubuntu installer so I automated it.

## Requirements
Google Cloud CLI
* Run gcloud init
* Run gcloud auth application-default login

Google Cloud SDK and crc32
* pip install google-cloud-secret-manager
* pip install google-crc32c

Libvirt and Rados Python modules
* apt install python3-libvirt python3-rbd
User password hash and root public key in Google Secret Manager.

## Tasks done
1. Download Ubuntu KVM Cloud Image if newer than the one downloaded.
2. Copy image to RBD volume.
3. Create CloudInit.
    * Create Netplan with appropriate network info.
    * Create user data with user/password and SSH key for root.
    * SSH key and user password hash are pulled from Google Secret Manager.
    * Create VFAT - ISO doesn't detect properly.
4. Create KVM Domain XML.
    * Specify Cloud Init VFAT volume.
    * Specify RBD volume.
5. Deploy on specfied host.

## Challenges
There is some race condition detecting ISOs. By the time the CDROM is online, Cloud Init has long finished detection. Switched to VFAT.
