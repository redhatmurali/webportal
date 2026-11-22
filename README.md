# webportal

sudo WEB_PORT=9090 bash install-mail-simple.sh

sudo bash install-prometheus.sh -p 9095 -v 3.5.0 -y

sudo bash install-grafana.sh -p 3001 -v 12.2.0 -y

sudo ./install-openobserve.sh --version 0.14.7 --port 5080
