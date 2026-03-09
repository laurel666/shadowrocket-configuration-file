#!/bin/bash
# GoTelegram MTProxy — refactored build.
# Основано на пользовательской версии install.sh, с упрощением структуры bash-части
# и сохранением исходной функциональности.

set -u

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly CYAN='\033[0;36m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[0;35m'
readonly BLUE='\033[0;34m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

readonly CONTAINER_NAME="mtproto-proxy"
readonly BOT_DIR="/opt/gotelegram-bot"
readonly SERVICE_NAME="gotelegram-bot"
readonly SELF_INSTALL_PATH="/usr/local/bin/gotelegram"
readonly DOCKER_IMAGE="nineseconds/mtg:2"
readonly TIP_LINK="https://pay.cloudtips.ru/p/7410814f"
readonly PROMO_LINK="https://vk.cc/ct29NQ"

spin_pid=""

spinner_start() {
  local msg="${1:-Подождите...}"
  (
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
      printf "\r  ${CYAN}${frames[$i]}${NC} $msg" >&2
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.12
    done
  ) &
  spin_pid=$!
}

spinner_stop() {
  if [ -n "${spin_pid:-}" ]; then
    kill "$spin_pid" 2>/dev/null || true
    wait "$spin_pid" 2>/dev/null || true
  fi
  spin_pid=""
  printf "\r\033[K" >&2
}

trap spinner_stop EXIT INT TERM

pause() {
  read -r -p "${1:-Нажмите Enter...}"
}

clear_screen() {
  command -v clear >/dev/null 2>&1 && clear || true
}

print_header() {
  local color="$1"
  local title="$2"
  echo -e "${color}╔══════════════════════════════════════════════════════════════╗${NC}"
  printf "%b║ %-60s ║%b\n" "$color" "$title" "$NC"
  echo -e "${color}╚══════════════════════════════════════════════════════════════╝${NC}"
}

info() { echo -e "  ${CYAN}•${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
error() { echo -e "  ${RED}✗${NC} $*"; }

progress_bar() {
  local current="$1" total="$2" label="${3:-}"
  local pct=0 filled=0 empty=50 i
  if [ "$total" -gt 0 ]; then
    pct=$(( current * 100 / total ))
  fi
  filled=$(( pct / 2 ))
  empty=$(( 50 - filled ))

  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  printf "\r  ${GREEN}[%s]${NC} %s%%%% %s" "$bar" "$pct" "$label" >&2
  [ "$current" -eq "$total" ] && echo "" >&2
}

run_with_progress() {
  local label="$1"; shift
  spinner_start "$label"
  "$@" >/dev/null 2>&1
  local rc=$?
  spinner_stop
  if [ $rc -eq 0 ]; then
    success "$label"
  else
    error "$label (ошибка)"
  fi
  return $rc
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}Запустите с sudo / root.${NC}"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_pkg_manager() {
  if command_exists apt-get; then
    echo apt-get
  elif command_exists dnf; then
    echo dnf
  elif command_exists yum; then
    echo yum
  else
    return 1
  fi
}

install_pkg() {
  local pm
  pm="$(detect_pkg_manager)" || {
    echo "Нет поддерживаемого менеджера пакетов" >&2
    return 1
  }

  case "$pm" in
    apt-get)
      apt-get update -qq || return $?
      apt-get install -y -qq "$@" || return $?
      ;;
    dnf)
      dnf install -y "$@" 2>/dev/null || return $?
      ;;
    yum)
      yum install -y "$@" || return $?
      ;;
  esac
}

ensure_dir() {
  mkdir -p "$1"
}

install_base_deps() {
  local steps=0 total=4

  progress_bar "$steps" "$total" "Проверка зависимостей..."
  if ! command_exists curl; then
    run_with_progress "Установка curl" install_pkg curl || return 1
  fi
  steps=$((steps + 1)); progress_bar "$steps" "$total" "curl"

  if ! command_exists docker; then
    spinner_start "Установка Docker (это может занять 1-2 минуты)..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    local rc=$?
    systemctl enable --now docker >/dev/null 2>&1 || true
    spinner_stop
    [ $rc -eq 0 ] && success "Docker установлен" || { error "Не удалось установить Docker"; return 1; }
  fi
  steps=$((steps + 1)); progress_bar "$steps" "$total" "docker"

  if ! command_exists qrencode; then
    run_with_progress "Установка qrencode" install_pkg qrencode || return 1
  fi
  steps=$((steps + 1)); progress_bar "$steps" "$total" "qrencode"

  if ! docker info >/dev/null 2>&1; then
    systemctl start docker 2>/dev/null || true
    sleep 2
  fi
  steps=$((steps + 1)); progress_bar "$steps" "$total" "Готово"
  echo ""
}

get_ip() {
  local ip
  ip=$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s -4 --max-time 5 https://icanhazip.com 2>/dev/null \
    || echo "0.0.0.0")
  echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\\"/g'
}

docker_running() {
  docker info >/dev/null 2>&1
}

proxy_is_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"
}

get_proxy_secret() {
  docker inspect "$CONTAINER_NAME" --format='{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null | awk '{print $NF}'
}

get_proxy_port() {
  docker inspect "$CONTAINER_NAME" --format='{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}' 2>/dev/null | awk '{print $1}'
}

show_containers() {
  local list
  list=$(docker ps --format "{{.Names}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null | grep -v "^${CONTAINER_NAME}")
  if [ -n "$list" ]; then
    echo -e "${CYAN}  Другие контейнеры на сервере:${NC}"
    while IFS= read -r line; do
      echo "    $line"
    done <<< "$list"
  fi
}

check_port() {
  local port="$1"
  local hp="" line=""

  if proxy_is_running; then
    hp="$(docker inspect "$CONTAINER_NAME" --format='{{range $p,$c := .HostConfig.PortBindings}}{{(index $c 0).HostPort}} {{end}}' 2>/dev/null)"
    for p in $hp; do
      [ "$p" = "$port" ] && return 1
    done
  fi

  line="$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1 || true)"
  if [ -z "$line" ]; then
    line="$(netstat -tlnp 2>/dev/null | grep -E ":${port}\b" | head -1 || true)"
  fi

  if [ -n "$line" ]; then
    echo "$line"
    return 0
  fi
  return 1
}

ensure_self_installed() {
  local self
  self="$(realpath "$0")"
  if [ "$self" != "$SELF_INSTALL_PATH" ]; then
    cp "$self" "$SELF_INSTALL_PATH" && chmod +x "$SELF_INSTALL_PATH"
  fi
}

show_config() {
  if ! proxy_is_running; then
    echo -e "${RED}Прокси не запущен! Выберите пункт 1 для установки.${NC}"
    return 1
  fi

  local secret ip port link
  secret="$(get_proxy_secret)"
  ip="$(get_ip)"
  port="$(get_proxy_port)"
  port="${port:-443}"
  link="tg://proxy?server=${ip}&port=${port}&secret=${secret}"

  echo ""
  print_header "$GREEN" "ДАННЫЕ ПОДКЛЮЧЕНИЯ"
  echo -e "  IP:     ${WHITE}${ip}${NC}"
  echo -e "  Port:   ${WHITE}${port}${NC} (TCP + UDP)"
  echo -e "  Secret: ${WHITE}${secret}${NC}"
  echo ""
  echo -e "  Ссылка: ${BLUE}${link}${NC}"
  echo ""

  if command_exists qrencode; then
    echo -e "${CYAN}  Наведите камеру телефона на QR-код для подключения:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$link"
  fi

  echo ""
  show_containers
}

show_promo() {
  clear_screen
  print_header "$MAGENTA" "ХОСТИНГ СО СКИДКОЙ ДО -60% ОТ ANTEN-KA"
  echo ""
  echo -e "${CYAN} Хостинг #1: $PROMO_LINK ${NC}"
  echo -e "${MAGENTA}❖ ••••••••••••••••••• АКТУАЛЬНЫЕ ПРОМОКОДЫ •••••••••••••••••• ❖${NC}"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "Скидка 60% на ПЕРВЫЙ МЕСЯЦ"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka20" "Буст 20% + 3% (оплата за 3 МЕС)"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka6" "Буст 15% + 5% (оплата за 6 МЕС)"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "antenka12" "Буст 5% + 5% (оплата за 12 МЕС)"
  echo -e "${MAGENTA}❖ •••••••••••••••••••••••••••••••••••••••••••••••••••••••••••• ❖${NC}"
  command_exists qrencode && qrencode -t ANSIUTF8 "$PROMO_LINK"

  echo ""
  echo -e "${CYAN} Хостинг #2: https://vk.cc/cUxAhj ${NC}"
  echo -e "${MAGENTA}❖ ••••••••••••••••••• АКТУАЛЬНЫЕ ПРОМОКОДЫ •••••••••••••••••• ❖${NC}"
  printf "  ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "Скидка 60% на ПЕРВЫЙ МЕСЯЦ"
  echo -e "${MAGENTA}❖ •••••••••••••••••••••••••••••••••••••••••••••••••••••••••••• ❖${NC}"
  command_exists qrencode && qrencode -t ANSIUTF8 "https://vk.cc/cUxAhj"
  echo "--------------------------------------------------------------"
  pause "Нажмите [ENTER] для возврата в меню..."
}

choose_domain() {
  local domains=(
    "google.com" "wikipedia.org" "habr.com" "github.com"
    "coursera.org" "udemy.com" "medium.com" "stackoverflow.com"
    "bbc.com" "cnn.com" "reuters.com" "nytimes.com"
    "lenta.ru" "rbc.ru" "ria.ru" "kommersant.ru"
    "stepik.org" "duolingo.com" "khanacademy.org" "ted.com"
  )
  local idx domain

  clear_screen
  print_header "$CYAN" "Выберите домен для маскировки (Fake TLS)"

  for i in "${!domains[@]}"; do
    printf "  ${YELLOW}%2d)${NC} %-22s" "$((i + 1))" "${domains[$i]}"
    [[ $(( (i + 1) % 2 )) -eq 0 ]] && echo ""
  done
  echo ""
  echo -e "  ${CYAN}21)${NC} Ввести свой домен"
  echo ""

  read -r -p "Ваш выбор [1-21]: " idx
  if [ "$idx" = "21" ]; then
    read -r -p "  Введите домен (например, example.com): " domain
    domain="$(echo "$domain" | tr -d '[:space:]')"
    if ! echo "$domain" | grep -qE '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
      warn "Некорректный домен. Используется google.com"
      domain="google.com"
    fi
  else
    domain="${domains[$((idx - 1))]:-google.com}"
  fi

  printf '%s\n' "$domain"
}

choose_port() {
  local port_choice port busy_line force_choice

  echo ""
  echo -e "${CYAN}--- Выберите порт ---${NC}"

  echo -n "  1) 443  (Рекомендуется) "
  if busy_line="$(check_port 443)"; then
    echo -e "${RED}[ЗАНЯТ: $busy_line]${NC}"
  else
    echo -e "${GREEN}[свободен]${NC}"
  fi

  echo -n "  2) 8443                 "
  if busy_line="$(check_port 8443)"; then
    echo -e "${RED}[ЗАНЯТ: $busy_line]${NC}"
  else
    echo -e "${GREEN}[свободен]${NC}"
  fi

  echo -e "  3) Свой порт"
  read -r -p "  Выбор: " port_choice

  case "$port_choice" in
    2) port=8443 ;;
    3)
      while true; do
        read -r -p "  Введите порт (1-65535): " port
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && break
        echo -e "  ${RED}Неверный порт.${NC}"
      done
      ;;
    *) port=443 ;;
  esac

  if busy_line="$(check_port "$port")"; then
    echo ""
    echo -e "  ${YELLOW}Порт $port занят:${NC}"
    echo -e "  ${RED}$busy_line${NC}"
    echo -e "  1) Всё равно использовать (если это ваш процесс)"
    echo -e "  2) Отмена"
    read -r -p "  Выбор: " force_choice
    if [ "$force_choice" != "1" ]; then
      echo -e "  ${YELLOW}Отменено.${NC}"
      return 1
    fi
  fi

  printf '%s\n' "$port"
}

install_proxy() {
  local domain="$1"
  local port="$2"
  local secret install_steps=5 install_cur=0

  echo ""
  echo -e "${YELLOW}[*] Настройка прокси (домен: $domain, порт: $port)...${NC}"
  echo ""

  if ! docker_running; then
    echo -e "${RED}Docker не запущен!${NC}"
    return 1
  fi

  install_cur=$((install_cur + 1)); progress_bar "$install_cur" "$install_steps" "Загрузка образа mtg..."
  spinner_start "Загрузка Docker-образа mtg..."
  if ! docker pull "$DOCKER_IMAGE" >/dev/null 2>&1; then
    spinner_stop
    error "Не удалось загрузить образ mtg. Проверьте интернет."
    return 1
  fi
  spinner_stop
  success "Образ mtg готов"

  install_cur=$((install_cur + 1)); progress_bar "$install_cur" "$install_steps" "Генерация secret..."
  spinner_start "Генерация secret для $domain..."
  secret="$(docker run --rm "$DOCKER_IMAGE" generate-secret --hex "$domain" 2>&1)"
  local secret_rc=$?
  spinner_stop
  if [ $secret_rc -ne 0 ] || [ -z "$secret" ]; then
    error "Ошибка генерации secret."
    [ -n "$secret" ] && echo -e "  ${RED}$secret${NC}"
    return 1
  fi
  success "Secret сгенерирован"

  install_cur=$((install_cur + 1)); progress_bar "$install_cur" "$install_steps" "Очистка..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  success "Старый контейнер удалён"

  install_cur=$((install_cur + 1)); progress_bar "$install_cur" "$install_steps" "Запуск контейнера..."
  spinner_start "Запуск MTProxy (TCP + UDP)..."
  docker run -d --name "$CONTAINER_NAME" --restart always \
    -p "$port:$port/tcp" \
    -p "$port:$port/udp" \
    "$DOCKER_IMAGE" simple-run \
    -n 1.1.1.1 -i prefer-ipv4 \
    "0.0.0.0:$port" "$secret" >/dev/null 2>&1
  sleep 2
  spinner_stop

  if ! proxy_is_running; then
    error "Контейнер не запустился. Проверьте: docker logs $CONTAINER_NAME"
    return 1
  fi
  success "Контейнер запущен"

  install_cur=$((install_cur + 1)); progress_bar "$install_cur" "$install_steps" "Готово!"
  ensure_dir "$BOT_DIR"
  cat > "$BOT_DIR/proxy.json" <<CFGEOF
{"domain":"$(json_escape "$domain")","port":"$port","secret":"$(json_escape "$secret")"}
CFGEOF
  chmod 600 "$BOT_DIR/proxy.json"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Прокси установлен! (TCP + UDP, звонки поддержаны)${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  show_config
}

menu_install() {
  local domain port
  domain="$(choose_domain)"
  echo -e "  Домен: ${GREEN}$domain${NC}"

  if ! port="$(choose_port)"; then
    pause "  Нажмите Enter..."
    return
  fi

  if install_proxy "$domain" "$port"; then
    pause "Нажмите Enter для возврата в меню..."
  else
    pause "Нажмите Enter..."
  fi
}

write_bot_files() {
  ensure_dir "$BOT_DIR"

  cat > "$BOT_DIR/requirements.txt" <<'REQEOF'
python-telegram-bot>=21.0
REQEOF

  cat > "$BOT_DIR/bot.py" <<'BOTEOF'
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
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, text_handler))
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF
}

install_bot_deps() {
  local bot_steps=3 bot_cur=0 py_ver

  bot_cur=$((bot_cur + 1)); progress_bar "$bot_cur" "$bot_steps" "Создание venv..."

  if [ -d "$BOT_DIR/venv" ] && [ ! -f "$BOT_DIR/venv/bin/pip" ]; then
    warn "venv повреждён (нет pip), пересоздаю..."
    rm -rf "$BOT_DIR/venv"
  fi

  if [ ! -d "$BOT_DIR/venv" ]; then
    if ! python3 -m ensurepip --version >/dev/null 2>&1; then
      py_ver="$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3")"
      warn "Установка python${py_ver}-venv (с ensurepip)..."
      install_pkg "python${py_ver}-venv" >/dev/null 2>&1 || true
      install_pkg python3-venv python3-pip >/dev/null 2>&1 || true
    fi

    spinner_start "Создание Python venv..."
    python3 -m venv "$BOT_DIR/venv" >/dev/null 2>&1
    spinner_stop

    if [ ! -f "$BOT_DIR/venv/bin/pip" ]; then
      error "venv создан, но pip отсутствует."
      echo -e "  ${YELLOW}Выполните вручную: apt install python3-venv && rm -rf $BOT_DIR/venv${NC}"
      return 1
    fi
  fi
  success "Python venv готов"

  bot_cur=$((bot_cur + 1)); progress_bar "$bot_cur" "$bot_steps" "Обновление pip..."
  spinner_start "Обновление pip..."
  "$BOT_DIR/venv/bin/pip" install --upgrade pip -q >/dev/null 2>&1
  spinner_stop
  success "pip обновлён"

  bot_cur=$((bot_cur + 1)); progress_bar "$bot_cur" "$bot_steps" "Установка зависимостей..."
  spinner_start "Установка python-telegram-bot (до 1 мин)..."
  "$BOT_DIR/venv/bin/pip" install -r "$BOT_DIR/requirements.txt" -q >/dev/null 2>&1
  local rc=$?
  spinner_stop
  if [ $rc -ne 0 ]; then
    error "pip install не удался."
    return 1
  fi
  if ! "$BOT_DIR/venv/bin/python" -c "import telegram" >/dev/null 2>&1; then
    error "Модуль telegram не найден после установки."
    return 1
  fi
  success "Зависимости установлены"
}

write_env_file() {
  local token="$1"
  local admin_ids="$2"
  {
    echo "BOT_TOKEN=$token"
    [ -n "$admin_ids" ] && echo "ALLOWED_IDS=$admin_ids"
  } > "$BOT_DIR/.env"
  chmod 600 "$BOT_DIR/.env"
}

install_or_update_systemd_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$SERVICE_NAME" >/dev/null 2>&1
}

bot_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

read_admin_ids_prompt() {
  local admin_ids=""
  echo -e "${YELLOW}Введите ваш Telegram ID (администратор бота):${NC}"
  echo -e "  ${CYAN}Как узнать свой ID:${NC}"
  echo -e "    • Бот ${WHITE}@userinfobot${NC} — напишите ему /start"
  echo -e "    • Бот ${WHITE}@getmyid_bot${NC} — напишите ему /start"
  echo -e "    • Бот ${WHITE}@RawDataBot${NC} — напишите ему /start"
  echo -e "  ${CYAN}Можно указать несколько через запятую: 123456,789012${NC}"
  echo -e "  ${CYAN}Оставьте пустым, чтобы бот был доступен всем.${NC}"
  read -r admin_ids
  admin_ids="$(echo "$admin_ids" | tr -d '[:space:]')"
  printf '%s\n' "$admin_ids"
}

menu_setup_bot() {
  local cur_ids sub tok new_ids token admin_ids py_ver

  clear_screen
  print_header "$CYAN" "Настройка Telegram-бота"

  if bot_is_active; then
    echo -e "  Статус бота: ${GREEN}работает${NC}"
    echo ""
    cur_ids="$(grep "^ALLOWED_IDS=" "$BOT_DIR/.env" 2>/dev/null | cut -d= -f2)"
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
    read -r -p "  Выбор: " sub

    case "$sub" in
      1)
        write_bot_files
        install_bot_deps && systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}[*] Бот обновлён и перезапущен.${NC}"
        ;;
      2)
        echo -e "${YELLOW}Введите новый BOT_TOKEN:${NC}"
        read -r tok
        tok="$(echo "$tok" | tr -d '[:space:]')"
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
        read -r new_ids
        new_ids="$(echo "$new_ids" | tr -d '[:space:]')"
        sed -i "/^ALLOWED_IDS=/d" "$BOT_DIR/.env"
        [ -n "$new_ids" ] && echo "ALLOWED_IDS=$new_ids" >> "$BOT_DIR/.env"
        systemctl restart "$SERVICE_NAME"
        if [ -n "$new_ids" ]; then
          echo -e "${GREEN}[*] Администратор(ы): $new_ids. Перезапуск...${NC}"
        else
          echo -e "${GREEN}[*] Ограничение снято, бот доступен всем. Перезапуск...${NC}"
        fi
        ;;
      4)
        systemctl stop "$SERVICE_NAME"
        echo -e "${YELLOW}Бот остановлен.${NC}"
        ;;
      *)
        return
        ;;
    esac

    pause "Нажмите Enter..."
    return
  fi

  echo -e "  Статус бота: ${RED}не установлен / не запущен${NC}"
  echo ""
  echo -e "  Бот позволяет управлять MTProxy из Telegram:"
  echo -e "  установка, статус, ссылка, поделиться ключом и т.д."
  echo ""
  read -r -p "  Установить бота? (y/n): " sub
  [[ "$sub" =~ ^[Yy]$ ]] || return

  echo -e "${GREEN}[*] Проверка Python...${NC}"
  if ! command_exists python3; then
    install_pkg python3 python3-pip || {
      error "python3 не найден и установить его не удалось."
      pause "Enter..."
      return
    }
  fi

  py_ver="$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "3")"
  if ! python3 -m venv --help >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Установка python${py_ver}-venv...${NC}"
    install_pkg "python${py_ver}-venv" >/dev/null 2>&1 || true
    install_pkg python3-venv >/dev/null 2>&1 || true
    install_pkg python3-pip >/dev/null 2>&1 || true
    python3 -m venv --help >/dev/null 2>&1 || {
      echo -e "${RED}Не удалось установить venv. Выполните: apt install python${py_ver}-venv${NC}"
      pause "Enter..."
      return
    }
  fi

  write_bot_files
  install_bot_deps || {
    pause "Enter..."
    return
  }

  if [ ! -f "$BOT_DIR/.env" ]; then
    echo ""
    echo -e "${YELLOW}Введите BOT_TOKEN от @BotFather:${NC}"
    echo -e "  ${CYAN}(Откройте @BotFather в Telegram → /newbot → скопируйте токен)${NC}"

    token=""
    while [ -z "$token" ]; do
      read -r token
      token="$(echo "$token" | tr -d '[:space:]')"
      [ -z "$token" ] && echo -e "${RED}Токен не может быть пустым.${NC}"
    done

    echo ""
    admin_ids="$(read_admin_ids_prompt)"
    write_env_file "$token" "$admin_ids"

    if [ -n "$admin_ids" ]; then
      echo -e "${GREEN}[*] .env создан. Администратор(ы): $admin_ids${NC}"
    else
      echo -e "${GREEN}[*] .env создан. Бот доступен всем пользователям.${NC}"
    fi
  else
    echo -e "${GREEN}[*] .env уже есть — используем существующий.${NC}"
  fi

  install_or_update_systemd_service
  echo ""
  echo -e "${GREEN}[*] Telegram-бот установлен и запущен!${NC}"
  echo -e "  Проверка: systemctl status $SERVICE_NAME"
  echo -e "  Логи:     journalctl -u $SERVICE_NAME -f"
  pause "  Нажмите Enter..."
}

remove_bot_artifacts() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$BOT_DIR"
}

confirm_with_word() {
  local prompt="$1"; shift
  local words=("$@")
  local word input
  word="${words[$((RANDOM % ${#words[@]}))]}"
  echo ""
  echo -e "  ${RED}$prompt${NC} ${WHITE}$word${NC}"
  read -r -p "  >>> " input
  [ "$input" = "$word" ]
}

remove_container_only() {
  clear_screen
  print_header "$YELLOW" "Удаление контейнера MTProxy"
  echo ""
  echo -e "  Будет удалено:"
  echo -e "    • Контейнер ${WHITE}$CONTAINER_NAME${NC}"
  echo -e "    • Telegram-бот (сервис ${WHITE}$SERVICE_NAME${NC})"
  echo -e "    • Файлы бота (${WHITE}$BOT_DIR${NC})"
  echo -e "    • Скрипт ${WHITE}$SELF_INSTALL_PATH${NC}"
  echo ""
  echo -e "  Docker и другие контейнеры ${GREEN}НЕ будут затронуты${NC}."
  echo ""

  local yn
  read -r -p "  Вы уверены? (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]] || {
    echo -e "  ${GREEN}Отменено.${NC}"
    pause "  Нажмите Enter..."
    return
  }

  confirm_with_word "Для подтверждения введите слово:" "УДАЛИТЬ" "СТЕРЕТЬ" "ПРОКСИ" "ОЧИСТКА" "ФИНАЛ" "СБРОС" || {
    echo -e "  ${GREEN}Слово не совпало. Удаление отменено.${NC}"
    pause "  Нажмите Enter..."
    return
  }

  echo ""
  spinner_start "Остановка и удаление контейнера..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  spinner_stop
  success "Контейнер удалён"

  spinner_start "Остановка Telegram-бота..."
  remove_bot_artifacts
  spinner_stop
  success "Сервис бота удалён"

  rm -f "$SELF_INSTALL_PATH"
  success "Скрипт gotelegram удалён"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Удаление завершено. Docker остался на месте.${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  pause "  Нажмите Enter..."
}

remove_with_docker() {
  clear_screen
  print_header "$RED" "⚠ ПОЛНОЕ УДАЛЕНИЕ: MTProxy + Docker + всё ⚠"
  echo ""
  echo -e "  ${RED}ВНИМАНИЕ! Будет удалено ВСЁ:${NC}"
  echo -e "    • Контейнер ${WHITE}$CONTAINER_NAME${NC}"
  echo -e "    • Telegram-бот и файлы"
  echo -e "    • Скрипт gotelegram"
  echo -e "    • ${RED}Docker Engine полностью${NC}"
  echo -e "    • ${RED}ВСЕ Docker-контейнеры, образы и тома${NC}"
  echo ""

  local other_containers
  other_containers="$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -v "^${CONTAINER_NAME}" || true)"
  if [ -n "$other_containers" ]; then
    echo -e "  ${RED}⚠ На сервере есть ДРУГИЕ контейнеры, которые тоже будут уничтожены:${NC}"
    echo -e "  ${RED}────────────────────────────────────────────────────────────────${NC}"
    while IFS= read -r line; do
      echo -e "    ${WHITE}$line${NC}"
    done <<< "$other_containers"
    echo -e "  ${RED}────────────────────────────────────────────────────────────────${NC}"
    echo ""
  fi

  local yn
  echo -e "  ${RED}Это действие НЕОБРАТИМО.${NC}"
  read -r -p "  Вы точно уверены? (y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]] || {
    echo -e "  ${GREEN}Отменено.${NC}"
    pause "  Нажмите Enter..."
    return
  }

  confirm_with_word "████ Для подтверждения введите:" "УНИЧТОЖИТЬ" "ПОЛНЫЙ-СБРОС" "СТЕРЕТЬ-ВСЁ" "ПОДТВЕРЖДАЮ" "DOCKER-УДАЛИТЬ" "ТОЧНО-ДА" || {
    echo -e "  ${GREEN}Слово не совпало. Удаление отменено.${NC}"
    pause "  Нажмите Enter..."
    return
  }

  echo ""
  spinner_start "Удаление контейнера MTProxy..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  spinner_stop
  success "Контейнер MTProxy удалён"

  spinner_start "Удаление Telegram-бота..."
  remove_bot_artifacts
  spinner_stop
  success "Telegram-бот удалён"

  spinner_start "Остановка всех контейнеров Docker..."
  docker stop $(docker ps -aq) >/dev/null 2>&1 || true
  docker rm $(docker ps -aq) >/dev/null 2>&1 || true
  spinner_stop
  success "Все контейнеры остановлены и удалены"

  spinner_start "Удаление Docker Engine..."
  systemctl stop docker 2>/dev/null || true
  if command_exists apt-get; then
    apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
  elif command_exists dnf; then
    dnf remove -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
  elif command_exists yum; then
    yum remove -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
  fi
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  spinner_stop
  success "Docker полностью удалён"

  rm -f "$SELF_INSTALL_PATH"
  success "Скрипт gotelegram удалён"

  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Полное удаление завершено.${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "  Для повторной установки используйте команду curl."
  pause "  Нажмите Enter для выхода..."
  exit 0
}

menu_remove() {
  clear_screen
  print_header "$RED" "УДАЛЕНИЕ КОМПОНЕНТОВ"
  echo ""
  echo -e "  ${YELLOW}1)${NC} Удалить только контейнер MTProxy"
  echo -e "     (Docker и другие контейнеры останутся)"
  echo ""
  echo -e "  ${RED}2)${NC} Удалить контейнер MTProxy + Docker полностью"
  echo -e "     ${RED}⚠ ВСЕ контейнеры и образы будут уничтожены!${NC}"
  echo ""
  echo -e "  ${WHITE}0)${NC} Назад"
  echo ""

  local choice
  read -r -p "  Выбор: " choice
  case "$choice" in
    1) remove_container_only ;;
    2) remove_with_docker ;;
    *) return ;;
  esac
}

restart_proxy() {
  if proxy_is_running; then
    docker restart "$CONTAINER_NAME" >/dev/null 2>&1 && echo -e "${GREEN}Перезапущен.${NC}" || echo -e "${RED}Ошибка.${NC}"
  else
    echo -e "${RED}Прокси не запущен.${NC}"
  fi
  pause "Нажмите Enter..."
}

show_proxy_logs() {
  if proxy_is_running; then
    docker logs --tail 50 "$CONTAINER_NAME" 2>&1
  else
    echo -e "${RED}Прокси не запущен.${NC}"
  fi
  pause "Нажмите Enter..."
}

show_exit() {
  clear
  show_config
  exit 0
}

usage() {
  echo "Usage: $0 [install|status|bot|remove|promo]" >&2
}

handle_cli_command() {
  [ $# -eq 0 ] && return 1

  case "$1" in
    install) menu_install ;;
    status) show_config ;;
    bot) menu_setup_bot ;;
    remove) menu_remove ;;
    promo) show_promo ;;
    *) usage; return 1 ;;
  esac
  return 0
}

show_main_menu() {
  echo ""
  print_header "$MAGENTA" "GoTelegram Manager (by anten-ka)"

  if proxy_is_running; then
    echo -e "  Прокси: ${GREEN}работает${NC}"
  else
    echo -e "  Прокси: ${RED}не запущен${NC}"
  fi

  if bot_is_active; then
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
}

main_loop() {
  local choice
  while true; do
    show_main_menu
    read -r -p "  Пункт: " choice
    case "$choice" in
      1) menu_install ;;
      2) clear_screen; show_config; pause "Нажмите Enter..." ;;
      3) menu_setup_bot ;;
      4) restart_proxy ;;
      5) show_proxy_logs ;;
      6) show_promo ;;
      7) menu_remove ;;
      0) show_exit ;;
      *) echo -e "${RED}Неверный ввод.${NC}" ;;
    esac
  done
}

main() {
  require_root
  install_base_deps || exit 1
  ensure_self_installed

  if handle_cli_command "$@"; then
    exit 0
  elif [ $# -gt 0 ]; then
    exit 1
  fi

  show_promo
  main_loop
}

main "$@"
