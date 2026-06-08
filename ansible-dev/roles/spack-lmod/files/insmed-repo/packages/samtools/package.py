# Site backport: adds samtools@1.20 to match burdentesting image.
# Inherits from upstream builtin samtools; only adds the new version().
#
# Why depends_on() is also declared: upstream's samtools package uses
# version-qualified depends_on() (e.g. when="@1.19:1.19.X") to bind each
# release to a matching htslib. Our new 1.20 doesn't fall inside any of
# those when= clauses, so concretization skipped htslib → KeyError
# 'No spec with name htslib' at configure_args time. Declaring it here
# fixes the graph.
#
# Remove this file when bumping Spack to a version that ships 1.20 natively.

from spack.pkg.builtin.samtools import Samtools as BuiltinSamtools


class Samtools(BuiltinSamtools):
    version("1.20", sha256="c71be865e241613c2ca99679c074f1a0daeb55288af577db945bdabe3eb2cf10")
    depends_on("htslib@1.20", when="@1.20")
