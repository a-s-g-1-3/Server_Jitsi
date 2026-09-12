#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ОШИБКА] Скрипт должен быть запущен от имени root (sudo).${NC}"
   exit 1
fi

BIN_DIR="/opt/olcrtc"
BIN_PATH="${BIN_DIR}/olcrtc-linux-amd64"

# ==========================================
# ФУНКЦИИ БАЗОВОЙ УСТАНОВКИ (RUN ONCE)
# ==========================================
install_dependencies() {
    if [ ! -f "$BIN_PATH" ]; then
        echo -e "${YELLOW}[*] Первичная настройка: установка зависимостей и компиляция olcRTC...${NC}"
        apt-get update -q >/dev/null 2>&1
        apt-get install -y git wget ufw jq curl iproute2 -q
        
        if [ ! -f "/swapfile" ]; then
            fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
        fi

        wget -q https://go.dev/dl/go1.26.3.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.26.3.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        rm -f go1.26.3.linux-amd64.tar.gz
        
        go install github.com/magefile/mage@latest
        export PATH=$PATH:$HOME/go/bin

        rm -rf /opt/olcrtc-src && mkdir -p /opt/olcrtc-src
        git clone https://github.com/openlibrecommunity/olcrtc --recurse-submodules /opt/olcrtc-src
        cd /opt/olcrtc-src
        mage build
        
        mkdir -p $BIN_DIR
        cp ./build/olcrtc-linux-amd64 $BIN_PATH
        echo -e "${GREEN}[+] Базовое ядро olcRTC успешно скомпилировано!${NC}"
    fi
}

# ==========================================
# ФУНКЦИЯ ДОБАВЛЕНИЯ НОДЫ
# ==========================================
add_node() {
    install_dependencies
    
    echo -e "\n${CYAN}--- ДОБАВЛЕНИЕ НОВОЙ НОДЫ ---${NC}"
    echo -e "${YELLOW}Подсказка: Скопируйте и вставьте всю строку URI целиком, которую выдал сервер.${NC}"
    read -p "Введите полный URI (начинается с olcrtc://...): " FULL_URI
    
    if [ -z "$FULL_URI" ]; then 
        echo -e "${RED}Ошибка: Строка не может быть пустой.${NC}"
        return
    fi

    # Автоматический парсинг строки
    ROOM_ID=$(echo "$FULL_URI" | sed -e 's/.*@\([^#]*\).*/\1/')
    CRYPTO_KEY=$(echo "$FULL_URI" | sed -e 's/.*#\([^$]*\).*/\1/')

    # Проверка, успешно ли отработал парсинг
    if [ -z "$ROOM_ID" ] || [ -z "$CRYPTO_KEY" ] || [[ "$ROOM_ID" == "$FULL_URI" ]]; then
        echo -e "${RED}Ошибка: Не удалось распознать формат URI. Убедитесь, что скопировали строку целиком.${NC}"
        return
    fi

    echo -e "${GREEN}[+] Распознан ROOM_ID: ${ROOM_ID}${NC}"
    echo -e "${GREEN}[+] Распознан CRYPTO_KEY: ${CRYPTO_KEY}${NC}"

    # Автоматический поиск свободного порта начиная с 1090
    PORT=1090
    while true; do
        if ss -tuln | grep -q ":$PORT " || [ -f "$BIN_DIR/client_${PORT}.yaml" ]; then
            PORT=$((PORT+1))
        else
            break
        fi
    done

    echo -e "${YELLOW}[*] Выделен локальный порт: ${PORT}${NC}"

    cat > $BIN_DIR/client_${PORT}.yaml <<EOF
mode: cnc
socks:
  host: "127.0.0.1"
  port: ${PORT}
auth:
  provider: jitsi
room:
  id: "${ROOM_ID}"
crypto:
  key: "${CRYPTO_KEY}"
net:
  transport: datachannel
  dns: "8.8.8.8:53"
EOF

    cat > /etc/systemd/system/olcrtc-client-${PORT}.service <<EOF
[Unit]
Description=OlcRTC Client Proxy (Port ${PORT})
After=network.target network-online.target

[Service]
Type=simple
WorkingDirectory=$BIN_DIR
ExecStart=$BIN_PATH client_${PORT}.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now olcrtc-client-${PORT}.service
    
    echo -e "${GREEN}✅ Нода успешно создана! Локальный SOCKS5 порт: ${PORT}${NC}"
}

# ==========================================
# ФУНКЦИЯ УДАЛЕНИЯ НОДЫ
# ==========================================
remove_node() {
    echo -e "\n${CYAN}--- УДАЛЕНИЕ НОДЫ ---${NC}"
    NODES=$(ls $BIN_DIR/client_*.yaml 2>/dev/null)
    
    if [ -z "$NODES" ]; then
        echo -e "${YELLOW}Нет установленных нод.${NC}"
        return
    fi

    echo "Список активных нод:"
    for NODE in $NODES; do
        PORT=$(basename $NODE | tr -dc '0-9')
        echo " - Нода на порту: $PORT"
    done

    read -p "Введите ПОРТ ноды для удаления (или 0 для отмены): " DEL_PORT
    if [[ "$DEL_PORT" == "0" || -z "$DEL_PORT" ]]; then return; fi

    if [ -f "$BIN_DIR/client_${DEL_PORT}.yaml" ]; then
        systemctl stop olcrtc-client-${DEL_PORT}.service 2>/dev/null
        systemctl disable olcrtc-client-${DEL_PORT}.service 2>/dev/null
        rm -f /etc/systemd/system/olcrtc-client-${DEL_PORT}.service
        rm -f $BIN_DIR/client_${DEL_PORT}.yaml
        systemctl daemon-reload
        echo -e "${GREEN}[+] Нода на порту ${DEL_PORT} полностью удалена.${NC}"
    else
        echo -e "${RED}[-] Нода с портом ${DEL_PORT} не найдена.${NC}"
    fi
}

# ==========================================
# ФУНКЦИЯ ТЕСТИРОВАНИЯ НОД
# ==========================================
test_nodes() {
    echo -e "\n${CYAN}--- ДИАГНОСТИКА НОД ---${NC}"
    NODES=$(ls $BIN_DIR/client_*.yaml 2>/dev/null)
    
    if [ -z "$NODES" ]; then
        echo -e "${YELLOW}Нет установленных нод для проверки.${NC}"
        return
    fi

    echo "Проверяем подключение через активные туннели..."
    echo "------------------------------------------------"
    for NODE in $NODES; do
        PORT=$(basename $NODE | tr -dc '0-9')
        STATUS=$(systemctl is-active olcrtc-client-${PORT}.service)
        
        if [ "$STATUS" == "active" ]; then
            IP_CHECK=$(curl -s --socks5-hostname 127.0.0.1:${PORT} --connect-timeout 5 https://api.ipify.org)
            if [ -n "$IP_CHECK" ]; then
                echo -e "Порт ${PORT}: ${GREEN}РАБОТАЕТ${NC} (Выходной IP: $IP_CHECK)"
            else
                echo -e "Порт ${PORT}: ${RED}ОШИБКА МАРШРУТИЗАЦИИ${NC} (Туннель не пропускает трафик)"
            fi
        else
            echo -e "Порт ${PORT}: ${RED}СЛУЖБА ОСТАНОВЛЕНА${NC} ($STATUS)"
        fi
    done
    echo "------------------------------------------------"
}

# ==========================================
# ФУНКЦИЯ ПОЛНОГО ОБНОВЛЕНИЯ OLCRTC
# ==========================================
update_olcrtc() {
    echo -e "\n${CYAN}--- ОБНОВЛЕНИЕ ЯДРА olcRTC ---${NC}"
    export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
    
    if ! command -v mage &> /dev/null; then
        echo -e "${YELLOW}[*] Устанавливаем mage (сборщик Go)...${NC}"
        go install github.com/magefile/mage@latest
    fi

    echo -e "${YELLOW}[*] Скачиваем последние исходники с GitHub...${NC}"
    rm -rf /opt/olcrtc-src
    git clone https://github.com/openlibrecommunity/olcrtc --recurse-submodules /opt/olcrtc-src
    cd /opt/olcrtc-src
    
    echo -e "${YELLOW}[*] Выполняем компиляцию...${NC}"
    mage build
    
    if [ -f "./build/olcrtc-linux-amd64" ]; then
        echo -e "${YELLOW}[*] Остановка всех активных клиентских служб...${NC}"
        for svc in $(ls /etc/systemd/system/olcrtc-client-*.service 2>/dev/null); do
            systemctl stop $(basename $svc)
        done
        
        echo -e "${YELLOW}[*] Замена бинарника...${NC}"
        cp ./build/olcrtc-linux-amd64 $BIN_PATH
        chmod +x $BIN_PATH
        
        echo -e "${YELLOW}[*] Запуск служб с новой версия ядра...${NC}"
        for svc in $(ls /etc/systemd/system/olcrtc-client-*.service 2>/dev/null); do
            systemctl start $(basename $svc)
        done
        
        echo -e "${GREEN}[+] olcRTC успешно обновлен до последней версии из репозитория!${NC}"
    else
        echo -e "${RED}[-] Ошибка компиляции. Обновление прервано, старая версия не затронута.${NC}"
    fi
}

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================
while true; do
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${CYAN}      🛡️ OLC-RTC MULTI-NODE MANAGER (RUSSIA)        ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo "1) ➕ Добавить новую клиентскую ноду"
    echo "2) 🗑️  Удалить существующую ноду"
    echo "3) 📡 Тестировать активные ноды (Проверка IP/SOCKS)"
    echo "4) 🔄 Обновить ядро (Пересобрать olcRTC из исходников)"
    echo "0) ❌ Выход"
    read -p "Выберите действие: " CHOICE

    case $CHOICE in
        1) add_node ;;
        2) remove_node ;;
        3) test_nodes ;;
        4) update_olcrtc ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор.${NC}" ;;
    esac
done
