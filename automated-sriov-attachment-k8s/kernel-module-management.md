
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
