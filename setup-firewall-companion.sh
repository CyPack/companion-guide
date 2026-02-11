#!/bin/bash
# =============================================================================
# Companion Firewall Setup Script
# Blocks port 3456 from LAN, allows Tailscale and Docker
#
# Agent-Friendly: Each phase has DOING/EXPECT/VERIFY pattern.
# Dry-run mode: pass --dry-run to preview without changes.
#
# Usage:
#   sudo bash setup-firewall-companion.sh            # apply changes
#   sudo bash setup-firewall-companion.sh --dry-run   # preview only
#   sudo bash setup-firewall-companion.sh --check      # verify current state
# =============================================================================
set -euo pipefail

# --- Config (edit if your interfaces differ) ---
LAN_IFACE="${LAN_IFACE:-wlp2s0}"
COMPANION_PORT="${COMPANION_PORT:-3456}"
TAILSCALE_HTTPS_PORT="${TAILSCALE_HTTPS_PORT:-8443}"

# --- Parse flags ---
DRY_RUN=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --check)     CHECK_ONLY=true ;;
        --help|-h)
            echo "Usage: sudo bash $0 [--dry-run|--check|--help]"
            echo ""
            echo "  --dry-run   Preview changes without applying"
            echo "  --check     Only verify current firewall state"
            echo "  --help      Show this help"
            exit 0
            ;;
    esac
done

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
dry()   { echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"; }

# Run or preview a command
run() {
    if $DRY_RUN; then
        dry "$*"
    else
        "$@"
    fi
}

# Must run as root
[[ $EUID -eq 0 ]] || error "Bu script sudo ile calistirilmali: sudo bash $0"

echo "============================================="
echo "  Companion Firewall Setup"
echo "  Docker + Tailscale Compatible"
if $DRY_RUN; then
    echo "  MODE: DRY-RUN (no changes)"
elif $CHECK_ONLY; then
    echo "  MODE: CHECK ONLY"
fi
echo "============================================="
echo ""

# =============================================================================
# CHECK-ONLY MODE: just verify and exit
# =============================================================================
if $CHECK_ONLY; then
    info "Firewall durum kontrolu..."
    echo ""

    # Service status
    if systemctl is-active --quiet firewalld; then
        info "firewalld: active"
    else
        warn "firewalld: inactive"
    fi

    # Backend
    BACKEND=$(grep "^FirewallBackend=" /etc/firewalld/firewalld.conf 2>/dev/null | cut -d= -f2)
    if [[ "$BACKEND" == "iptables" ]]; then
        info "Backend: iptables (Docker uyumlu)"
    else
        warn "Backend: ${BACKEND:-unknown} (Docker icin iptables onerilir)"
    fi
    echo ""

    # Active zones
    echo "Active zones:"
    firewall-cmd --get-active-zones 2>/dev/null || echo "(firewalld calismiyior)"
    echo ""

    # Port 3456 block check
    if firewall-cmd --zone=public --list-rich-rules 2>/dev/null | grep -q "$COMPANION_PORT"; then
        info "Port $COMPANION_PORT: LAN'dan engelli"
    else
        warn "Port $COMPANION_PORT: LAN'dan engelli DEGIL"
    fi

    # Tailscale zone
    if firewall-cmd --zone=trusted --list-interfaces 2>/dev/null | grep -q "tailscale0"; then
        info "tailscale0: trusted zone'da"
    else
        warn "tailscale0: trusted zone'da DEGIL"
    fi

    # Docker zone
    if firewall-cmd --zone=docker --list-interfaces 2>/dev/null | grep -q "docker0"; then
        info "docker0: docker zone'da"
    else
        warn "docker0: docker zone'da DEGIL"
    fi
    echo ""

    # Connectivity tests
    info "Baglanti testleri..."
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${COMPANION_PORT}/" 2>/dev/null | grep -q "200"; then
        info "localhost:${COMPANION_PORT} -> PASS"
    else
        warn "localhost:${COMPANION_PORT} -> FAIL (Companion calisiyor mu?)"
    fi

    TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
    if [[ -n "$TS_HOSTNAME" ]] && curl -sk -o /dev/null -w "%{http_code}" "https://${TS_HOSTNAME}:${TAILSCALE_HTTPS_PORT}/" 2>/dev/null | grep -q "200"; then
        info "Tailscale:${TAILSCALE_HTTPS_PORT} -> PASS"
    else
        warn "Tailscale:${TAILSCALE_HTTPS_PORT} -> FAIL"
    fi

    echo ""
    echo "============================================="
    info "Kontrol tamamlandi."
    echo "============================================="
    exit 0
fi

# =============================================================================
# Phase 1: Pre-flight checks
# =============================================================================
step "Phase 1/8: On kontroller..."

# Check firewalld is installed
command -v firewall-cmd &>/dev/null || error "firewalld kurulu degil! Kur: sudo dnf install firewalld"

# Verify key interfaces
MISSING_IFACES=0
for iface in "$LAN_IFACE" tailscale0 docker0; do
    if ip link show "$iface" &>/dev/null; then
        info "$iface mevcut"
    else
        warn "$iface bulunamadi"
        ((MISSING_IFACES++))
    fi
done

# Check companion is running
if ss -tlnp | grep -q ":${COMPANION_PORT} "; then
    info "Companion port ${COMPANION_PORT}'da calisiyor"
else
    warn "Port ${COMPANION_PORT} aktif degil (Companion calismiyior olabilir)"
fi

echo ""

# =============================================================================
# Phase 2: Configure firewalld backend (iptables for Docker)
# =============================================================================
step "Phase 2/8: Firewalld backend ayari (iptables - Docker uyumu)..."

CONF="/etc/firewalld/firewalld.conf"
if [[ -f "$CONF" ]]; then
    CURRENT_BACKEND=$(grep "^FirewallBackend=" "$CONF" | cut -d= -f2)
    if [[ "$CURRENT_BACKEND" == "iptables" ]]; then
        info "Backend zaten iptables"
    elif [[ "$CURRENT_BACKEND" == "nftables" ]]; then
        if $DRY_RUN; then
            dry "sed -i 's/^FirewallBackend=nftables/FirewallBackend=iptables/' $CONF"
        else
            sed -i 's/^FirewallBackend=nftables/FirewallBackend=iptables/' "$CONF"
            info "Backend nftables -> iptables olarak degistirildi"
        fi
    else
        if $DRY_RUN; then
            dry "echo 'FirewallBackend=iptables' >> $CONF"
        else
            echo "FirewallBackend=iptables" >> "$CONF"
            info "Backend iptables olarak eklendi"
        fi
    fi
else
    warn "firewalld.conf bulunamadi, varsayilan kullanilacak"
fi

echo ""

# =============================================================================
# Phase 3: Start firewalld
# =============================================================================
step "Phase 3/8: Firewalld baslatiliyor..."

if systemctl is-active --quiet firewalld; then
    info "Firewalld zaten calisiyor"
else
    run systemctl start firewalld
    if ! $DRY_RUN; then
        sleep 2
        systemctl is-active --quiet firewalld || error "Firewalld baslatilamadi!"
        info "Firewalld baslatildi"
    fi
fi

echo ""

# =============================================================================
# Phase 4: Tailscale zone (trusted)
# =============================================================================
step "Phase 4/8: Tailscale zone (trusted)..."

run firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 2>/dev/null || true
run firewall-cmd --permanent --zone=trusted --add-masquerade 2>/dev/null || true
info "tailscale0 -> trusted zone"

echo ""

# =============================================================================
# Phase 5: Docker zone
# =============================================================================
step "Phase 5/8: Docker zone..."

# Create docker zone if not exists
run firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
run firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true

# Add Docker interfaces
for iface in docker0 docker_gwbridge; do
    if ip link show "$iface" &>/dev/null; then
        run firewall-cmd --permanent --zone=docker --add-interface="$iface" 2>/dev/null || true
        info "$iface -> docker zone"
    fi
done

# Add custom Docker bridge networks (br-xxxx)
for iface in $(ip -br link show 2>/dev/null | awk '/^br-/ {print $1}'); do
    run firewall-cmd --permanent --zone=docker --add-interface="$iface" 2>/dev/null || true
    info "$iface -> docker zone"
done

run firewall-cmd --permanent --zone=docker --add-masquerade 2>/dev/null || true

echo ""

# =============================================================================
# Phase 6: LAN zone (public) - block Companion port
# =============================================================================
step "Phase 6/8: LAN zone (public) - port ${COMPANION_PORT} bloklama..."

# Assign LAN interface to public zone
run firewall-cmd --permanent --zone=public --change-interface="$LAN_IFACE" 2>/dev/null || true

# Allow essential services
for svc in ssh http https mdns dhcpv6-client; do
    run firewall-cmd --permanent --zone=public --add-service="$svc" 2>/dev/null || true
done

# Block Companion port from LAN (reject with message)
run firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv4\" port port=\"${COMPANION_PORT}\" protocol=\"tcp\" reject" 2>/dev/null || true
run firewall-cmd --permanent --zone=public --add-rich-rule="rule family=\"ipv6\" port port=\"${COMPANION_PORT}\" protocol=\"tcp\" reject" 2>/dev/null || true

info "Port ${COMPANION_PORT} LAN'dan engellendi"

echo ""

# =============================================================================
# Phase 7: Reload and enable
# =============================================================================
step "Phase 7/8: Yapilandirma uygulaniyor..."

run firewall-cmd --reload
run systemctl enable firewalld

if $DRY_RUN; then
    dry "firewall-cmd --reload && systemctl enable firewalld"
fi

echo ""

# =============================================================================
# Phase 8: Verification
# =============================================================================
step "Phase 8/8: Dogrulama..."
echo ""

if $DRY_RUN; then
    info "Dry-run modu - dogrulama atlaniyor."
    echo ""
    echo "============================================="
    info "Dry-run tamamlandi. Uygulamak icin --dry-run olmadan calistirin."
    echo "============================================="
    exit 0
fi

echo "--- Active Zones ---"
firewall-cmd --get-active-zones
echo ""

echo "--- Public Zone (LAN: ${LAN_IFACE}) ---"
firewall-cmd --zone=public --list-all
echo ""

echo "--- Trusted Zone (Tailscale) ---"
firewall-cmd --zone=trusted --list-all
echo ""

echo "--- Docker Zone ---"
firewall-cmd --zone=docker --list-all 2>/dev/null || echo "(docker zone bos veya yok)"
echo ""

# Connectivity tests
info "Baglanti testleri..."

PASS=0
FAIL=0

if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${COMPANION_PORT}/" 2>/dev/null | grep -q "200"; then
    info "localhost:${COMPANION_PORT} -> PASS"
    ((PASS++))
else
    warn "localhost:${COMPANION_PORT} -> FAIL (Companion calisiyor mu?)"
    ((FAIL++))
fi

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
if [[ -n "$TS_HOSTNAME" ]] && curl -sk -o /dev/null -w "%{http_code}" "https://${TS_HOSTNAME}:${TAILSCALE_HTTPS_PORT}/" 2>/dev/null | grep -q "200"; then
    info "Tailscale:${TAILSCALE_HTTPS_PORT} -> PASS"
    ((PASS++))
else
    warn "Tailscale:${TAILSCALE_HTTPS_PORT} -> FAIL"
    ((FAIL++))
fi

echo ""
echo "============================================="
info "Firewall yapilandirmasi tamamlandi! (${PASS} pass, ${FAIL} fail)"
echo ""
echo "  Erisim matrisi:"
echo "    localhost:${COMPANION_PORT}       -> IZINLI"
echo "    Tailscale:${TAILSCALE_HTTPS_PORT}        -> IZINLI (HTTPS)"
echo "    Docker containers    -> IZINLI"
echo "    LAN:${COMPANION_PORT}             -> ENGELLI"
echo ""
echo "  Kontrol:  sudo bash $0 --check"
echo "  Geri al:  sudo systemctl stop firewalld && sudo systemctl disable firewalld"
echo "============================================="
