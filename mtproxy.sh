#!/bin/bash
# GoTelegram MTProxy — всё в одном файле.
# Установка: curl -sL -H "Authorization: token TOKEN" https://raw.githubusercontent.com/anten-ka/gotelegram_pro/main/install.sh -o /usr/local/bin/gotelegram && chmod +x /usr/local/bin/gotelegram && gotelegram

# ── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Спиннер и прогресс-бар ────────────────────────────────────────────────────
spin_pid=""
spinner_start() {
  local msg="${1:-Подождите...}"
  (
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
      printf "\r  ${CYAN}${frames[$i]}${NC} ${msg}" >&2
      i=$(( (i+1) % ${#frames[@]} ))
      sleep 0.12
    done
  ) &
  spin_pid=$!
}
spinner_stop() {
  [ -n "$spin_pid" ] && kill "$spin_pid" 2>/dev/null && wait "$spin_pid" 2>/dev/null
  spin_pid=""
  printf "\r\033[K" >&2
}

progress_bar() {
  local current="$1" total="$2" label="${3:-}"
  local pct=$(( current * 100 / total ))
  local filled=$(( pct / 2 ))
  local empty=$(( 50 - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "\r  ${GREEN}[${bar}]${NC} ${pct}%% ${label}" >&2
  [ "$current" -eq "$total" ] && echo "" >&2
}

run_with_progress() {
  local label="$1"; shift
  spinner_start "$label"
  "$@" >/dev/null 2>&1
  local rc=$?
  spinner_stop
  if [ $rc -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label ${RED}(ошибка)${NC}"
  fi
  return $rc
}

# ── Конфиг ───────────────────────────────────────────────────────────────────
CONTAINER_NAME="mtproto-proxy"
BOT_DIR="/opt/gotelegram-bot"
SERVICE_NAME="gotelegram-bot"
TIP_LINK="https://pay.cloudtips.ru/p/7410814f"
PROMO_LINK="https://vk.cc/ct29NQ"

# ── Проверка root ────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите с sudo / root.${NC}"
  exit 1
fi

# ── Установка пакетов ────────────────────────────────────────────────────────
install_pkg() {
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq "$@"
  elif command -v dnf &>/dev/null; then
    dnf install -y "$@" 2>/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y "$@"
  fi
}

install_base_deps() {
  local steps=0 total=4 # curl, docker, qrencode, docker-start

  progress_bar $steps $total "Проверка зависимостей..."
  if ! command -v curl &>/dev/null; then
    run_with_progress "Установка curl" install_pkg curl
  fi
  steps=$((steps+1)); progress_bar $steps $total "curl"

  if ! command -v docker &>/dev/null; then
    spinner_start "Установка Docker (это может занять 1-2 минуты)..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable --now docker >/dev/null 2>&1
    spinner_stop
    echo -e "  ${GREEN}✓${NC} Docker установлен"
  fi
  steps=$((steps+1)); progress_bar $steps $total "docker"

  if ! command -v qrencode &>/dev/null; then
    run_with_progress "Установка qrencode" install_pkg qrencode
  fi
  steps=$((steps+1)); progress_bar $steps $total "qrencode"

  if ! docker info &>/dev/null 2>&1; then
    systemctl start docker 2>/dev/null || true
    sleep 2
  fi
  steps=$((steps+1)); progress_bar $steps $total "Готово"
  echo ""
}

# ── Утилиты ──────────────────────────────────────────────────────────────────
get_ip() {
  local ip
  ip=$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s -4 --max-time 5 https://icanhazip.com 2>/dev/null \
    || echo "0.0.0.0")
  echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}

check_port() {
  local port="$1"
  # Если порт занят нашим контейнером — ОК
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local hp
    hp=$(docker inspect "$CONTAINER_NAME" --format='{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}' 2>/dev/null)
    for p in $hp; do [ "$p" = "$port" ] && return 1; done
  fi
  # Проверяем через ss или netstat
  local line
  line=$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1)
  [ -z "$line" ] && line=$(netstat -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1)
  if [ -n "$line" ]; then
    echo "$line"
    return 0
  fi
  return 1
}

show_containers() {
  local list
  list=$(docker ps --format "{{.Names}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null | grep -v "^${CONTAINER_NAME}")
  if [ -n "$list" ]; then
    echo -e "${CYAN}  Другие контейнеры на сервере:${NC}"
    echo "$list" | while IFS= read -r l; do echo "    $l"; done
  fi
}

proxy_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

# ── Показать данные подключения ──────────────────────────────────────────────
show_config() {
  if ! proxy_is_running; then
    echo -e "${RED}Прокси не запущен! Выберите пункт 1 для установки.${NC}"
    return
  fi
  local SECRET IP PORT LINK
  SECRET=$(docker inspect "$CONTAINER_NAME" --format='{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null | awk '{print $NF}')
  IP=$(get_ip)
  PORT=$(docker inspect "$CONTAINER_NAME" --format='{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}' 2>/dev/null | awk '{print $1}')
  PORT=${PORT:-443}
  LINK="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                   ДАННЫЕ ПОДКЛЮЧЕНИЯ                         ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "  IP:     ${WHITE}$IP${NC}"
  echo -e "  Port:   ${WHITE}$PORT${NC} (TCP + UDP)"
  echo -e "  Secret: ${WHITE}$SECRET${NC}"
  echo ""
  echo -e "  Ссылка: ${BLUE}$LINK${NC}"
  echo ""
  if command -v qrencode &>/dev/null; then
    echo -e "${CYAN}  Наведите камеру телефона на QR-код для подключения:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"
  fi
  echo ""
  show_containers
}

# ── ПРОМО ────────────────────────────────────────────────────────────────────
show_promo() {
  clear
  echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║          ХОСТИНГ СО СКИДКОЙ ДО -60% ОТ ANTEN-KA            ║${NC}"
  echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN} Хостинг #1: $PROMO_LINK ${NC}"
  echo -e "${MAGENTA}❖ ••••••••••••••••••• АКТУАЛЬНЫЕ ПРОМОКОДЫ •••••••••••••••••• ❖${NC}"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "Скидка 60% на ПЕРВЫЙ МЕСЯЦ"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka20" "Буст 20% + 3% (оплата за 3 МЕС)"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka6" "Буст 15% + 5% (оплата за 6 МЕС)"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka12" "Буст 5% + 5% (оплата за 12 МЕС)"
  echo -e "${MAGENTA}❖ •••••••••••••••••••••••••••••••••••••••••••••••••••••••••••• ❖${NC}"
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$PROMO_LINK"
  fi
  echo ""
  echo -e "${CYAN} Хостинг #2: https://vk.cc/cUxAhj ${NC}"
  echo -e "${MAGENTA}❖ ••••••••••••••••••• АКТУАЛЬНЫЕ ПРОМОКОДЫ •••••••••••••••••• ❖${NC}"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "Скидка 60% на ПЕРВЫЙ МЕСЯЦ"
  echo -e "${MAGENTA}❖ •••••••••••••••••••••••••••••••••••••••••••••••••••••••••••• ❖${NC}"
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "https://vk.cc/cUxAhj"
  fi
  echo "--------------------------------------------------------------"
  read -p "Нажмите [ENTER] для возврата в меню..."
}

# ── 1) Установить / Обновить MTProxy ─────────────────────────────────────────
menu_install() {
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       Выберите домен для маскировки (Fake TLS)              ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  local domains=(
    "google.com" "wikipedia.org" "habr.com" "github.com"
    "coursera.org" "udemy.com" "medium.com" "stackoverflow.com"
    "bbc.com" "cnn.com" "reuters.com" "nytimes.com"
    "lenta.ru" "rbc.ru" "ria.ru" "kommersant.ru"
    "stepik.org" "duolingo.com" "khanacademy.org" "ted.com"
  )

  for i in "${!domains[@]}"; do
    printf "  ${YELLOW}%2d)${NC} %-22s" "$((i+1))" "${domains[$i]}"
    [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
  done
  echo ""
  echo -e "  ${CYAN}21)${NC} Ввести свой домен"
  echo ""

  local d_idx DOMAIN
  read -p "Ваш выбор [1-21]: " d_idx
  if [ "$d_idx" = "21" ]; then
    read -p "  Введите домен (например, example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
    if [ -z "$DOMAIN" ] || ! echo "$DOMAIN" | grep -qE '\.'; then
      echo -e "  ${RED}Некорректный домен. Используется google.com${NC}"
      DOMAIN="google.com"
    fi
  else
    DOMAIN=${domains[$((d_idx-1))]}
    DOMAIN=${DOMAIN:-google.com}
  fi
  echo -e "  Домен: ${GREEN}$DOMAIN${NC}"

  # ── Выбор порта с проверкой занятости ────────────────────────────────────
  echo ""
  echo -e "${CYAN}--- Выберите порт ---${NC}"

  local busy_line
  echo -n "  1) 443  (Рекомендуется) "
  if busy_line=$(check_port 443); then
    echo -e "${RED}[ЗАНЯТ: $busy_line]${NC}"
  else
    echo -e "${GREEN}[свободен]${NC}"
  fi

  echo -n "  2) 8443                 "
  if busy_line=$(check_port 8443); then
    echo -e "${RED}[ЗАНЯТ: $busy_line]${NC}"
  else
    echo -e "${GREEN}[свободен]${NC}"
  fi

  echo -e "  3) Свой порт"

  local p_choice PORT
  read -p "  Выбор: " p_choice
  case $p_choice in
    2) PORT=8443 ;;
    3)
      while true; do
        read -p "  Введите порт (1-65535): " PORT
        [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) && break
        echo -e "  ${RED}Неверный порт.${NC}"
      done
      ;;
    *) PORT=443 ;;
  esac

  # Финальная проверка выбранного порта
  if busy_line=$(check_port "$PORT"); then
    echo ""
    echo -e "  ${YELLOW}Порт $PORT занят:${NC}"
    echo -e "  ${RED}$busy_line${NC}"
    echo -e "  1) Всё равно использовать (если это ваш процесс)"
    echo -e "  2) Отмена"
    local force_choice
    read -p "  Выбор: " force_choice
    if [ "$force_choice" != "1" ]; then
      echo -e "  ${YELLOW}Отменено.${NC}"
      read -p "  Нажмите Enter..."
      return
    fi
  fi

  echo ""
  echo -e "${YELLOW}[*] Настройка прокси (домен: $DOMAIN, порт: $PORT)...${NC}"
  echo ""

  # Docker проверка
  if ! docker info &>/dev/null 2>&1; then
    echo -e "${RED}Docker не запущен!${NC}"
    read -p "Нажмите Enter..."
    return
  fi

  local SECRET install_steps=5 install_cur=0

  # Шаг 1: pull образа (всегда проверяем/обновляем)
  install_cur=$((install_cur+1)); progress_bar $install_cur $install_steps "Загрузка образа mtg..."
  spinner_start "Загрузка Docker-образа mtg..."
  docker pull nineseconds/mtg:2 >/dev/null 2>&1
  spinner_stop
  if ! docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "nineseconds/mtg"; then
    echo -e "  ${RED}✗${NC} Не удалось загрузить образ mtg. Проверьте интернет."
    read -p "Нажмите Enter..."
    return
  fi
  echo -e "  ${GREEN}✓${NC} Образ mtg готов"

  # Шаг 2: генерация secret
  install_cur=$((install_cur+1)); progress_bar $install_cur $install_steps "Генерация secret..."
  spinner_start "Генерация secret для $DOMAIN..."
  SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$DOMAIN" 2>&1)
  local secret_rc=$?
  spinner_stop
  if [ $secret_rc -ne 0 ] || [ -z "$SECRET" ]; then
    echo -e "  ${RED}✗${NC} Ошибка генерации secret."
    [ -n "$SECRET" ] && echo -e "  ${RED}$SECRET${NC}"
    read -p "Нажмите Enter..."
    return
  fi
  echo -e "  ${GREEN}✓${NC} Secret сгенерирован"

  # Шаг 3: остановка старого
  install_cur=$((install_cur+1)); progress_bar $install_cur $install_steps "Очистка..."
  docker stop "$CONTAINER_NAME" &>/dev/null
  docker rm "$CONTAINER_NAME" &>/dev/null
  echo -e "  ${GREEN}✓${NC} Старый контейнер удалён"

  # Шаг 4: запуск нового
  install_cur=$((install_cur+1)); progress_bar $install_cur $install_steps "Запуск контейнера..."
  spinner_start "Запуск MTProxy (TCP + UDP)..."
  docker run -d --name "$CONTAINER_NAME" --restart always \
    -p "$PORT":"$PORT"/tcp \
    -p "$PORT":"$PORT"/udp \
    nineseconds/mtg:2 simple-run \
    -n 1.1.1.1 -i prefer-ipv4 \
    0.0.0.0:"$PORT" "$SECRET" > /dev/null 2>&1
  sleep 2
  spinner_stop

  if ! proxy_is_running; then
    echo -e "  ${RED}✗${NC} Контейнер не запустился. Проверьте: docker logs $CONTAINER_NAME"
    read -p "Нажмите Enter..."
    return
  fi
  echo -e "  ${GREEN}✓${NC} Контейнер запущен"

  # Шаг 5: сохранение
  install_cur=$((install_cur+1)); progress_bar $install_cur $install_steps "Готово!"
  mkdir -p "$BOT_DIR"
  cat > "$BOT_DIR/proxy.json" << CFGEOF
{"domain": "$DOMAIN", "port": "$PORT", "secret": "$SECRET"}
CFGEOF

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Прокси установлен! (TCP + UDP, звонки поддержаны)${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  show_config
  read -p "Нажмите Enter для возврата в меню..."
}

# ── 3) Настроить Telegram-бот ─────────────────────────────────────────────────
menu_setup_bot() {
  clear
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║            Настройка Telegram-бота                          ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

  # Проверка статуса
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "  Статус бота: ${GREEN}работает${NC}"
    echo ""
    # Показываем текущие настройки
    local cur_ids
    cur_ids=$(grep "^ALLOWED_IDS=" "$BOT_DIR/.env" 2>/dev/null | cut -d= -f2)
    if [ -n "$cur_ids" ]; then
      echo -e "  Администратор(ы): ${WHITE}$cur_ids${NC}"
    else
      echo -e "  Администратор: ${YELLOW}не задан (бот доступен всем)${NC}"
    fi
    echo ""
    echo -e "  1) Обновить файлы бота и перезапустить"
    echo -e "  2) Изменить BOT_TOKEN"
    echo -e "  3) Изменить администратора (ALLOWED_IDS)"
    echo -e "  4) Остановить бота"
    echo -e "  0) Назад"
    local sub
    read -p "  Выбор: " sub
    case $sub in
      1)
        write_bot_files
        install_bot_deps
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}[*] Бот обновлён и перезапущен.${NC}"
        ;;
      2)
        echo -e "${YELLOW}Введите новый BOT_TOKEN:${NC}"
        local tok
        read -r tok
        tok=$(echo "$tok" | tr -d '[:space:]')
        if [ -n "$tok" ]; then
          sed -i "s/^BOT_TOKEN=.*/BOT_TOKEN=$tok/" "$BOT_DIR/.env"
          chmod 600 "$BOT_DIR/.env"
          systemctl restart "$SERVICE_NAME"
          echo -e "${GREEN}[*] Токен обновлён, бот перезапущен.${NC}"
        else
          echo -e "${RED}Пустой токен, отмена.${NC}"
        fi
        ;;
      3)
        echo -e "${YELLOW}Введите Telegram ID администратора (или несколько через запятую):${NC}"
        echo -e "  ${CYAN}Узнать ID: @userinfobot, @getmyid_bot или @RawDataBot${NC}"
        echo -e "  ${CYAN}Оставьте пустым — бот будет доступен всем.${NC}"
        local new_ids
        read -r new_ids
        new_ids=$(echo "$new_ids" | tr -d '[:space:]')
        # Удаляем старую строку ALLOWED_IDS
        sed -i "/^ALLOWED_IDS=/d" "$BOT_DIR/.env"
        if [ -n "$new_ids" ]; then
          echo "ALLOWED_IDS=$new_ids" >> "$BOT_DIR/.env"
          echo -e "${GREEN}[*] Администратор(ы): $new_ids. Перезапуск...${NC}"
        else
          echo -e "${GREEN}[*] Ограничение снято, бот доступен всем. Перезапуск...${NC}"
        fi
        systemctl restart "$SERVICE_NAME"
        ;;
      4)
        systemctl stop "$SERVICE_NAME"
        echo -e "${YELLOW}Бот остановлен.${NC}"
        ;;
      *) return ;;
    esac
    read -p "Нажмите Enter..."
    return
  fi

  echo -e "  Статус бота: ${RED}не установлен / не запущен${NC}"
  echo ""
  echo -e "  Бот позволяет управлять MTProxy из Telegram:"
  echo -e "  установка, статус, ссылка, поделиться ключом и т.д."
  echo ""
  read -p "  Установить бота? (y/n): " yn
  [ "$yn" != "y" ] && [ "$yn" != "Y" ] && return

  # Зависимости Python
  echo -e "${GREEN}[*] Проверка Python...${NC}"
  if ! command -v python3 &>/dev/null; then
    install_pkg python3 python3-pip
  fi
  command -v python3 &>/dev/null || { echo -e "${RED}python3 не найден!${NC}"; read -p "Enter..."; return; }

  local PY_VER
  PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3")
  if ! python3 -m venv --help &>/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Установка python${PY_VER}-venv...${NC}"
    install_pkg "python${PY_VER}-venv" 2>/dev/null
    install_pkg python3-venv 2>/dev/null
    install_pkg python3-pip 2>/dev/null
    python3 -m venv --help &>/dev/null 2>&1 || {
      echo -e "${RED}Не удалось установить venv. Выполните: apt install python${PY_VER}-venv${NC}"
      read -p "Enter..."; return
    }
  fi

  # Файлы бота
  write_bot_files

  # venv + pip
  install_bot_deps

  # BOT_TOKEN + ALLOWED_IDS
  if [ ! -f "$BOT_DIR/.env" ]; then
    echo ""
    echo -e "${YELLOW}Введите BOT_TOKEN от @BotFather:${NC}"
    echo -e "  ${CYAN}(Откройте @BotFather в Telegram → /newbot → скопируйте токен)${NC}"
    local TOKEN=""
    while [ -z "$TOKEN" ]; do
      read -r TOKEN
      TOKEN=$(echo "$TOKEN" | tr -d '[:space:]')
      [ -z "$TOKEN" ] && echo -e "${RED}Токен не может быть пустым.${NC}"
    done

    echo ""
    echo -e "${YELLOW}Введите ваш Telegram ID (администратор бота):${NC}"
    echo -e "  ${CYAN}Как узнать свой ID:${NC}"
    echo -e "    • Бот ${WHITE}@userinfobot${NC} — напишите ему /start"
    echo -e "    • Бот ${WHITE}@getmyid_bot${NC} — напишите ему /start"
    echo -e "    • Бот ${WHITE}@RawDataBot${NC} — напишите ему /start"
    echo -e "  ${CYAN}Можно указать несколько через запятую: 123456,789012${NC}"
    echo -e "  ${CYAN}Оставьте пустым, чтобы бот был доступен всем.${NC}"
    local ADMIN_IDS=""
    read -r ADMIN_IDS
    ADMIN_IDS=$(echo "$ADMIN_IDS" | tr -d '[:space:]')

    {
      echo "BOT_TOKEN=$TOKEN"
      [ -n "$ADMIN_IDS" ] && echo "ALLOWED_IDS=$ADMIN_IDS"
    } > "$BOT_DIR/.env"
    chmod 600 "$BOT_DIR/.env"

    if [ -n "$ADMIN_IDS" ]; then
      echo -e "${GREEN}[*] .env создан. Администратор(ы): $ADMIN_IDS${NC}"
    else
      echo -e "${GREEN}[*] .env создан. Бот доступен всем пользователям.${NC}"
    fi
  else
    echo -e "${GREEN}[*] .env уже есть — используем существующий.${NC}"
  fi

  # systemd
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=GoTelegram MTProxy Bot
After=network.target docker.service

[Service]
Type=simple
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
Restart=always
RestartSec=5
Environment=PATH=$BOT_DIR/venv/bin:/usr/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" 2>/dev/null
  systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"

  echo ""
  echo -e "${GREEN}[*] Telegram-бот установлен и запущен!${NC}"
  echo -e "  Проверка: systemctl status $SERVICE_NAME"
  echo -e "  Логи:     journalctl -u $SERVICE_NAME -f"
  read -p "  Нажмите Enter..."
}

write_bot_files() {
  mkdir -p "$BOT_DIR"

  cat > "$BOT_DIR/requirements.txt" << 'REQEOF'
python-telegram-bot>=21.0
REQEOF

  cat > "$BOT_DIR/bot.py" << 'BOTEOF'
#!/usr/bin/env python3
import asyncio, html, json, os, re
from pathlib import Path
_env_path = Path(__file__).resolve().parent / ".env"
if _env_path.exists():
    with open(_env_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes, MessageHandler, filters

BOT_TOKEN = os.environ.get("BOT_TOKEN")
_allowed = os.environ.get("ALLOWED_IDS", "").strip()
try:
    ALLOWED_IDS = set(int(x) for x in _allowed.split(",") if x.strip()) if _allowed else None
except ValueError:
    ALLOWED_IDS = None

CONTAINER_NAME = "mtproto-proxy"
CONFIG_FILE = Path("/opt/gotelegram-bot/proxy.json")
DOMAINS = [
    "google.com","wikipedia.org","habr.com","github.com",
    "coursera.org","udemy.com","medium.com","stackoverflow.com",
    "bbc.com","cnn.com","reuters.com","nytimes.com",
    "lenta.ru","rbc.ru","ria.ru","kommersant.ru",
    "stepik.org","duolingo.com","khanacademy.org","ted.com",
]
PROMO_LINK = "https://vk.cc/ct29NQ"
TIP_LINK = "https://pay.cloudtips.ru/p/7410814f"

def _ok(uid):
    return ALLOWED_IDS is None or uid in ALLOWED_IDS
def _decode(data):
    return (data or b"").decode("utf-8", errors="replace").strip()

async def sh(*args, timeout=60):
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill(); await proc.wait(); return -1, "", "Timeout"
    return proc.returncode or 0, _decode(out), _decode(err)

async def get_ip():
    for url in ("https://api.ipify.org","https://icanhazip.com","https://ifconfig.me"):
        code, out, _ = await sh("curl","-s","-4","--max-time","5",url, timeout=8)
        if code == 0 and out:
            m = re.search(r"(\d{1,3}\.){3}\d{1,3}", out)
            if m: return m.group(0)
    return "0.0.0.0"

async def proxy_running():
    code, out, _ = await sh("docker","ps","--format","{{.Names}}", timeout=10)
    return code == 0 and CONTAINER_NAME in out

async def docker_val(fmt):
    code, out, _ = await sh("docker","inspect",CONTAINER_NAME,"--format",fmt, timeout=10)
    return out.strip() if code == 0 else ""

async def check_port(port):
    if await proxy_running():
        hp = await docker_val("{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}")
        if str(port) in hp.split(): return None
    for cmd in ["/usr/bin/ss", "/usr/sbin/ss", "/sbin/ss", "/bin/ss", "ss", "/usr/bin/netstat", "netstat"]:
        try:
            code, out, _ = await sh(cmd, "-tlnp", timeout=5)
        except Exception:
            continue
        if code == 0 and out:
            for line in out.splitlines():
                if re.search(rf":{port}\b", line): return line
            return None
    return None

async def docker_containers_info():
    code, out, _ = await sh("docker","ps","--format","{{.Names}}\t{{.Image}}\t{{.Ports}}", timeout=10)
    return out if code == 0 else ""

def save_config(data):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

def load_config():
    if CONFIG_FILE.exists():
        try: return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception: pass
    return {}

async def proxy_info():
    if not await proxy_running(): return None
    cmd_str = await docker_val("{{range .Config.Cmd}}{{.}} {{end}}")
    secret = cmd_str.split()[-1] if cmd_str else ""
    hp = await docker_val("{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}")
    port = hp.split()[0] if hp.strip() else "443"
    ip = await get_ip()
    link = f"tg://proxy?server={ip}&port={port}&secret={secret}"
    cfg = load_config()
    return {"ip":ip,"port":port,"secret":secret,"link":link,"domain":cfg.get("domain","—")}

def main_menu_kb():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🔧 Установить / Обновить", callback_data="menu_install")],
        [InlineKeyboardButton("📊 Статус", callback_data="menu_status"),
         InlineKeyboardButton("🔗 Ссылка", callback_data="menu_link")],
        [InlineKeyboardButton("📤 Поделиться ключом", callback_data="menu_share")],
        [InlineKeyboardButton("🔄 Перезапуск", callback_data="menu_restart"),
         InlineKeyboardButton("📋 Логи", callback_data="menu_logs")],
        [InlineKeyboardButton("🗑 Удалить", callback_data="menu_remove"),
         InlineKeyboardButton("🏷 Промо", callback_data="menu_promo")],
    ])

HELP_TEXT = (
    "🚀 <b>GoTelegram MTProxy Bot</b>\n\n"
    "Управление MTProxy (Fake TLS) на сервере.\n"
    "TCP + UDP (звонки) поддержаны.\n\n"
    "Используйте кнопки ниже или команды:\n"
    "/install /status /link /share /restart /logs /remove /promo"
)

async def start(update, ctx):
    if not update.effective_user: return
    if not _ok(update.effective_user.id):
        msg = update.message or (update.callback_query and update.callback_query.message)
        if msg: await msg.reply_text("⛔ Доступ запрещён.")
        return
    if update.message:
        await update.message.reply_text(HELP_TEXT, parse_mode="HTML", reply_markup=main_menu_kb())
    elif update.callback_query:
        await update.callback_query.edit_message_text(HELP_TEXT, parse_mode="HTML", reply_markup=main_menu_kb())

async def cmd_status(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): await msg.reply_text("⛔"); return
    info = await proxy_info()
    if not info:
        text = "❌ Прокси не запущен.\nНажмите <b>Установить</b>."
    else:
        containers = await docker_containers_info()
        other = "\n".join(l for l in containers.splitlines() if CONTAINER_NAME not in l)
        text = ("✅ <b>Прокси работает</b>\n\n"
            f"IP: <code>{html.escape(info['ip'])}</code>\n"
            f"Порт: <code>{html.escape(info['port'])}</code>\n"
            f"Домен: <code>{html.escape(info['domain'])}</code>\n"
            f"Secret: <code>{html.escape(info['secret'])}</code>\n\n"
            f"Ссылка:\n<code>{html.escape(info['link'])}</code>")
        if other:
            text += f"\n\n📦 <b>Другие контейнеры:</b>\n<pre>{html.escape(other)}</pre>"
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    if update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML", reply_markup=kb)
    else:
        await msg.reply_text(text, parse_mode="HTML", reply_markup=kb)

async def cmd_link(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    info = await proxy_info()
    text = f"<code>{html.escape(info['link'])}</code>" if info else "❌ Прокси не запущен."
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    if update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML", reply_markup=kb)
    else:
        await msg.reply_text(text, parse_mode="HTML", reply_markup=kb)

async def cmd_share(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    info = await proxy_info()
    if not info:
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
        if update.callback_query: await update.callback_query.edit_message_text("❌ Прокси не запущен.", reply_markup=kb)
        else: await msg.reply_text("❌ Прокси не запущен.", reply_markup=kb)
        return
    tg_link = info["link"]
    share_text = (
        f"🔐 <b>MTProxy для Telegram</b>\n\n"
        f"🌍 Сервер: <code>{html.escape(info['ip'])}</code>\n"
        f"🔌 Порт: <code>{html.escape(info['port'])}</code>\n"
        f"🔑 Secret: <code>{html.escape(info['secret'])}</code>\n\n"
        f"👉 <b>Подключиться одним нажатием:</b>\n"
        f"{html.escape(tg_link)}\n\n"
        f"Просто нажмите на ссылку или перешлите это сообщение.")
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("📤 Переслать другу", switch_inline_query=tg_link)],
        [InlineKeyboardButton("◀️ Меню", callback_data="menu_main")],
    ])
    if update.callback_query:
        await update.callback_query.edit_message_text(share_text, parse_mode="HTML", reply_markup=kb)
    else:
        await msg.reply_text(share_text, parse_mode="HTML", reply_markup=kb)

async def cmd_remove(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    chat = msg.chat
    if update.callback_query: await update.callback_query.edit_message_text("⏳ Удаляю прокси...")
    else: await chat.send_message("⏳ Удаляю прокси...")
    await sh("docker","stop",CONTAINER_NAME, timeout=15)
    await sh("docker","rm",CONTAINER_NAME, timeout=10)
    text = "✅ Прокси удалён." if not await proxy_running() else "⚠️ Не удалось удалить."
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    await chat.send_message(text, reply_markup=kb)

async def cmd_restart(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    if not await proxy_running():
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
        if update.callback_query: await update.callback_query.edit_message_text("❌ Прокси не запущен.", reply_markup=kb)
        else: await msg.reply_text("❌ Прокси не запущен.", reply_markup=kb)
        return
    chat = msg.chat
    if update.callback_query: await update.callback_query.edit_message_text("⏳ Перезапуск...")
    code, _, err = await sh("docker","restart",CONTAINER_NAME, timeout=30)
    text = "✅ Перезапущен." if code == 0 else f"❌ Ошибка: {err or 'unknown'}"
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    await chat.send_message(text, reply_markup=kb)

async def cmd_logs(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    if not await proxy_running():
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
        if update.callback_query: await update.callback_query.edit_message_text("❌ Прокси не запущен.", reply_markup=kb)
        else: await msg.reply_text("❌ Прокси не запущен.", reply_markup=kb)
        return
    code, out, err = await sh("docker","logs","--tail","40",CONTAINER_NAME, timeout=15)
    text = (out or "") + (("\n" + err) if err else "") or "Нет вывода."
    if len(text) > 4000: text = text[-4000:]
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    if update.callback_query:
        await update.callback_query.edit_message_text(f"<pre>{html.escape(text)}</pre>", parse_mode="HTML", reply_markup=kb)
    else:
        await msg.reply_text(f"<pre>{html.escape(text)}</pre>", parse_mode="HTML", reply_markup=kb)

async def cmd_promo(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    text = ("💰 <b>Хостинг со скидкой до -60%</b>\n\n"
        f"<b>Хостинг #1:</b> {PROMO_LINK}\n"
        "Промокоды: OFF60, antenka20, antenka6, antenka12\n\n"
        "<b>Хостинг #2:</b> https://vk.cc/cUxAhj\n"
        "Промокод: OFF60\n\n"
        f"☕ Донат: {TIP_LINK}")
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]])
    if update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML", reply_markup=kb)
    else:
        await msg.reply_text(text, parse_mode="HTML", reply_markup=kb)

async def install_step_domain(update, ctx):
    msg = update.message or (update.callback_query and update.callback_query.message)
    if not update.effective_user or not msg: return
    if not _ok(update.effective_user.id): return
    buttons, row = [], []
    for i, d in enumerate(DOMAINS):
        row.append(InlineKeyboardButton(d, callback_data=f"dom_{i}"))
        if len(row) == 2: buttons.append(row); row = []
    if row: buttons.append(row)
    text = "🌐 <b>Выберите домен для маскировки (Fake TLS):</b>"
    if update.callback_query:
        await update.callback_query.edit_message_text(text, parse_mode="HTML", reply_markup=InlineKeyboardMarkup(buttons))
    else:
        await msg.reply_text(text, parse_mode="HTML", reply_markup=InlineKeyboardMarkup(buttons))

async def install_step_port(update, ctx):
    query = update.callback_query
    domain = ctx.user_data.get("install_domain", "google.com")
    busy_443 = await check_port(443)
    busy_8443 = await check_port(8443)
    rows = []
    l443 = "443 (рекомендуется)" if not busy_443 else "443 ⚠️ занят"
    l8443 = "8443" if not busy_8443 else "8443 ⚠️ занят"
    rows.append([InlineKeyboardButton(l443, callback_data="port_443"), InlineKeyboardButton(l8443, callback_data="port_8443")])
    rows.append([InlineKeyboardButton("◀️ Меню", callback_data="menu_main")])
    pi = ""
    if busy_443: pi += f"\n⚠️ Порт 443 занят:\n<pre>{html.escape(busy_443[:300])}</pre>\n"
    if busy_8443: pi += f"\n⚠️ Порт 8443 занят:\n<pre>{html.escape(busy_8443[:300])}</pre>\n"
    text = f"Домен: <b>{html.escape(domain)}</b>\n\n🔌 <b>Выберите порт</b> или введите свой (1-65535):{pi}"
    ctx.user_data["install_wait_port"] = True
    await query.edit_message_text(text, parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))

async def install_port_chosen(update, ctx, port_str):
    port = int(port_str)
    msg = update.callback_query.message if update.callback_query else update.message
    if not msg: return
    chat = msg.chat
    busy = await check_port(port)
    if busy:
        kb = InlineKeyboardMarkup([
            [InlineKeyboardButton(f"Всё равно использовать {port}", callback_data=f"force_{port}")],
            [InlineKeyboardButton("Выбрать другой порт", callback_data="reselect_port")],
            [InlineKeyboardButton("◀️ Меню", callback_data="menu_main")],
        ])
        text = f"⚠️ <b>Порт {port} занят!</b>\n\n<pre>{html.escape(busy[:500])}</pre>\n\nМожно использовать всё равно или выбрать другой."
        if update.callback_query: await update.callback_query.edit_message_text(text, parse_mode="HTML", reply_markup=kb)
        else: await chat.send_message(text, parse_mode="HTML", reply_markup=kb)
        ctx.user_data["install_port"] = port_str
        return
    ctx.user_data["install_port"] = port_str
    ctx.user_data["install_wait_port"] = False
    await do_install(update, ctx)

async def do_install(update, ctx):
    domain = ctx.user_data.get("install_domain") or "google.com"
    port = ctx.user_data.get("install_port") or "443"
    if update.callback_query:
        msg = update.callback_query.message
        await msg.edit_text("⏳ Генерация secret и запуск контейнера...", reply_markup=None)
    elif update.message:
        msg = update.message
        await msg.reply_text("⏳ Генерация secret и запуск контейнера...")
    else: return
    chat = msg.chat
    code, _, _ = await sh("docker","info", timeout=10)
    if code != 0:
        await chat.send_message("❌ Docker не запущен.", parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Меню", callback_data="menu_main")]]))
        return
    code, secret_out, err = await sh("docker","run","--rm","nineseconds/mtg:2","generate-secret","--hex",domain, timeout=60)
    if code != 0: await chat.send_message(f"❌ Генерация secret: {err or secret_out}"); return
    secret = secret_out.strip().split()[-1] if secret_out.strip() else ""
    if not secret: await chat.send_message("❌ Пустой secret."); return
    await sh("docker","stop",CONTAINER_NAME, timeout=15)
    await sh("docker","rm",CONTAINER_NAME, timeout=10)
    code, _, err = await sh("docker","run","-d","--name",CONTAINER_NAME,"--restart","always",
        "-p",f"{port}:{port}/tcp","-p",f"{port}:{port}/udp",
        "nineseconds/mtg:2","simple-run","-n","1.1.1.1","-i","prefer-ipv4",
        f"0.0.0.0:{port}",secret, timeout=90)
    if code != 0: await chat.send_message(f"❌ Запуск контейнера: {err}"); return
    save_config({"domain":domain,"port":port,"secret":secret})
    ip = await get_ip()
    link = f"tg://proxy?server={ip}&port={port}&secret={secret}"
    text = ("✅ <b>Прокси установлен!</b>\n\n"
        f"🌍 IP: <code>{html.escape(ip)}</code>\n"
        f"🔌 Порт: <code>{html.escape(port)}</code> (TCP + UDP)\n"
        f"🎭 Домен: <code>{html.escape(domain)}</code>\n"
        f"🔑 Secret: <code>{html.escape(secret)}</code>\n\n"
        f"👉 Ссылка:\n<code>{html.escape(link)}</code>\n\n📞 Звонки поддержаны (UDP).")
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("📤 Поделиться ключом", callback_data="menu_share")],
        [InlineKeyboardButton("◀️ Меню", callback_data="menu_main")],
    ])
    await chat.send_message(text, parse_mode="HTML", reply_markup=kb)
    for k in ("install_domain","install_port","install_wait_port"): ctx.user_data.pop(k, None)

async def callback_handler(update, ctx):
    query = update.callback_query
    if not query or not update.effective_user: return
    await query.answer()
    if not _ok(update.effective_user.id): await query.edit_message_text("⛔ Доступ запрещён."); return
    data = query.data or ""
    if data == "menu_main": await start(update, ctx)
    elif data == "menu_install": await install_step_domain(update, ctx)
    elif data == "menu_status": await cmd_status(update, ctx)
    elif data == "menu_link": await cmd_link(update, ctx)
    elif data == "menu_share": await cmd_share(update, ctx)
    elif data == "menu_restart": await cmd_restart(update, ctx)
    elif data == "menu_logs": await cmd_logs(update, ctx)
    elif data == "menu_remove": await cmd_remove(update, ctx)
    elif data == "menu_promo": await cmd_promo(update, ctx)
    elif data.startswith("dom_"):
        try: idx = int(data[4:])
        except ValueError: await query.edit_message_text("❌ Ошибка."); return
        if not (0 <= idx < len(DOMAINS)): await query.edit_message_text("❌ Неверный выбор."); return
        ctx.user_data["install_domain"] = DOMAINS[idx]
        await install_step_port(update, ctx)
    elif data == "port_443": await install_port_chosen(update, ctx, "443")
    elif data == "port_8443": await install_port_chosen(update, ctx, "8443")
    elif data.startswith("force_"):
        ctx.user_data["install_port"] = data[6:]
        ctx.user_data["install_wait_port"] = False
        await do_install(update, ctx)
    elif data == "reselect_port": await install_step_port(update, ctx)

async def text_handler(update, ctx):
    if not update.message or not ctx.user_data.get("install_wait_port"): return
    text = (update.message.text or "").strip()
    if not re.match(r"^\d+$", text): return
    port = int(text)
    if not (1 <= port <= 65535): await update.message.reply_text("Введите число от 1 до 65535."); return
    await install_port_chosen(update, ctx, str(port))

def main():
    if not BOT_TOKEN: raise SystemExit("Задайте BOT_TOKEN в .env")
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", start))
    app.add_handler(CommandHandler("install", install_step_domain))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("link", cmd_link))
    app.add_handler(CommandHandler("share", cmd_share))
    app.add_handler(CommandHandler("remove", cmd_remove))
    app.add_handler(CommandHandler("restart", cmd_restart))
    app.add_handler(CommandHandler("logs", cmd_logs))
    app.add_handler(CommandHandler("promo", cmd_promo))
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF
}

install_bot_deps() {
  local bot_steps=3 bot_cur=0

  bot_cur=$((bot_cur+1)); progress_bar $bot_cur $bot_steps "Создание venv..."

  # Если venv сломан (нет pip), удаляем и пересоздаём
  if [ -d "$BOT_DIR/venv" ] && [ ! -f "$BOT_DIR/venv/bin/pip" ]; then
    echo -e "  ${YELLOW}!${NC} venv повреждён (нет pip), пересоздаю..."
    rm -rf "$BOT_DIR/venv"
  fi

  if [ ! -d "$BOT_DIR/venv" ]; then
    # Убеждаемся что ensurepip доступен
    if ! python3 -m ensurepip --version &>/dev/null; then
      local PY_VER
      PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3")
      echo -e "  ${YELLOW}!${NC} Установка python${PY_VER}-venv (с ensurepip)..."
      install_pkg "python${PY_VER}-venv" 2>/dev/null
      install_pkg python3-venv python3-pip 2>/dev/null
    fi
    spinner_start "Создание Python venv..."
    python3 -m venv "$BOT_DIR/venv" 2>/dev/null
    spinner_stop
    if [ ! -f "$BOT_DIR/venv/bin/pip" ]; then
      echo -e "  ${RED}✗${NC} venv создан, но pip отсутствует."
      echo -e "  ${YELLOW}Выполните вручную: apt install python3-venv && rm -rf $BOT_DIR/venv${NC}"
      return 1
    fi
  fi
  echo -e "  ${GREEN}✓${NC} Python venv готов"

  bot_cur=$((bot_cur+1)); progress_bar $bot_cur $bot_steps "Обновление pip..."
  spinner_start "Обновление pip..."
  "$BOT_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
  spinner_stop
  echo -e "  ${GREEN}✓${NC} pip обновлён"

  bot_cur=$((bot_cur+1)); progress_bar $bot_cur $bot_steps "Установка зависимостей..."
  spinner_start "Установка python-telegram-bot (до 1 мин)..."
  "$BOT_DIR/venv/bin/pip" install -r "$BOT_DIR/requirements.txt" -q 2>/dev/null
  local rc=$?
  spinner_stop
  if [ $rc -ne 0 ]; then
    echo -e "  ${RED}✗${NC} pip install не удался."
    return 1
  fi
  # Проверяем что модуль реально доступен
  if ! "$BOT_DIR/venv/bin/python" -c "import telegram" 2>/dev/null; then
    echo -e "  ${RED}✗${NC} Модуль telegram не найден после установки."
    return 1
  fi
  echo -e "  ${GREEN}✓${NC} Зависимости установлены"
}

# ── 7) Полное меню удаления ────────────────────────────────────────────────────
menu_remove() {
  clear
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║                     УДАЛЕНИЕ КОМПОНЕНТОВ                     ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}1)${NC} Удалить только контейнер MTProxy"
  echo -e "     (Docker и другие контейнеры останутся)"
  echo ""
  echo -e "  ${RED}2)${NC} Удалить контейнер MTProxy + Docker полностью"
  echo -e "     ${RED}⚠  ВСЕ контейнеры и образы будут уничтожены!${NC}"
  echo ""
  echo -e "  ${WHITE}0)${NC} Назад"
  echo ""
  local choice
  read -p "  Выбор: " choice

  case $choice in
    1) remove_container_only ;;
    2) remove_with_docker ;;
    *) return ;;
  esac
}

remove_container_only() {
  clear
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║          Удаление контейнера MTProxy                        ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Будет удалено:"
  echo -e "    • Контейнер ${WHITE}$CONTAINER_NAME${NC}"
  echo -e "    • Telegram-бот (сервис ${WHITE}$SERVICE_NAME${NC})"
  echo -e "    • Файлы бота (${WHITE}$BOT_DIR${NC})"
  echo -e "    • Скрипт ${WHITE}/usr/local/bin/gotelegram${NC}"
  echo ""
  echo -e "  Docker и другие контейнеры ${GREEN}НЕ будут затронуты${NC}."
  echo ""

  # Подтверждение 1
  local yn
  read -p "  Вы уверены? (y/N): " yn
  if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
    echo -e "  ${GREEN}Отменено.${NC}"
    read -p "  Нажмите Enter..."
    return
  fi

  # Подтверждение 2 — случайное слово
  local words=("УДАЛИТЬ" "СТЕРЕТЬ" "ПРОКСИ" "ОЧИСТКА" "ФИНАЛ" "СБРОС")
  local confirm_word="${words[$((RANDOM % ${#words[@]}))]}"
  echo ""
  echo -e "  ${RED}Для подтверждения введите слово:${NC} ${WHITE}${confirm_word}${NC}"
  local input_word
  read -p "  >>> " input_word
  if [ "$input_word" != "$confirm_word" ]; then
    echo -e "  ${GREEN}Слово не совпало. Удаление отменено.${NC}"
    read -p "  Нажмите Enter..."
    return
  fi

  echo ""
  # Удаление
  spinner_start "Остановка и удаление контейнера..."
  docker stop "$CONTAINER_NAME" &>/dev/null
  docker rm "$CONTAINER_NAME" &>/dev/null
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Контейнер удалён"

  spinner_start "Остановка Telegram-бота..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null
  systemctl disable "$SERVICE_NAME" 2>/dev/null
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload 2>/dev/null
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Сервис бота удалён"

  rm -rf "$BOT_DIR"
  echo -e "  ${GREEN}✓${NC} Файлы бота удалены"

  rm -f /usr/local/bin/gotelegram
  echo -e "  ${GREEN}✓${NC} Скрипт gotelegram удалён"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Удаление завершено. Docker остался на месте.${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  read -p "  Нажмите Enter..."
}

remove_with_docker() {
  clear
  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║     ⚠  ПОЛНОЕ УДАЛЕНИЕ: MTProxy + Docker + всё ⚠           ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${RED}ВНИМАНИЕ! Будет удалено ВСЁ:${NC}"
  echo -e "    • Контейнер ${WHITE}$CONTAINER_NAME${NC}"
  echo -e "    • Telegram-бот и файлы"
  echo -e "    • Скрипт gotelegram"
  echo -e "    • ${RED}Docker Engine полностью${NC}"
  echo -e "    • ${RED}ВСЕ Docker-контейнеры, образы и тома${NC}"
  echo ""

  # Показываем что ещё есть в Docker
  local other_containers
  other_containers=$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -v "^${CONTAINER_NAME}")
  if [ -n "$other_containers" ]; then
    echo -e "  ${RED}⚠  На сервере есть ДРУГИЕ контейнеры, которые тоже будут уничтожены:${NC}"
    echo -e "  ${RED}────────────────────────────────────────────────────────────────${NC}"
    echo "$other_containers" | while IFS= read -r line; do
      echo -e "    ${WHITE}$line${NC}"
    done
    echo -e "  ${RED}────────────────────────────────────────────────────────────────${NC}"
    echo ""
  fi

  # Подтверждение 1
  local yn
  echo -e "  ${RED}Это действие НЕОБРАТИМО.${NC}"
  read -p "  Вы точно уверены? (y/N): " yn
  if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
    echo -e "  ${GREEN}Отменено.${NC}"
    read -p "  Нажмите Enter..."
    return
  fi

  # Подтверждение 2 — случайное слово
  local words=("УНИЧТОЖИТЬ" "ПОЛНЫЙ-СБРОС" "СТЕРЕТЬ-ВСЁ" "ПОДТВЕРЖДАЮ" "DOCKER-УДАЛИТЬ" "ТОЧНО-ДА")
  local confirm_word="${words[$((RANDOM % ${#words[@]}))]}"
  echo ""
  echo -e "  ${RED}████████████████████████████████████████████████████████████${NC}"
  echo -e "  ${RED}██${NC}  Для подтверждения введите:  ${WHITE}${confirm_word}${NC}"
  echo -e "  ${RED}████████████████████████████████████████████████████████████${NC}"
  local input_word
  read -p "  >>> " input_word
  if [ "$input_word" != "$confirm_word" ]; then
    echo -e "  ${GREEN}Слово не совпало. Удаление отменено.${NC}"
    read -p "  Нажмите Enter..."
    return
  fi

  echo ""
  # Удаление MTProxy
  spinner_start "Удаление контейнера MTProxy..."
  docker stop "$CONTAINER_NAME" &>/dev/null
  docker rm "$CONTAINER_NAME" &>/dev/null
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Контейнер MTProxy удалён"

  # Удаление бота
  spinner_start "Удаление Telegram-бота..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null
  systemctl disable "$SERVICE_NAME" 2>/dev/null
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload 2>/dev/null
  rm -rf "$BOT_DIR"
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Telegram-бот удалён"

  # Удаление всех контейнеров Docker
  spinner_start "Остановка всех контейнеров Docker..."
  docker stop $(docker ps -aq) &>/dev/null
  docker rm $(docker ps -aq) &>/dev/null
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Все контейнеры остановлены и удалены"

  # Удаление Docker
  spinner_start "Удаление Docker Engine..."
  systemctl stop docker 2>/dev/null
  if command -v apt-get &>/dev/null; then
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null
    apt-get autoremove -y -qq 2>/dev/null
  elif command -v dnf &>/dev/null; then
    dnf remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null
  elif command -v yum &>/dev/null; then
    yum remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null
  fi
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  spinner_stop
  echo -e "  ${GREEN}✓${NC} Docker полностью удалён"

  # Удаление скрипта
  rm -f /usr/local/bin/gotelegram
  echo -e "  ${GREEN}✓${NC} Скрипт gotelegram удалён"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Полное удаление завершено.${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "  Для повторной установки используйте команду curl."
  read -p "  Нажмите Enter для выхода..."
  exit 0
}

# ── Выход ────────────────────────────────────────────────────────────────────
show_exit() {
  clear
  show_config
  echo ""
  echo -e "${MAGENTA}Поддержка автора (CloudTips):${NC}"
  echo -e "  $TIP_LINK"
  echo -e "  YouTube: https://www.youtube.com/@antenkaru"
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "$TIP_LINK"
  fi
  exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# ██  СТАРТ СКРИПТА
# ══════════════════════════════════════════════════════════════════════════════

install_base_deps

# Копируем себя в /usr/local/bin/gotelegram (если запущены из другого места)
SELF="$(realpath "$0")"
if [ "$SELF" != "/usr/local/bin/gotelegram" ]; then
  cp "$SELF" /usr/local/bin/gotelegram && chmod +x /usr/local/bin/gotelegram
fi

show_promo

# ── Главное меню (цикл) ─────────────────────────────────────────────────────
while true; do
  echo ""
  echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}║            GoTelegram Manager (by anten-ka)                  ║${NC}"
  echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"

  # Статус прокси
  if proxy_is_running; then
    echo -e "  Прокси: ${GREEN}работает${NC}"
  else
    echo -e "  Прокси: ${RED}не запущен${NC}"
  fi
  # Статус бота
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "  Telegram-бот: ${GREEN}работает${NC}"
  else
    echo -e "  Telegram-бот: ${YELLOW}не настроен${NC}"
  fi
  echo ""
  echo -e "  ${GREEN}1)${NC} Установить / Обновить прокси"
  echo -e "  ${GREEN}2)${NC} Показать данные подключения"
  echo -e "  ${CYAN}3)${NC} Настроить Telegram-бот"
  echo -e "  ${GREEN}4)${NC} Перезапустить прокси"
  echo -e "  ${GREEN}5)${NC} Логи прокси"
  echo -e "  ${YELLOW}6)${NC} Показать PROMO"
  echo -e "  ${RED}7)${NC} Удалить (полное меню удаления)"
  echo -e "  ${WHITE}0)${NC} Выход"
  echo ""
  read -p "  Пункт: " m_idx
  case $m_idx in
    1) menu_install ;;
    2) clear; show_config; read -p "Нажмите Enter..." ;;
    3) menu_setup_bot ;;
    4)
      if proxy_is_running; then
        docker restart "$CONTAINER_NAME" && echo -e "${GREEN}Перезапущен.${NC}" || echo -e "${RED}Ошибка.${NC}"
      else
        echo -e "${RED}Прокси не запущен.${NC}"
      fi
      read -p "Нажмите Enter..."
      ;;
    5)
      if proxy_is_running; then
        docker logs --tail 50 "$CONTAINER_NAME" 2>&1
      else
        echo -e "${RED}Прокси не запущен.${NC}"
      fi
      read -p "Нажмите Enter..."
      ;;
    6) show_promo ;;
    7) menu_remove ;;
    0) show_exit ;;
    *) echo -e "${RED}Неверный ввод.${NC}" ;;
  esac
done
