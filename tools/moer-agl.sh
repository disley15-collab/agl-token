#!/usr/bin/env bash
# Pool/hook (bits 0x2000, deployer = carteira de publicação) e depois token (deployer = pool, que publica o token).
set -e
cd "$(dirname "$0")"
DEP=0x4a5beD839b3cb0736c03fB3A7eb096701E8A89c8
./menor_create3 --deployer $DEP --hook --secs ${SEG_POOL:-5400} --min-bits 20 > gpu-pool.jsonl 2> gpu-pool.log
POOL=$(tail -n1 gpu-pool.jsonl | python3 -c 'import json,sys;print(json.load(sys.stdin)["endereco"])')
echo "pool=$POOL" >> gpu-pool.log
./menor_create3 --deployer $POOL --secs ${SEG_TOKEN:-9000} --min-bits 32 > gpu-token.jsonl 2> gpu-token.log
echo FIM >> gpu-token.log
