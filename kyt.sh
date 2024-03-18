#!/bin/bash

domain=$(cat /etc/xray/domain)
#color
grenbo="\e[92;1m"
NC='\e[0m'
#install
apt update && apt upgrade
apt install python3 python3-pip git
cd /usr/bin
wget https://raw.githubusercontent.com/s4msulm44rif/vpsku/main/bot.zip
unzip bot.zip
mv bot/* /usr/bin
chmod +x /usr/bin/*
rm -rf bot.zip
clear
wget https://raw.githubusercontent.com/s4msulm44rif/vpsku/main/kyt.zip
unzip kyt.zip
pip3 install -r kyt/requirements.txt

CHATID="1849721300"
KEY="5765384772:AAGUVlNWYF5vwvHgALKFSSu6saMCPl8F3dg"

#isi data
echo ""
echo -e ""
echo -e "ADD BOT PANEL"
echo -e "###############"
echo -e "${grenbo}Tutorial Creat Bot and ID Telegram${NC}"
echo -e "${grenbo}[*] Creat Bot and Token Bot : @BotFather${NC}"
echo -e "${grenbo}[*] Info Id Telegram : m44rif@bot , perintah /info${NC}"
echo -e ""
#read -e -p "[*] Input your Bot Token : " KEY
#read -e -p "[*] Input Your Id Telegram :" CHATID
echo -e BOT_TOKEN='"'$KEY'"' >> /usr/bin/kyt/var.txt
echo -e ADMIN='"'$CHATID'"' >> /usr/bin/kyt/var.txt
echo -e DOMAIN='"'$domain'"' >> /usr/bin/kyt/var.txt
clear

cat > /etc/systemd/system/kyt.service << END
[Unit]
Description=Simple kyt - @kyt
After=network.target

[Service]
WorkingDirectory=/usr/bin
ExecStart=/usr/bin/python3 -m kyt
Restart=always

[Install]
WantedBy=multi-user.target
END

systemctl start kyt 
systemctl enable kyt
systemctl restart kyt
cd /root
rm -rf kyt.sh
echo "Done"
echo "Your Data Bot"
echo -e "==============================="
echo "Token Bot         : $KEY"
echo "Admin          : $CHATID"
echo "Domain        : $domain"
echo -e "==============================="
echo "Setting done"
echo "Installations complete, type /menu on your bot"