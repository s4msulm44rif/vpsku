#!/usr/bin/env bash
set -euo pipefail

echo "[+] Update system"
apt-get update -y >/dev/null 2>&1
apt-get upgrade -y >/dev/null 2>&1

echo "[+] Remove old zivpn service (if any)"
systemctl stop zivpn.service 2>/dev/null || true
systemctl disable zivpn.service 2>/dev/null || true
rm -f /etc/systemd/system/zivpn.service
systemctl daemon-reload 2>/dev/null || true

echo "[+] Install dependencies"
apt-get install -y wget curl openssl iptables ufw python3 python3-venv python3-full >/dev/null 2>&1

echo "[+] Install ZIVPN binary"
wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn
chmod +x /usr/local/bin/zivpn

echo "[+] Setup /etc/zivpn"
mkdir -p /etc/zivpn
wget -q https://raw.githubusercontent.com/zahidbd2/udp-zivpn/main/config.json -O /etc/zivpn/config.json

echo "[+] Generate TLS cert"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
  -subj "/C=US/ST=California/L=LA/O=Example/OU=IT/CN=zivpn" \
  -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt >/dev/null 2>&1

echo "[+] Kernel tuning"
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1

echo "[?] Input password(s) (comma separated, default=zi)"
read -r input_config || true
if [ -n "${input_config:-}" ]; then
  IFS=',' read -r -a config <<< "$input_config"
else
  config=("zi")
fi

# inject passwords safely
new_config_str="\"config\": [$(printf "\"%s\"," "${config[@]}" | sed 's/,$//')]"
sed -i -E "s/\"config\": ?\[[^]]*\]/${new_config_str}/g" /etc/zivpn/config.json

echo "[+] Firewall rules"
iptables -t nat -A PREROUTING -i $(ip route | awk '/default/ {print $5}') -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || true
ufw allow 6000:19999/udp >/dev/null 2>&1 || true
ufw allow 5667/udp >/dev/null 2>&1 || true

# =========================
# ZIMAN + VENV (SELF-HEALING)
# =========================

echo "[+] Install ziman (venv + self-healing)"
rm -rf /opt/zivman
mkdir -p /opt/zivman/{app,data,logs}
cd /opt/zivman

echo "[+] Create virtualenv"
python3 -m venv venv
./venv/bin/pip install --upgrade pip >/dev/null 2>&1

# -------- config.ini --------
cat > /opt/zivman/config.ini << 'EOF'
ZIVPN_BIN=/usr/local/bin/zivpn
CONFIG_JSON=/etc/zivpn/config.json
PID_FILE=/var/run/zivpn.pid
LOG_FILE=/opt/zivman/logs/zivpn.log
DB_PATH=/opt/zivman/data/db.sqlite3
LOCK_FILE=/tmp/zivpn.lock
EOF

# -------- app/config.py --------
cat > /opt/zivman/app/config.py << 'EOF'
CONFIG={}
for line in open("/opt/zivman/config.ini"):
    if "=" in line:
        k,v=line.strip().split("=",1)
        CONFIG[k]=v
def get(k): return CONFIG.get(k)
EOF

# -------- app/db.py --------
cat > /opt/zivman/app/db.py << 'EOF'
import sqlite3, os
from app.config import get
def connect():
    path=get("DB_PATH")
    os.makedirs(os.path.dirname(path),exist_ok=True)
    return sqlite3.connect(path)
def init():
    con=connect()
    con.execute("CREATE TABLE IF NOT EXISTS users(username TEXT, expired_at TEXT, status TEXT)")
    con.commit(); con.close()
EOF

# -------- app/utils.py --------
cat > /opt/zivman/app/utils.py << 'EOF'
import os,time,json,shutil
from app.config import get
LOCK=get("LOCK_FILE")
def lock():
    while os.path.exists(LOCK): time.sleep(0.2)
    open(LOCK,"w").close()
def unlock():
    if os.path.exists(LOCK): os.remove(LOCK)
def atomic_write(path,data):
    tmp=path+".tmp"
    with open(tmp,"w") as f: json.dump(data,f,indent=2)
    os.replace(tmp,path)
def backup(path):
    if os.path.exists(path): shutil.copy(path,path+".bak")
EOF

# -------- app/process.py (BUG-FREE + SELF-HEAL) --------
cat > /opt/zivman/app/process.py << 'EOF'
import os,signal,subprocess,time
from app.config import get

BIN=get("ZIVPN_BIN"); CFG=get("CONFIG_JSON")
PID=get("PID_FILE"); LOG=get("LOG_FILE")

def running(pid):
    try: os.kill(pid,0); return True
    except: return False

def get_pid():
    if not os.path.exists(PID): return None
    try:
        content=open(PID).read().strip()
        if not content: return None
        return int(content)
    except:
        return None

def clean_stale_pid():
    pid=get_pid()
    if pid and not running(pid):
        try: os.remove(PID)
        except: pass

def start():
    clean_stale_pid()
    pid=get_pid()
    if pid and running(pid):
        return f"already running ({pid})"

    if os.path.exists(PID):
        try: os.remove(PID)
        except: pass

    os.makedirs(os.path.dirname(LOG),exist_ok=True)
    log=open(LOG,"a")

    p=subprocess.Popen([BIN,"server","-c",CFG],
        stdout=log,stderr=log,preexec_fn=os.setsid)

    with open(PID,"w") as f:
        f.write(str(p.pid))

    return f"started {p.pid}"

def stop():
    pid=get_pid()
    if not pid:
        return "not running"

    try:
        os.killpg(os.getpgid(pid),signal.SIGTERM)
        time.sleep(2)
        if running(pid):
            os.killpg(os.getpgid(pid),signal.SIGKILL)
    except:
        pass

    try: os.remove(PID)
    except: pass

    return "stopped"

def restart():
    stop(); time.sleep(1); return start()

def status():
    clean_stale_pid()
    pid=get_pid()
    return f"running {pid}" if pid and running(pid) else "stopped"
EOF

# -------- app/users.py (JSON passwords mode) --------
cat > /opt/zivman/app/users.py << 'EOF'
import json
from datetime import datetime,timedelta
from app.config import get
from app.utils import lock,unlock,atomic_write,backup
from app.db import connect

CFG=get("CONFIG_JSON")

def load():
    try:
        return json.load(open(CFG))
    except:
        return {"auth":{"mode":"passwords","config":[]}}

def save(data):
    backup(CFG)
    atomic_write(CFG,data)

def ensure_structure(data):
    if "auth" not in data:
        data["auth"]={"mode":"passwords","config":[]}
    if "config" not in data["auth"]:
        data["auth"]["config"]=[]
    return data

def get_list(data):
    data=ensure_structure(data)
    return data["auth"]["config"]

def add(pw):
    lock()
    data=load()
    pw_list=get_list(data)

    if pw in pw_list:
        unlock(); return "exists"

    pw_list.append(pw)
    save(data)

    con=connect()
    con.execute("INSERT INTO users VALUES(?,?,?)",
        (pw,(datetime.now()+timedelta(days=30)).isoformat(),"active"))
    con.commit(); con.close()

    unlock()
    return "added"

def delete(pw):
    lock()
    data=load()
    pw_list=get_list(data)

    data["auth"]["config"]=[p for p in pw_list if p!=pw]
    save(data)

    con=connect()
    con.execute("UPDATE users SET status='deleted' WHERE username=?",(pw,))
    con.commit(); con.close()

    unlock()

def list_users():
    data=load()
    return get_list(data)

def expire():
    lock()
    data=load()
    pw_list=get_list(data)

    con=connect()
    rows=con.execute("SELECT username,expired_at FROM users WHERE status='active'").fetchall()

    changed=False
    for r in rows:
        if datetime.now()>datetime.fromisoformat(r[1]):
            pw_list=[p for p in pw_list if p!=r[0]]
            con.execute("UPDATE users SET status='expired' WHERE username=?",(r[0],))
            changed=True

    if changed:
        data["auth"]["config"]=pw_list
        save(data)

    con.commit(); con.close()
    unlock()
EOF

# -------- app/cli.py --------
cat > /opt/zivman/app/cli.py << 'EOF'
from app.process import *
from app.users import *
from app.config import get
import os

def menu():
    while True:
        print(f"\nZIMAN [{status()}]")
        print("1.Start 2.Stop 3.Restart 4.List 5.Add 6.Del 7.Expire 8.Log 0.Exit")
        c=input("> ")
        if c=="1": print(start())
        elif c=="2": print(stop())
        elif c=="3": print(restart())
        elif c=="4": [print(u) for u in list_users()]
        elif c=="5":
            pw=input("password: "); print(add(pw)); restart()
        elif c=="6":
            pw=input("password: "); delete(pw); restart()
        elif c=="7": expire(); restart()
        elif c=="8": os.system("tail -f "+get("LOG_FILE"))
        elif c=="0": break
EOF

# -------- run.py (venv shebang) --------
cat > /opt/zivman/run.py << 'EOF'
#!/opt/zivman/venv/bin/python
import sys
from app.db import init
from app.cli import menu
from app.process import *
from app.users import *

init()

if len(sys.argv)>1:
    cmd=sys.argv[1]
    if cmd=="start": print(start())
    elif cmd=="stop": print(stop())
    elif cmd=="restart": print(restart())
    elif cmd=="status": print(status())
    elif cmd=="add": print(add(sys.argv[2])); restart()
    elif cmd=="del": delete(sys.argv[2]); restart()
    elif cmd=="list": [print(u) for u in list_users()]
    elif cmd=="expire": expire(); restart()
else:
    menu()
EOF

chmod +x /opt/zivman/run.py
ln -sf /opt/zivman/run.py /usr/local/bin/ziman

echo "[+] Permissions"
chmod -R 700 /opt/zivman

echo "[+] Setup auto-start (venv)"
(crontab -l 2>/dev/null; echo "@reboot /opt/zivman/venv/bin/python /opt/zivman/run.py start") | crontab -

echo "[+] Start ZIVPN via ziman"
ziman start

echo -e "\n[✓] INSTALL COMPLETE"
echo "Use:"
echo "  ziman"
echo "  ziman start|stop|restart|status"
echo "  ziman add <password>"
echo "  ziman del <password>"
echo "  ziman list"
echo "  ziman expire"