# Dashboard da planta simulada

Interface web em tempo real para o banco `fabrica_iot`. Mostra a planta ao vivo, executa as demonstrações e exibe os resultados do benchmark.

O servidor é Node.js com Express. A comunicação com o navegador usa Server-Sent Events, e as notificações da trigger chegam via `LISTEN alertas_fabrica`. Gráficos (Chart.js) e fontes são servidos localmente, então tudo funciona sem internet no dia da apresentação.

## Instalar e rodar

Pré-requisito: Node.js 16 ou mais recente (`node -v`). No Ubuntu, se não tiver: `sudo apt install -y nodejs npm`.

```bash
cd dashboard
npm install
npm start
```

Abra **http://localhost:3000**.

O servidor conecta pelo socket local (`/var/run/postgresql`) com o seu usuário Linux, que é o mesmo usuário criado pelo `setup.sh`, então não precisa de senha. Para outro banco ou usuário, use as variáveis padrão do PostgreSQL:

```bash
PGHOST=localhost PGUSER=rks PGPASSWORD=suasenha PGDATABASE=fabrica_iot npm start
```

Para mostrar o dashboard em outro computador da mesma rede (por exemplo, o do projetor), rode com `HOST=0.0.0.0 npm start` e acesse `http://IP-DA-MAQUINA:3000`.

## Telas

| Tela | O que mostra e o que dá para fazer |
|---|---|
| Planta ao vivo | Leituras por segundo, equipamentos por área com status (forma + cor), alarmes que piscam até serem reconhecidos, tendência de vazão e notificações da trigger em tempo real. Clicar num equipamento mostra os sensores e permite colocá-lo em manutenção. |
| Laboratório | **Leitura manual**: escolha um sensor, veja as faixas normal, de atenção e crítica, insira um valor e veja exatamente o que a trigger fez (alerta aberto ou incrementado, escalada de severidade, mudança de status, tempo gasto). **Geração de carga**: roda a procedure `sp_simular_fluxo` ou uma carga concorrente com N conexões. **Plano de execução lado a lado**: compara consultas com e sem filtro de período, dados brutos contra a view materializada, e busca por id com e sem data, mostrando quantas partições cada uma leu. |
| Benchmark | Executa `sp_executar_benchmark` com log ao vivo, gráfico por cenário (escala logarítmica), tabela com ganho e plano, tamanho dos índices e vazão de escrita de cada execução. |
| Dados e ciclo de vida | Leituras por partição, botão de arquivamento (> 30 dias) com antes e depois, linha do tempo da tabela temporal de status com disponibilidade, e relatório de produção da view materializada. |

## Roteiro sugerido para a apresentação

1. Abra a **Planta ao vivo** com todos os equipamentos operando.
2. No **Laboratório**, insira 200 °C na CALD-01 (atenção) e na CALD-02 (crítico). Volte à planta para ver os alarmes piscando e as notificações chegando.
3. Rode a **carga concorrente** com 16 conexões e acompanhe a vazão e os alarmes ao vivo.
4. Mostre o **plano de execução lado a lado** (filtro de período: 1 partição lida contra todas).
5. Na aba **Benchmark**, mostre o gráfico e, se houver tempo, execute um benchmark novo.
6. Em **Dados e ciclo de vida**, mostre a linha do tempo de status gerada pela demonstração e o arquivamento.

Só uma tarefa longa roda por vez (simulador, carga, benchmark ou arquivamento). Os botões ficam desativados enquanto uma delas está em execução.
