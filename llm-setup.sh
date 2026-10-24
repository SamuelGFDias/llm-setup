#!/usr/bin/env bash
# llm-setup.sh — diagnostica a máquina, recomenda o tamanho de modelo que cabe
# com folga, grava um teto de memória para o Ollama e sobe a interface (Open WebUI).
# Tudo que o script aloca tem um comando de desalocação correspondente.
#
# Usage:
#   ./llm-setup.sh diagnose              report and recommendation (default, changes nothing)
#   ./llm-setup.sh status                list active services (Ollama, memory ceiling, Open WebUI)
#   ./llm-setup.sh install               install Ollama if missing
#   ./llm-setup.sh apply                 write the memory ceiling (systemd) and pull the recommended model
#   ./llm-setup.sh unapply               remove the memory ceiling
#   ./llm-setup.sh pull <tag> [--force]  pull a specific model, checking it against the ceiling
#   ./llm-setup.sh model-rm <tag> [--yes]  remove a model from Ollama
#   ./llm-setup.sh ui up                 run Open WebUI (podman) wired to Ollama, RAG with bge-m3
#   ./llm-setup.sh ui down               stop and remove the Open WebUI container (keeps its data)
#   ./llm-setup.sh ui purge [--yes]      remove the container AND its data volume
#   ./llm-setup.sh up                    start all services (Ollama, then Open WebUI)
#   ./llm-setup.sh down                  stop all services (Open WebUI, then Ollama); data is kept
#   ./llm-setup.sh uninstall [--yes] [--purge-models]  remove everything above, plus Ollama itself
set -euo pipefail

# ---- Parâmetros de decisão (ajuste aqui) -----------------------------------
FOLGA_RAM=0.50     # sem GPU dedicada: usa até 50% da RAM disponível
FOLGA_VRAM=0.85    # com GPU NVIDIA: usa até 85% da VRAM total
OVERHEAD_MB=600    # contexto, buffers e runtime, reservados fora do modelo
GB_POR_B=0.60      # GB de modelo por bilhão de parâmetros (quantização Q4)
TETO_MEM_HIGH=65   # % da RAM em que o systemd começa a pressionar o serviço
TETO_MEM_MAX=75    # % da RAM em que o systemd encerra o serviço (protege o resto do sistema)

# Interface e embeddings
OLLAMA_URL="http://127.0.0.1:11434"
EMBED_TAG="bge-m3:latest"
UI_NOME="open-webui"
UI_IMAGEM="ghcr.io/open-webui/open-webui:main"
UI_PORTA=3000
UI_VOLUME="open-webui"
LIMITES_DIR="/etc/systemd/system/ollama.service.d"
LIMITES_CONF="$LIMITES_DIR/limites.conf"

# Tamanhos disponíveis: "<bilhões de parâmetros> <tag do Ollama>"
TIERS=(
  "0.5 qwen2.5:0.5b"
  "1.5 qwen2.5:1.5b"
  "3 qwen2.5:3b"
  "7 qwen2.5:7b"
  "14 qwen2.5:14b"
  "32 qwen2.5:32b"
  "72 qwen2.5:72b"
)

# Flags globais (preenchidas em main)
ASSUME_YES=0
PURGE_MODELS=0
FORCE=0
POS=()

# ---- Helpers ---------------------------------------------------------------
titulo() { printf '\n== %s ==\n' "$1"; }

confirma() { # pergunta sim/não; --yes responde sim direto
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local resp
  read -r -p "$1 [s/N] " resp || resp=""
  [[ "$resp" =~ ^[sSyY]$ ]]
}

params_de() { # tag -> bilhões de parâmetros (vazio se a tag não estiver na lista)
  local item
  for item in "${TIERS[@]}"; do
    if [[ "${item#* }" == "$1" ]]; then
      echo "${item%% *}"
    fi
  done
}

maior_tier_ate() { # limite em bilhões -> maior tag que cabe
  local item p tag escolhido=""
  for item in "${TIERS[@]}"; do
    p=${item%% *}
    tag=${item#* }
    if awk -v p="$p" -v m="$1" 'BEGIN{exit !(p<=m)}'; then
      escolhido="$tag"
    fi
  done
  echo "$escolhido"
}

# ---- Detecção --------------------------------------------------------------
detecta() {
  CPU_NOME=$(lscpu | awk -F': *' '/Model name/{print $2; exit}')
  CPU_THREADS=$(nproc)
  RAM_TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  RAM_LIVRE_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
  DISCO_LIVRE_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')

  GPU_NVIDIA=0
  GPU_NOME=""
  VRAM_TOTAL_MB=0
  VRAM_LIVRE_MB=0
  GPU_QTD_NVIDIA=0
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    GPU_NVIDIA=1
    GPU_QTD_NVIDIA=$(nvidia-smi -L | wc -l)
    # Se houver mais de uma NVIDIA, usa a de maior VRAM
    linha=$(nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits | sort -t, -k2 -nr | head -1)
    GPU_NOME=$(echo "$linha" | awk -F', *' '{print $1}')
    VRAM_TOTAL_MB=$(echo "$linha" | awk -F', *' '{print int($2)}')
    VRAM_LIVRE_MB=$(echo "$linha" | awk -F', *' '{print int($3)}')
  fi

  # Classes PCI de vídeo: 0300 VGA, 0302 3D, 0380 display
  OUTRAS_GPUS=$(lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]' | grep -viE 'nvidia' | sed 's/^[^ ]* //' || true)

  OLLAMA_OK=0
  if command -v ollama >/dev/null 2>&1; then OLLAMA_OK=1; fi
}

# Calcula o teto de parâmetros (em bilhões) e o modo de uso
calcula_teto() {
  if [[ $GPU_NVIDIA -eq 1 ]]; then
    MODO="GPU NVIDIA (VRAM)"
    orcamento_mb=$(awk -v t="$VRAM_TOTAL_MB" -v f="$FOLGA_VRAM" -v o="$OVERHEAD_MB" 'BEGIN{printf "%d", t*f - o}')
  else
    MODO="CPU (RAM)"
    orcamento_mb=$(awk -v t="$RAM_LIVRE_MB" -v f="$FOLGA_RAM" -v o="$OVERHEAD_MB" 'BEGIN{printf "%d", t*f - o}')
  fi
  if [[ $orcamento_mb -lt 0 ]]; then orcamento_mb=0; fi
  TETO_B=$(awk -v m="$orcamento_mb" -v g="$GB_POR_B" 'BEGIN{printf "%.1f", m/(g*1000)}')
  TAG_RECOMENDADA=$(maior_tier_ate "$TETO_B")
}

# Lista o estado dos serviços que o script gerencia
servicos() {
  titulo "Serviços"
  if command -v ollama >/dev/null 2>&1; then
    if systemctl is-active --quiet ollama 2>/dev/null; then
      echo "Ollama (systemd):     ativo"
    else
      echo "Ollama (systemd):     inativo ou não gerido pelo systemd"
    fi
  else
    echo "Ollama:               não instalado"
  fi

  if [[ -f "$LIMITES_CONF" ]]; then
    echo "Teto de memória:      aplicado ($LIMITES_CONF)"
  else
    echo "Teto de memória:      não aplicado"
  fi

  if curl -s -m 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
    echo "API do Ollama:        respondendo em $OLLAMA_URL"
  else
    echo "API do Ollama:        sem resposta em $OLLAMA_URL"
  fi

  if command -v podman >/dev/null 2>&1; then
    estado=$(podman inspect -f '{{.State.Status}}' "$UI_NOME" 2>/dev/null || true)
    echo "Open WebUI (podman):  ${estado:-não criado}"
    if [[ -n "$estado" ]]; then
      echo "  URL:                http://127.0.0.1:$UI_PORTA"
    fi
    if podman volume exists "$UI_VOLUME" 2>/dev/null; then
      echo "  Volume de dados:    existe ($UI_VOLUME)"
    else
      echo "  Volume de dados:    não existe"
    fi
  else
    echo "Open WebUI:           podman não instalado"
  fi
}

# ---- Comandos --------------------------------------------------------------
diagnose() {
  detecta
  calcula_teto

  titulo "Sistema"
  echo "CPU:        $CPU_NOME ($CPU_THREADS threads)"
  echo "RAM:        ${RAM_TOTAL_MB} MB total, ${RAM_LIVRE_MB} MB disponíveis"
  echo "Swap:       ${SWAP_MB} MB"
  echo "Disco livre em \$HOME: ${DISCO_LIVRE_GB} GB"

  titulo "Placas de vídeo"
  if [[ $GPU_NVIDIA -eq 1 ]]; then
    echo "NVIDIA:     $GPU_NOME — VRAM total ${VRAM_TOTAL_MB} MB, livre ${VRAM_LIVRE_MB} MB (NVIDIAs detectadas: $GPU_QTD_NVIDIA)"
  else
    echo "NVIDIA:     não detectada (ou driver não carregado)"
  fi
  if [[ -n "$OUTRAS_GPUS" ]]; then
    echo "Outras:     $OUTRAS_GPUS"
  fi

  titulo "Ollama"
  if [[ $OLLAMA_OK -eq 1 ]]; then
    echo "Instalado:  $(ollama --version 2>/dev/null | tail -1)"
    modelos=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ')
    echo "Modelos:    ${modelos:-nenhum}"
  else
    echo "Instalado:  não (rode: ./llm-setup.sh install)"
  fi

  titulo "Recomendação"
  echo "Modo de uso:          $MODO"
  echo "Orçamento de memória: $orcamento_mb MB (para o modelo, já descontado o overhead)"
  echo "Teto de parâmetros:   ${TETO_B} B"
  if [[ -n "$TAG_RECOMENDADA" ]]; then
    echo "Modelo recomendado:   $TAG_RECOMENDADA"
  else
    echo "Modelo recomendado:   nenhum cabe com folga; use um sistema com mais memória"
  fi
  echo "Teto do serviço:      MemoryHigh=${TETO_MEM_HIGH}%, MemoryMax=${TETO_MEM_MAX}% da RAM (${RAM_TOTAL_MB} MB)"

  if [[ $DISCO_LIVRE_GB -lt 20 ]]; then
    echo "AVISO: pouco espaço em disco para baixar modelos."
  fi
  if [[ $SWAP_MB -lt 2048 && $GPU_NVIDIA -eq 0 ]]; then
    echo "AVISO: sem swap razoável. Em CPU, um modelo grande pode travar o sistema sem aviso."
  fi

  servicos
}

status() {
  servicos
}

install() {
  if command -v ollama >/dev/null 2>&1; then
    echo "Ollama já instalado: $(ollama --version 2>/dev/null | tail -1)"
    return 0
  fi
  echo "Instalando Ollama com o script oficial..."
  curl -fsSL https://ollama.com/install.sh | sh
  sudo systemctl enable --now ollama
  echo "Ollama instalado."
}

apply() {
  detecta
  calcula_teto
  if [[ $OLLAMA_OK -ne 1 ]]; then
    echo "Ollama não está instalado. Rode primeiro: ./llm-setup.sh install" >&2
    return 1
  fi

  echo "Gravando teto de memória para o serviço ollama..."
  sudo mkdir -p "$LIMITES_DIR"
  sudo tee "$LIMITES_CONF" >/dev/null <<EOF
# Gerado por llm-setup.sh — teto para o Ollama não derrubar o sistema
[Service]
MemoryHigh=${TETO_MEM_HIGH}%
MemoryMax=${TETO_MEM_MAX}%
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart ollama
  echo "Teto aplicado."

  # Espera a API responder antes de baixar (o restart leva alguns segundos)
  for _ in $(seq 1 30); do
    if curl -s -m 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then break; fi
    sleep 1
  done

  if [[ -n "$TAG_RECOMENDADA" ]]; then
    echo "Baixando modelo recomendado: $TAG_RECOMENDADA"
    ollama pull "$TAG_RECOMENDADA"
  fi
}

unapply() {
  if [[ ! -f "$LIMITES_CONF" ]]; then
    echo "Teto de memória já não está aplicado."
    return 0
  fi
  echo "Removendo teto de memória do serviço ollama..."
  sudo rm -f "$LIMITES_CONF"
  sudo rmdir --ignore-fail-on-non-empty "$LIMITES_DIR" 2>/dev/null || true
  sudo systemctl daemon-reload
  if systemctl is-active --quiet ollama 2>/dev/null; then
    sudo systemctl restart ollama
  fi
  echo "Teto removido."
}

pull() {
  local tag="${POS[0]:-}"
  if [[ -z "$tag" ]]; then
    echo "Usage: ./llm-setup.sh pull <tag> [--force]" >&2
    return 1
  fi
  detecta
  calcula_teto
  local p
  p=$(params_de "$tag")
  if [[ -n "$p" ]]; then
    if awk -v p="$p" -v m="$TETO_B" 'BEGIN{exit !(p>m)}'; then
      if [[ "$FORCE" -ne 1 ]]; then
        echo "BLOQUEADO: $tag tem ${p} B, acima do teto de ${TETO_B} B para este sistema." >&2
        echo "Use --force se quiseres tentar mesmo assim (pode travar a máquina)." >&2
        return 1
      fi
      echo "AVISO: $tag acima do teto, baixando por causa de --force."
    fi
  else
    echo "AVISO: tag fora da lista de tamanhos conhecidos; o teto não foi validado."
  fi
  ollama pull "$tag"
}

model_rm() {
  local tag="${POS[0]:-}"
  if [[ -z "$tag" ]]; then
    echo "Usage: ./llm-setup.sh model-rm <tag> [--yes]" >&2
    return 1
  fi
  if ! confirma "Remover o modelo $tag do Ollama?"; then
    echo "Cancelado."
    return 0
  fi
  ollama rm "$tag"
}

ui_down() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman não instalado; nada a fazer."
    return 0
  fi
  if podman inspect "$UI_NOME" >/dev/null 2>&1; then
    podman rm -f "$UI_NOME" >/dev/null
    echo "Contêiner $UI_NOME removido (dados preservados no volume $UI_VOLUME)."
  else
    echo "Contêiner $UI_NOME não existe."
  fi
}

ui_up() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman não instalado. Instale com: sudo dnf install podman" >&2
    return 1
  fi
  if ! curl -s -m 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
    echo "AVISO: o Ollama não responde em $OLLAMA_URL; a UI sobe mas sem modelos." >&2
  fi
  # Recria o contêiner com a configuração atual; o volume de dados é mantido
  podman rm -f "$UI_NOME" >/dev/null 2>&1 || true
  echo "Subindo $UI_NOME em http://127.0.0.1:$UI_PORTA ..."
  podman run -d --name "$UI_NOME" --network=host \
    -e HOST=127.0.0.1 -e PORT="$UI_PORTA" \
    -e OLLAMA_BASE_URL="$OLLAMA_URL" \
    -e RAG_EMBEDDING_ENGINE=ollama -e RAG_EMBEDDING_MODEL="$EMBED_TAG" \
    -v "$UI_VOLUME":/app/backend/data \
    --restart unless-stopped "$UI_IMAGEM" >/dev/null

  for _ in $(seq 1 40); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$UI_PORTA/")" == "200" ]]; then
      echo "Pronto: http://127.0.0.1:$UI_PORTA"
      return 0
    fi
    sleep 4
  done
  echo "Contêiner criado, mas a UI não respondeu. Veja: podman logs $UI_NOME" >&2
  return 1
}

ui_purge() {
  if ! confirma "Remover o contêiner $UI_NOME E todos os dados do volume $UI_VOLUME (conversas, contas, RAG)?"; then
    echo "Cancelado."
    return 0
  fi
  ui_down
  if podman volume exists "$UI_VOLUME" 2>/dev/null; then
    podman volume rm -f "$UI_VOLUME" >/dev/null
    echo "Volume $UI_VOLUME removido."
  fi
}

up_all() {
  if ! command -v ollama >/dev/null 2>&1; then
    echo "Ollama não está instalado. Rode primeiro: ./llm-setup.sh install" >&2
    return 1
  fi
  echo "Iniciando serviço do Ollama..."
  sudo systemctl start ollama
  for _ in $(seq 1 30); do
    if curl -s -m 2 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  ui_up
}

down_all() {
  ui_down
  if command -v ollama >/dev/null 2>&1; then
    echo "Parando serviço do Ollama..."
    sudo systemctl stop ollama
  fi
  echo "Todos os serviços parados. Dados e modelos foram mantidos."
}

uninstall() {
  if ! confirma "Desinstalar TUDO: Open WebUI (com dados), teto de memória e Ollama (binário, serviço, usuário$([[ $PURGE_MODELS -eq 1 ]] && echo ', modelos'))?"; then
    echo "Cancelado."
    return 0
  fi

  echo "Removendo Open WebUI..."
  ui_down
  podman volume rm -f "$UI_VOLUME" >/dev/null 2>&1 || true

  echo "Removendo teto de memória..."
  sudo rm -f "$LIMITES_CONF"
  sudo rmdir --ignore-fail-on-non-empty "$LIMITES_DIR" 2>/dev/null || true

  echo "Parando e removendo o serviço do Ollama..."
  sudo systemctl disable --now ollama 2>/dev/null || true
  sudo rm -f /etc/systemd/system/ollama.service
  sudo systemctl daemon-reload

  echo "Removendo binário e bibliotecas..."
  sudo rm -f /usr/local/bin/ollama
  sudo rm -rf /usr/local/lib/ollama

  echo "Removendo usuário e grupo ollama..."
  sudo userdel ollama 2>/dev/null || true
  sudo groupdel ollama 2>/dev/null || true

  if [[ $PURGE_MODELS -eq 1 ]]; then
    echo "Removendo modelos (/usr/share/ollama)..."
    sudo rm -rf /usr/share/ollama
  else
    echo "Modelos mantidos em /usr/share/ollama (use --purge-models para apagar)."
  fi
  echo "Desinstalação concluída."
}

# ---- Entrada ---------------------------------------------------------------
ajuda() {
  cat <<'EOF'
Uso: ./llm-setup.sh <comando> [opções]

Diagnóstico:
  diagnose                    recomendação de modelo e estado geral (padrão; não altera nada)
  status                      lista os serviços ativos (Ollama, teto de memória, API, UI)

Serviços:
  up                          sobe tudo (Ollama e depois Open WebUI); dados mantidos
  down                        derruba tudo (Open WebUI e depois Ollama); dados mantidos

Ollama:
  install                     instala o Ollama se não existir
  apply                       grava o teto de memória e baixa o modelo recomendado
  unapply                     remove o teto de memória
  pull <tag> [--force]        baixa um modelo, validando contra o teto
  model-rm <tag> [--yes]      remove um modelo

Open WebUI (podman):
  ui up                       cria ou recria o contêiner, ligado ao Ollama, com RAG (bge-m3)
  ui down                     remove o contêiner, mantendo os dados
  ui purge [--yes]            remove o contêiner e apaga os dados

Remoção total:
  uninstall [--yes] [--purge-models]
                              remove a UI (com dados), o teto e o Ollama; modelos só com --purge-models

Opções:
  --yes                       responde sim às confirmações
  --force                     permite pull acima do teto de memória
  -h, --help                  mostra esta ajuda
EOF
}

main() {
  local cmd="${1:-diagnose}"
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --yes)          ASSUME_YES=1 ;;
      --purge-models) PURGE_MODELS=1 ;;
      --force)        FORCE=1 ;;
      *)              POS+=("$arg") ;;
    esac
  done

  case "$cmd" in
    -h|--help|help) ajuda ;;
    diagnose)  diagnose ;;
    status)    status ;;
    install)   install ;;
    apply)     apply ;;
    unapply)   unapply ;;
    pull)      pull ;;
    model-rm)  model_rm ;;
    ui)
      case "${POS[0]:-}" in
        up)    ui_up ;;
        down)  ui_down ;;
        purge) ui_purge ;;
        *)     echo "Usage: ./llm-setup.sh ui <up|down|purge> [--yes]" >&2; exit 1 ;;
      esac ;;
    up)        up_all ;;
    down)      down_all ;;
    uninstall) uninstall ;;
    *)         echo "Comando desconhecido: $cmd" >&2; echo >&2; ajuda >&2; exit 1 ;;
  esac
}

main "$@"
