

#!/bin/bash

# Exit on any error
set -e

# Node-specific identifier (0 or 1), pass as argument (e.g., ./script.sh 0)
NODE_ID=${1:-0}
NUM_NICS=4
PORTS_PER_NIC=2
TOTAL_PORTS=8
HUGEPAGES_SIZE="1G"
HUGEPAGES_COUNT=256  # 256x1GiB = 256GiB total, split across NUMA nodes
DPDK_LCORES_PER_PORT=4  # 4 logical cores per 100G port
MTL_THREADS_PER_PORT=2  # MTL threads per port

# Detect CPU cores and NUMA nodes
TOTAL_CORES=$(nproc)
NUMA_NODES=$(lscpu | grep "NUMA node(s)" | awk '{print $3}')
CORES_PER_NODE=$((TOTAL_CORES / NUMA_NODES))

# Assign NICs and cores NUMA-aware (assuming NICs are evenly split)
declare -A NIC_NUMA_MAP
NIC_NUMA_MAP[0]=0  # NIC 0 on NUMA 0
NIC_NUMA_MAP[1]=0  # NIC 1 on NUMA 0
NIC_NUMA_MAP[2]=1  # NIC 2 on NUMA 1
NIC_NUMA_MAP[3]=1  # NIC 3 on NUMA 1

# Step 1: Update system and install dependencies
apt update -y
apt install -y linux-modules-extra-$(uname -r) build-essential libnuma-dev python3-pyelftools git numactl

# Step 2: Configure BIOS settings via AMI MegaRAC SP-X BMC (assumes BMC CLI access)
# Replace BMC_IP, BMC_USER, BMC_PASS with your actual creds
BMC_IP="192.168.1.100"
BMC_USER="admin"
BMC_PASS="password"
BMC_CLI="ipmitool -I lanplus -H ${BMC_IP} -U ${BMC_USER} -P ${BMC_PASS}"

# Disable power-saving features, enable SR-IOV, optimize memory
${BMC_CLI} raw 0x30 0x02 0x01 0x00  # Disable C-states
${BMC_CLI} raw 0x30 0x02 0x03 0x00  # Disable P-states
${BMC_CLI} raw 0x30 0x05 0x01 0x01  # Enable SR-IOV
${BMC_CLI} raw 0x30 0x07 0x02 0x01  # Set memory frequency to max (assume 3200MHz)
${BMC_CLI} raw 0x30 0x08 0x01 0x00  # Disable Hyper-Threading for DPDK predictability

# Configure PXE boot on the first Intel E810 NIC (port 0)
${BMC_CLI} raw 0x0c 0x08 0x00 0x00 0x01  # Set Legacy Boot Type to Network (PXE)
${BMC_CLI} raw 0x0c 0x08 0x01 0x00 0x03  # Set Boot Protocol to PXE
${BMC_CLI} raw 0x0c 0x05 0x00 0x00 0x08  # Clear existing boot order
${BMC_CLI} raw 0x0c 0x05 0x00 0x01 0x04  # Set boot device 1: Network (PXE NIC)
${BMC_CLI} raw 0x0c 0x05 0x00 0x02 0x00  # Set boot device 2: HDD (fallback)
${BMC_CLI} raw 0x0c 0x05 0x00 0x03 0xff  # Disable remaining boot devices
NIC_PCI_BDF=$(lspci | grep "Ethernet controller: Intel.*E810" | head -n 1 | awk '{print $1}')  # Auto-detect first NIC
${BMC_CLI} raw 0x30 0x0a 0x01 "${NIC_PCI_BDF}" 0x01  # Enable PXE on first E810 NIC
${BMC_CLI} raw 0x30 0x0f 0x01  # Save BIOS configuration
${BMC_CLI} power reset          # Reset system to apply changes

# ... (remaining steps unchanged until final reboot)
# Notes
# The NIC_PCI_BDF is now dynamically detected using lspci, targeting the first E810 NIC. Adjust head -n 1 to head -n X if you want a different NIC (e.g., head -n 2 for the second NIC).
# If your AMI BIOS version differs, test each raw command manually via ipmitool to confirm compatibility. AMI’s raw command set can vary slightly.
# Post-PXE, you’ll need a custom image (e.g., Ubuntu with DPDK/MTL pre-installed) served via TFTP to maintain your high-performance config.
# This gives you a PXE-booted node with the NIC as the primary boot device, ready to load your optimized environment. Let me know if you need further tweaks!

# Step 3: Configure kernel boot parameters
GRUB_FILE="/etc/default/grub"
GRUB_CMDLINE="default_hugepagesz=${HUGEPAGES_SIZE} hugepagesz=${HUGEPAGES_SIZE} hugepages=${HUGEPAGES_COUNT} isolcpus=4-${TOTAL_CORES} nohz_full=4-${TOTAL_CORES} rcu_nocbs=4-${TOTAL_CORES} intel_iommu=on iommu=pt"
sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"/" ${GRUB_FILE}
update-grub

# Step 4: Configure hugepages on each NUMA node
HUGEPAGES_PER_NODE=$((HUGEPAGES_COUNT / NUMA_NODES))
for node in $(seq 0 $((NUMA_NODES - 1))); do
    echo ${HUGEPAGES_PER_NODE} > /sys/devices/system/node/node${node}/hugepages/hugepages-1048576kB/nr_hugepages
done
mkdir -p /mnt/huge
mount -t hugetlbfs -o pagesize=1G none /mnt/huge

# Step 5: Install and configure Intel Ice drivers
ICE_VERSION="1.13.7"
wget -O ice-${ICE_VERSION}.tar.gz "https://sourceforge.net/projects/e1000/files/ice%20stable/${ICE_VERSION}/ice-${ICE_VERSION}.tar.gz"
tar -xzf ice-${ICE_VERSION}.tar.gz
cd ice-${ICE_VERSION}/src
make -j$(nproc)
make install
modprobe ice
cd ../..

# Step 6: Install DPDK
DPDK_VERSION="23.11"
wget -O dpdk-${DPDK_VERSION}.tar.xz "http://fast.dpdk.org/rel/dpdk-${DPDK_VERSION}.tar.xz"
tar -xJf dpdk-${DPDK_VERSION}.tar.xz
cd dpdk-${DPDK_VERSION}
meson setup build --prefix=/usr/local/dpdk
ninja -C build install
cd ..

# Step 7: Install Media Transport Library (MTL)
git clone https://github.com/OpenVisualCloud/Media-Transport-Library.git mtl
cd mtl
./build.sh
make install
cd ..

# Step 8: Configure NICs and bind to DPDK
# Identify NIC PCI addresses (assumes 4 NICs with 2 ports each)
NIC_PCIS=($(lspci | grep "Ethernet controller: Intel.*E810" | awk '{print $1}'))
if [ ${#NIC_PCIS[@]} -ne ${NUM_NICS} ]; then
    echo "Error: Expected ${NUM_NICS} NICs, found ${#NIC_PCIS[@]}"
    exit 1
fi

# Unload kernel drivers and bind to vfio-pci
modprobe vfio-pci
for pci in "${NIC_PCIS[@]}"; do
    echo "0000:${pci}" > /sys/bus/pci/drivers/ice/unbind
    echo "0000:${pci}" > /sys/bus/pci/drivers/vfio-pci/bind
done

# Step 9: Generate DPDK and MTL configuration
CONFIG_FILE="/etc/mtl_config_${NODE_ID}.sh"
cat << EOF > ${CONFIG_FILE}
#!/bin/bash
export RTE_SDK=/usr/local/dpdk
export RTE_TARGET=x86_64-native-linux-gcc
# NUMA-aware lcore assignment
LCORE_LIST=""
for i in $(seq 0 $((TOTAL_PORTS - 1))); do
    NIC_IDX=\$((i / PORTS_PER_NIC))
    NUMA_NODE=\${NIC_NUMA_MAP[\${NIC_IDX}]}
    CORE_START=\$((NUMA_NODE * CORES_PER_NODE + 4 + (i * DPDK_LCORES_PER_PORT)))
    CORE_END=\$((CORE_START + DPDK_LCORES_PER_PORT - 1))
    LCORE_LIST="\${LCORE_LIST}\${LCORE_LIST:+,}\${CORE_START}-\${CORE_END}"
done
# MTL port configuration
MTL_PORTS=""
for i in $(seq 0 $((TOTAL_PORTS - 1))); do
    NIC_IDX=\$((i / PORTS_PER_NIC))
    PORT_IDX=\$((i % PORTS_PER_NIC))
    PCI=\${NIC_PCIS[\${NIC_IDX}]}
    MTL_PORTS="\${MTL_PORTS}\${MTL_PORTS:+,}\"0000:\${PCI}.\${PORT_IDX}\""
done
# Launch MTL application (example: testpmd-like)
mtl_app --lcores "\${LCORE_LIST}" --ports "\${MTL_PORTS}" --num-threads $((TOTAL_PORTS * MTL_THREADS_PER_PORT)) --huge-dir /mnt/huge
EOF
chmod +x ${CONFIG_FILE}

# Step 10: Tune network stack
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.core.netdev_max_backlog=5000
sysctl -w net.core.optmem_max=16777216
for dev in $(ls /sys/class/net | grep -E "^en"); do
    ethtool -G ${dev} rx 4096 tx 4096
    ethtool -K ${dev} tso off gso off gro off
    ethtool -C ${dev} adaptive-rx off rx-usecs 10
done

# Step 11: Persist settings
echo "ice" >> /etc/modules
echo "vfio-pci" >> /etc/modules
cat << EOF > /etc/systemd/system/mtl.service
[Unit]
Description=Media Transport Library Service
After=network.target
[Service]
ExecStart=/etc/mtl_config_${NODE_ID}.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl enable mtl.service

# Step 12: Reboot to apply changes
echo "Configuration complete. Rebooting in 5 seconds..."
sleep 5
reboot