#!/usr/bin/env bash
# Confere a publicação numa rede. Uso: REGISTRO=0x.. ESCROW=0x.. script/conferir.sh <rede> [rpc]
# Sai com código != 0 se qualquer checagem falhar.
set -euo pipefail
cd "$(dirname "$0")/.."
REDE=$1
read -r nome id rpc pm moeda casas < <(awk -F'\t' -v n=$REDE '$1==n' script/redes.tsv)
R=${2:-$rpc}
: "${REGISTRO:?defina REGISTRO}" "${ESCROW:?defina ESCROW}" "${TIMELOCK:?defina TIMELOCK}"
ALL="30102 30184 30110 30109 30111 30106 30125 30101"
EID=$(cast call 0x1a44076050125825900e736c501f859c50fE728c "eid()(uint32)" --rpc-url $R | awk '{print $1}')
EIDS=$(for e in $ALL; do if [[ $e != "$EID" ]]; then printf "%s," $e; fi; done | sed "s/,$//")
POOL=$(python3 -c "import json;print(json.load(open('script/salt-pool.json'))['endereco'])")
TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['endereco'])")
out=$(EIDS=$EIDS TIMELOCK=$TIMELOCK POOL=$POOL TOKEN=$TOKEN REGISTRO=$REGISTRO ESCROW=$ESCROW CASAS_MOEDA=$casas PM=$pm MOEDA=$moeda \
  ESCADA=script/escada-$REDE.json DEPLOYER=0x4a5beD839b3cb0736c03fB3A7eb096701E8A89c8 \
  forge script script/Conferir.s.sol --rpc-url $R 2>&1) || { echo "$out" | grep -E "rror|revert" | head -3; exit 1; }
echo "$out" | grep -E "checagens OK" || { echo "sem resultado"; exit 1; }
