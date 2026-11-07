#!/usr/bin/env python3
"""Escada da pool AGL de UMA rede (ticks e quantidades).

Modelo (07/11/2026):
  - cada rede tem 1/7 de 1 sextilhão; 5% vai ao dono, 95% à pool;
  - a escada tem --degraus degraus com a MESMA quantidade de token (95%/degraus); o preço
    multiplica por --crescimento a cada degrau (padrão 1,5x, 19 degraus de 5%);
  - o preço inicial é calibrado para a META: quando a escada inteira é comprada, o dono
    ganhou (taxas de 2% das compras) + (USDT/USDC de vender os 5% dele de volta na pool)
    = --meta-usd / --redes nesta rede.

Num degrau [p, r*p] com X tokens, comprar tudo custa X * p * sqrt(r) (sem a taxa).

Uso: escada.py --token 0x.. --moeda 0x.. --casas-moeda 18 --chainid 56 > escada.json
"""
import argparse, json
from decimal import Decimal as D, getcontext

getcontext().prec = 80

SUPPLY_TOTAL = 10**30      # unidades (1 sextilhão, 9 casas)
REDES = 7
CASAS = 9
TAXA = D("0.02")
MIN_TICK, MAX_TICK = -887272, 887272


def supply_da_rede(chainid):
    parte = SUPPLY_TOTAL // REDES
    return parte + SUPPLY_TOTAL % REDES if chainid == 56 else parte


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--moeda", required=True)
    ap.add_argument("--casas-moeda", type=int, required=True)
    ap.add_argument("--chainid", type=int, required=True)
    ap.add_argument("--espacamento", type=int, default=10)
    ap.add_argument("--meta-usd", type=D, default=D(20_000_000))
    ap.add_argument("--crescimento", type=D, default=D("1.5"))
    ap.add_argument("--degraus", type=int, default=19)
    a = ap.parse_args()

    parte = supply_da_rede(a.chainid)
    dono = parte * 500 // 10_000
    pool = parte - dono
    n, r = a.degraus, a.crescimento
    T = D(pool) / n / D(10**CASAS)          # tokens por degrau
    Td = D(dono) / D(10**CASAS)             # tokens do dono

    def resultado(p1):
        """Preços das bordas, custo (principal) de cada degrau e o que o dono ganha."""
        bordas = [p1 * r**k for k in range(n + 1)]
        custo = [T * bordas[k] * r.sqrt() for k in range(n)]
        principal = sum(custo)
        taxas_compra = principal * TAXA / (1 - TAXA)
        # venda dos 5% do dono do topo para baixo (taxa de 2% sai do token que entra)
        x = Td * (1 - TAXA)
        recebido, k = D(0), n - 1
        while x > 0 and k >= 0:
            pa, pb = bordas[k], bordas[k + 1]
            L = T / (1 / pa.sqrt() - 1 / pb.sqrt())
            cabe = T
            usa = min(x, cabe)
            p_novo = (1 / (1 / pb.sqrt() + usa / L)) ** 2
            recebido += L * (pb.sqrt() - p_novo.sqrt())
            x -= usa
            k -= 1
        return bordas, custo, principal, taxas_compra, recebido

    alvo = a.meta_usd / REDES
    _, _, _, t1, v1 = resultado(D(1))
    p1 = alvo / (t1 + v1)                   # tudo é linear em p1
    bordas, custo, principal, taxas, venda = resultado(p1)

    token_eh_0 = int(a.token, 16) < int(a.moeda, 16)
    esp = a.espacamento
    ln = D("1.0001").ln()

    def tick(usd):
        bruto = usd * D(10) ** a.casas_moeda / D(10**CASAS)   # moeda (unid.) por token (unid.)
        preco = bruto if token_eh_0 else 1 / bruto
        t = int((preco.ln() / ln).to_integral_value())
        t = round(t / esp) * esp
        assert MIN_TICK < t < MAX_TICK, t
        return t

    ticks = [tick(p) for p in bordas]
    faixas = []
    q = pool // n
    for i in range(n):
        lo, hi = ticks[i], ticks[i + 1]
        if not token_eh_0:
            lo, hi = hi, lo
        faixas.append({"inferior": lo, "superior": hi, "quantidade": str(q if i < n - 1 else pool - q * (n - 1))})

    out = {
        "chainid": a.chainid,
        "tokenEhMoeda0": token_eh_0,
        "espacamento": esp,
        "tickInicial": ticks[0],
        "degraus": n,
        "supplyDaRede": str(parte),
        "dono": str(dono),
        "naPool": str(pool),
        "faixas": faixas,
        "usd": {
            "precoInicial": f"{p1:.6e}",
            "precoTopo": f"{bordas[-1]:.6e}",
            "fdvRedeInicial": f"{p1 * D(parte) / D(10**CASAS):.2f}",
            "fdvRedeTopo": f"{bordas[-1] * D(parte) / D(10**CASAS):.2f}",
            "primeiroDegrau": f"{custo[0] / (1 - TAXA):.2f}",
            "compradoresGastamEscadaInteira": f"{principal / (1 - TAXA):.2f}",
            "taxasDasCompras": f"{taxas:.2f}",
            "vendaDos5PorCento": f"{venda:.2f}",
            "donoGanhaNaRede": f"{taxas + venda:.2f}",
        },
    }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
