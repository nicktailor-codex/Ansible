# /etc/profile.d/spack.sh — set up Spack + Lmod for every login shell.
# Deployed to every cluster node by the spack-lmod role. /software/spack is
# NetApp-shared so all nodes see the same module catalogue.

# Source Spack's setup script (idempotent — does nothing if already sourced).
# This sets PATH, defines the `spack` shell function, and prepares Lmod.
if [ -r /software/spack/share/spack/setup-env.sh ]; then
    . /software/spack/share/spack/setup-env.sh
fi

# Make Spack-generated Lmod modulefiles visible to `module avail`.
# Hard-code the expected core dir rather than globbing the existing tree:
# globbing only works if the dir exists at login time, which fails for shells
# opened during a rebuild or before the first spack-build-burden completes.
# Lmod silently tolerates a non-existent entry — it just shows nothing under
# that path until modulefiles are generated there.
if command -v module >/dev/null 2>&1; then
    module use /software/spack/share/spack/lmod/linux-ubuntu24.04-x86_64/Core
fi
