#!/usr/bin/env bash
# Confere a publicação numa rede. Uso: script/conferir.sh <rede> [rpc]
set -uo pipefail
cd "$(dirname "$0")/.."
REDE=$1
read -r nome id rpc pm moeda casas < <(awk -F'\t' -v n=$REDE '$1==n' script/redes.tsv)
R=${2:-$rpc}
POOL=$(python3 -c "import json;print(json.load(open('script/salt-pool.json'))['endereco'])")
TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['endereco'])")
POOL=$POOL TOKEN=$TOKEN PM=$pm MOEDA=$moeda ESCADA=script/escada-$REDE.json DEPLOYER=0x4a5beD839b3cb0736c03fB3A7eb096701E8A89c8 \
  forge script script/Conferir.s.sol --rpc-url $R 2>&1 | grep -E "checagens|rror|revert" | head -3
