#!/usr/bin/env bash
# Publica o AGL numa rede (fork: passar RPC de um anvil). Uso: script/publicar.sh <rede> [rpc]
# ETAPA 1 (padrão): token, pool, registro, escrow, preços, chaves ao dono. Rodar nas 8 redes.
# ETAPA 2 (LIGAR_PONTE=1): liga a ponte, fixa a configuração e passa ao Timelock. Só depois
# de as 8 redes terem passado na etapa 1.
set -uo pipefail
cd "$(dirname "$0")/.."
REDE=$1
read -r nome id rpc pm moeda casas < <(awk -F'\t' -v n=$REDE '$1==n' script/redes.tsv)
R=${2:-$rpc}
PK=${AGL_PK:-$(cat ~/credenciais/agl-deployer.key)}
[[ $(cast chain-id --rpc-url $R) == "$id" ]] || { echo "RPC da rede errada"; exit 1; }
SALT_POOL=$(python3 -c "import json;print(json.load(open('script/salt-pool.json'))['salt'])")
SALT_TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['salt'])")
TOKEN=$(python3 -c "import json;print(json.load(open('script/salt-token.json'))['endereco'])")
python3 script/escada.py --token $TOKEN --moeda $moeda --casas-moeda $casas > script/escada-$REDE.json
EU=$(cast wallet address --private-key "$PK")
ALL="30102 30184 30110 30109 30111 30106 30125 30101"
EID=$(cast call 0x1a44076050125825900e736c501f859c50fE728c "eid()(uint32)" --rpc-url $R | awk '{print $1}')
EIDS=$(for e in $ALL; do if [[ $e != "$EID" ]]; then printf "%s," $e; fi; done | sed "s/,$//")
SALT_REGISTRO=$(python3 -c "print('$EU'.lower()+'00'+b'agl-registr'.hex())")
SALT_ESCROW=$(python3 -c "print('$EU'.lower()+'00'+b'agl-escrow0'.hex())")
SALT_CAGL=$(python3 -c "print('$EU'.lower()+'00'+b'agl-confid0'.hex())")
LIGAR_PONTE=${LIGAR_PONTE:-false} EIDS=$EIDS AGL_PK=$PK SALT_POOL=$SALT_POOL SALT_TOKEN=$SALT_TOKEN SALT_REGISTRO=$SALT_REGISTRO SALT_ESCROW=$SALT_ESCROW SALT_CAGL=$SALT_CAGL \
  PM=$pm MOEDA=$moeda CASAS_MOEDA=$casas ESCADA=script/escada-$REDE.json forge script script/Publicar.s.sol --rpc-url $R --broadcast --slow > publicacao-$REDE.log 2>&1
cod=$?
echo "[$REDE] forge script: código $cod"
[[ $cod == 0 ]] || { grep -E "rror" publicacao-$REDE.log | head -5; exit 1; }
grep -E "pool/hook|token|registro|escrow|rror" publicacao-$REDE.log | head -6
TIMELOCK=$(grep -oP "timelock \K0x[0-9a-fA-F]+" publicacao-$REDE.log || true) REGISTRO=$(grep -oP "registro \K0x[0-9a-fA-F]+" publicacao-$REDE.log) ESCROW=$(grep -oP "escrow \K0x[0-9a-fA-F]+" publicacao-$REDE.log) script/conferir.sh $REDE $R || exit 1
if [[ $REDE == ethereum ]]; then
  AGL_PK=$PK SALT_CAGL=$SALT_CAGL TOKEN=$TOKEN FOUNDRY_PROFILE=zama forge script zama/script/PublicarConfidencial.s.sol --rpc-url $R --broadcast --slow 2>&1 | grep -E "cAGL|rror" | head -3
fi
