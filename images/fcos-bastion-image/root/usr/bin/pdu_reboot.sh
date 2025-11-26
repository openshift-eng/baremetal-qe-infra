#!/bin/bash

set -euo pipefail

if [ "${#}" -lt 2 ]; then
    echo "Usage: ${0} pdu_uri host_id"
    exit 1
fi

pdu_uri="${1}"
host="${2}"
pdu_host=${pdu_uri%%/*}
pdu_socket=${pdu_uri##*/}
pdu_creds=${pdu_host%%@*}
pdu_host=${pdu_host##*@}
pdu_user=${pdu_creds%%:*}
pdu_pass=${pdu_creds##*:}
# pub-priv key auth is not supported by the PDUs
echo "${pdu_pass}" > /tmp/ssh-pass
PDU_SSHOPTS=(-o 'ConnectTimeout=5'
-o 'StrictHostKeyChecking=no'
-o 'UserKnownHostsFile=/dev/null'
-o 'ServerAliveInterval=90'
-o 'LogLevel=ERROR')

echo "$(date): -- STARTING PDU REBOOT FOR ${host} ---"
sshpass -f /tmp/ssh-pass ssh "${PDU_SSHOPTS[@]}" "${pdu_user}@${pdu_host}" <<EOF || true
olReboot $pdu_socket
quit
EOF

EXIT_CODE=$?
echo "$(date): -- PDU REBOOT FOR host ${host} FINISHED with exit code: $EXIT_CODE ---"
