#!/usr/bin/env bash
# Confere a publicação numa rede. Uso: script/conferir.sh <rede> [rpc]
set -uo pipefail
cd "$(dirname "$0")/.."
REDE=$1
read -r nome id rpc pm moeda casas < <(awk -F'\t' -v n=$REDE '$1==n' script/redes.tsv)
R=${2:-$rpc}
POOL=$(python3 -c "import json;print(json.load(open('script/salt-pool.json'))['endereco'])")
TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['endereco'])")
POOL=$POOL TOKEN=$TOKEN PM=$pm MOEDA=$moeda ESCADA=script/escada-$REDE.json DEPLOYER=0xcDb05fEDD9ef3258e75De23AbF2751aC22156A1c \
  forge script script/Conferir.s.sol --rpc-url $R 2>&1 | grep -E "checagens|rror|revert" | head -3
