# Site backport: adds gcta@1.94.1 to match burdentesting image (~closest fetchable;
# image had 1.94.4 but that build is only on cn-only Yang Lab host).
# Inherits from upstream builtin gcta; only adds the new version().
#
# Also adds a `gcta -> gcta64` symlink in the install prefix because upstream
# names the 64-bit build `gcta64` (historical hold-over from when 32-bit
# existed) but every user expects `gcta` on PATH. Symlink lives inside the
# install dir so it survives uninstalls/reinstalls.
#
# Remove this file when bumping Spack to a version that ships 1.94.1 natively.

from spack.package import run_after, symlink, working_dir
from spack.pkg.builtin.gcta import Gcta as BuiltinGcta


class Gcta(BuiltinGcta):
    version("1.94.1", commit="6da64e9d8be838d01c34efb974e69c72e861f4c2", submodules=True)

    @run_after("install")
    def add_gcta_symlink(self):
        with working_dir(self.prefix.bin):
            symlink("gcta64", "gcta")
