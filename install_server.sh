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

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   OLC-RTC + NATIVE JITSI ALTHOME22.RU INSTALLER       ${NC}"
echo -e "${CYAN}====================================================${NC}"
echo "Выберите действие:"
echo "1) Установить и настроить сервер (Native Jitsi + olcRTC)"
echo "2) ПОЛНАЯ ЗАЧИСТКА (С удалением кэшей ucf)"
echo "0) Выход"
read -p "Ваш выбор: " ACTION

if [[ "$ACTION" == "0" ]]; then exit 0; fi

# ==============================================================================
# БЛОК 2: АБСОЛЮТНАЯ ЗАЧИСТКА
# ==============================================================================
if [[ "$ACTION" == "2" ]]; then
    echo -e "${YELLOW}[*] Начинаем абсолютную зачистку сервера...${NC}"
    systemctl stop olcrtc.service 2>/dev/null || true
    systemctl disable olcrtc.service 2>/dev/null || true
    rm -f /etc/systemd/system/olcrtc.service
    rm -rf /opt/olcrtc /opt/olcrtc-src
    
    rm -f /etc/apt/sources.list.d/jitsi*.list /etc/apt/sources.list.d/prosody*.list
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y jitsi-meet jitsi-meet-prosody jitsi-meet-turnserver jitsi-meet-web-config jitsi-meet-web jitsi-videobridge2 jicofo prosody nginx nginx-common coturn 2>/dev/null || true
    apt-get autoremove -y --purge
    
    if command -v ucf &>/dev/null; then
        rm -rf /var/lib/ucf/hashfile
        rm -rf /var/lib/ucf/registry
    fi
    
    rm -rf /etc/jitsi /etc/prosody /usr/share/jitsi-meet /etc/nginx /etc/turnserver.conf
    
    echo -e "${YELLOW}[*] Отключаем systemd-resolved и прописываем Google DNS...${NC}"
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    systemctl daemon-reload
    echo -e "${GREEN}[+] Сервер чисто и безопасно очищен!${NC}"
    exit 0
fi

# ==============================================================================
# БЛОК 1: УСТАНОВКА И НАСТРОЙКА
# ==============================================================================
if [[ "$ACTION" == "1" ]]; then
    read -p "Введите домен (например, rknzalupa.ru): " DOMAIN
    if [ -z "$DOMAIN" ]; then exit 1; fi
    read -p "Введите email для SSL (Let's Encrypt): " ADMIN_EMAIL
    if [ -z "$ADMIN_EMAIL" ]; then exit 1; fi

    SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}[ОШИБКА] Не удалось определить внешний IP-адрес.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[+] Определен IP сервера: $SERVER_IP${NC}"

    echo -e "\n${YELLOW}[1/11] Настройка файла подкачки (Swap)...${NC}"
    if swapon --show | grep -q "/swapfile"; then
        echo -e "${GREEN}[+] Файл подкачки уже существует.${NC}"
    else
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}[+] Swap 4GB успешно создан.${NC}"
    fi

    echo -e "\n${YELLOW}[2/11] Обновление системы и установка зависимостей...${NC}"
    apt-get update -q
    apt-get install -y ufw gnupg2 apt-transport-https wget jq curl certbot python3-certbot-nginx openjdk-17-jre-headless lua5.2 lua5.4

    ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
    ufw allow 10000/udp >/dev/null; ufw allow 5349/tcp >/dev/null; ufw allow 3478/udp >/dev/null
    ufw --force enable >/dev/null

    echo -e "\n${YELLOW}[3/11] Установка Nginx (Подготовка)...${NC}"
    apt-get -o Dpkg::Options::="--force-confmiss" install --reinstall -y nginx nginx-common
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    echo -e "\n${YELLOW}[4/11] Установка стека Jitsi Meet...${NC}"
    curl -sL https://prosody.im/files/prosody-debian-packages.key | gpg --dearmor > /usr/share/keyrings/prosody-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/prosody-archive-keyring.gpg] http://packages.prosody.im/debian $(lsb_release -sc) main" > /etc/apt/sources.list.d/prosody.list
    curl -sL https://download.jitsi.org/jitsi-key.gpg.key | gpg --dearmor > /usr/share/keyrings/jitsi-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/" > /etc/apt/sources.list.d/jitsi-stable.list
    
    apt-get update -q
    export DEBIAN_FRONTEND=noninteractive
    echo "jitsi-videobridge jitsi-videobridge/jvb-hostname string $DOMAIN" | debconf-set-selections
    echo "jitsi-meet-web-config jitsi-meet/jvb-hostname string $DOMAIN" | debconf-set-selections
    echo "jitsi-meet-web-config jitsi-meet/cert-choice select Generate a new self-signed certificate" | debconf-set-selections
    echo "jitsi-meet jitsi-meet/jvb-hostname string $DOMAIN" | debconf-set-selections
    apt-get install -y jitsi-meet jitsi-meet-turnserver

    echo -e "\n${YELLOW}[5/11] Валидация конфигов (Прямое восстановление)...${NC}"
    rm -f /etc/nginx/sites-enabled/*
    
    if [ ! -f "/etc/nginx/sites-available/$DOMAIN.conf" ]; then
        cp /usr/share/jitsi-meet-web-config/jitsi-meet.example /etc/nginx/sites-available/$DOMAIN.conf
        sed -i "s/jitsi-meet.example.com/$DOMAIN/g" /etc/nginx/sites-available/$DOMAIN.conf
    fi

    if [ ! -f "/etc/jitsi/meet/$DOMAIN-config.js" ]; then
        cp /usr/share/jitsi-meet-web-config/jitsi-meet.example-config.js /etc/jitsi/meet/$DOMAIN-config.js
        sed -i "s/jitsi-meet.example.com/$DOMAIN/g" /etc/jitsi/meet/$DOMAIN-config.js
    fi

    if [ ! -f "/etc/jitsi/meet/$DOMAIN.crt" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/jitsi/meet/$DOMAIN.key -out /etc/jitsi/meet/$DOMAIN.crt -subj "/CN=$DOMAIN" >/dev/null 2>&1
    fi

    ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
    
    if ! nginx -t; then
        echo -e "${RED}[ОШИБКА] Синтаксис Nginx сломан. Остановка скрипта.${NC}"; exit 1
    fi
    systemctl restart nginx

    echo -e "\n${YELLOW}[6/11] Выпуск SSL и настройка TLS 1.2/1.3 (Обход ТСПУ)...${NC}"
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL --redirect
    
    if ! grep -q "ssl_prefer_server_ciphers" /etc/nginx/sites-available/$DOMAIN.conf; then
        sed -i '/ssl_certificate/a \    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_prefer_server_ciphers on;\n    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";' /etc/nginx/sites-available/$DOMAIN.conf
    fi
    systemctl restart nginx

    echo -e "\n${YELLOW}[7/11] Настройка Coturn (STUN/TURN) и порта 5349...${NC}"
    if [ -f "/etc/turnserver.conf" ]; then
        sed -i '/listening-ip=/d' /etc/turnserver.conf
        sed -i '/relay-ip=/d' /etc/turnserver.conf
        
        # Разрешаем TCP и TCP-relay, комментируя параметры блокировки
        sed -i 's/^[[:space:]]*no-tcp/#no-tcp/g' /etc/turnserver.conf
        sed -i 's/^[[:space:]]*no-tcp-relay/#no-tcp-relay/g' /etc/turnserver.conf
        
        echo "listening-ip=0.0.0.0" >> /etc/turnserver.conf
        echo "relay-ip=$SERVER_IP" >> /etc/turnserver.conf
    fi

    openssl ecparam -name prime256v1 -genkey -noout -out /etc/jitsi/meet/coturn.key
    openssl req -new -x509 -days 365 -key /etc/jitsi/meet/coturn.key -out /etc/jitsi/meet/coturn.crt -subj "/CN=$DOMAIN" -addext "subjectAltName = DNS:$DOMAIN, IP:$SERVER_IP"

    chmod +r /etc/jitsi/meet/coturn.key
    chmod +r /etc/jitsi/meet/coturn.crt

    sed -i 's|cert=.*|cert=/etc/jitsi/meet/coturn.crt|g' /etc/turnserver.conf
    sed -i 's|pkey=.*|pkey=/etc/jitsi/meet/coturn.key|g' /etc/turnserver.conf

    systemctl restart coturn
    sleep 3
    
    if ss -tuln | grep -q 5349; then
        echo -e "${GREEN}[+] Порт 5349 успешно открыт и слушает подключения.${NC}"
    else
        echo -e "${RED}[-] Порт 5349 не найден. Проверьте статус службы coturn.${NC}"
    fi

    echo -e "\n${YELLOW}[8/11] Перезапуск и проверка служб Jitsi...${NC}"
    systemctl restart prosody jicofo jitsi-videobridge2
    sleep 5 
    
    for svc in prosody jicofo jitsi-videobridge2 coturn; do
        if systemctl is-active --quiet $svc; then echo -e "Служба $svc: ${GREEN}РАБОТАЕТ${NC}"; else echo -e "Служба $svc: ${RED}ОШИБКА${NC}"; fi
    done

    echo -e "\n${YELLOW}[9/11] Установка Go и сборка olcRTC...${NC}"
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
    
    mkdir -p /opt/olcrtc
    cp ./build/olcrtc-linux-amd64 /opt/olcrtc/

    echo -e "\n${YELLOW}[10/11] Настройка и запуск olcRTC Server...${NC}"
    OLC_KEY=$(openssl rand -hex 32)
    OLC_ROOM_HASH=$(openssl rand -hex 8)
    OLC_ROOM="https://$DOMAIN/$OLC_ROOM_HASH"
    
    cat > /opt/olcrtc/server.yaml <<EOF
mode: srv
auth:
  provider: jitsi
room:
  id: "${OLC_ROOM}"
crypto:
  key: "${OLC_KEY}"
net:
  transport: datachannel
  dns: "8.8.8.8:53"
EOF

    cat > /etc/systemd/system/olcrtc.service <<EOF
[Unit]
Description=OlcRTC Proxy Server
After=network.target network-online.target prosody.service jicofo.service jitsi-videobridge2.service coturn.service

[Service]
Type=simple
WorkingDirectory=/opt/olcrtc
ExecStart=/opt/olcrtc/olcrtc-linux-amd64 server.yaml
Restart=always
RestartSec=5
LimitNOFILE=65000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now olcrtc.service
    sleep 3
    if systemctl is-active --quiet olcrtc.service; then echo -e "olcRTC Server: ${GREEN}РАБОТАЕТ${NC}"; else echo -e "olcRTC Server: ${RED}ОШИБКА${NC}"; fi

    echo -e "\n${YELLOW}[11/11] Сводка и версии компонентов...${NC}"
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -n "Nginx: " && nginx -v 2>&1
    echo -n "Prosody: " && prosodyctl --version
    echo -n "Java (Jicofo/JVB): " && java -version 2>&1 | head -n 1
    echo -n "Go: " && go version
    echo -e "${CYAN}------------------------------------------------${NC}"

    CONFIG_FILE="/root/olcrtc_client_config.txt"
    cat > $CONFIG_FILE <<EOF
===================================================
ДОМЕН: $DOMAIN
IP СЕРВЕРА: $SERVER_IP
TLS: 1.2 & 1.3 (TSPU Bypass Enabled)

URI ДЛЯ КЛИЕНТОВ (Owenclave/olcbox):
olcrtc://jitsi?datachannel@${OLC_ROOM}#${OLC_KEY}\$Мой сервер
===================================================
EOF
    
    echo -e "${GREEN}✅ Нативная установка успешно завершена!${NC}"
    cat $CONFIG_FILE
fi
