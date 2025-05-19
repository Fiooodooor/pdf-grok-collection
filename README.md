# pdf-grok-collection

## "Deploying Ephemeral Kubernetes with SR-IOV on Harvester"

https://x.com/i/grok/share/UZUEebJmIIqhEFdSZDUZYukDe

### I) I have a Harvester Cluster, RKE2 up and running and accessible under ip address 10.123.235.200/22. I have also Rancher standalone deployed as well as Argo stack.
Everything is running on Intel based CPU (Xeon) with VT-d enabled and ready to use Intel E810 network cards in each node with SRIOV support enabled.
I want to deploy a 3 node ephemeral Kubernetes cluster on Virtual Machines provisioned on demand, that uses custom build of DPDK and Ice drivers for E810 hardware network interfaces from host I a way that I could urilize it as Virtual NIC and/or VF driver inside the VM.
I need the best known method to do it in an automated way, for example using ansible, helm or just argo. The purpose of this is to test Intel ICE drivers on top of witch MTL and MCM from https://www.github.com/OpenVisualCloud are being run.

### II) Reiterate above, but focus on NIC part utilizing Intel Ethernet Operator and/or SR-IOV Network Device Plugin for Kubernetes.


## "Ansible Script for PXE Boot via BMC LAN"

https://x.com/i/grok/share/Z4Cxy97XDEjGbWMAnJEptkSln

### 1) Write a script for me using ansible for enabling PXE boot using remote BMC LAN connection. It should be set to use specific interface and boot from - if it is possible - from specific address - 10.123.232.180.

### 2) I have a harvester cluster up and running and accessible under ip address 10.123.235.200/22. I want to deploy a 3 node kubernetes cluster running on virtual machines that uses hardware network interface from host in a pass through or a sriov virtual interface. I need a best known method to do it in an automated way, for example using ansible.


