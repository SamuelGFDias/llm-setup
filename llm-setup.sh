#!/usr/bin/env bash
# llm-setup.sh — diagnostica a máquina, recomenda o tamanho de modelo que cabe
# com folga e grava um teto de memória para o Ollama não derrubar o sistema.
#
# Usage:
#   ./llm-setup.sh diagnose              report and recommendation (default, changes nothing)
#   ./llm-setup.sh install               install Ollama if missing
#   ./llm-setup.sh apply                 write the memory ceiling (systemd) and pull the recommended model
#   ./llm-setup.sh pull <tag> [--force]  pull a specific model, checking it against the ceiling
set -euo pipefail

# ---- Parâmetros de decisão (ajuste aqui) -----------------------------------
FOLGA_RAM=0.50     # sem GPU dedicada: usa até 50% da RAM disponível
FOLGA_VRAM=0.85    # com GPU NVIDIA: usa até 85% da VRAM total
OVERHEAD_MB=600    # contexto, buffers e runtime, reservados fora do modelo
GB_POR_B=0.60      # GB de modelo por bilhão de parâmetros (quantização Q4)
TETO_MEM_HIGH=65   # % da RAM em que o systemd começa a pressionar o serviço
TETO_MEM_MAX=75    # % da RAM em que o systemd encerra o serviço (protege o resto do sistema)

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

# ---- Helpers ---------------------------------------------------------------
titulo() { printf '\n== %s ==\n' "$1"; }

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
    if systemctl is-active --quiet ollama 2>/dev/null; then
      echo "Serviço:    ativo"
    else
      echo "Serviço:    inativo ou não gerido pelo systemd"
    fi
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
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  sudo tee /etc/systemd/system/ollama.service.d/limites.conf >/dev/null <<EOF
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
    if curl -s -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then break; fi
    sleep 1
  done

  if [[ -n "$TAG_RECOMENDADA" ]]; then
    echo "Baixando modelo recomendado: $TAG_RECOMENDADA"
    ollama pull "$TAG_RECOMENDADA"
  fi
}

pull() {
  local tag="${1:-}" forcar="${2:-}"
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
      if [[ "$forcar" != "--force" ]]; then
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

case "${1:-diagnose}" in
  diagnose) diagnose ;;
  install)  install ;;
  apply)    apply ;;
  pull)     shift; pull "$@" ;;
  *)        echo "Unknown command: $1" >&2; echo "See the script header for usage." >&2; exit 1 ;;
esac
