# Site backport: adds bcftools@1.20 to match burdentesting image.
# Inherits from upstream builtin bcftools; only adds the new version().
#
# Why depends_on() is also declared: upstream's bcftools package uses
# version-qualified depends_on() (e.g. when="@1.19:1.19.X") to bind each
# release to a matching htslib. Our new 1.20 doesn't fall inside any of
# those when= clauses, so concretization skipped htslib → KeyError
# 'No spec with name htslib' at configure_args time. Declaring it here
# fixes the graph.
#
# Remove this file when bumping Spack to a version that ships 1.20 natively.

from spack.pkg.builtin.bcftools import Bcftools as BuiltinBcftools


class Bcftools(BuiltinBcftools):
    version("1.20", sha256="312b8329de5130dd3a37678c712951e61e5771557c7129a70a327a300fda8620")
    depends_on("htslib@1.20", when="@1.20")
