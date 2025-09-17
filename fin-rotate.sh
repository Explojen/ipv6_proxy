#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/3proxy/3proxy.cfg"

# --- Автоматическое извлечение подсетей из "local ... dev lo" с фильтрацией ---
echo "Извлечение IPv6 подсетей из таблицы local (фильтрация системных записей)..."

mapfile -t IPV6_NETWORKS < <(
    ip -6 route show table local | \
    awk '
    /^local [^ ]+\/[0-9]+ dev lo/ {
        gsub(/^local /, "", $0)
        gsub(/ dev lo.*$/, "", $0)
        if ($0 ~ /^::1\//) next           # loopback
        if ($0 ~ /^fe80:/) next           # link-local
        if ($0 ~ /^ff[0-9a-fA-F]{2}:/) next  # multicast
#Тут вам нужно заменить свою корневую подсеть, что прописана ИМЕННО НА ИНТЕРФЕЙС вашего сервера, иначе будете вопровать адреса соседних серверов и будете забанены провайдером.
        if ($0 ~ /^2a0a:9300:/) next      # ❗ исключаем основную подсеть сервера
        print $0
    }'
)

if [ ${#IPV6_NETWORKS[@]} -eq 0 ]; then
    echo "Ошибка: не найдено ни одной подходящей подсети (local ... dev lo, исключая системные)."
    exit 1
fi

echo "Найдены подходящие подсети:"
for NET in "${IPV6_NETWORKS[@]}"; do
    echo "  $NET"
done

# --- Определение IPv4 адреса ---
IPV4_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IPV4_ADDR" ]; then
    echo "Ошибка: не удалось определить IPv4 адрес."
    exit 1
fi

# --- Определение количества прокси из текущего конфига ---
PROXY_COUNT=$(grep -c "^proxy.*-p[0-9]" "$CONFIG_FILE" 2>/dev/null || echo 0)
if [ "$PROXY_COUNT" -eq 0 ]; then
    echo "В конфиге не найдено прокси — будет создано 10 по умолчанию."
    PROXY_COUNT=10
fi

# --- Чтение старых адресов для исключения дублей ---
mapfile -t OLD_ADDRESSES < <(grep "^proxy.* -e" "$CONFIG_FILE" | sed -E 's/.* -e([^ ]+).*/\1/' 2>/dev/null || true)

# --- Функция генерации случайного IPv6 в подсети ---
generate_random_ipv6() {
    local net="$1"
    python3 -c "
import ipaddress
import random
n = ipaddress.IPv6Network('$net', strict=False)
print(n[random.randint(1, n.num_addresses - 2)])
" 2>/dev/null
}

# --- Генерация новых адресов ---
declare -a NEW_ADDRESSES
PORT=3000

echo "Генерация $PROXY_COUNT новых IPv6 адресов..."

for i in $(seq 1 $PROXY_COUNT); do
    while :; do
        SELECTED_NET="${IPV6_NETWORKS[RANDOM % ${#IPV6_NETWORKS[@]}]}"

        NEW_ADDR=$(generate_random_ipv6 "$SELECTED_NET")
        if [ -z "$NEW_ADDR" ]; then
            echo "Не удалось сгенерировать адрес в подсети $SELECTED_NET"
            exit 1
        fi

        DUPLICATE=false
        for ADDR in "${NEW_ADDRESSES[@]}" "${OLD_ADDRESSES[@]}"; do
            if [[ "$ADDR" == "$NEW_ADDR" ]]; then
                DUPLICATE=true
                break
            fi
        done

        if [[ "$DUPLICATE" == false ]]; then
            NEW_ADDRESSES+=("$NEW_ADDR")
            echo "Принят адрес: $NEW_ADDR (из подсети $SELECTED_NET)"
            break
        else
            echo "Адрес $NEW_ADDR — дубликат, повтор генерации..."
        fi
    done
done

# --- Обновление конфига 3proxy ---
echo "Обновление конфигурации 3proxy..."

TMP_CONFIG=$(mktemp)
grep -v "^proxy" "$CONFIG_FILE" > "$TMP_CONFIG"

for ADDR in "${NEW_ADDRESSES[@]}"; do
    echo "proxy -6 -n -a -p$PORT -i$IPV4_ADDR -e$ADDR" >> "$TMP_CONFIG"
    ((PORT++))
done

mv "$TMP_CONFIG" "$CONFIG_FILE"
echo "Конфиг обновлён."

# --- Создание файла списка прокси: /root/<IPv4>.proxy.txt ---
PROXY_LIST_FILE="/root/${IPV4_ADDR}.proxy.txt"

if [ ! -f /etc/3proxy/.proxypass ]; then
    echo "Ошибка: файл /etc/3proxy/.proxypass не найден."
    exit 1
fi

USER_PASS_LINE=$(head -1 /etc/3proxy/.proxypass 2>/dev/null)
USER=$(echo "$USER_PASS_LINE" | cut -d':' -f1)
PASS=$(echo "$USER_PASS_LINE" | cut -d':' -f3)

if [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "Ошибка: не удалось извлечь логин/пароль из .proxypass."
    exit 1
fi

> "$PROXY_LIST_FILE"

PORT=3000
for ADDR in "${NEW_ADDRESSES[@]}"; do
    echo "$IPV4_ADDR:$PORT@$USER:$PASS" >> "$PROXY_LIST_FILE"
    ((PORT++))
done

echo "Список прокси сохранён в: $PROXY_LIST_FILE"

# --- Перезапуск 3proxy ---
echo "Перезапуск 3proxy..."
systemctl restart 3proxy

sleep 2

if systemctl is-active --quiet 3proxy; then
    echo " 3proxy успешно перезапущен. Ротация завершена."
else
    echo " Ошибка: 3proxy не запущен. Проверьте конфиг."
    journalctl -u 3proxy --no-pager -n 20
    exit 1
fi
