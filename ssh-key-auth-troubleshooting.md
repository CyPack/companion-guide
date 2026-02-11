# SSH Key Authentication Troubleshooting Guide

> **Scenario:** SSH key-based auth fails silently, falls back to password prompt.
>
> Written: 2026-02-11 | OS: Fedora 43 (Server) / macOS (Client) | Tailscale: Active

---

## Problem

After adding an SSH public key to the server's `~/.ssh/authorized_keys`, the connection still prompts for a password instead of using key-based authentication.

```
$ ssh ayaz@100.75.115.68
ayaz@100.75.115.68's password: _
```

---

## Environment

| Component | Detail |
|-----------|--------|
| Server | Fedora 43, SELinux Enforcing |
| Client | macOS with multiple SSH keys |
| Network | Tailscale (100.x.x.x) |
| SSH keys on client | `id_ed25519`, `infra_ed25519` |

---

## Troubleshooting Steps

### Step 1: Verify Server-Side Setup

**Action:** Check permissions on `.ssh` directory and `authorized_keys` file.

```bash
stat -c '%a %U:%G' ~/.ssh ~/.ssh/authorized_keys ~
```

**Result:**
```
710 ayaz:ayaz    # ~ (home dir)
700 ayaz:ayaz    # ~/.ssh
600 ayaz:ayaz    # ~/.ssh/authorized_keys
```

**Verdict:** Permissions are correct. Not the issue.

> **Expected permissions:**
> - Home directory: `755` or `710` (must NOT be group/world writable)
> - `~/.ssh/`: `700`
> - `authorized_keys`: `600`

---

### Step 2: Check SELinux Context

**Action:** Since the server runs SELinux in Enforcing mode, verify the security context.

```bash
getenforce          # → Enforcing
restorecon -Rv ~/.ssh/
```

**Result:** No relabeling needed -- contexts were already correct.

**Verdict:** SELinux is not blocking. Not the issue.

---

### Step 3: Verbose SSH Connection (The Breakthrough)

**Action:** Connect with maximum verbosity to see which keys are being offered.

```bash
ssh -vvv ayaz@100.75.115.68 2>&1 | grep -E "Offering|Trying|identity|userauth"
```

**Result:**
```
debug1: identity file /home/ayaz/.ssh/infra_ed25519 type 3
debug1: Offering public key: /home/ayaz/.ssh/infra_ed25519 ED25519 SHA256:JjSpbc...
ayaz@100.75.115.68's password:
```

**Verdict:** SSH client is offering `infra_ed25519`, NOT `id_ed25519`. We added `id_ed25519.pub` to `authorized_keys` but the client never sends that key.

---

### Step 4: Root Cause Analysis

The client machine had **multiple SSH keys**:

| Key File | Status |
|----------|--------|
| `~/.ssh/infra_ed25519` | Offered by SSH client (configured or default) |
| `~/.ssh/id_ed25519` | Exists but NOT offered |

SSH was configured (or defaulting) to use `infra_ed25519` for all connections. The `id_ed25519` key we added to the server was never presented during authentication.

**Root Cause:** Key mismatch -- the public key added to the server did not match the private key the client was offering.

---

### Step 5: The Fix

**Option A (Chosen): Configure SSH client to use the correct key for this host.**

Added to `~/.ssh/config` on the client (macOS):

```
Host 100.75.115.68
  IdentityFile ~/.ssh/id_ed25519
```

**Option B (Alternative): Add the actually-used key to the server.**

```bash
# On client: get the public key SSH is actually using
cat ~/.ssh/infra_ed25519.pub
# Then add that key to server's ~/.ssh/authorized_keys
```

---

### Step 6: Verification

```bash
ssh ayaz@100.75.115.68
# Connected without password prompt
```

---

## Key Takeaways

### 1. Always use `ssh -vvv` first
The verbose output immediately shows which keys the client is offering. This is the single most useful debugging step.

### 2. Multiple keys = specify which one
When a machine has multiple SSH keys, SSH may not offer the one you expect. Always use `~/.ssh/config` with `IdentityFile` to be explicit:

```
Host myserver
  HostName 100.75.115.68
  User ayaz
  IdentityFile ~/.ssh/id_ed25519
```

### 3. Server-side checklist
Before blaming the server, verify:
- [ ] Correct permissions (`700` for `.ssh`, `600` for `authorized_keys`)
- [ ] SELinux context (`restorecon -Rv ~/.ssh/`)
- [ ] `PubkeyAuthentication yes` in `sshd_config` (default: yes)
- [ ] Key is actually in `authorized_keys` (check for trailing whitespace/newlines)

### 4. Client-side checklist
- [ ] Private key exists and matches the public key on server
- [ ] Correct key is being offered (`ssh -vvv`)
- [ ] Key permissions: private key must be `600`
- [ ] SSH agent: check `ssh-add -l` for loaded keys

---

## Common SSH Auth Failure Causes (Quick Reference)

| Cause | How to Detect | Fix |
|-------|--------------|-----|
| Wrong permissions | `stat ~/.ssh` | `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys` |
| SELinux | `ausearch -m avc -ts recent` | `restorecon -Rv ~/.ssh/` |
| Wrong key offered | `ssh -vvv` output | `IdentityFile` in `~/.ssh/config` |
| Key not in agent | `ssh-add -l` | `ssh-add ~/.ssh/id_ed25519` |
| sshd config | `sshd -T \| grep pubkey` | Ensure `PubkeyAuthentication yes` |
| Home dir writable | `ls -ld ~` | `chmod 755 ~` or `chmod 710 ~` |

---

## Tools Used

- `ssh -vvv` -- verbose connection debugging
- `stat` -- permission checking
- `getenforce` / `restorecon` -- SELinux diagnostics
- `~/.ssh/config` -- per-host key configuration

---

*Part of [The Vibe Companion](https://github.com/CyPack/companion-guide) project.*
