#!/bin/bash

#echo "=== Установка и настройка 3proxy с ручным вводом IPv6 ==="
#
# Обновление и установка зависимостей
#echo "Обновление пакетов и установка зависимостей..."
#sudo apt update >/dev/null 2>&1
#sudo apt install -y wget build-essential python3 iproute2

# Скачивание и установка 3proxy
#if [ ! -f "3proxy-0.9.4.x86_64.deb" ]; then
#    echo "Скачивание 3proxy..."
#    wget -q https://github.com/z3APA3A/3proxy/releases/download/0.9.4/3proxy-0.9.4.x86_64.deb
#fi

#echo "Установка 3proxy..."
#sudo dpkg -i 3proxy-0.9.4.x86_64.deb 2>/dev/null || sudo apt install -f -y


set -euo pipefail

# --- Ручной ввод ОДНОЙ или НЕСКОЛЬКИХ IPv6 подсетей ---
read -p "Введите IPv6 подсети через пробел (например, 2a0a:9300:d1::/48 2a0b:abcd::/64): " -a IPV6_NETWORKS_INPUT

if [ ${#IPV6_NETWORKS_INPUT[@]} -eq 0 ]; then
    echo "Ошибка: Не введено ни одной подсети."
    exit 1
fi

IPV4_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IPV4_ADDR" ]; then
    echo "Ошибка: Не удалось определить IPv4 адрес."
    exit 1
fi

# Запрос параметров
read -p "Введите количество прокси портов (начиная с 3000): " PROXY_COUNT
read -p "Введите Логин: " USER
read -p "Введите Пароль: " PASS

# Проверка числа
if ! [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] || [ "$PROXY_COUNT" -eq 0 ]; then
    echo "Ошибка: Количество прокси должно быть положительным числом."
    exit 1
fi

# Функция генерации случайного IPv6 — БЕЗ проверок, упрощённая
generate_random_ipv6() {
    local net="$1"  # Передаём подсеть как аргумент
    python3 -c "
import ipaddress
import random
net = ipaddress.IPv6Network('$net', strict=False)
print(str(net[random.randint(1, net.num_addresses - 2)]))
"
}

# Настройка sysctl — безопасная версия
echo "Настройка sysctl..."

# Устанавливаем параметры напрямую (без записи в файл — если не нужно сохранять после перезагрузки)
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
sysctl -w net.ipv6.ip_nonlocal_bind=1 >/dev/null 2>&1

# Если нужно сохранить в файл — сначала удаляем дубли, потом добавляем
if [ -f /etc/sysctl.conf ]; then
    # Удаляем старые записи, если есть
    sed -i '/^net\.ipv6\.conf\.all\.forwarding/d' /etc/sysctl.conf
    sed -i '/^net\.ipv6\.ip_nonlocal_bind/d' /etc/sysctl.conf
    # Добавляем новые
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.ip_nonlocal_bind=1" >> /etc/sysctl.conf
fi

# Создаём директорию логов
mkdir -p /var/log/3proxy

# Создаём файл с паролями
echo "$USER:CL:$PASS" > /etc/3proxy/.proxypass
chmod 600 /etc/3proxy/.proxypass

# Основной конфиг 3proxy
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
PROXY_LIST_FILE="/root/$IPV4_ADDR.proxy.txt"

# --- Этап 1: Чтение старых адресов из конфига (только для исключения дублей в генерации) ---
OLD_ADDRESSES=()
if [ -f "$CONFIG_FILE" ]; then
    mapfile -t OLD_ADDRESSES < <(grep "^proxy.* -e" "$CONFIG_FILE" | sed -E 's/.* -e([^ ]+).*/\1/' 2>/dev/null || true)
fi

# --- Этап 2: Удаление старых маршрутов для ВСЕХ введённых подсетей (на всякий случай) ---
echo "Очистка старых маршрутов для введённых подсетей..."
for NET in "${IPV6_NETWORKS_INPUT[@]}"; do
    ip -6 route del local "$NET" dev lo 2>/dev/null && echo "Удалён маршрут для $NET" || true
done

# Основной конфиг 3proxy
cat > "$CONFIG_FILE" << 'EOF'
setgid 110
setuid 103
nserver 8.8.8.8
nserver 8.8.4.4
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
users $/etc/3proxy/.proxypass
daemon
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
auth cache strong
EOF

# Генерируем прокси-порты
PORT=3000
> "$PROXY_LIST_FILE"

echo "Генерация $PROXY_COUNT новых IPv6 адресов из ${#IPV6_NETWORKS_INPUT[@]} подсетей..."

for i in $(seq 1 $PROXY_COUNT); do
    while :; do
        # Случайный выбор подсети
        RANDOM_INDEX=$((RANDOM % ${#IPV6_NETWORKS_INPUT[@]}))
        SELECTED_NET="${IPV6_NETWORKS_INPUT[$RANDOM_INDEX]}"

        # Генерация адреса
        if ! NEW_ADDR=$(generate_random_ipv6 "$SELECTED_NET" 2>/dev/null); then
            echo "Не удалось сгенерировать адрес в подсети $SELECTED_NET"
            exit 1
        fi

        # Проверка дубликатов
        DUPLICATE=false
        for ADDR in "${NEW_ADDRESSES[@]}" "${OLD_ADDRESSES[@]}"; do
            if [[ "$ADDR" == "$NEW_ADDR" ]]; then
                DUPLICATE=true
                break
            fi
        done

        if [[ "$DUPLICATE" == false ]]; then
            break
        else
            echo "Адрес $NEW_ADDR — дубликат — повтор генерации..."
        fi
    done

    NEW_ADDRESSES+=("$NEW_ADDR")

    # Добавляем в конфиг
    echo "proxy -6 -n -a -p$PORT -i$IPV4_ADDR -e$NEW_ADDR" >> "$CONFIG_FILE"
    echo "$IPV4_ADDR:$PORT@$USER:$PASS" >> "$PROXY_LIST_FILE"
    echo "Добавлено: порт $PORT → $NEW_ADDR"


    ((PORT++))
done

# --- Этап 3: Добавление маршрутов для ВСЕХ введённых подсетей ---
echo "Добавление маршрутов для подсетей через lo..."
for NET in "${IPV6_NETWORKS_INPUT[@]}"; do
    if ip -6 route add local "$NET" dev lo 2>/dev/null; then
        echo " Добавлен маршрут для $NET"
    else
        if ip -6 route show table local | grep -q "local $NET"; then
            echo " Маршрут для $NET уже существует"
        else
            echo " Не удалось добавить маршрут для $NET"
            exit 1
        fi
    fi
done

# Перезапуск 3proxy
echo "Перезапуск 3proxy..."
systemctl daemon-reload
systemctl restart 3proxy

sleep 2

if systemctl is-active --quiet 3proxy; then
    echo " 3proxy успешно запущен."
else
    echo " Ошибка запуска 3proxy:"
    journalctl -u 3proxy --no-pager -n 20
    exit 1
fi

echo "Список прокси: $PROXY_LIST_FILE"

# --- Запрос расписания cron у пользователя ---
read -p "Введите cron расписание для fin-rotate.sh (например, 0 3 * * *): " CRON_TIME

# Проверяем, что введено 5 полей
if [[ $(echo "$CRON_TIME" | wc -w) -eq 5 ]]; then
    CRON_JOB="$CRON_TIME /root/testip/fin-rotate.sh >> /var/log/fin-rotate.log 2>&1"
    (crontab -l 2>/dev/null | grep -vF "/root/testip/fin-rotate.sh" || true; echo "$CRON_JOB") | crontab -
    echo " Задача добавлена: $CRON_JOB"
else
    echo " Ошибка: неверный формат. Нужно 5 полей (например: 0 3 * * *)"
fi

echo " Готово. Ошибок нет"
