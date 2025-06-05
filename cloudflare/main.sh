#!/bin/bash
# Deploy Enterprise-Ready Cloudflare Tunnel in Proxmox with Zero Trust
# Usage: bash -c "$(curl -fsSL https://github.com/Provisio-Hosting/bash-helperscript/tree/master/cloudflare/main.sh) | bash"

# ---------------------------
# FUNZIONI PRINCIPALI
# ---------------------------

validate_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || {
        echo "Formato CIDR non valido! Esempio: 10.42.42.0/24"
        exit 1
    }
}

deploy_network() {
    echo -e "\n\033[1;34m=== CREAZIONE NETWORK ZONE ===\033[0m"
    read -p "Inserisci VLAN ID (default: 42): " VLAN_TAG
    VLAN_TAG=${VLAN_TAG:-42}
    
    read -p "Inserisci CIDR rete dedicata (default: 10.42.42.0/24): " NETWORK_CIDR
    NETWORK_CIDR=${NETWORK_CIDR:-10.42.42.0/24}
    validate_cidr "$NETWORK_CIDR"

    # Estrai gateway dalla CIDR
    NETWORK_GW=$(echo "$NETWORK_CIDR" | sed 's|0/[0-9]*$|1|')
    VLAN_IFACE="vmbr0.$VLAN_TAG"
    
    # Configurazione rete
    cat >> /etc/network/interfaces <<EOF

auto $VLAN_IFACE
iface $VLAN_IFACE inet static
    address  $NETWORK_GW
    netmask  ${NETWORK_CIDR#*/}
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF

    ifup "$VLAN_IFACE"
    echo "✅ Rete creata: $VLAN_IFACE ($NETWORK_CIDR)"
}

deploy_vm() {
    echo -e "\n\033[1;34m=== DEPLOY VM CLOUDFLARE ===\033[0m"
    read -p "Inserisci ID VM (default: 7000): " VM_ID
    VM_ID=${VM_ID:-7000}
    
    read -p "Inserisci nome VM (default: cf-tunnel): " VM_NAME
    VM_NAME=${VM_NAME:-cf-tunnel}
    
    # Genera password casuale per l'utente
    CLOUDFLARE_PASS=$(openssl rand -base64 12)
    CLOUDFLARE_USER="cfadmin"
    
    # Crea VM
    qm create "$VM_ID" \
        --name "$VM_NAME" \
        --memory 1024 \
        --cores 1 \
        --net0 virtio,bridge=vmbr0,tag="$VLAN_TAG" \
        --scsihw virtio-scsi-pci \
        --ostype l26 \
        --agent enabled=1 \
        --scsi0 local-lvm:0,import-from="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2" \
        --ide2 local-lvm:cloudinit \
        --ciuser "$CLOUDFLARE_USER" \
        --cipassword "$CLOUDFLARE_PASS" \
        --ipconfig0 "ip=$NETWORK_CIDR,gw=$NETWORK_GW"
    
    echo "✅ VM creata (ID: $VM_ID)"
}

configure_zero_trust() {
    echo -e "\n\033[1;34m=== CONFIGURAZIONE ZERO TRUST ===\033[0m"
    read -s -p "Incolla il token del tunnel Cloudflare: " CLOUDFLARE_TOKEN
    echo ""
    
    # Crea script di configurazione
    cat > /tmp/cloudflared-init.sh <<EOF
#!/bin/bash
# Cloudflare Zero Trust Setup

# Installazione cloudflared
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Configurazione Zero Trust
mkdir -p /etc/cloudflared/
echo "$CLOUDFLARE_TOKEN" | cloudflared tunnel login

# Crea tunnel
TUNNEL_NAME="proxmox-tunnel-\$(hostname)"
cloudflared tunnel create "\$TUNNEL_NAME"

# Configurazione automatica
TUNNEL_CRED_FILE=\$(cloudflared tunnel list -o json | jq -r ".[] | select(.name == \"\$TUNNEL_NAME\") | .credentials_file")
cat > /etc/cloudflared/config.yml <<CFG
tunnel: \$TUNNEL_NAME
credentials-file: \$TUNNEL_CRED_FILE
logfile: /var/log/cloudflared.log
loglevel: info
ingress: []
CFG

# Configurazione servizio
cat > /etc/systemd/system/cloudflared.service <<SVC
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable cloudflared
EOF

    # Inietta script nella VM
    qm set "$VM_ID" --cicustom "user=local:snippets/cloudflared-init.sh"
    echo "✅ Configurazione Zero Trust completata"
}

domain_management() {
    echo -e "\n\033[1;34m=== GESTIONE DOMINI ===\033[0m"
    cat > /tmp/domain-manager.sh <<'EOF'
#!/bin/bash
CONFIG_FILE="/etc/cloudflared/config.yml"

manage_domains() {
    while true; do
        clear
        echo "Cloudflare Tunnel Domain Manager"
        echo "-------------------------------"
        echo "1) Aggiungi dominio"
        echo "2) Rimuovi dominio"
        echo "3) Lista domini"
        echo "4) Esci"
        
        read -p "Scelta: " choice
        
        case $choice in
            1)
                read -p "Hostname (es. servizio.azienda.com): " hostname
                read -p "IP interno: " ip
                read -p "Porta: " port
                
                # Aggiungi prima della regola catch-all
                sed -i "/http_status:404/i \ \ - hostname: $hostname\n    service: http://$ip:$port" "$CONFIG_FILE"
                systemctl restart cloudflared
                echo "✅ Dominio aggiunto!"
                sleep 2
                ;;
            2)
                read -p "Hostname da rimuovere: " hostname
                sed -i "/hostname: $hostname$/,+1d" "$CONFIG_FILE"
                systemctl restart cloudflared
                echo "✅ Dominio rimosso!"
                sleep 2
                ;;
            3)
                echo -e "\nDomini configurati:"
                grep "hostname:" "$CONFIG_FILE" | awk '{print $2}'
                echo ""
                read -n 1 -s -r -p "Premi un tasto per continuare..."
                ;;
            4)
                exit 0
                ;;
            *)
                echo "Scelta non valida!"
                sleep 1
                ;;
        esac
    done
}

manage_domains
EOF

    qm set "$VM_ID" --cicustom "user=local:snippets/domain-manager.sh"
    echo "✅ Script di gestione domini installato"
}

start_services() {
    echo -e "\n\033[1;34m=== AVVIO SERVIZI ===\033[0m"
    qm start "$VM_ID"
    
    cat <<EOF

########################## DEPLOY COMPLETATO ##########################

VM ID:          $VM_ID
Rete dedicata:  $VLAN_IFACE ($NETWORK_CIDR)
Gateway:        $NETWORK_GW
Accesso VM:     qm terminal $VM_ID
Utente:         $CLOUDFLARE_USER
Password:       $CLOUDFLARE_PASS

Per gestire i domini:
1) Accedi alla VM: qm terminal $VM_ID
2) Esegui: /var/lib/cloud/scripts/per-boot/domain-manager.sh

#######################################################################
EOF
}

# ---------------------------
# ESECUZIONE PRINCIPALE
# ---------------------------
main() {
    # Verifica privilegi
    [ "$(id -u)" -eq 0 ] || {
        echo "Esegui come root!"
        exit 1
    }

    deploy_network
    deploy_vm
    configure_zero_trust
    domain_management
    start_services
}

main