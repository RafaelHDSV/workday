# Workday — overlay de expediente

Overlay leve com contagens do expediente (entrada, almoço, saída e extras), posicionado junto à barra de tarefas, com log de horas extras.

## Executar (sem CMD aberto)

Dê **duplo clique** em `workday-start.vbs` (ou em `workday-start.bat`, que chama o VBS).

O VBS sobe o PowerShell em modo oculto — nenhuma janela de console fica aberta.

## Iniciar com o Windows (opcional)

1. Pressione `Win + R`, digite `shell:startup` e confirme.
2. Crie um atalho para **`workday-start.vbs`** nessa pasta.

Para remover: apague o atalho e encerre o processo PowerShell do overlay (Gerenciador de Tarefas).

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
- **Clique direito → Ver extras:** atualiza e abre o relatório de horas extras
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

Prefira **Configurar…** no menu ou arrastar o overlay; editar o JSON também funciona (relê no próximo start).

## Log de extras (ligar / desligar)

O overlay consulta o **Event Log** do Windows (ligar/desligar — **todo o histórico ainda retido** pelo log System) e gera:

| Arquivo | Uso |
|---------|-----|
| `data/sessions.jsonl` | Histórico bruto das sessões |
| `data/extras.md` | Relatório para consulta |
| `data/config.json` | Horários e posição |

- **Early / Late:** usam `entryHour` / `leaveHour` da config
- **Dias úteis** e **fim de semana** têm totais separados
- Detecta ligar/desligar (incluindo sleep híbrido do “Desligar” no Windows moderno)
- Sessões curtas (&lt; 2h) vão para **Dias atípicos**
- **`omitExtrasDates`:** lista `yyyy-MM-dd` com extras forçados a 0 (casos à parte)
- A pasta `data/` é local e está no `.gitignore`
