#!/usr/bin/env python3
"""
Patch upstream CAPEv2/installer/cape2.sh for CN + openKylin 2.0 deployment.
Reads /opt/cape-deploy/CAPEv2/installer/cape2.sh, writes cape2.sh.patched.
"""
import re, sys, pathlib, hashlib

SRC = pathlib.Path("/opt/cape-deploy/CAPEv2/installer/cape2.sh")
DST = pathlib.Path("/opt/cape-deploy/CAPEv2/installer/cape2.sh.patched")
MONGO_KEY = "/opt/cape-deploy/vendor/mongodb-server-8.0.asc"

text = SRC.read_text()
orig_sha = hashlib.sha256(text.encode()).hexdigest()[:12]
print(f"[+] upstream sha256: {orig_sha}  size: {len(text)} bytes")

patches = []

# P1: openKylin codename "nile" → force "jammy"
# Multiple call sites: $(lsb_release -cs), $(lsb_release -sc), and `[ "$(lsb_release -cs)" = "noble" ]`
before = text
text = text.replace('"$(lsb_release -cs)"', '"jammy"')
text = text.replace('$(lsb_release -cs)', 'jammy')
text = text.replace('$(lsb_release -sc)', 'jammy')
text = text.replace('$(lsb_release -sr)', '22.04')
text = text.replace('$(lsb_release -rs)', '22.04')
assert text != before, "P1 missed: lsb_release"
patches.append("P1 lsb_release → jammy/22.04")

# P2: Tor block — wrap entire Tor install/config in if false; then ... fi
tor_start = text.find("    # https://www.torproject.org/docs/debian.html.en")
tor_end_marker = "    sudo systemctl start tor\n"
tor_end = text.find(tor_end_marker, tor_start)
assert tor_start > 0 and tor_end > 0, f"P2 markers not found: start={tor_start} end={tor_end}"
tor_end_full = tor_end + len(tor_end_marker)
before_tor = text[:tor_start]
tor_block = text[tor_start:tor_end_full]
after_tor = text[tor_end_full:]
wrapped = "    # === CN PATCH: Tor block disabled (deb.torproject.org unreachable from CN) ===\n    if false; then\n" + tor_block + "    fi  # === CN PATCH: end Tor disable ===\n"
text = before_tor + wrapped + after_tor
patches.append(f"P2 Tor block wrapped ({len(tor_block)} bytes)")

# P3: MongoDB GPG — replace pgp.mongodb.com curl with local file
before = text
text = text.replace(
    'sudo curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" | sudo gpg --dearmor -o /etc/apt/keyrings/mongo.gpg --yes',
    f'sudo install -d -m 0755 /etc/apt/keyrings && sudo cat {MONGO_KEY} | sudo gpg --dearmor -o /etc/apt/keyrings/mongo.gpg --yes  # CN PATCH: local key'
)
assert text != before, "P3 missed: pgp.mongodb.com"
patches.append("P3 MongoDB GPG → local file")

# P4: MongoDB repo URL → TUNA mirror
before = text
text = text.replace(
    'https://repo.mongodb.org/apt/ubuntu',
    'https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/ubuntu'
)
assert text != before, "P4 missed: mongo apt URL"
patches.append("P4 mongo repo → TUNA")

# P5: Postgres repo URL → TUNA mirror
before = text
text = text.replace(
    'http://apt.postgresql.org/pub/repos/apt/',
    'https://mirrors.tuna.tsinghua.edu.cn/postgresql/repos/apt/'
)
assert text != before, "P5 missed: postgres apt URL"
patches.append("P5 postgres repo → TUNA")

# P6: raw.githubusercontent.com → gh-proxy
before = text
text = re.sub(
    r'(?<!gh-proxy\.com/)https://raw\.githubusercontent\.com/',
    'https://gh-proxy.com/https://raw.githubusercontent.com/',
    text
)
assert text != before, "P6 missed: raw.githubusercontent.com"
patches.append("P6 raw.githubusercontent.com → gh-proxy")

# P7: install_CAPE's git clone — go via gh-proxy
before = text
text = text.replace(
    'git clone https://github.com/kevoreilly/CAPEv2/ "$CAPE_ROOT"',
    'git clone https://gh-proxy.com/https://github.com/kevoreilly/CAPEv2/ "$CAPE_ROOT"  # CN PATCH'
)
assert text != before, "P7 missed: CAPEv2 git clone"
patches.append("P7 CAPEv2 git clone → gh-proxy")

# P8: comment out buggy pip install -r pyproject.toml in install_CAPE
before = text
text = text.replace(
    'sudo -u ${USER} bash -c "export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring; CRYPTOGRAPHY_DONT_BUILD_RUST=1 $PYTHON_MGR pip install -r pyproject.toml"',
    '# CN PATCH: disabled — pip cannot read pyproject.toml as requirements; venv built separately after install\n    # sudo -u ${USER} bash -c "export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring; CRYPTOGRAPHY_DONT_BUILD_RUST=1 $PYTHON_MGR pip install -r pyproject.toml"'
)
assert text != before, "P8 missed: buggy pip install -r pyproject.toml"
patches.append("P8 buggy pip install -r pyproject.toml commented")

# P9: community.py 60s timeout fix (raw.githubusercontent.com hang)
before = text
# Already covered by P6 (raw.githubusercontent → gh-proxy); add explicit retry timeout note
# Skip — P6 handles it

# P10: install_CAPE community.py: same problem — leave (P6 covers community.py URLs since they use raw.gh)

new_sha = hashlib.sha256(text.encode()).hexdigest()[:12]
DST.write_text(text)
print(f"[+] patched   sha256: {new_sha}  size: {len(text)} bytes")
print("[+] patches applied:")
for p in patches:
    print(f"    - {p}")
print(f"[+] written → {DST}")
