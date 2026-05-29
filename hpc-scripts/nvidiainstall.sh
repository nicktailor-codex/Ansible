bash
# Confirm hardware sees the GPU
lspci | grep -i nvidia

# Expected: a line like "Bus PCI: ... NVIDIA Corporation Device ... [H200 NVL]"
# If nothing shows, the GPU isn't seated correctly or BIOS hasn't enabled it

# Update package lists and upgrade existing packages
sudo apt update
sudo apt upgrade -y

# Reboot if kernel was updated
sudo reboot
________________________________________
Step 2: Install build prerequisites and blacklist nouveau
The open-source nouveau driver conflicts with NVIDIA's proprietary driver. Blacklist it before installing.
bash
# Build prerequisites for DKMS
sudo apt install -y build-essential dkms linux-headers-$(uname -r) \
  software-properties-common curl wget gnupg

# Blacklist nouveau
sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

# Regenerate initramfs to apply
sudo update-initramfs -u

# Reboot to ensure nouveau is fully unloaded
sudo reboot
After reboot, verify nouveau is gone:
bash
lsmod | grep nouveau
# Should return nothing
________________________________________
Step 3: Add the NVIDIA CUDA repository
bash
# Get the keyring package for Ubuntu 24.04
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb

# Install the keyring (adds the repo and signing key)
sudo dpkg -i cuda-keyring_1.1-1_all.deb

# Refresh package index
sudo apt update
________________________________________
Step 4: Install the NVIDIA driver
bash
# Install the latest production-branch driver (recommended for H200 NVL)
sudo apt install -y nvidia-driver-580-server

# 'server' variant: headless, no Wayland/X11 components, ideal for compute nodes
# If 565 isn't available yet, try nvidia-driver-560-server or nvidia-driver-555-server
# Check available versions with: apt-cache search nvidia-driver-.*-server

# Reboot to load the new driver
sudo reboot
After reboot, verify the driver loaded:
bash
nvidia-smi

# Expected output: a table showing the H200 NVL with 141 GB memory,
# driver version 565.xx (or whatever you installed), CUDA version 12.x,
# 0% utilization, and 0 processes

# If nvidia-smi says "no devices found" or similar, the driver didn't load.
# Check with: dmesg | grep -i nvidia
________________________________________
Step 5: Install CUDA Toolkit
bash
# Install CUDA toolkit (the development environment: nvcc, libraries, headers)
sudo apt install -y cuda-toolkit-12-6

# (Or whichever 12.x is current; check with: apt-cache search cuda-toolkit-12)

# This installs to /usr/local/cuda-12.6 with a symlink /usr/local/cuda
________________________________________
Step 6: Add CUDA to PATH and LD_LIBRARY_PATH
Add this to /etc/profile.d/cuda.sh so it's available for all users:
bash
sudo tee /etc/profile.d/cuda.sh > /dev/null <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
export CUDA_HOME=/usr/local/cuda
EOF

# Apply to current shell
source /etc/profile.d/cuda.sh

# Verify nvcc works
nvcc --version
# Expected: nvcc release 12.6 (or whichever)
________________________________________
Step 7: Install NVIDIA Container Toolkit (for Apptainer/Docker GPU passthrough)
Skip this if you're not using containers. But you will eventually want it for Parabricks, NGC containers, etc.
bash
# Add the NVIDIA Container Toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
________________________________________
________________________________________
Step 9: Validate the full stack
bash
# 1. Driver loads and sees the GPU
nvidia-smi

# 2. nvcc compiler works
nvcc --version

# 3. Sample CUDA program compiles and runs
cd /tmp
cat > cuda_test.cu <<'EOF'
#include <cstdio>
#include <cuda_runtime.h>

__global__ void hello(){ printf("Hello from GPU thread %d\n", threadIdx.x); }

int main(){
    int dev; cudaGetDevice(&dev);
    cudaDeviceProp p; cudaGetDeviceProperties(&p, dev);
    printf("Device: %s\n", p.name);
    printf("Compute capability: %d.%d\n", p.major, p.minor);
    printf("Total memory: %.1f GB\n", p.totalGlobalMem / 1e9);
    hello<<<1, 4>>>();
    cudaDeviceSynchronize();
    return 0;
}
EOF

nvcc cuda_test.cu -o cuda_test
./cuda_test

# Expected output:
# Device: NVIDIA H200 NVL (or NVIDIA L4 on gpu03)
# Compute capability: 9.0 (H200) or 8.9 (L4)
# Total memory: 141.0 GB (H200) or 24.0 GB (L4)
# Hello from GPU thread 0
# Hello from GPU thread 1
# Hello from GPU thread 2
# Hello from GPU thread 3

# 4. Apptainer can see the GPU
apptainer exec --nv docker://nvcr.io/nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
If all four checks pass, the GPU stack is fully working.
________________________________________
Step 10: Enable persistence mode (recommended for compute nodes)
NVIDIA persistence mode keeps the driver loaded even when no process is using the GPU. Prevents the multi-second driver init lag on each new job.
bash
# Enable persistence mode now
sudo nvidia-smi -pm 1

# Make it persistent across reboots
sudo systemctl enable nvidia-persistenced
sudo systemctl start nvidia-persistenced

# Verify
nvidia-smi -q | grep "Persistence Mode"
# Expected: Persistence Mode : Enabled
________________________________________
Step 11: Optional but recommended — Lock GPU clocks for consistent performance
For research clusters, you usually want predictable performance over thermal headroom.
bash
# Check available clocks
nvidia-smi --query-gpu=clocks.max.sm,clocks.max.memory --format=csv

# 1. Enable Persistence Mode (if not already done)
sudo nvidia-smi -pm 1

# 2. Set the application clocks to the max values you just found
# Format is --applications-clocks=MEM_CLOCK,SM_CLOCK
sudo nvidia-smi --applications-clocks=3201,1785

# 3. (Optional) Lock the hardware clocks so they never downclock
sudo nvidia-smi --lock-gpu-clocks=1785,1785
sudo nvidia-smi --lock-memory-clocks-deferred 3201

# Set persistent application clocks to max (H200 NVL specific - adjust for L4)
# H200 NVL: SM clock 1830 MHz, memory clock 3201 MHz (verify against nvidia-smi output)
# sudo nvidia-smi --applications-clocks=3201,1830

# Or just enable auto-boost which is the default these days and usually fine:
# nvidia-smi --auto-boost-default=ENABLED

# For most research workloads, default behaviour is fine. Skip this step unless 
# you have specific performance variability complaints.

# 1. Stop the persistence daemon so we can unload the driver
sudo systemctl stop nvidia-persistenced

# 2. Attempt to unload the driver modules (this might fail if a process is using it)
sudo modprobe -r nvidia_uvm nvidia_modeset nvidia

# 3. If the above fails, just do a quick reboot—it's the cleanest way
sudo reboot


________________________________________
Step 12: Install NVIDIA Fabric Manager (H200 NVL only, skip for L4)
If the H200 NVL is in NVLink configuration (multiple H200s in one node communicating via NVLink), you need Fabric Manager. For single H200 NVL per node, you don't need this — but install it anyway because it's harmless and future-proofs for adding more GPUs.
Actually, let me correct that — for single GPU systems, fabric-manager is not needed and can cause issues. Skip it unless you're adding multiple GPUs with NVLink later.
________________________________________
Step 13: Reboot once more to confirm everything starts clean
bash
sudo reboot

# After reboot:
nvidia-smi
nvcc --version
systemctl status nvidia-persistenced



L4 Clock stuff
Yes, the clock settings for the NVIDIA L4 will be significantly different from the H200. While the H200 is a "Hopper" beast built for maximum throughput, the L4 is an "Ada Lovelace" card designed for efficiency and versatility (inference, video transcoding, etc.).

If you try to force 1785/3201 on an L4, it will reject the command because those frequencies are physically out of its range.

1. Find the L4 Limits
First, you need to query the specific L4 node (e.g., gpu03) to see what its silicon is capable of:

Bash
nvidia-smi --query-gpu=clocks.max.sm,clocks.max.memory --format=csv
Common L4 Max Clocks (Estimated):

Max SM: Usually around 2040 MHz

Max Memory: Usually around 7501 MHz (L4 uses GDDR6, which is clocked differently than the HBM3e on the H200).

2. Lock the L4 Clocks
Once you have the numbers from the command above, apply them. If your output was 2040,7501, the commands would be:

Bash
# 1. Enable Persistence Mode
sudo nvidia-smi -pm 1

# 2. Set the application clocks for L4
# Based on your query: MEM 6251, SM 2040
sudo nvidia-smi --applications-clocks=6251,2040

# 3. Lock the GPU Core clock
sudo nvidia-smi --lock-gpu-clocks=2040,2040

# 4. Lock the Memory clock (using the deferred flag for the 565 driver)
sudo nvidia-smi --lock-memory-clocks-deferred 6251
