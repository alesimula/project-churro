#!/usr/bin/env bash
# Remove the Trusty-VM-backed HAL declarations from the system_ext VINTF manifest so keystore2
# falls back to its software KeyMint. Usage: patch-system_ext.sh <extracted system_ext tree>
set -euo pipefail
# The Trusty security VM launchers: no Trusty VM image here, so the protected one crash-loops
# (SIGABRT on the missing desktop.security_vm.vm_image property) whenever a client asks for one
# of its interfaces, all session long.
rm -f "$1/etc/init/desktop-trusty_security_vm_launcher.rc"
M=$1/etc/vintf/manifest.xml
[ -f "$M" ] || exit 0
# drop every <hal>...</hal> block that names one of these interfaces
awk '
  /<hal[ >]/ { buf = $0 "\n"; inhal = 1; next }
  inhal { buf = buf $0 "\n"
          if ($0 ~ /<\/hal>/) { inhal = 0
            if (buf !~ /security\.keymint|security\.secureclock|security\.sharedsecret|finger_guard|KeyMintProvisioningService/) printf "%s", buf }
          next }
  { print }' "$M" > "$M.new"
cat "$M.new" > "$M"; rm -f "$M.new"   # rewrite in place: keeps the file's SELinux label (xattr)
echo "   system_ext VINTF: $(grep -c '<hal' "$M") HALs left"
