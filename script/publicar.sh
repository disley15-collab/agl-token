#!/usr/bin/env bash
# Publica o AGL numa rede (fork: passar RPC de um anvil). Uso: script/publicar.sh <rede> [rpc]
set -uo pipefail
cd "$(dirname "$0")/.."
REDE=$1
read -r nome id rpc pm moeda casas < <(awk -F'\t' -v n=$REDE '$1==n' script/redes.tsv)
R=${2:-$rpc}
PK=${AGL_PK:-$(cat ~/credenciais/sdbr-deployer.key)}
[[ $(cast chain-id --rpc-url $R) == "$id" ]] || { echo "RPC da rede errada"; exit 1; }
SALT_POOL=$(python3 -c "import json;print(json.load(open('script/salt-pool.json'))['salt'])")
SALT_TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['salt'])")
TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['endereco'])")
python3 script/escada.py --token $TOKEN --moeda $moeda --casas-moeda $casas --chainid $id > script/escada-$REDE.json
AGL_PK=$PK SALT_POOL=$SALT_POOL SALT_TOKEN=$SALT_TOKEN PM=$pm MOEDA=$moeda DONO=0x979514BddD0346FdD218c49B8242b92C1A6D0ffC \
  ESCADA=script/escada-$REDE.json forge script script/Publicar.s.sol --rpc-url $R --broadcast --slow -q > publicacao-$REDE.log 2>&1
echo "[$REDE] forge script: código $?"
grep -E "pool/hook|token|rror" publicacao-$REDE.log | head -5
script/conferir.sh $REDE $R
