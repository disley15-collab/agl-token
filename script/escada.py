#!/usr/bin/env python3
"""Escada da pool AGL/USDC de UMA rede (ticks e quantidades).

Modelo v2 (07/11/2026):
  - 1 sextilhão por rede, 100% na pool;
  - --degraus degraus com a MESMA quantidade de token; o preço multiplica por
    --crescimento a cada degrau, começando em --preco-inicial (US$ por AGL);
  - o ÚLTIMO degrau vai até o preço máximo do Uniswap: sempre há AGL à venda e o
    preço não pode ser empurrado de graça para cima.

Num degrau [p, r*p] com X tokens, comprar tudo custa X * p * sqrt(r) (sem a taxa).

Uso: escada.py --token 0x.. --moeda 0x.. --casas-moeda 6 > escada.json
"""
import argparse, json
from decimal import Decimal as D, getcontext

getcontext().prec = 80

SUPPLY = 10**30          # unidades por rede (1 sextilhão, 9 casas)
CASAS = 9
TAXA = D("0.02")
MIN_TICK, MAX_TICK = -887272, 887272


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--moeda", required=True)
    ap.add_argument("--casas-moeda", type=int, required=True)
    ap.add_argument("--espacamento", type=int, default=10)
    ap.add_argument("--preco-inicial", type=D, default=D("0.000000001"))
    ap.add_argument("--crescimento", type=D, default=D("1.5"))
    ap.add_argument("--degraus", type=int, default=20)
    a = ap.parse_args()

    n, r, p1 = a.degraus, a.crescimento, a.preco_inicial
    T = D(SUPPLY) / n / D(10**CASAS)
    bordas = [p1 * r**k for k in range(n + 1)]
    custo = [T * bordas[k] * r.sqrt() for k in range(n - 1)]  # o último é aberto

    token_eh_0 = int(a.token, 16) < int(a.moeda, 16)
    esp = a.espacamento
    ln = D("1.0001").ln()

    def tick(usd):
        bruto = usd * D(10) ** a.casas_moeda / D(10**CASAS)
        preco = bruto if token_eh_0 else 1 / bruto
        t = int((preco.ln() / ln).to_integral_value())
        t = round(t / esp) * esp
        assert MIN_TICK < t < MAX_TICK, t
        return t

    ticks = [tick(p) for p in bordas[:n]]
    limite = (MAX_TICK // esp) * esp
    ticks.append(limite if token_eh_0 else -limite)
    faixas = []
    q = SUPPLY // n
    for i in range(n):
        lo, hi = ticks[i], ticks[i + 1]
        if not token_eh_0:
            lo, hi = hi, lo
        faixas.append({"inferior": lo, "superior": hi, "quantidade": str(q if i < n - 1 else SUPPLY - q * (n - 1))})

    principal = sum(custo)
    out = {
        "tokenEhMoeda0": token_eh_0,
        "espacamento": esp,
        "tickInicial": ticks[0],
        "degraus": n,
        "supply": str(SUPPLY),
        "faixas": faixas,
        "usd": {
            "precoInicial": f"{p1:.3e}",
            "precoInicioUltimoDegrau": f"{bordas[n-1]:.6e}",
            "fdvInicial": f"{p1 * D(SUPPLY) / D(10**CASAS):.2f}",
            "primeiroDegrau": f"{custo[0] / (1 - TAXA):.2f}",
            "compradoresGastamAteUltimoDegrau": f"{principal / (1 - TAXA):.2f}",
            "taxasAteUltimoDegrau": f"{principal * TAXA / (1 - TAXA):.2f}",
        },
    }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
