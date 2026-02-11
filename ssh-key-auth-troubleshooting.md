# SSH Key Authentication Troubleshooting Guide

> **Agent-Friendly Format**: Each issue follows `SYMPTOM → DIAGNOSE → FIX → VERIFY` pattern.
> Copy-paste the diagnostic commands directly. All commands are non-destructive.
>
> Written: 2026-02-11 | OS: Fedora 43 (Server) / macOS (Client) | Tailscale: Active

---

## Quick Diagnosis Flowchart

```
SSH key auth fails → password prompt appears
  │
  ├─ 1. ssh -vvv → which key is offered?
  │     ├─ Wrong key offered → Fix: ~/.ssh/config IdentityFile (Section 2)
  │     ├─ No key offered   → Fix: ssh-add or check key exists (Section 3)
  │     └─ Correct key offered but rejected ↓
  │
  ├─ 2. Server-side checks
  │     ├─ Permissions wrong → Fix: chmod 700/600 (Section 4)
  │     ├─ SELinux blocking  → Fix: restorecon (Section 5)
  │     ├─ sshd config       → Fix: PubkeyAuthentication yes (Section 6)
  │     └─ Key not in authorized_keys → Fix: add correct pubkey (Section 7)
  │
  └─ 3. Still failing → Check logs: journalctl -u sshd -n 50
```

---

## 1. First Step (Always): Verbose SSH

**Symptom**: SSH prompts for password instead of using key auth.

**Diagnose**:
```bash
# Connect with max verbosity — shows exactly which keys are tried
ssh -vvv USER@HOST 2>&1 | grep -E "Offering|Trying|identity|userauth|Authentication"
```

**What to look for**:
```
debug1: Offering public key: /home/user/.ssh/KEYNAME TYPE SHA256:...
# ↑ This shows which key the client is actually sending
# If this doesn't match what's in authorized_keys → key mismatch (Section 2)
# If no "Offering" lines → no keys found (Section 3)
```

---

## 2. Wrong Key Offered (Most Common Cause)

**Symptom**: `ssh -vvv` shows a different key being offered than what's in `authorized_keys`.

**Diagnose**:
```bash
# On CLIENT: see which keys exist
ls -la ~/.ssh/*.pub

# On CLIENT: see which keys SSH agent has loaded
ssh-add -l

# On SERVER: see which keys are authorized
cat ~/.ssh/authorized_keys
```

**Fix** (Option A — configure client, recommended):
```bash
# On CLIENT: add to ~/.ssh/config
cat >> ~/.ssh/config << 'EOF'

Host SERVER_IP_OR_HOSTNAME
  IdentityFile ~/.ssh/id_ed25519
  User YOUR_USER
EOF
chmod 600 ~/.ssh/config
```

**Fix** (Option B — add the actually-used key to server):
```bash
# On CLIENT: get the public key SSH is actually offering
cat ~/.ssh/OFFERED_KEY.pub
# Then add that to SERVER's ~/.ssh/authorized_keys
```

**Verify**:
```bash
ssh USER@HOST
# Expected: connects without password prompt

# Double-check with verbose
ssh -v USER@HOST 2>&1 | grep "Authentication succeeded"
```

---

## 3. No Key Offered at All

**Symptom**: `ssh -vvv` shows no "Offering public key" lines.

**Diagnose**:
```bash
# Check if private key exists
ls -la ~/.ssh/id_* ~/.ssh/*_ed25519 2>&1

# Check key permissions (must be 600)
stat -c '%a %n' ~/.ssh/id_* ~/.ssh/*_ed25519 2>/dev/null

# Check SSH agent
ssh-add -l
```

**Fix**:
```bash
# If key exists but wrong permissions
chmod 600 ~/.ssh/id_ed25519

# If key not in agent
ssh-add ~/.ssh/id_ed25519

# If no key exists at all
ssh-keygen -t ed25519 -C "your_email@example.com"
# Then copy to server:
ssh-copy-id -i ~/.ssh/id_ed25519.pub USER@HOST
```

**Verify**:
```bash
ssh-add -l
# Expected: shows your key

ssh -v USER@HOST 2>&1 | grep "Offering"
# Expected: shows your key being offered
```

---

## 4. Server Permissions Wrong

**Symptom**: Correct key is offered but server rejects it. `ssh -vvv` shows key offered then falls back to password.

**Diagnose** (on server):
```bash
# Check all relevant permissions in one command
stat -c '%a %U:%G %n' ~ ~/.ssh ~/.ssh/authorized_keys 2>&1

# Expected:
# 755 or 710  user:user  /home/user
# 700         user:user  /home/user/.ssh
# 600         user:user  /home/user/.ssh/authorized_keys
```

**Fix**:
```bash
chmod 710 ~                      # or 755
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown -R $(whoami):$(whoami) ~/.ssh
```

**Verify**:
```bash
stat -c '%a %U:%G %n' ~ ~/.ssh ~/.ssh/authorized_keys
# Then test from client:
ssh USER@HOST
```

---

## 5. SELinux Blocking (Fedora/RHEL/CentOS)

**Symptom**: Permissions are correct, correct key is offered, but still rejected. Only happens on SELinux-enforcing systems.

**Diagnose**:
```bash
# Check SELinux mode
getenforce
# If "Enforcing" → could be blocking

# Check for SSH-related denials
ausearch -m avc -ts recent 2>/dev/null | grep ssh
# or
journalctl -t setroubleshoot --since "1 hour ago" 2>/dev/null | grep ssh
```

**Fix**:
```bash
# Restore correct SELinux labels
restorecon -Rv ~/.ssh/

# Verify labels
ls -laZ ~/.ssh/
# Expected: unconfined_u:object_r:ssh_home_t:s0
```

**Verify**:
```bash
ls -laZ ~/.ssh/authorized_keys
# Expected: ...ssh_home_t...
# Then test from client
```

---

## 6. sshd Configuration Disables Key Auth

**Symptom**: Everything looks correct client-side and permission-wise, but server always asks for password.

**Diagnose**:
```bash
# Check effective sshd config
sshd -T 2>/dev/null | grep -iE "pubkey|authorized|authentication" || \
  grep -iE "^PubkeyAuthentication|^AuthorizedKeysFile" /etc/ssh/sshd_config
```

**Fix**:
```bash
# Ensure these are in /etc/ssh/sshd_config:
#   PubkeyAuthentication yes
#   AuthorizedKeysFile .ssh/authorized_keys

sudo systemctl restart sshd
```

**Verify**:
```bash
sshd -T 2>/dev/null | grep pubkeyauthentication
# Expected: pubkeyauthentication yes
```

---

## 7. Key Not in authorized_keys (or Malformed)

**Symptom**: Key is correct, permissions are fine, but the public key simply isn't in the file (or has extra whitespace/newlines).

**Diagnose**:
```bash
# On CLIENT: get fingerprint of your key
ssh-keygen -lf ~/.ssh/id_ed25519.pub

# On SERVER: list fingerprints in authorized_keys
while IFS= read -r key; do echo "$key" | ssh-keygen -lf - 2>/dev/null; done < ~/.ssh/authorized_keys

# Compare: do they match?
```

**Fix**:
```bash
# Easiest: use ssh-copy-id from client
ssh-copy-id -i ~/.ssh/id_ed25519.pub USER@HOST

# Or manually on server — ensure single line, no extra whitespace
echo "ssh-ed25519 AAAA... comment" >> ~/.ssh/authorized_keys
```

**Verify**:
```bash
# Fingerprints should match
ssh-keygen -lf ~/.ssh/id_ed25519.pub        # client
ssh-keygen -lf ~/.ssh/authorized_keys        # server (shows all)
```

---

## Quick Reference Table

| Cause | Diagnose Command | Fix |
|-------|-----------------|-----|
| Wrong key offered | `ssh -vvv HOST 2>&1 \| grep Offering` | `IdentityFile` in `~/.ssh/config` |
| No key offered | `ssh-add -l` | `ssh-add ~/.ssh/id_ed25519` |
| Bad permissions | `stat -c '%a' ~/.ssh ~/.ssh/authorized_keys` | `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys` |
| SELinux | `ausearch -m avc -ts recent \| grep ssh` | `restorecon -Rv ~/.ssh/` |
| sshd config | `sshd -T \| grep pubkey` | Ensure `PubkeyAuthentication yes`, restart sshd |
| Key not in file | Compare `ssh-keygen -lf` fingerprints | `ssh-copy-id -i KEY.pub USER@HOST` |
| Home dir writable | `stat -c '%a' ~` | `chmod 755 ~` or `chmod 710 ~` |
| Key in agent but wrong | `ssh-add -l` | `ssh-add -D` then `ssh-add ~/.ssh/CORRECT_KEY` |

---

## Real-World Case Study

**Setup**: Fedora 43 server, macOS client, Tailscale network.

**Problem**: Added `id_ed25519.pub` to server's `authorized_keys`, but SSH kept asking for password.

**Diagnosis** (`ssh -vvv`): Client was offering `infra_ed25519` instead of `id_ed25519` — multiple keys on client, wrong one being used.

**Fix**: Added `IdentityFile ~/.ssh/id_ed25519` to `~/.ssh/config` for the host.

**Lesson**: With multiple SSH keys, always use `~/.ssh/config` to specify which key goes to which host.

---

*Part of [The Vibe Companion](https://github.com/CyPack/companion-guide) project.*
