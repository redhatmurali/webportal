# Web Portal – Installation Toolkit

Download all installation scripts from GitHub.

### Option 1: Clone using Git (Recommended)

```bash
sudo apt update
sudo apt install git -y

git clone https://github.com/redhatmurali/webportal.git

cd webportal
```

### Option 2: Download ZIP

```bash
wget https://github.com/redhatmurali/webportal/archive/refs/heads/main.zip -O webportal.zip

sudo apt install unzip -y

unzip webportal.zip

cd webportal-main
```

### Option 3: Make all scripts executable

```bash
chmod +x *.sh
```

### Start Installation

Follow the installation phases below in the recommended order.

All installation scripts are available in this repository.

GitHub Repository:
https://github.com/redhatmurali/webportal


# Server Installation Toolkit

Production-ready installation scripts for deploying a complete server infrastructure.

## Installation Guide

Run the following commands from your cloned GitHub repository directory.

### Phase 1 – VICIDIAL Installation

Install and configure the VICIDIAL dialer.

```bash
chmod +x install-vicidial-prod-ip.sh
sudo bash install-vicidial-prod-ip.sh --timezone Asia/Kolkata --lan

chmod +x vicidial-postinstall-fix.sh
sudo bash vicidial-postinstall-fix.sh 192.168.29.105
```

### Phase 2 – PBX Installation

Install FreePBX.

```bash
chmod +x install-freepbx.sh
sudo bash install-freepbx.sh --port 3060
```

### Phase 3 – Monitoring and Observability

Install Prometheus, Grafana and OpenObserve.

**1. Prometheus**
```bash
chmod +x install-prometheus.sh
sudo bash install-prometheus.sh -p 9095 -v 3.5.0 -y
```

**2. Grafana**
```bash
chmod +x install-grafana.sh
sudo bash install-grafana.sh -p 3001 -v 12.2.0 -y
```

**3. OpenObserve**
```bash
chmod +x install-openobserve.sh
sudo bash install-openobserve.sh --version 0.14.7 --port 5080
```

### Phase 4 – Identity and Automation

Install Keycloak, Semaphore, n8n and WAHA.

**1. Keycloak**
```bash
chmod +x install-keycloak.sh
sudo bash install-keycloak.sh --version 26.0.7 --port 8080
```

**2. Ansible Semaphore**
```bash
chmod +x install-semaphore.sh
sudo bash install-semaphore.sh --version 2.10.35 --port 3000
```

**3. n8n**
```bash
chmod +x install-n8n.sh
sudo bash install-n8n.sh --version 1.76.1 --port 5678
```

**4. WAHA**
```bash
chmod +x install-waha.sh
sudo bash install-waha.sh --version latest --port 3002
```

Note: WAHA uses port 3002 here to avoid conflicting with Semaphore on port 3000.

### Phase 5 – Business Applications

Install the following applications.

**1. FreeScout – Helpdesk**
```bash
chmod +x install-freescout.sh
sudo bash install-freescout.sh --version 1.8.150 --port 3010
```

**2. BookStack – Documentation**
```bash
chmod +x install-bookstack.sh
sudo bash install-bookstack.sh --version v25.02.1 --port 3020
```

**3. Redmine – Project Management**
```bash
chmod +x install-redmine.sh
sudo bash install-redmine.sh --version 6.0.5 --port 3030
```

**4. Docusaurus – Knowledge Portal**
```bash
chmod +x install-docusaurus.sh
sudo bash install-docusaurus.sh --version 3.9.2 --port 3040
```

### Phase 6 – Web Portal and Mail

Install the mail application.

```bash
chmod +x install-mail-simple.sh
sudo env WEB_PORT=9090 bash install-mail-simple.sh
```

---

## Application Port Reference

| Application | Port |
|---|---:|
| VICIDIAL | 80 / 443 |
| FreePBX | 3060 |
| Prometheus | 9095 |
| Grafana | 3001 |
| OpenObserve | 5080 |
| Keycloak | 8080 |
| Semaphore | 3000 |
| n8n | 5678 |
| WAHA | 3002 |
| FreeScout | 3010 |
| BookStack | 3020 |
| Redmine | 3030 |
| Docusaurus | 3040 |
| Mail Web Portal | 9090 |

## Important Notes

- Run installation scripts with root privileges using `sudo`.
- Execute installations in the recommended order.
- Ensure the required ports are available before installation.
- Configure firewall rules for the services you intend to expose.
- Use HTTPS and reverse proxy configurations for production deployments.
- Secure all default credentials immediately after installation.
- Verify each application before proceeding to the next phase.

