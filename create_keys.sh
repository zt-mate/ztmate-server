#!/usr/bin/env bash
set -eu

gen_key() {
  keytype=$1
  ks="${keytype}_"
  key="keys/ssh_host_${ks}key"
  if [ ! -e "${key}" ] ; then
    ssh-keygen -t "${keytype}" -f "${key}" -N ''
    echo ""
  fi
  SIG=$(ssh-keygen -l -E SHA256 -f "$key.pub" | cut -d ' ' -f 2)
}

mkdir -p keys
gen_key rsa
RSA_SIG=$SIG
gen_key ed25519
ED25519_SIG=$SIG


echo "You may use the following settings this in your .ztmate.conf:"
echo ""
echo "set -g ztmate-server-host localhost"
echo "set -g ztmate-server-port 22"
echo "set -g ztmate-server-rsa-fingerprint $RSA_SIG"
echo "set -g ztmate-server-ed25519-fingerprint $ED25519_SIG"
