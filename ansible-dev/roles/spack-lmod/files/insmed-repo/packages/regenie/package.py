from spack.package import *


class Regenie(Package):
    """Whole-genome regression for quantitative and binary phenotypes,
    including rare-variant burden / SKAT testing. This package installs
    the pre-built static gz binary from the upstream GitHub release."""

    homepage = "https://github.com/rgcgithub/regenie"
    maintainers = ["insmed-research"]

    version(
        "3.4.1",
        sha256="0f09ffca6dc33905c36146d203ab4fca7ea7d2b1cc71611942ddd4311f4f127c",
        url="https://github.com/rgcgithub/regenie/releases/download/v3.4.1/regenie_v3.4.1.gz_x86_64_Linux.zip",
        expand=True,
    )

    def install(self, spec, prefix):
        mkdirp(prefix.bin)
        binary = f"regenie_v{self.version}.gz_x86_64_Linux"
        install(binary, prefix.bin.regenie)
        set_executable(prefix.bin.regenie)
