import json
T='0x0000000000109de411eabC9f04906d79F06FDa0e'; P='0x0000000456b76bc801253eF2366664750F602840'
R='0xcF429Bbbbc6498f50418a7A5996Ab35A76ba001a'; E='0xA7f625C1a64893eB803c0a3b4316E4832809eC48'; C='0xd02F76eA336552D8019f7596E47EbDB4685d0528'
SITE='https://agl.soliditybrasil.com.br'
REDES=[('BNB Chain',56,'https://bscscan.com'),('Base',8453,'https://basescan.org'),('Arbitrum',42161,'https://arbiscan.io'),('Polygon',137,'https://polygonscan.com'),('Optimism',10,'https://optimistic.etherscan.io'),('Avalanche',43114,'https://snowtrace.io'),('Celo',42220,'https://celoscan.io'),('Ethereum',1,'https://etherscan.io')]
linhas=''.join(f'<tr><td>{n}</td><td>{i}</td><td><a href="{x}/token/{T}" rel="noopener">explorador</a> · <a href="https://repo.sourcify.dev/{i}/{T}" rel="noopener">código</a></td></tr>' for n,i,x in REDES)
html=f'''<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AgroLastro (AGL) · Solidity Brasil</title>
<meta name="description" content="AGL, token da AgroLastro (Solidity Brasil): escrow on-chain para o comércio agro lusófono. Mesmo contrato em 8 redes: {T}.">
<link rel="icon" href="/favicon.ico"><link rel="apple-touch-icon" href="/agl-logo-256.png">
<meta property="og:title" content="AgroLastro (AGL)"><meta property="og:description" content="Escrow on-chain para o comércio agro lusófono. Contrato {T}"><meta property="og:image" content="{SITE}/agl-logo-1024.png"><meta property="og:url" content="{SITE}">
<style>
:root{{--bg:#f6f1e4;--ink:#12201a;--mut:#4b5a51;--ac:#b8860b;--card:#fffdf7;--line:#ddd3bb}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0e1813;--ink:#efe8d6;--mut:#a9b5ac;--ac:#d4a017;--card:#15231c;--line:#2a3a31}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
main{{max-width:880px;margin:0 auto;padding:40px 16px 64px}}header{{display:flex;gap:18px;align-items:center}}header img{{width:72px;height:72px}}
h1{{font-size:clamp(28px,5vw,40px);margin:0;letter-spacing:-.02em}}h2{{font-size:20px;margin:40px 0 12px}}.sub{{color:var(--mut);margin:2px 0 0}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin-top:16px}}
code{{font:14px/1.4 ui-monospace,Menlo,monospace;word-break:break-all}}.end{{display:flex;gap:10px;align-items:center;flex-wrap:wrap}}
button{{font:inherit;font-size:14px;border:1px solid var(--line);background:var(--bg);color:var(--ink);border-radius:8px;padding:6px 12px;cursor:pointer}}
.aviso{{border-left:4px solid var(--ac)}}table{{width:100%;border-collapse:collapse;font-size:15px}}td,th{{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line)}}
a{{color:var(--ac)}}ul{{padding-left:20px}}.links a{{margin-right:16px;white-space:nowrap}}footer{{color:var(--mut);font-size:14px;margin-top:48px}}
</style></head><body><main>
<header><img src="/agl-logo-256.png" alt="Logo AgroLastro" width="72" height="72"><div><h1>AgroLastro (AGL)</h1><p class="sub">Token da plataforma AgroLastro · Solidity Brasil</p></div></header>
<div class="card"><b>Contrato oficial</b>, o mesmo endereço em 8 redes:<div class="end"><code id="t">{T}</code><button onclick="navigator.clipboard.writeText('{T}');this.textContent='Copiado'">Copiar</button></div></div>
<div class="card aviso"><b>Atenção ao símbolo.</b> Existe outro token chamado <i>Apex Gold Ledger</i> que também usa o símbolo AGL. Ele não tem nenhuma relação com a AgroLastro. Confira sempre o nome <b>AgroLastro</b> e o endereço acima.</div>
<h2>O que é</h2><p>A AgroLastro é uma plataforma de escrow em stablecoin para importadores e exportadores do mundo lusófono. O pagamento fica travado num contrato e só é liberado quando a entrega é confirmada. Se o negócio falhar, o comprador recebe 100% de volta. A plataforma não guarda o dinheiro de ninguém: ganha só as taxas.</p>
<p>O AGL paga os serviços do Registro (KYC, cadastro, contato e informações) e circula entre as 8 redes pela ponte LayerZero.</p>
<h2>Como é o token</h2><ul>
<li>1 sextilhão de AGL por rede, 100% numa pool Uniswap v4 AGL/USDC criada na mesma transação do token. A liquidez fica travada para sempre.</li>
<li>Sem dono: a ponte foi renunciada nas 8 redes. Ninguém cria AGL fora da ponte.</li>
<li>Sem taxa de transferência, sem pausa, sem blacklist, sem proxy.</li>
<li>Taxa de 2% nas compras e vendas da pool oficial.</li>
<li>Código verificado no Sourcify nas 8 redes.</li></ul>
<h2>Contratos por rede</h2><div class="card" style="overflow-x:auto"><table><tr><th>Rede</th><th>Chain ID</th><th>Links</th></tr>{linhas}</table></div>
<div class="card"><table>
<tr><td>Pool oficial (hook Uniswap v4)</td><td><code>{P}</code></td></tr>
<tr><td>Registro</td><td><code>{R}</code></td></tr>
<tr><td>Escrow</td><td><code>{E}</code></td></tr>
<tr><td>cAGL confidencial (Ethereum)</td><td><code>{C}</code></td></tr></table></div>
<h2>Comunidade</h2><p class="links"><a href="https://t.me/agrolastro">Telegram: canal oficial</a><a href="https://t.me/agrolastro_comunidade">Telegram: comunidade</a><a href="/token.json">token.json</a><a href="/tokenlist.json">token list</a></p>
<h2>Quem está por trás</h2><p>A AgroLastro é um serviço da Solidity Brasil (<a href="https://soliditybrasil.com.br">soliditybrasil.com.br</a>). Contato pelo canal oficial <a href="https://t.me/agrolastro">t.me/agrolastro</a> e pelo site <a href="https://agl-token.vercel.app/#cadastro">agl-token.vercel.app</a>.</p>
<footer>A equipe nunca pede chave privada, frase de recuperação nem envia "airdrop" por mensagem. O AGL é um token de utilidade: não é investimento nem promessa de valorização.</footer>
</main></body></html>'''
open('index.html','w').write(html)
tok={"name":"AgroLastro","symbol":"AGL","decimals":9,"address":T,"chains":[i for _,i,_ in REDES],"website":SITE,"logo":SITE+"/agl-logo-256.png","logoSvg":SITE+"/agl-logo-32.svg","provider":"Solidity Brasil (https://soliditybrasil.com.br)","telegram":"https://t.me/agrolastro","community":"https://t.me/agrolastro_comunidade","description":"AGL is the utility token of AgroLastro (Solidity Brasil), an on-chain stablecoin escrow platform for agricultural trade across Portuguese-speaking countries. Same contract address on 8 EVM chains; 100% of supply in a Uniswap v4 AGL/USDC pool with locked liquidity; no owner (bridge renounced).","notAffiliatedWith":"Apex Gold Ledger (AGL, Ethereum 0x63401cDd577478F9389A1683e866A937f072D1C2)","officialPoolHook":P,"supplyPerChain":"1000000000000000000000","bridge":"LayerZero v2 OFT (renounced)"}
open('token.json','w').write(json.dumps(tok,indent=1,ensure_ascii=False))
tl={"name":"AgroLastro","timestamp":"2026-11-08T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"logoURI":SITE+"/agl-logo-256.png","keywords":["agrolastro","agl"],"tokens":[{"chainId":i,"address":T,"name":"AgroLastro","symbol":"AGL","decimals":9,"logoURI":SITE+"/agl-logo-256.png"} for _,i,_ in REDES]}
open('tokenlist.json','w').write(json.dumps(tl,indent=1))
open('robots.txt','w').write(f'User-agent: *\nAllow: /\nSitemap: {SITE}/sitemap.xml\n')
open('sitemap.xml','w').write(f'<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>{SITE}/</loc></url></urlset>')
