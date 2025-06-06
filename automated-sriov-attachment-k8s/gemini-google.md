https://aistudio.google.com/app/prompts?state=%7B%22ids%22:%5B%2218N7fm39xWr_5_Knv2vS6KzG-goWcXy6O%22%5D,%22action%22:%22open%22,%22userId%22:%22109535256116166338809%22,%22resourceKeys%22:%7B%7D%7D&usp=sharing

Okay, this is a comprehensive and advanced request! Let's break this down. Fully automating the *custom build and kernel module insertion* of DPDK and ICE drivers *from within Kubernetes manifests* is extremely challenging and generally not the recommended "best practice" due to the tight coupling with the host kernel and potential instability.

The "best known method" typically involves:
1.  **Node Preparation (Potentially outside K8s):** Ensuring the correct kernel modules (custom ICE, DPDK-compatible) are loaded on the worker nodes. This might be done via OS image customization, Ansible playbooks run on nodes, or a privileged DaemonSet that carefully manages kernel modules (this is the riskiest part if fully automated from K8s).
2.  **Kubernetes Operators:** Deploying the Intel Device Plugins Operator and Intel Ethernet Operator to manage and expose these hardware resources to pods.

Given your requirement for full automation, we'll aim for a solution where a privileged DaemonSet *could* attempt to build/load drivers, but with strong caveats. The Intel Ethernet Operator itself *can* manage out-of-tree drivers using a "driver container" approach, which is safer if you can pre-build the drivers for your specific kernel.

**Core Challenge: Custom Driver Build & Installation**

*   **Kernel Headers:** Building kernel modules requires the exact kernel headers for `suse/sle-mikro/base-5.5:2.0.4-5.8.162`. SLE Micro is a minimal OS; these headers might not be present by default or easily installable without custom repositories.
*   **DKMS (Dynamic Kernel Module Support):** This is the standard way to manage out-of-tree kernel modules.
*   **Privileges:** Any process building and inserting kernel modules needs high privileges on the node.

**Proposed Strategy:**

1.  **Prerequisites on Harvester Nodes (Manual or Semi-Automated):**
    *   BIOS: VT-d, SR-IOV enabled for E810 and GPU.
    *   OS: Hugepages enabled (you confirmed this).
    *   Kernel cmdline: `intel_iommu=on iommu=pt` (usually Harvester/RKE2 handles this if virtualization is enabled).
    *   **Crucially: Custom ICE/DPDK Drivers.**
        *   **Option A (Recommended):** Pre-install these drivers on your Harvester nodes. This is the most stable. You'd build them once for your kernel, then install.
        *   **Option B (Complex & Risky via K8s):** Attempt a DaemonSet to build/load. We'll outline this, but it's fragile.
        *   **Option C (Operator-managed driver container):** The Intel Ethernet Operator can deploy a container with pre-compiled drivers. You'd still need to *build* these `.ko` files against your specific kernel version and package them into an image.

2.  **Kubernetes Deployment (Helm Charts / YAMLs):**
    *   Multus CNI (Harvester should have this).
    *   Intel Device Plugins Operator (for GPU).
    *   Intel Ethernet Operator (for E810 NICs).
    *   Configuration CRs for both operators.

Let's proceed with the understanding that **Option C** for drivers is the most "Kubernetes-native automated" way if you can pre-compile the drivers and package them. If you *must* build from source *on the nodes via Kubernetes*, it's a highly advanced and potentially unstable path.

---

**Step-by-Step Deployment Plan**

**Phase 0: Node Prerequisites (Critical!)**

1.  **Verify SR-IOV and VT-d:**
    *   In BIOS: Ensure SR-IOV is enabled for your E810 NICs and Intel Flex GPUs. Ensure VT-d (Intel Virtualization Technology for Directed I/O) is enabled.
2.  **Verify Hugepages:**
    *   Login to a Harvester node: `grep HugePages /proc/meminfo`. Ensure `HugePages_Total` is greater than 0.
3.  **Verify IOMMU:**
    *   Login to a Harvester node: `dmesg | grep -e DMAR -e IOMMU`. You should see IOMMU enabled. Check kernel command line: `cat /proc/cmdline` for `intel_iommu=on`.
4.  **Custom ICE and DPDK Drivers (The Hard Part):**
    This is where your custom patched drivers come in. The Intel Ethernet Operator supports a `driverContainer` approach.

    *   **a. Build your custom drivers:**
        *   You need a build environment with the exact kernel headers for `suse/sle-mikro/base-5.5:2.0.4-5.8.162`.
        *   Download the Intel ICE driver source, apply your patches.
        *   Compile it (`make`). This will produce `ice.ko`.
        *   Download the DPDK source, apply your patches. Configure and build it for your target. The key part for kernel interaction is often the `igb_uio` or `vfio-pci` driver (though `vfio-pci` is generally preferred and in-kernel). If your custom DPDK needs a specific kernel module, build that too.
    *   **b. Create a Driver Container Image:**
        Create a Dockerfile that copies these pre-compiled `.ko` files and potentially some helper scripts (e.g., for `modprobe`, `depmod`).

        ```dockerfile
        # Use a base image compatible with your Harvester node OS if possible
        # Or a minimal base like alpine/busybox if just copying .ko files and using host tools
        FROM alpine:latest
        ARG KERNEL_VERSION="5.8.162" # Adjust to your *exact* kernel version string if needed for pathing
        # The path structure /lib/modules/$(uname -r)/updates/drivers/net/ethernet/intel/ice/ice.ko
        # is a common place for DKMS or manually installed drivers to override in-tree ones.
        # The operator might look in /opt/drivers as well. Check operator docs.
        COPY ./ice.ko /opt/drivers/ice.ko
        # If you have other custom modules (e.g., a custom igb_uio for DPDK)
        # COPY ./custom_dpdk_module.ko /opt/drivers/custom_dpdk_module.ko

        # Add any tools if your container needs to do more than just provide the .ko
        # RUN apk add --no-cache kmod # if you plan to modprobe from container (not typical for this pattern)

        CMD ["sleep", "infinity"] # Container just needs to exist to provide files
        ```
        Build and push this image to a registry accessible by your Harvester cluster (e.g., Docker Hub, or Harvester's embedded registry).
        `docker build . -t your-registry/custom-ice-driver:TAG`
        `docker push your-registry/custom-ice-driver:TAG`

        **Note:** The Intel Ethernet Operator will mount `/lib/modules` from the host and try to place/load the driver from the container into the correct host path.

**Phase 1: Prepare Kubernetes Cluster (kubectl on your management machine)**

1.  **Install Helm (if not already installed):**
    ```bash
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    ```

2.  **Verify Multus CNI:**
    Harvester installs RKE2, which usually comes with Multus. Verify:
    ```bash
    kubectl get pods -n kube-system | grep multus
    kubectl get crd network-attachment-definitions.k8s.cni.cncf.io
    ```
    If not present, you'd need to install it, but this is unlikely for Harvester.

**Phase 2: Deploy Intel Device Plugins Operator (for GPU)**

This operator will deploy the necessary device plugin for Intel Flex GPUs.

1.  **Add Intel Helm Repository:**
    ```bash
    helm repo add intel https://intel.github.io/helm-charts/
    helm repo update
    ```

2.  **Install Intel Device Plugins Operator:**
    ```bash
    helm install intel-device-plugins-operator intel/intel-device-plugins-operator \
      -n intel-device-plugins-operator --create-namespace
    ```

3.  **Verify Operator Pod:**
    ```bash
    kubectl get pods -n intel-device-plugins-operator
    ```
    Wait for the operator pod to be `Running`.

4.  **Deploy `DevicePlugin` CR for Intel GPUs:**
    Create `intel-gpu-plugin.yaml`:
    ```yaml
    apiVersion: deviceplugin.intel.com/v1
    kind: GpuDevicePlugin
    metadata:
      name: gpuplugin
      namespace: intel-device-plugins-operator # Must be in the same namespace as the operator
    spec:
      image: intel/intel-gpu-plugin:0.29.0 # Check for latest version
      sharedDevNum: 1 # Number of containers that can share one GPU. Adjust as needed.
      # nodeSelector: # Optional: If only some nodes have GPUs
      #   gpu-node: "true"
      # initImage: To load i915 firmware if needed, often handled by base OS
      # preferredAllocationPolicy: "none" # "balanced", "packed", or "none"
    ```
    Apply it:
    ```bash
    kubectl apply -f intel-gpu-plugin.yaml
    ```

5.  **Verify GPU Device Plugin DaemonSet:**
    The operator will create a DaemonSet.
    ```bash
    kubectl get daemonset -n intel-device-plugins-operator
    kubectl get pods -n intel-device-plugins-operator -l app=intel-gpu-device-plugin
    ```
    Check logs of these pods to ensure they detect your Flex GPUs.
    After a short while, you should see GPU resources on your nodes:
    ```bash
    kubectl get nodes -o=custom-columns=NAME:.metadata.name,"GPU_ALLOCATABLE:.status.allocatable.gpu\.intel\.com/i915","GPU_CAPACITY:.status.capacity.gpu\.intel\.com/i915"
    # The resource name might be different (e.g., gpu.intel.com/i915, gpu.intel.com/xe)
    # Check with `kubectl describe node <your-gpu-node-name>`
    ```

**Phase 3: Deploy Intel Ethernet Operator (for E810 SR-IOV)**

This operator will manage the SR-IOV CNI plugin and device plugin for your E810 NICs.

1.  **Install Intel Ethernet Operator:**
    (Uses the same Helm repo as above)
    ```bash
    # Values for the operator chart - important for custom driver
    # Create a values.yaml file: ethernet-operator-values.yaml
    cat <<EOF > ethernet-operator-values.yaml
    sriovDevicePlugin:
      # If your custom driver container needs specific resource requests/limits
      # resources:
      #   requests:
      #     cpu: "100m"
      #     memory: "100Mi"
      #   limits:
      #     cpu: "200m"
      #     memory: "200Mi"

      # This is where you specify your custom driver image.
      # The operator will use this image to try and install the 'ice' driver.
      driverImage: "your-registry/custom-ice-driver:TAG" # <--- YOUR CUSTOM DRIVER IMAGE!

      # If you want to use a specific config for the underlying SRIOV Network Device Plugin
      # configData:
      #   resourceNixPrefix: "intel.com"
      #   # Other plugin configurations...
EOF

    helm install intel-ethernet-operator intel/intel-ethernet-operator \
      -n intel-ethernet-operator --create-namespace \
      -f ethernet-operator-values.yaml
    ```

2.  **Verify Operator Pod:**
    ```bash
    kubectl get pods -n intel-ethernet-operator
    ```
    Wait for the operator pod to be `Running`.

3.  **Create `SriovNetworkNodePolicy`:**
    This CRD tells the operator which NICs to manage and how many VFs to create.
    *   First, identify your E810 PF names and Vendor/Device IDs on a Harvester node:
        ```bash
        # On a Harvester Node
        lspci -nnk | grep -i "Ethernet Controller E810"
        # Example output:
        # 31:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller E810-C for QSFP [8086:1592] (rev 02)
        #   Subsystem: Intel Corporation Ethernet Network Adapter E810-C-Q2 [8086:000e]
        #   Kernel driver in use: ice  <-- This should be your custom driver after it's loaded
        #   Kernel modules: ice
        # 31:00.1 Ethernet controller [0200]: Intel Corporation Ethernet Controller E810-C for QSFP [8086:1592] (rev 02)
        # ...
        # Note the interface names (e.g., ens802f0np0) associated with these
        ip link show
        ```
    *   Create `e810-nodepolicy.yaml`:
        ```yaml
        apiVersion: sriovnetwork.openshift.io/v1 # Yes, it's often openshift.io, even for vanilla K8s
        kind: SriovNetworkNodePolicy
        metadata:
          name: policy-e810
          namespace: intel-ethernet-operator # Must be in the same namespace as the operator
        spec:
          resourceName: intel_e810_100g # This will be the resource pods request
          nodeSelector:
            kubernetes.io/os: "linux" # Or more specific if only some nodes have E810
            # feature.node.kubernetes.io/custom-intel-e810: "true" # If you label nodes
          priority: 99
          mtu: 9000 # Optional: Set MTU for VFs
          numVfs: 8  # Number of VFs to create per PF
          nicSelector:
            vendor: "8086"
            deviceIDs:
              - "1592" # Example E810-C ID, replace with YOURS
              - "1593" # Example E810-XXV ID, replace with YOURS
            # pfNames: # You can also select by PF names
            #  - "ens802f0np0"
            #  - "ens802f0np1#0-7" # Select specific VFs from a PF
            # rootDevices: # PCI Address of the PF
            # - "0000:31:00.0"
          deviceType: vfio-pci # For DPDK workloads. Use "netdevice" for kernel networking.
          isRdma: false # Set to true if you need RDMA over RoCE/iWARP
          # externManaged: true # Set to true if VFs are created outside of operator (e.g. by systemd or bios)
          # driverUpdate: # This section is relevant if you use the operator's driver update capability
          #   updateDrivers: true # Tells the operator to try managing the driver from driverImage
        ```
        **Important choices for `deviceType`:**
        *   `netdevice`: VFs will be standard kernel network interfaces inside the pod.
        *   `vfio-pci`: VFs will be passed through using `vfio-pci`, suitable for DPDK applications that will bind to them. **This is likely what you want for OpenVisualCloud DPDK workloads.**

    Apply it:
    ```bash
    kubectl apply -f e810-nodepolicy.yaml
    ```

4.  **Verify Node State and VFs:**
    The operator will create a DaemonSet (sriov-network-config-daemon).
    ```bash
    kubectl get pods -n intel-ethernet-operator -l app=sriov-network-config-daemon
    ```
    Check its logs. Then check the `SriovNetworkNodeState` objects:
    ```bash
    kubectl get sriovnetworknodestates -n intel-ethernet-operator -o yaml
    ```
    Look for your nodes. The status should show interfaces being configured and VFs created.
    On a Harvester node, you can verify VFs:
    ```bash
    # On Harvester node
    ip link show # You should see new VF interfaces
    lspci | grep "Virtual Function" # Should list VFs for E810
    ```
    And check allocatable resources:
    ```bash
    kubectl get node <your-e810-node-name> -o jsonpath='{.status.allocatable}'
    # Look for "intel.com/intel_e810_100g"
    ```

5.  **Create `NetworkAttachmentDefinition` (NAD):**
    This Multus CRD defines how pods can attach to the SR-IOV VFs.
    Create `e810-vf-nad.yaml`:
    ```yaml
    apiVersion: "k8s.cni.cncf.io/v1"
    kind: NetworkAttachmentDefinition
    metadata:
      name: sriov-e810-vfio-a
      namespace: default # Or the namespace where your workloads will run
      annotations:
        k8s.v1.cni.cncf.io/resourceName: intel.com/intel_e810_100g # Must match resourceName in NodePolicy
    spec:
      config: '{
        "cniVersion": "0.3.1",
        "name": "sriov-e810-vfio-a-net",
        "type": "sriov", # This type invokes the SR-IOV CNI plugin
        "ipam": {
          "type": "static" # Or "dhcp", or "host-local" if you need IP addresses on VFs for some reason
                           # For vfio-pci DPDK, IPAM is often not strictly needed as DPDK handles the device directly.
                           # However, some CNI plugins might require an IPAM section.
                           # If using "static", you'd add "addresses": [{"address": "192.168.100.50/24"}] etc. in pod annotation.
                           # For pure passthrough, sometimes an empty ipam {} is enough, or you might omit it if sriov CNI allows.
        }
        # Optional: Add VLAN, MAC, Spoof Check, etc.
        # "vlan": 100,
        # "mac": "CA:FE:C0:FF:EE:01",
        # "spoofchk": "off",
        # "trust": "on"
      }'
    ```
    Apply it:
    ```bash
    kubectl apply -f e810-vf-nad.yaml
    ```
    If you want to attach Physical Functions (PFs), the `SriovNetworkNodePolicy`'s `pfNames` can be used, and the `NetworkAttachmentDefinition` would reference a resource name dedicated to PFs. Using PFs directly in pods is less common than VFs but possible. You'd need to ensure the PF is unbound from its kernel driver and bound to `vfio-pci` if used by DPDK. The operator can help with this too.

**Phase 4: Deploy Workloads Requesting Devices**

1.  **Example Pod Requesting Intel GPU:**
    ```yaml
    apiVersion: v1
    kind: Pod
    metadata:
      name: gpu-test-pod
    spec:
      containers:
      - name: gpu-test-container
        image: intel/openvino-ubi8-dev:2023.2.0 # Or any image that can test the GPU
        command: ["/bin/bash", "-c", "sleep infinity"] # Replace with actual workload
        resources:
          limits:
            gpu.intel.com/i915: 1 # Request 1 GPU. Use the resource name you found earlier.
          requests:
            gpu.intel.com/i915: 1
        # For Hugepages
        volumeMounts:
        - mountPath: /hugepages
          name: hugepage
      volumes:
      - name: hugepage
        emptyDir:
          medium: HugePages
      # nodeSelector: # if you used nodeSelector for the device plugin
      #   gpu-node: "true"
    ```

2.  **Example Pod Requesting SR-IOV VF (for DPDK):**
    ```yaml
    apiVersion: v1
    kind: Pod
    metadata:
      name: dpdk-test-pod
      namespace: default # Same namespace as the NAD
      annotations:
        k8s.v1.cni.cncf.io/networks: sriov-e810-vfio-a # Attach to the NAD
    spec:
      containers:
      - name: dpdk-app-container
        image: your-dpdk-app-image # Image containing your DPDK application
        command: ["/bin/bash", "-c", "sleep infinity"] # Replace with actual workload
        securityContext:
          privileged: false # DPDK apps usually don't need full privilege if vfio-pci is set up correctly
          capabilities:
            add: ["IPC_LOCK", "SYS_ADMIN"] # SYS_ADMIN might be needed for some VFIO operations or hugepages mapping depending on config
        resources:
          limits:
            intel.com/intel_e810_100g: 1 # Request 1 VF of this type
            hugepages-2Mi: "2Gi" # Example Hugepage request
          requests:
            intel.com/intel_e810_100g: 1
            hugepages-2Mi: "2Gi"
        volumeMounts:
        - mountPath: /dev/hugepages
          name: hugepage
        # If vfio-pci device files are needed directly (usually handled by DPDK):
        # - mountPath: /dev/vfio/vfio # hostPath mount, needs privileged or PSP adjustments
        #   name: vfio-dir
      volumes:
      - name: hugepage
        emptyDir:
          medium: HugePages
      # - name: vfio-dir
      #   hostPath:
      #     path: /dev/vfio/vfio
      #     type: DirectoryOrCreate
    ```
    **Inside the `dpdk-app-container`:**
    *   The environment variable `PCIDEVICE_INTEL_COM_INTEL_E810_100G` will be set, containing the PCI address(es) of the allocated VF(s).
    *   Your DPDK application will use this PCI address to initialize and use the VF.
    *   Ensure your DPDK application is compiled against the same DPDK version whose drivers (if any custom kernel parts) you are using.

**Phase 5: Running OpenVisualCloud Benchmarks**

The OVC workloads (MTL, MCM, Tiber) are typically packaged as Docker containers and often have Helm charts or Kubernetes YAMLs.
1.  **Clone the Repository:** `git clone https://www.github.com/OpenVisualCloud`
2.  **Inspect their YAMLs/Charts:** Look for sections related to:
    *   `resources`: They will need to request `gpu.intel.com/i915` (or equivalent) and `intel.com/intel_e810_100g`.
    *   `annotations`: For `k8s.v1.cni.cncf.io/networks` if they use SR-IOV VFs.
    *   `hugepages`: Mounts and requests.
    *   `securityContext` / `capabilities`: For DPDK or GPU access.
3.  **Adapt:** You'll need to modify their deployment files to use the resource names and NAD names you've configured (`intel_e810_100g`, `sriov-e810-vfio-a`, etc.).

**Regarding PF (Physical Function) Attachment:**

To use a PF directly:
1.  **Modify `SriovNetworkNodePolicy`:**
    *   You might need a separate policy or adjust the existing one to not create VFs on a specific PF if you want to pass that PF through.
    *   Or, allow the operator to manage the PF by specifying it in `pfNames` and setting `deviceType: vfio-pci`. The operator would then unbind it from the kernel driver (e.g., `ice`) and bind it to `vfio-pci`.
    *   The `resourceName` would be different, e.g., `intel_e810_pf`.
2.  **Create a new NAD:** Similar to the VF NAD, but referencing the PF resource name.
3.  **Pod Spec:** Request `intel.com/intel_e810_pf: 1`.

This is less common as it dedicates an entire physical NIC port to one pod.

---

**Important Considerations and Caveats:**

*   **Driver Container (Option C):** The success of the `driverImage` in the Intel Ethernet Operator highly depends on the compatibility of your pre-compiled `.ko` with the running kernel and the operator's ability to correctly place and load it. Thoroughly test this. Check the logs of the `sriov-network-config-daemon` pods.
*   **Kernel Version Lock-in:** If you manage drivers this way, you are tied to the specific kernel version you built them for. OS updates that change the kernel will break this until you provide new drivers in the container.
*   **Privileged DaemonSet for Driver Build (Option B - Not Detailed Above):**
    *   If you were to attempt an on-node build via a DaemonSet, it would need:
        *   To mount `/lib/modules` and `/usr/src` (or wherever headers are).
        *   Access to build tools and kernel headers *on the node or in the container*.
        *   High privileges to run `modprobe`, `insmod`, `depmod`.
        *   A mechanism to get the custom driver source (e.g., git clone in initContainer).
    *   This is very complex to make robust, especially on a minimal OS like SLE Micro. I strongly advise against this for production unless you have deep expertise in this area.
*   **Troubleshooting:**
    *   `kubectl logs <pod-name> -n <namespace>` for all operator and plugin pods.
    *   `kubectl describe node <node-name>` for resource allocation and events.
    *   `dmesg` on Harvester nodes for kernel messages related to `ice`, `vfio-pci`, IOMMU.
    *   `ip link`, `lspci -nnk` on nodes.
*   **Intel Support:** Refer to the official GitHub repositories for Intel Device Plugins Operator and Intel Ethernet Operator for the latest documentation, versions, and troubleshooting guides. They often have more detailed examples.

This script provides a comprehensive framework. The custom driver part is the most environment-specific. Start by ensuring your nodes *can* load your custom drivers manually, then move to automating their deployment via the driver container method with the Ethernet Operator. Good luck!
