#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Run once: the startup script executes on every boot
if [ -f /var/lib/hr-provisioned ]; then
  exit 0
fi

# e2-micro has only 1 GB RAM: add swap, then install the stack
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# tomcat9 lives in Ubuntu's universe repo
apt-get update -y
apt-get install -y software-properties-common
add-apt-repository -y universe
apt-get update -y

# headless JDK provides java/javac without GUI libs (saves disk); cat is part of coreutils (preinstalled)
apt-get install -y \
  nginx \
  openjdk-17-jdk-headless \
  tomcat9 \
  mysql-server \
  python3 python3-pip python3-venv \
  git \
  vim

# Tomcat should use JDK 17 explicitly
echo 'JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> /etc/default/tomcat9

# Tomcat: listen on localhost only; nginx is the only public entry point
sed -i 's|<Connector port="8080" protocol="HTTP/1.1"|<Connector port="8080" address="127.0.0.1" protocol="HTTP/1.1"|' /etc/tomcat9/server.xml
grep -q 'address="127.0.0.1"' /etc/tomcat9/server.xml

# nginx reverse proxy to Tomcat (8080 stays closed to the internet)
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/hr <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    # Never serve dotfiles (.git, .env, ...) or backups
    location ~ /\. { deny all; return 404; }
    location ~ \.(bak|old|orig|sql|swp)$ { deny all; return 404; }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/hr /etc/nginx/sites-enabled/hr
nginx -t

# MySQL: local access only
mkdir -p /etc/mysql/mysql.conf.d
printf '[mysqld]\nbind-address = 127.0.0.1\n' > /etc/mysql/mysql.conf.d/zz-bind-local.cnf

# Automatic security patches
apt-get install -y unattended-upgrades

systemctl enable --now nginx tomcat9 mysql
systemctl reload nginx
systemctl restart tomcat9

touch /var/lib/hr-provisioned
