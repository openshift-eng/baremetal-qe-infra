#!/bin/bash

set -eEo pipefail

function fail() {
  echo "$1"
  exit 1
}

function download_and_verify() {
  local arch="$1"
  local urls="$2"
  local artifact="$3"
  local destination="$4"
  if [ -f "${destination}/${artifact}" ]; then
    echo "<4>~~ ${arch}/${artifact} is already available ~~"
    return
  fi
  set -exo pipefail
  TMPDIR=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf ${TMPDIR}; fail 'Failed downloading and verifying ${arch}/${artifact}'" ERR SIGINT SIGTERM
  pushd "${TMPDIR}"

  local location
  local signature
  location="$(jq -r ."${artifact}".location <<< "${urls}")"
  signature="$(jq -r ."${artifact}".signature <<< "${urls}")"
  curl -f -o "./${artifact}" "${location}"
  curl -f -o "./${artifact}.sig" "${signature}"
  echo "$(jq -r ."${artifact}".sha256 <<< "${urls}") ${artifact}" > "${artifact}.checksum"
  gpgv --keyring /tmp/fedora.gpg "${artifact}.sig" "${artifact}"
  sha256sum -c "${artifact}.checksum"
  # Commit: move the file to the destination only if the checksum and signature verifications passed
  mv "./${artifact}" "${destination}/${artifact}"
  popd
  rm -rf "${TMPDIR}"
  trap - ERR SIGINT SIGTERM
}

function end_cmd() {
  # At the end of the process, restore SELinux contexts and restart the podman-based services to allow the container_t context to
  # be set on the newly downloaded files
  restorecon -R "${TFTP_DIR}"
  restorecon -R "${HTTP_DIR}"
  # Allow temporary failures at provisioning time, when the other services might not be ready yet
  systemctl restart dhcp || true
  systemctl restart nginx || true
}

trap end_cmd EXIT

TFTP_DIR=${TFTP_DIR:-/var/opt/dnsmasq/tftpboot}
HTTP_DIR=${HTTP_DIR:-/var/mnt/data-storage/html}
mkdir -p "${TFTP_DIR}"/fcos-{aarch64,x86_64}
mkdir -p "${HTTP_DIR}"/fcos-{aarch64,x86_64}

curl -f -o /tmp/stable.json "https://builds.coreos.fedoraproject.org/streams/stable.json"
curl -f -o /tmp/fedora.gpg "https://fedoraproject.org/fedora.gpg"
fcos_release=$(jq -r .architectures.aarch64.artifacts.metal.release /tmp/stable.json)
echo "<4>~~ Downloading Fedora CoreOS Release ${fcos_release} ~~"
for arch in aarch64 x86_64; do
  urls="$(jq -rc .architectures."${arch}".artifacts.metal.formats.pxe /tmp/stable.json)"
  find "${TFTP_DIR}/fcos-${arch}" -type f -mtime +60 -exec rm {} \;
  find "${HTTP_DIR}/fcos-${arch}" -type f -mtime +60 -exec rm {} \;
  download_and_verify "${arch}" "${urls}" kernel "${TFTP_DIR}/fcos-${arch}"
  download_and_verify "${arch}" "${urls}" initramfs "${TFTP_DIR}/fcos-${arch}"
  download_and_verify "${arch}" "${urls}" rootfs "${HTTP_DIR}/fcos-${arch}"
done

# Download upstream ipxe
mkdir -p "${HTTP_DIR}"/ipxe

# Copy working ARM64 iPXE USB from static location (newer versions from boot.ipxe.org have issues chainloading grubaa64.efi)
cp /usr/share/bastion_services/ipxe/ipxe.aarch64.usb "${HTTP_DIR}/ipxe/"
