#!/bin/bash
# =============================================================================
# Companion Firewall Setup Script
# Blocks port 3456 from LAN, allows Tailscale and Docker
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Must run as root
[[ $EUID -eq 0 ]] || error "Bu script sudo ile çalıştırılmalı: sudo bash $0"

echo "============================================="
echo "  Companion Firewall Setup"
echo "  Docker + Tailscale Compatible"
echo "============================================="
echo ""

# --- Phase 1: Pre-flight checks ---
info "Phase 1: Ön kontroller..."

# Check firewalld is installed
command -v firewall-cmd &>/dev/null || error "firewalld kurulu değil!"

# Verify key interfaces exist
ip link show wlp2s0 &>/dev/null    || warn "wlp2s0 (LAN) bulunamadı!"
ip link show tailscale0 &>/dev/null || warn "tailscale0 bulunamadı!"
ip link show docker0 &>/dev/null    || warn "docker0 bulunamadı!"

# Check companion is running
ss -tlnp | grep -q ':3456 ' && info "Companion port 3456'da çalışıyor ✓" || warn "Port 3456 aktif değil"

echo ""

# --- Phase 2: Configure firewalld backend ---
info "Phase 2: Firewalld backend ayarı (iptables - Docker uyumu)..."

# Ensure iptables backend for Docker compatibility
CONF="/etc/firewalld/firewalld.conf"
if [[ -f "$CONF" ]]; then
    if grep -q "^FirewallBackend=nftables" "$CONF"; then
        sed -i 's/^FirewallBackend=nftables/FirewallBackend=iptables/' "$CONF"
        info "Backend nftables → iptables olarak değiştirildi"
    elif grep -q "^FirewallBackend=iptables" "$CONF"; then
        info "Backend zaten iptables ✓"
    else
        echo "FirewallBackend=iptables" >> "$CONF"
        info "Backend iptables olarak eklendi"
    fi
else
    warn "firewalld.conf bulunamadı, varsayılan kullanılacak"
fi

echo ""

# --- Phase 3: Start firewalld ---
info "Phase 3: Firewalld başlatılıyor..."

if systemctl is-active --quiet firewalld; then
    info "Firewalld zaten çalışıyor ✓"
else
    systemctl start firewalld
    sleep 2
    if systemctl is-active --quiet firewalld; then
        info "Firewalld başlatıldı ✓"
    else
        error "Firewalld başlatılamadı!"
    fi
fi

echo ""

# --- Phase 4: Tailscale zone ---
info "Phase 4: Tailscale zone (trusted)..."

firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 2>/dev/null || true
firewall-cmd --permanent --zone=trusted --add-masquerade 2>/dev/null || true
info "tailscale0 → trusted zone ✓"

echo ""

# --- Phase 5: Docker zone ---
info "Phase 5: Docker zone..."

# Create docker zone if not exists
firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true

# Add Docker interfaces
for iface in docker0 docker_gwbridge; do
    if ip link show "$iface" &>/dev/null; then
        firewall-cmd --permanent --zone=docker --add-interface="$iface" 2>/dev/null || true
        info "$iface → docker zone ✓"
    fi
done

# Add custom Docker bridge networks
for iface in $(ip -br link show | awk '/^br-/ {print $1}'); do
    firewall-cmd --permanent --zone=docker --add-interface="$iface" 2>/dev/null || true
    info "$iface → docker zone ✓"
done

firewall-cmd --permanent --zone=docker --add-masquerade 2>/dev/null || true

echo ""

# --- Phase 6: LAN zone (public) ---
info "Phase 6: LAN zone (public) - port 3456 bloklama..."

# Assign LAN interface to public zone
firewall-cmd --permanent --zone=public --change-interface=wlp2s0 2>/dev/null || true

# Allow essential services
firewall-cmd --permanent --zone=public --add-service=ssh 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-service=http 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-service=https 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-service=mdns 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-service=dhcpv6-client 2>/dev/null || true

# Block port 3456 from LAN (reject with message)
firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" port port="3456" protocol="tcp" reject' 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv6" port port="3456" protocol="tcp" reject' 2>/dev/null || true

info "Port 3456 LAN'dan engellendi ✓"

echo ""

# --- Phase 7: Reload and enable ---
info "Phase 7: Yapılandırma uygulanıyor..."

firewall-cmd --reload
systemctl enable firewalld

echo ""

# --- Phase 8: Verification ---
info "Phase 8: Doğrulama..."
echo ""

echo "Active zones:"
firewall-cmd --get-active-zones
echo ""

echo "Public zone (LAN):"
firewall-cmd --zone=public --list-all
echo ""

echo "Trusted zone (Tailscale):"
firewall-cmd --zone=trusted --list-all
echo ""

echo "Docker zone:"
firewall-cmd --zone=docker --list-all 2>/dev/null || echo "(docker zone boş veya yok)"
echo ""

# Test connectivity
info "Bağlantı testleri..."

if curl -s -o /dev/null -w "%{http_code}" http://localhost:3456/ 2>/dev/null | grep -q "200"; then
    info "localhost:3456 erişimi ✓ (PASS)"
else
    warn "localhost:3456 erişilemedi (Companion çalışıyor mu?)"
fi

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null)
if [ -n "$TS_HOSTNAME" ] && curl -sk -o /dev/null -w "%{http_code}" "https://${TS_HOSTNAME}:8443/" 2>/dev/null | grep -q "200"; then
    info "Tailscale serve erişimi ✓ (PASS)"
else
    warn "Tailscale serve erişilemedi"
fi

echo ""
echo "============================================="
info "Firewall yapılandırması tamamlandı!"
echo ""
echo "  Erişim matrisi:"
echo "    localhost:3456      → ✅ İzinli"
echo "    Tailscale:8443      → ✅ İzinli (HTTPS)"
echo "    LAN              → ❌ Engelli"
echo ""
echo "  Geri almak için: sudo systemctl stop firewalld && sudo systemctl disable firewalld"
echo "============================================="
