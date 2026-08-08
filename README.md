# Workday — overlay de expediente

Contador discreto do expediente encostado na barra de tarefas: quanto falta para entrar, almoçar e sair, e quanto tempo extra já passou da saída. Em paralelo, gera um relatório de horas extras a partir do histórico de ligar/desligar do Windows — sem registrar horários à mão.

Roda em PowerShell 5.1+, sem instalação. Some nos fins de semana; horários e posição são configuráveis.

## Demonstração

O vídeo mostra o overlay percorrendo as fases do contador (antes da entrada, manhã, almoço, tarde e hora extra) e o relatório de extras aberto ao lado.

https://github.com/user-attachments/assets/06cf29e9-9973-4698-a3dc-365ad1bd4aab

## Executar (sem janela de console)

Dê **duplo clique** em `workday-start.bat`.

O overlay sobe em modo oculto — nenhuma janela de console fica aberta, só o contador junto à barra de tarefas.

## Iniciar com o Windows (opcional)

1. Pressione `Win + R`, digite `shell:startup` e confirme.
2. Crie um atalho para **`workday-start.bat`** nessa pasta.

Para remover: apague o atalho e encerre o processo PowerShell do overlay no Gerenciador de Tarefas.

## Comportamento

Em **segunda a sexta** (horários padrão; configuráveis):

| Fase | Horário | Exibição |
|------|---------|----------|
| Antes da entrada | até a hora de entrada | Contagem `-HH:mm:ss` |
| Manhã | até o almoço | Contagem `HH:mm:ss` |
| Almoço | intervalo configurado | Texto **Almoço** |
| Tarde | até a saída | Contagem `HH:mm:ss` |
| Extra | após a saída | Contagem `+HH:mm:ss` |

- **Fim de semana:** overlay oculto
- **Clique direito → Ver extras:** abre o relatório `data/extras.md` (o sync com o Event Log ocorre na subida do overlay)
- **Clique direito → Configurar…:** horários e posição (salva em `data/config.json`)
- **Arrastar o overlay:** move e salva a posição
- **Clique direito → Sair:** encerra o overlay
- **Duplo clique:** oculta até o dia seguinte

## Configuração

Arquivo: `data/config.json` (criado na primeira execução).

| Campo | Padrão | Uso |
|-------|--------|-----|
| `entryHour` | `9` | Hora de entrada |
| `lunchStartHour` | `13` | Início do almoço |
| `lunchEndHour` | `14` | Fim do almoço |
| `leaveHour` | `18` | Hora de saída |
| `trayOffsetPx` | `215` | Distância da borda direita |
| `marginBottom` | `-35` | Margem em relação à base da área útil |
| `omitExtrasDates` | `[]` | Datas `yyyy-MM-dd` com Early/Late/Short forçados a 0 |

Prefira **Configurar…** no menu ou arrastar o overlay; editar o JSON também funciona (relê no próximo start).

## Log de extras (ligar / desligar)

Na subida, o overlay consulta o **Event Log** do Windows (ligar/desligar — todo o histórico ainda retido pelo log System) e gera:

| Arquivo | Uso |
|---------|-----|
| `data/sessions.jsonl` | Histórico bruto das sessões |
| `data/extras.md` | Relatório para consulta |
| `data/config.json` | Horários e posição |

- **Early / Late:** usam `entryHour` / `leaveHour` da config
- **Short (saída antecipada):** em dias úteis encerrados, tempo entre o último desligamento e `leaveHour` (ex.: saiu 16:00 → 2h de déficit)
- **Total líquido:** Early + Late − Short (pode ser negativo no dia; saldo global no resumo)
- **Dias úteis** e **fim de semana** têm totais separados
- Detecta ligar/desligar (incluindo sleep híbrido do “Desligar” no Windows moderno)
- Sessões curtas (&lt; 2h) vão para **Dias atípicos** (reinícios no mesmo dia com gap ≤ 30 min são fundidos antes do relatório)
- A pasta `data/` é local e está no `.gitignore`

## Requisitos

- Windows 10/11
- PowerShell 5.1 ou superior (já incluso no Windows)

## Apoie

<a href="https://www.buymeacoffee.com/vieira" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="32" width="117" style="height: 32px !important; width: 117px !important;" ></a>
