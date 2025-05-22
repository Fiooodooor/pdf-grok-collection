
`sudo modprobe vfio-pci`
`echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf`

ICE custom builder image:

```Dockerfile
# Use a base image with kernel headers for your Harvester SUSE 5.15 kernel
# You might need to find or build a specific image.
# For SUSE, zypper is the package manager.
# This is a SLES 15 SP4/SP5 base, kernel 5.15 is common. Adjust as needed.
FROM suse/sles15:5.15 # Or an appropriate image with matching kernel headers
ARG KERNEL_VERSION=5.15.x-y-default # Specify the exact kernel version of your nodes

RUN zypper -n install --auto-agree-with-licenses \
    kernel-default-devel-${KERNEL_VERSION} \
    # Use this if kernel-default-devel alone doesn't match:
    # kernel-devel-${KERNEL_VERSION} \
    # kernel-source-${KERNEL_VERSION} \
    make \
    gcc \
    git \
    bc \
    rsync \
    elfutils \
    libelf-devel \
    zlib-devel \
    openssl-devel

# Copy your patched source code
COPY ./custom-ice-driver-src /usr/src/custom-ice-driver
WORKDIR /usr/src/custom-ice-driver

# Build command (KMM will execute this)
# The actual build steps depend on your driver's build system
# This is a generic example for an out-of-tree kernel module
CMD ["make", "-C", "/lib/modules/${KERNEL_VERSION}/build", "M=/usr/src/custom-ice-driver", "modules"]
```

### Build and push to registry:

```shell
docker build -t your-registry/custom-ice-builder:latest --build-arg KERNEL_VERSION=$(uname -r) . # Run on a node to get KERNEL_VERSION
docker push your-registry/custom-ice-builder:latest
```

### Deploy Kernel Module Management (KMM) helm chart:

```shell
helm repo add kmm https://kubernetes-sigs.github.io/kernel-module-management/
helm repo update
helm install kmm-operator kmm/kernel-module-management \
    --namespace kernel-module-management --create-namespace \
    --set manager.serviceAccount.annotations."iam\.amazonaws\.com/role"="" # Adjust if on AWS, otherwise remove or set to your SA annotation
```

### Step 3: Define KMM Module CR for your Custom ice Driver

```yaml
kmm-custom-ice-module.yaml
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: ice-kahawai-version
  namespace: kernel-module-management # Or where you installed KMM
spec:
  # ModuleLoader specifies how to load the driver and what image to use.
  moduleLoader:
    container:
      # This section defines how to build the kernel module.
      # KMM will create a job that runs this image and executes its CMD.
      # The resulting .ko file will be extracted.
      modprobe:
        moduleName: ice # The name of the .ko file without extension
      kernelMappings:
        - regexp: '^.*$' # Match all kernel versions (adjust if needed)
          containerImage: your-registry/custom-ice-builder:latest # Image built in Step 1
          # If your driver is already pre-compiled and you just want to load it:
          # inTreeModulesToRemove: # If replacing an in-tree ice driver
          #   - ice
          # build: # If building within KMM
          #   buildArgs:
          #     - name: KERNEL_VERSION # This can be passed to the Dockerfile
          #       value: # KMM can provide this, or you hardcode
          #   secrets: [] # If your build needs secrets
          #   dockerfileConfigMap: # If Dockerfile is in a ConfigMap
          # The builder image (custom-ice-builder) should output the .ko file
          # to a path KMM can find, typically /opt/lib/modules/${KERNEL_VERSION}/
          # KMM will then copy it to the node.
          # The CMD in your builder Dockerfile should handle the actual compilation.
          # KMM will look for <moduleName>.ko in the standard module path within the build container after it runs.
          # Ensure your builder image's CMD places the compiled ice.ko there.
          # E.g., make M=$(pwd) modules_install INSTALL_MOD_PATH=/opt
          # Then KMM extracts from /opt/lib/modules/${KERNEL_VERSION}/.../ice.ko

  # DevicePlugin section is optional for KMM if Intel Ethernet Operator handles device plugin
  # We will let Intel Ethernet Operator handle the device plugin for NICs.

  # Selector targets nodes where this module should be loaded.
  # Adjust to match your Harvester worker nodes with E810 cards.
  selector:
    kubernetes.io/hostname: "your-harvester-node-1" # Example, use appropriate labels
    # You might use a label you apply to nodes with E810s:
    # hardware.intel.com/networking: "e810"
```

### Important KMM Build Configuration:

The moduleLoader.container.kernelMappings[].containerImage is the builder image.
The moduleLoader.container.modprobe.moduleName is ice.
KMM runs the builder image. The CMD in the builder Dockerfile is executed. This CMD (e.g., make ...) should compile ice.ko.
KMM then expects to find ice.ko in a standard location within the finished builder container (e.g., /opt/lib/modules/${KERNEL_VERSION}/extra/ice.ko if you used INSTALL_MOD_PATH=/opt during make modules_install). KMM copies this to the host.

Apply it:

```shell
kubectl apply -f kmm-custom-ice-module.yaml
```

### Step 6: Install Intel Device Plugins Operator

```shell
helm repo add intel https://intel.github.io/helm-charts/
helm repo update
helm install intel-device-plugins-operator intel/intel-device-plugins-operator \
    -n intel-device-plugins-operator --create-namespace
```

#### 7.1 Deploy Intel Ethernet Operator using a CR for intel-device-plugins-operator (if applicable) or directly via its own Helm chart.

Often, the intel-device-plugins-operator itself doesn't have a high-level CR to enable/disable "Ethernet features". Instead, you'd deploy the intel-ethernet-operator Helm chart, which the main operator might then "be aware of" or integrate with.
Let's deploy intel-ethernet-operator directly:

```shell
helm install intel-ethernet-operator intel/intel-ethernet-operator \
    -n intel-ethernet-operator --create-namespace \
    --set sriovDevicePlugin.image.tag=latest # Or a specific version
    # Potentially set other values like node selectors for the operator itself
```

First, identify your E810 PF names (e.g., ensXYZ, ethM) on the nodes.
lspci | grep E810 will give PCI addresses. ip link show will show interface names.

```yaml
# sriov-e810-policy.yaml
apiVersion: sriovnetwork.openshift.io/v1 # Note: API group might be intel.com or k8s.cni.cncf.io depending on plugin version
kind: SriovNetworkNodePolicy
metadata:
  name: policy-e810
  namespace: intel-ethernet-operator # Namespace where intel-ethernet-operator is running
spec:
  resourceName: sriov_e810_net # This will be the resource pods request, e.g., intel.com/sriov_e810_net
  nodeSelector:
    # Select nodes with E810 cards. You should label these nodes.
    # e.g., kubectl label node your-node-name hardware.intel.com/networking=e810
    hardware.intel.com/networking: "e810"
  priority: 99
  mtu: 9000 # Optional: Set MTU for VFs
  numVfs: 8   # Number of VFs to create per PF
  nicSelector:
    # How to select the PFs on the matched nodes
    # Option 1: By Vendor/Device ID (safer if names change)
    # Get these from lspci -nn | grep E810
    vendor: "8086" # Intel
    deviceID: "1592" # Example E810 ID, replace with your actual ID
    # pfNames: ["ens803f0", "ens803f1"] # Optionally specify PFs by name if consistent
    # rootDevices: ["0000:81:00.0", "0000:81:00.1"] # PCI addresses of PFs
  deviceType: vfio-pci # Use vfio-pci for DPDK. For kernel networking, use 'netdevice'
  isRdma: false # Set to true if RDMA is needed and supported by VFs
  # Optional: Eswitch Mode (for E810, usually 'switchdev')
  # eSwitchMode: switchdev
```

Apply it:

```shell
kubectl apply -f sriov-e810-policy.yaml
```

### To expose PFs for direct assignment (e.g., one pod gets a whole PF):

You can create another SriovNetworkNodePolicy but set numVfs: 0 and target specific PFs. The resourceName would be different, e.g., sriov_e810_pf.

```yaml
# sriov-e810-pf-policy.yaml (Example for PF passthrough)
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: policy-e810-pf
  namespace: intel-ethernet-operator
spec:
  resourceName: sriov_e810_pf # Resource name for PFs
  nodeSelector:
    hardware.intel.com/networking: "e810"
  priority: 90 # Lower priority than VF policy if on same nodes/interfaces
  numVfs: 0 # Key for PF passthrough
  nicSelector:
    pfNames: ["enp129s0f1"] # Example: target a specific second PF if you have multiple
    # vendor: "8086"
    # deviceID: "1592"
  deviceType: vfio-pci
  isRdma: false
```

#### 8.1 Deploy Intel GPU Operator/Plugin using a CR (if available) or directly.

Similar to Ethernet, you might deploy intel-gpu-operator or intel-gpu-plugin Helm chart.

```yaml
helm install intel-gpu-operator intel/intel-gpu-operator \
    -n intel-gpu-operator --create-namespace \
    --set nodeFeatureRules=false # If you don't want NFD, or manage it separately
    # The GPU operator will typically deploy the GPU device plugin
```

#### 8.2 Configure GPU resources (if needed, often auto-detects).

The GPU plugin usually auto-detects available GPUs and their SR-IOV VFs (if you've configured GPU VFs at the host/BIOS level and corresponding host drivers are loaded). It advertises them as resources like gpu.intel.com/i915 (for integrated/discrete) or gpu.intel.com/vf (for VFs).

If your Intel Flex GPU requires specific configuration (e.g., enabling VFs for GPUs if not done at BIOS/host level), you might need a GpuAllocationPolicy CRD or similar provided by the Intel GPU Operator. Check the Intel GPU Operator documentation for specifics on Flex GPU and SR-IOV.

For Flex GPUs, the resource names might be like gpu.intel.com/ats-m or gpu.intel.com/dg2.

### Step 9: Create NetworkAttachmentDefinition (NAD) for SR-IOV VFs/PFs

This defines a "network" that pods can request.

```yaml
# nad-sriov-vf.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-e810-vf-net # Name used in pod annotation
  namespace: default # Or the namespace where your workloads will run
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "sriov-e810-vf-net",
      "type": "sriov",  # CNI plugin name, provided by SR-IOV CNI installation
      "resourceName": "intel.com/sriov_e810_net", # MUST match resource advertised by device plugin
                                                 # Check `kubectl get node <node-name> -o jsonpath='{.status.allocatable}'`
      "ipam": {
        "type": "host-local", # Example: use host-local IPAM. Can be static, dhcp, etc.
        "subnet": "192.168.55.0/24",
        "rangeStart": "192.168.55.100",
        "rangeEnd": "192.168.55.200",
        "gateway": "192.168.55.1"
      }
      # Optional: "vlan": 100,
      # Optional: "link_state": "enable" # or "disable", "auto"
      # Optional for DPDK bound to vfio-pci:
      # "capabilities": { "ips": true } # If you still want an IP address for management
    }'
```

### Step 10: Deploy Workload Pods Requesting Resources

This example assumes your OpenVisualCloud workload image (your-ovc-workload:latest) has the custom DPDK libraries built-in.

```yaml
# ovc-workload-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ovc-benchmark-app
  namespace: default # Same namespace as the NADs or ensure NAD is cluster-wide accessible
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ovc-benchmark
  template:
    metadata:
      labels:
        app: ovc-benchmark
      annotations:
        # Request SR-IOV VF network interface
        k8s.v1.cni.cncf.io/networks: '[
          { "name": "sriov-e810-vf-net", "interface": "net1" }
        ]'
        # To request a PF (if configured and NAD exists):
        # k8s.v1.cni.cncf.io/networks: '[
        #   { "name": "sriov-e810-pf-net", "interface": "dpdk0" }
        # ]'
    spec:
      containers:
      - name: benchmark-container
        image: your-registry/your-ovc-workload-with-dpdk:latest # Your workload image
        securityContext:
          privileged: true # Often needed for DPDK/VFIO
          capabilities:
            add: ["IPC_LOCK", "SYS_ADMIN", "NET_ADMIN"] # NET_ADMIN for interface manipulation, IPC_LOCK for DPDK hugepages
        env:
        - name: HUGEPAGE_MOUNT
          value: "/mnt/huge"
        # Add other env vars your application needs
        resources:
          limits:
            # Request SR-IOV VF resource
            intel.com/sriov_e810_net: "1" # Request 1 VF from the pool
            # To request a PF (if configured):
            # intel.com/sriov_e810_pf: "1"

            # Request GPU resource (adjust resource name based on what GPU plugin exposes)
            gpu.intel.com/i915: "1" # Or gpu.intel.com/ats-m: "1", gpu.intel.com/dg2: "1", or gpu.intel.com/vf: "1"

            # Request Hugepages
            hugepages-1Gi: "4Gi" # Request 4 x 1Gi hugepages
            memory: "8Gi" # Regular memory
            cpu: "8"      # CPU cores
          requests:
            intel.com/sriov_e810_net: "1"
            # intel.com/sriov_e810_pf: "1"
            gpu.intel.com/i915: "1"
            hugepages-1Gi: "4Gi"
            memory: "8Gi"
            cpu: "8"
        volumeMounts:
        - mountPath: /mnt/huge # Mount for hugepages
          name: hugepage-volume
        - mountPath: /dev/vfio # For vfio access
          name: vfio-volume
      volumes:
      - name: hugepage-volume
        emptyDir:
          medium: HugePages
      - name: vfio-volume
        hostPath:
          path: /dev/vfio

```

`kubectl apply -f ovc-workload-deployment.yaml -n your-workload-namespace`


### Automation Summary and Best Practices:

**Helm Charts:** Use Helm to package KMM deployment, Intel Operators, NADs, and your workloads. This makes upgrades and rollbacks manageable.
**GitOps:** Store all these YAMLs and Helm chart configurations in Git and use a GitOps tool (ArgoCD, Flux) to automatically apply changes to the cluster.
**Node Labeling:** Crucial for targeting policies (KMM, SR-IOV, GPU) to the correct nodes. Automate this labeling if possible (e.g., based on detected hardware via NFD - Node Feature Discovery). The Intel Operators often deploy NFD or have their own discovery.
**Custom Driver Updates:**
Update your custom-ice-driver-src.
Rebuild and push the custom-ice-builder image with a new tag.
Update the Module CRD's containerImage field to point to the new builder image tag. KMM will handle the rolling update of the driver on nodes.
**DPDK Updates:** Rebuild your application container images with the new DPDK version. Update your Deployment/StatefulSet YAMLs.
**Monitoring:**
Monitor KMM operator and Module CR status.
Monitor Intel Ethernet Operator and SriovNetworkNodePolicy status.
Monitor Intel GPU Operator logs.
Check kubectl describe node <node-name> to see allocatable resources (intel.com/sriov..., gpu.intel.com/..., hugepages-...).
Check pod logs for DPDK/GPU initialization errors.
**Resource Names:** The resourceName in SriovNetworkNodePolicy and the resource name prefix used by the SR-IOV device plugin (e.g., intel.com/) combined with the policy's resourceName MUST match what pods request (intel.com/sriov_e810_net). This can be a common point of failure. Verify by checking node allocatable resources.
This comprehensive setup is complex, and each step might require debugging and adjustment based on your exact driver patches, kernel versions, and operator versions. Start by getting each component working individually before combining them. The Intel operator documentation (especially for Ethernet and GPU) will be your best friend for specific CRD fields and behaviors.





