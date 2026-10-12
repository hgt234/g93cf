# Vendored HardeningKitty dependency

This directory contains the minimal unmodified files needed to audit the CIS Microsoft
Windows 11 Enterprise Benchmark v4.0.0 for Windows 11 24H2.

- Upstream: <https://github.com/scipag/HardeningKitty>
- Version: `0.9.4`
- Commit: `da0976073caad006c48b2478588c2f7fa572ab46`
- License: MIT; the upstream `LICENSE` file is included with the vendored module

Only the module, module manifest, upstream license, signed upstream list manifest, detached
manifest signature, and the 24H2 machine/user finding lists are included. The source files
are not modified. `PackageManifest.psd1` pins every vendored file by SHA-256 and records the
expected list row counts.

Do not update these files individually. Review a complete upstream release, update all
vendored files together, regenerate the package manifest, validate the Authenticode and list
signatures, and rerun the integration tests.
