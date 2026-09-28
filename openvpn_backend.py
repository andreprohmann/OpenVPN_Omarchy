#!/usr/bin/env python3
"""
openvpn_backend.py - Backend helper for Omarchy OpenVPN plugin and tray manager.
Interacts with NetworkManager (nmcli) to manage OpenVPN profiles cleanly.
"""

import sys
import os
import json
import subprocess
import re

def run_cmd(args, timeout=15):
    try:
        res = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def get_status():
    code, stdout, stderr = run_cmd(["nmcli", "-t", "-f", "NAME,UUID,TYPE,ACTIVE,DEVICE,STATE", "connection", "show"])
    if code != 0:
        return {
            "success": False,
            "error": stderr or "Failed to list connections",
            "vpns": [],
            "connected": False,
            "connecting": False,
            "active_name": None,
            "active_ip": None,
            "active_device": None
        }

    vpns = []
    active_vpn = None
    is_connecting = False

    lines = [l for l in stdout.split("\n") if l.strip()]
    for line in lines:
        parts = line.split(":")
        if len(parts) >= 6 and parts[2] == "vpn":
            name = parts[0]
            uuid = parts[1]
            active = parts[3] == "yes"
            device = parts[4]
            state = parts[5]

            if "activating" in state.lower():
                is_connecting = True

            # Get vpn.data
            dcode, dstdout, _ = run_cmd(["nmcli", "-s", "-g", "vpn.data", "connection", "show", uuid])
            server = ""
            username = ""
            if dcode == 0 and dstdout:
                for item in dstdout.split(", "):
                    if "=" in item:
                        k, v = item.split("=", 1)
                        k = k.strip()
                        v = v.strip().replace("\\:", ":")
                        if k == "remote":
                            server = v
                        elif k == "username":
                            username = v

            # Check if secrets / password saved
            scode, sstdout, _ = run_cmd(["nmcli", "--show-secrets", "-s", "-g", "vpn.secrets", "connection", "show", uuid])
            has_saved_password = False
            if scode == 0 and sstdout:
                match = re.search(r"password\s*=\s*(.+)", sstdout)
                if match and match.group(1).strip():
                    has_saved_password = True

            # Get IP if active
            ip = ""
            if active and device:
                icode, istdout, _ = run_cmd(["nmcli", "-g", "IP4.ADDRESS", "device", "show", device])
                if icode == 0 and istdout:
                    ip = istdout.split("\n")[0].split("/")[0].strip()

            vpn_obj = {
                "name": name,
                "uuid": uuid,
                "active": active,
                "state": state if state else ("activated" if active else "inactive"),
                "device": device,
                "server": server,
                "username": username,
                "has_saved_password": has_saved_password,
                "ip": ip
            }
            vpns.append(vpn_obj)
            if active:
                active_vpn = vpn_obj

    return {
        "success": True,
        "connected": active_vpn is not None,
        "connecting": is_connecting,
        "active_name": active_vpn["name"] if active_vpn else None,
        "active_uuid": active_vpn["uuid"] if active_vpn else None,
        "active_ip": active_vpn["ip"] if active_vpn else None,
        "active_device": active_vpn["device"] if active_vpn else None,
        "active_server": active_vpn["server"] if active_vpn else None,
        "vpns": vpns
    }

def connect_vpn(target):
    # Check if another VPN is already active, disconnect it first
    status = get_status()
    if status.get("connected") and status.get("active_uuid") != target and status.get("active_name") != target:
        disconnect_vpn(status.get("active_uuid"))

    code, stdout, stderr = run_cmd(["nmcli", "connection", "up", target], timeout=25)
    if code == 0:
        return {"success": True, "message": f"Conectado com sucesso: {target}"}
    
    needs_credentials = False
    lower_err = (stderr + " " + stdout).lower()
    if "no valid secrets" in lower_err or "password is required" in lower_err:
        needs_credentials = True

    return {
        "success": False,
        "error": stderr or stdout or "Falha ao conectar",
        "needs_credentials": needs_credentials
    }

def disconnect_vpn(target=None):
    if not target:
        status = get_status()
        if status.get("connected") and status.get("active_uuid"):
            target = status.get("active_uuid")
        else:
            return {"success": True, "message": "Nenhuma VPN ativa para desconectar"}

    code, stdout, stderr = run_cmd(["nmcli", "connection", "down", target], timeout=15)
    if code == 0:
        return {"success": True, "message": "Desconectado com sucesso"}
    return {"success": False, "error": stderr or stdout or "Falha ao desconectar"}

def set_credentials(target, username, password=None):
    mod_data = f"username={username}, password-flags=0"
    code, stdout, stderr = run_cmd(["nmcli", "connection", "modify", target, "+vpn.data", mod_data])
    if code != 0:
        return {"success": False, "error": stderr or "Falha ao atualizar usuário"}

    if password is not None:
        pcode, pstdout, pstderr = run_cmd(["nmcli", "connection", "modify", target, "vpn.secrets", f"password={password}"])
        if pcode != 0:
            return {"success": False, "error": pstderr or "Falha ao atualizar senha"}

    return {"success": True, "message": "Credenciais atualizadas com sucesso"}

def import_ovpn(filepath, custom_name=None):
    if not os.path.isfile(filepath):
        return {"success": False, "error": f"Arquivo não encontrado: {filepath}"}

    code, stdout, stderr = run_cmd(["nmcli", "connection", "import", "type", "openvpn", "file", filepath])
    if code != 0:
        return {"success": False, "error": stderr or stdout or "Falha ao importar .ovpn"}

    # Extract connection name and UUID
    # Output format: Connection 'srvppfsense...' (c70ec7ba-...) successfully added.
    match = re.search(r"Connection '([^']+)' \(([^)]+)\) successfully added", stdout)
    conn_name = match.group(1) if match else None
    conn_uuid = match.group(2) if match else None

    target = conn_uuid or conn_name
    if target:
        # Default password-flags=0 so passwords can be saved
        run_cmd(["nmcli", "connection", "modify", target, "+vpn.data", "password-flags=0"])

        # Check if username exists in .ovpn or config
        if custom_name:
            run_cmd(["nmcli", "connection", "modify", target, "connection.id", custom_name])
            conn_name = custom_name

    return {
        "success": True,
        "name": conn_name,
        "uuid": conn_uuid,
        "message": f"Conexão '{conn_name}' importada com sucesso!"
    }

def pick_and_import():
    code, stdout, stderr = run_cmd([
        "zenity", "--file-selection",
        "--file-filter=Arquivos OpenVPN (*.ovpn) | *.ovpn",
        "--title=Selecionar arquivo OpenVPN (.ovpn)"
    ], timeout=120)

    if code != 0 or not stdout:
        return {"success": False, "cancelled": True, "error": "Seleção cancelada"}

    filepath = stdout.strip()
    return import_ovpn(filepath)

def delete_vpn(target):
    code, stdout, stderr = run_cmd(["nmcli", "connection", "delete", target])
    if code == 0:
        return {"success": True, "message": "Conexão excluída com sucesso"}
    return {"success": False, "error": stderr or stdout or "Falha ao excluir conexão"}

def rename_vpn(target, new_name):
    code, stdout, stderr = run_cmd(["nmcli", "connection", "modify", target, "connection.id", new_name])
    if code == 0:
        return {"success": True, "message": f"Renomeado para '{new_name}'"}
    return {"success": False, "error": stderr or stdout or "Falha ao renomear"}

def get_logs():
    code, stdout, _ = run_cmd(["journalctl", "-u", "NetworkManager", "-n", "30", "--no-pager"])
    lines = []
    if code == 0 and stdout:
        for line in stdout.split("\n"):
            if "vpn" in line.lower() or "openvpn" in line.lower():
                lines.append(line)
        if not lines:
            lines = stdout.split("\n")[-15:]
    return {"success": True, "logs": lines}

def main():
    if len(sys.argv) < 2:
        res = get_status()
        print(json.dumps(res, indent=2))
        return

    action = sys.argv[1].lower()

    if action in ("status", "list"):
        print(json.dumps(get_status()))
    elif action == "connect":
        if len(sys.argv) < 3:
            print(json.dumps({"success": False, "error": "Alvo de conexão não especificado"}))
            sys.exit(1)
        print(json.dumps(connect_vpn(sys.argv[2])))
    elif action == "disconnect":
        target = sys.argv[2] if len(sys.argv) > 2 else None
        print(json.dumps(disconnect_vpn(target)))
    elif action == "toggle":
        status = get_status()
        if status.get("connected"):
            print(json.dumps(disconnect_vpn(status.get("active_uuid"))))
        else:
            # If target specified, connect that. Otherwise connect first available VPN
            target = sys.argv[2] if len(sys.argv) > 2 else None
            if not target and status.get("vpns"):
                target = status["vpns"][0]["uuid"]
            if target:
                print(json.dumps(connect_vpn(target)))
            else:
                print(json.dumps({"success": False, "error": "Nenhuma conexão VPN configurada"}))
    elif action == "import":
        if len(sys.argv) < 3:
            print(json.dumps({"success": False, "error": "Caminho do arquivo não especificado"}))
            sys.exit(1)
        custom_name = sys.argv[3] if len(sys.argv) > 3 else None
        print(json.dumps(import_ovpn(sys.argv[2], custom_name)))
    elif action == "pick-and-import":
        print(json.dumps(pick_and_import()))
    elif action == "set-credentials":
        if len(sys.argv) < 4:
            print(json.dumps({"success": False, "error": "Parâmetros insuficientes: target username [password]"}))
            sys.exit(1)
        target = sys.argv[2]
        username = sys.argv[3]
        password = sys.argv[4] if len(sys.argv) > 4 else None
        print(json.dumps(set_credentials(target, username, password)))
    elif action == "delete":
        if len(sys.argv) < 3:
            print(json.dumps({"success": False, "error": "Alvo não especificado"}))
            sys.exit(1)
        print(json.dumps(delete_vpn(sys.argv[2])))
    elif action == "rename":
        if len(sys.argv) < 4:
            print(json.dumps({"success": False, "error": "Parâmetros insuficientes: target new_name"}))
            sys.exit(1)
        print(json.dumps(rename_vpn(sys.argv[2], sys.argv[3])))
    elif action == "logs":
        print(json.dumps(get_logs()))
    else:
        print(json.dumps({"success": False, "error": f"Ação desconhecida: {action}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
