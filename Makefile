# mosquitto-conf — repeatable TLS certificate issuance
#
#   make init                  one-time CA setup
#   make server                issue/reissue the broker certificate
#   make client CN=gw-01       issue a device certificate
#   make bundle CN=gw-01       stage the 3 files to copy to a gateway
#   make verify                offline sanity checks
#   make check-remote          live mTLS handshake against the broker
#   make revoke CN=gw-01       revoke a cert and regenerate the CRL
#   make expiry                warn on certs expiring within 30 days
#   make list                  show all issued certificates
#
# Design notes:
#   - `openssl ca` (not `x509 -req`) so ca/index.txt tracks issuance and CRLs
#     remain possible. This is the single most important choice in this file.
#   - SAN is defined once, here. It is the most error-prone value in the setup.
#   - ca.key is unencrypted for now (simplest start). See `make help-security`.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BROKER_IP   ?= 192.168.178.90
CA_CN       ?= Home LoRa CA
CA_DAYS     ?= 3650
LEAF_DAYS   ?= 365
KEY_BITS    ?= 2048

# The gateway dials a raw IP, so IP: must be present. localhost/127.0.0.1 let
# you test on the broker host itself without a second certificate.
SAN ?= IP:$(BROKER_IP),DNS:mqtt.lan,DNS:localhost,IP:127.0.0.1

CA_DIR    := ca
CERT_DIR  := certs
KEY_DIR   := private
CNF_DIR   := openssl
DIST_DIR  := dist

# OpenSSL expands every $ENV:: reference in a config file eagerly, not just the
# ones in the section being used. So all of these must always be set, even for
# commands that do not read them. Recipes override as needed.
export CA_DIR
export SAN
export CA_CN
LEAF_CN ?= unused
export LEAF_CN

CA_CRT := $(CA_DIR)/ca.crt
CA_KEY := $(CA_DIR)/ca.key
CRL    := $(CA_DIR)/ca.crl

OPENSSL ?= openssl

.DEFAULT_GOAL := help
.PHONY: help init server client bundle verify check-remote revoke crl expiry list clean-csr help-security deploy-help

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo "mosquitto-conf — TLS certificate issuance"
	@echo
	@echo "  make init                  create the CA (run once)"
	@echo "  make server                issue/reissue broker cert for $(BROKER_IP)"
	@echo "  make client CN=gw-01       issue a device cert"
	@echo "  make bundle CN=gw-01       stage 3 files for gateway upload"
	@echo "  make verify                offline checks (chain, SAN, EKU)"
	@echo "  make check-remote          live mTLS handshake test"
	@echo "  make revoke CN=gw-01       revoke + regenerate CRL"
	@echo "  make expiry                flag certs expiring within 30 days"
	@echo "  make list                  list issued certificates"
	@echo "  make deploy-help           commands to install on the broker"
	@echo "  make help-security         notes on ca.key handling"
	@echo
	@echo "Current SAN: $(SAN)"

# ---------------------------------------------------------------------------
# One-time CA setup
# ---------------------------------------------------------------------------

init: $(CA_CRT)

$(CA_CRT):
	@mkdir -p $(CA_DIR) $(CERT_DIR) $(KEY_DIR)
	@chmod 700 $(KEY_DIR)
	@touch $(CA_DIR)/index.txt
	@[ -f $(CA_DIR)/serial ]    || echo 1000 > $(CA_DIR)/serial
	@[ -f $(CA_DIR)/crlnumber ] || echo 1000 > $(CA_DIR)/crlnumber
	@echo "==> Generating CA private key ($(KEY_BITS)-bit RSA)"
	$(OPENSSL) genrsa -out $(CA_KEY) $(KEY_BITS)
	@chmod 600 $(CA_KEY)
	@echo "==> Self-signing CA certificate ($(CA_DAYS) days)"
	$(OPENSSL) req -x509 -new \
	  -config $(CNF_DIR)/ca.cnf \
	  -key $(CA_KEY) \
	  -days $(CA_DAYS) \
	  -out $(CA_CRT)
	@echo
	@echo "CA created: $(CA_CRT)"
	@echo "PROTECT $(CA_KEY) — it can mint broker AND gateway certs."
	@echo "Run 'make help-security' for options."

# ---------------------------------------------------------------------------
# Server certificate
# ---------------------------------------------------------------------------

server: init
	@echo "==> Issuing server certificate"
	@echo "    CN  = $(BROKER_IP)"
	@echo "    SAN = $(SAN)"
	@[ -f $(KEY_DIR)/server.key ] || { \
	  $(OPENSSL) genrsa -out $(KEY_DIR)/server.key $(KEY_BITS); \
	  chmod 600 $(KEY_DIR)/server.key; \
	}
	LEAF_CN="$(BROKER_IP)" $(OPENSSL) req -new \
	  -config $(CNF_DIR)/leaf.cnf \
	  -key $(KEY_DIR)/server.key \
	  -out $(CA_DIR)/server.csr
	$(OPENSSL) ca -batch \
	  -config $(CNF_DIR)/ca.cnf \
	  -extensions server_ext \
	  -days $(LEAF_DAYS) \
	  -notext \
	  -in $(CA_DIR)/server.csr \
	  -out $(CERT_DIR)/server.crt
	@rm -f $(CA_DIR)/server.csr
	@echo
	@$(OPENSSL) x509 -in $(CERT_DIR)/server.crt -noout -subject -enddate
	@$(OPENSSL) x509 -in $(CERT_DIR)/server.crt -noout -text \
	  | grep -A1 'Subject Alternative Name'
	@echo
	@echo "Deploy to broker, then: systemctl reload mosquitto"

# ---------------------------------------------------------------------------
# Client certificate — the command you run repeatedly
# ---------------------------------------------------------------------------

client: init
ifndef CN
	$(error CN is required. Usage: make client CN=gw-01)
endif
	@echo "==> Issuing client certificate for '$(CN)'"
	@echo "    This CN becomes the MQTT username via use_identity_as_username."
	@[ -f $(KEY_DIR)/client-$(CN).key ] || { \
	  $(OPENSSL) genrsa -out $(KEY_DIR)/client-$(CN).key $(KEY_BITS); \
	  chmod 600 $(KEY_DIR)/client-$(CN).key; \
	}
	LEAF_CN="$(CN)" $(OPENSSL) req -new \
	  -config $(CNF_DIR)/leaf.cnf \
	  -key $(KEY_DIR)/client-$(CN).key \
	  -out $(CA_DIR)/client-$(CN).csr
	$(OPENSSL) ca -batch \
	  -config $(CNF_DIR)/ca.cnf \
	  -extensions client_ext \
	  -days $(LEAF_DAYS) \
	  -notext \
	  -in $(CA_DIR)/client-$(CN).csr \
	  -out $(CERT_DIR)/client-$(CN).crt
	@rm -f $(CA_DIR)/client-$(CN).csr
	@echo
	@$(OPENSSL) x509 -in $(CERT_DIR)/client-$(CN).crt -noout -subject -enddate
	@echo
	@echo "Next: make bundle CN=$(CN)"
	@echo "Add an ACL entry for user '$(CN)' in mosquitto/acl"

# ---------------------------------------------------------------------------
# Gateway bundle
# ---------------------------------------------------------------------------

bundle:
ifndef CN
	$(error CN is required. Usage: make bundle CN=gw-01)
endif
	@mkdir -p $(DIST_DIR)/$(CN)
	@cp $(CA_CRT)                      $(DIST_DIR)/$(CN)/ca.crt
	@cp $(CERT_DIR)/client-$(CN).crt   $(DIST_DIR)/$(CN)/client.crt
	@cp $(KEY_DIR)/client-$(CN).key    $(DIST_DIR)/$(CN)/client.key
	@echo "Staged in $(DIST_DIR)/$(CN)/ :"
	@ls -1 $(DIST_DIR)/$(CN)/
	@echo
	@echo "Upload all three via the UG65 web GUI:"
	@echo "  Network Server > Application > <app> > MQTT"
	@echo "  TLS: enable, Mode: 'Self signed certificates'"
	@echo "  Broker Address: $(BROKER_IP)   Broker Port: 8884"
	@echo
	@echo "SET NTP ON THE GATEWAY FIRST — clock skew is the #1 failure."
	@echo "Delete $(DIST_DIR)/$(CN)/client.key once transferred."

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify:
	@echo "==> 1. Chain: does the CA vouch for the server cert?"
	@$(OPENSSL) verify -CAfile $(CA_CRT) $(CERT_DIR)/server.crt
	@echo
	@echo "==> 2. SAN (must contain IP:$(BROKER_IP))"
	@$(OPENSSL) x509 -in $(CERT_DIR)/server.crt -noout -text \
	  | grep -A1 'Subject Alternative Name' \
	  | grep -q "IP Address:$(BROKER_IP)" \
	  && echo "    OK: IP:$(BROKER_IP) present" \
	  || { echo "    FAIL: IP:$(BROKER_IP) MISSING — gateway will reject"; exit 1; }
	@echo
	@echo "==> 3. Server EKU"
	@$(OPENSSL) x509 -in $(CERT_DIR)/server.crt -noout -ext extendedKeyUsage
	@echo "==> 4. Client certs: chain + EKU + revocation status"
	@# `openssl verify` ignores CRLs unless -crl_check is given and the CRL is
	@# concatenated onto the CA file. Without this, a REVOKED cert reports OK.
	@if [ -f $(CRL) ]; then \
	  cat $(CA_CRT) $(CRL) > $(CA_DIR)/.verify-bundle.pem; \
	  VERIFY_ARGS="-crl_check -CAfile $(CA_DIR)/.verify-bundle.pem"; \
	else \
	  VERIFY_ARGS="-CAfile $(CA_CRT)"; \
	  echo "    (no CRL yet — revocation not checked)"; \
	fi; \
	for c in $(CERT_DIR)/client-*.crt; do \
	  [ -e "$$c" ] || continue; \
	  printf '    %s: ' "$$c"; \
	  out=$$($(OPENSSL) verify $$VERIFY_ARGS "$$c" 2>&1 || true); \
	  if echo "$$out" | grep -q 'certificate revoked'; then \
	    echo "REVOKED"; \
	  elif ! echo "$$out" | grep -q ': OK$$'; then \
	    echo "FAIL (chain) — $$(echo "$$out" | tail -1)"; \
	  elif ! $(OPENSSL) x509 -in "$$c" -noout -ext extendedKeyUsage \
	         | grep -q 'TLS Web Client Authentication'; then \
	    echo "FAIL (missing clientAuth EKU)"; \
	  else \
	    echo "OK"; \
	  fi; \
	done; \
	rm -f $(CA_DIR)/.verify-bundle.pem

check-remote:
ifndef CN
	$(error CN is required. Usage: make check-remote CN=gw-01)
endif
	@echo "==> Live mTLS handshake to $(BROKER_IP):8884"
	@echo "    Expect: 'Verify return code: 0 (ok)'"
	@echo | $(OPENSSL) s_client -connect $(BROKER_IP):8884 \
	  -CAfile $(CA_CRT) \
	  -cert $(CERT_DIR)/client-$(CN).crt \
	  -key $(KEY_DIR)/client-$(CN).key \
	  2>&1 | grep -E 'Verify return code|subject=|issuer=|Cipher is|error'

# ---------------------------------------------------------------------------
# Revocation and rotation
# ---------------------------------------------------------------------------

revoke:
ifndef CN
	$(error CN is required. Usage: make revoke CN=gw-01)
endif
	$(OPENSSL) ca -config $(CNF_DIR)/ca.cnf -revoke $(CERT_DIR)/client-$(CN).crt
	@$(MAKE) --no-print-directory crl
	@echo
	@echo "WARNING: Milesight firmware frequently ignores CRLs."
	@echo "To be certain a gateway is locked out, rotate the CA."

crl:
	$(OPENSSL) ca -batch -config $(CNF_DIR)/ca.cnf -gencrl \
	  -crlexts crl_ext -out $(CRL)
	@echo "CRL written: $(CRL) — copy to broker, then reload mosquitto"

expiry:
	@echo "==> Certificates expiring within 30 days:"
	@found=0; \
	for c in $(CERT_DIR)/*.crt $(CA_CRT); do \
	  [ -e "$$c" ] || continue; \
	  if ! $(OPENSSL) x509 -in "$$c" -noout -checkend $$((30*86400)) >/dev/null 2>&1; then \
	    printf '    EXPIRING  %s  (%s)\n' "$$c" \
	      "$$($(OPENSSL) x509 -in "$$c" -noout -enddate | cut -d= -f2)"; \
	    found=1; \
	  fi; \
	done; \
	[ $$found -eq 0 ] && echo "    none" || true

list:
	@echo "==> Issued certificates (from $(CA_DIR)/index.txt)"
	@echo "    V=valid  R=revoked  E=expired"
	@[ -s $(CA_DIR)/index.txt ] \
	  && awk -F'\t' '{printf "    %s  serial=%-6s  %s\n", $$1, $$4, $$6}' $(CA_DIR)/index.txt \
	  || echo "    none yet"

clean-csr:
	@rm -f $(CA_DIR)/*.csr

deploy-help:
	@echo "Deploying to the broker host ($(BROKER_IP))"
	@echo "==========================================="
	@echo
	@echo "1. Copy certificates:"
	@echo "     scp $(CA_CRT) $(CERT_DIR)/server.crt $(KEY_DIR)/server.key \\"
	@echo "         root@$(BROKER_IP):/etc/mosquitto/certs/"
	@echo
	@echo "2. Copy configs:"
	@echo "     scp mosquitto/mosquitto.conf   root@$(BROKER_IP):/etc/mosquitto/"
	@echo "     scp mosquitto/acl              root@$(BROKER_IP):/etc/mosquitto/"
	@echo "     scp mosquitto/conf.d/tls.conf  root@$(BROKER_IP):/etc/mosquitto/conf.d/"
	@echo
	@echo "3. Fix ownership and permissions (ON THE BROKER):"
	@echo "     chown -R mosquitto:mosquitto /etc/mosquitto/certs /etc/mosquitto/acl"
	@echo "     chmod 600 /etc/mosquitto/certs/server.key"
	@echo "     chmod 644 /etc/mosquitto/certs/ca.crt /etc/mosquitto/certs/server.crt"
	@echo "     chmod 700 /etc/mosquitto/acl   # 2.x warns if world-readable"
	@echo
	@echo "4. Create the :8883 password file (skip if you removed that listener):"
	@echo "     mosquitto_passwd -c /etc/mosquitto/passwd backend"
	@echo "     chown mosquitto:mosquitto /etc/mosquitto/passwd"
	@echo "     chmod 600 /etc/mosquitto/passwd"
	@echo
	@echo "5. Validate config WITHOUT starting the service:"
	@echo "     mosquitto -c /etc/mosquitto/mosquitto.conf -v"
	@echo "   Ctrl-C once you see 'mosquitto version ... running'."
	@echo
	@echo "6. Start / reload:"
	@echo "     systemctl restart mosquitto    # first time, or after listener changes"
	@echo "     systemctl reload mosquitto     # after cert reissue (keeps sessions)"
	@echo
	@echo "7. Enable CRL checking, after your first 'make crl':"
	@echo "     scp $(CRL) root@$(BROKER_IP):/etc/mosquitto/certs/"
	@echo "   then uncomment the crlfile line in conf.d/tls.conf and reload."


# ---------------------------------------------------------------------------
# Security notes
# ---------------------------------------------------------------------------

help-security:
	@echo "ca.key handling"
	@echo "==============="
	@echo
	@echo "Currently UNENCRYPTED at $(CA_KEY), mode 0600, gitignored."
	@echo "Simplest start; fine while the CA lives on a trusted workstation."
	@echo
	@echo "It is only needed when issuing a cert. Two hardening options:"
	@echo
	@echo "1. Encrypt at rest (prompts on every issuance):"
	@echo "     openssl rsa -aes256 -in $(CA_KEY) -out $(CA_KEY).enc"
	@echo "     mv $(CA_KEY).enc $(CA_KEY)"
	@echo
	@echo "2. Move offline — copy $(CA_KEY) to removable media, delete locally,"
	@echo "   restore only when issuing. Strongest; least convenient."
	@echo
	@echo "A leaked ca.key means an attacker can impersonate the broker AND"
	@echo "mint gateway certs. It is the only irrecoverable secret here."
