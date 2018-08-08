#!/bin/bash

set -e

# install git to make the version lookup succeed
dpkg -s git 2>/dev/null >/dev/null || univention-install git

APP="bitwarden-rs"
# get latest tagged image
VERSION=$(git ls-remote --refs --tags https://github.com/dani-garcia/bitwarden_rs.git | sort -t '/' -k 3 -V | awk -F/ '{ print $3 }' | tail -1)
docker_name="mprasil/bitwarden:$VERSION"
data_dir="/var/lib/bitwarden_rs"

eval "$(ucr shell hostname domainname)"

if [ ! -e ./env ]; then
	cat <<-EOF >"./env"
DOMAIN=https://bitwarden.$hostname.$domainname/
SIGNUPS_ALLOWED=true
EOF
fi

mkdir -p $data_dir

docker pull $docker_name
docker rm -f $APP
docker run -d --name=$APP --restart=unless-stopped \
	-v $data_dir:/data/ \
	-v /etc/localtime:/etc/localtime:ro \
	--env-file ./env \
	-p 127.0.0.1:9080:80 \
	$docker_name

if [ ! -z $(ucr get apache2/ssl/certificate) ]; then
	echo "using ucr defined certificate"
	SSLCERTIFICATE=$(ucr get apache2/ssl/certificate)
else
	echo "using ucs default certificate"
	SSLCERTIFICATE="/etc/univention/ssl/${hostname}.${domainname}/cert.pem"
fi

if [ ! -z $(ucr get apache2/ssl/key) ]; then
	echo "using ucr defined private key"
	SSLKEY=$(ucr get apache2/ssl/key)
else
	echo "using ucs default privat key"
	SSLKEY="/etc/univention/ssl/${hostname}.${domainname}/private.key"
fi

if [ ! -z $(ucr get apache2/ssl/ca) ]; then
	echo "using ucr defined ca"
	SSLCA=$(ucr get apache2/ssl/ca)
else
	echo "using ucs default ca"
	SSLCA="/etc/univention/ssl/ucsCA/CAcert.pem"
fi

if [ ! -z $(ucr get apache2/ssl/certificatechain) ]; then
	echo "using ucr defined chain"
	SSLCHAIN="SSLCertificateChainFile $(ucr get apache2/ssl/certificatechain)"
fi

cat <<-EOF >"/etc/apache2/sites-available/bitwarden_rs.conf"

###################################################################
# generated by bitwarden_rs app join script, do not edit manually #
###################################################################

<VirtualHost *:80>
        ServerName	bitwarden.$hostname.$domainname
        ServerAdmin	webmaster@example.org

        ErrorLog \${APACHE_LOG_DIR}/bitwarden-error.log
        CustomLog \${APACHE_LOG_DIR}/bitwarden-access.log combined

        # Enforce HTTPS:
        RewriteEngine On
        RewriteCond %{REQUEST_URI} !^/.well-known/acme-challenge/
        RewriteCond %{HTTPS} !=on
        RewriteRule ^/?(.*) https://bitwarden.$hostname.$domainname/\$1 [R,L]
</VirtualHost>

<VirtualHost *:443>
        SSLEngine on
        ServerName bitwarden.$hostname.$domainname
        ServerAdmin webmaster@example.org

        SSLCertificateFile ${SSLCERTIFICATE}
        SSLCertificateKeyFile ${SSLKEY}
        SSLCACertificateFile ${SSLCA}
        ${SSLCHAIN}

        ErrorLog \${APACHE_LOG_DIR}/bitwarden_rs-error.log
        CustomLog \${APACHE_LOG_DIR}/bitwarden_rs-access.log combined

        <Location />
                Require all granted
                ProxyPass http://127.0.0.1:9080/
                ProxyPassReverse http://127.0.0.1:9080/
        </Location>

        ProxyPreserveHost On
        ProxyRequests Off
</VirtualHost>

EOF

cat <<-EOF >"/etc/apache2/ucs-sites.conf.d/bitwarden_rs.conf"

###################################################################
# generated by bitwarden_rs app join script, do not edit manually #
###################################################################

Redirect 303 /bitwarden_rs https://bitwarden.$hostname.$domainname
EOF

a2ensite bitwarden_rs || true
invoke-rc.d apache2 reload

wget -O /usr/share/univention-web/js/dijit/themes/umc/icons/50x50/bitwarden.png \
	https://raw.githubusercontent.com/bitwarden/brand/master/icons/128x128.png

# create a link in the Univention portal
P="ucs/web/overview/entries/service"
ucr set \
	"$P/$APP"/description="Open source password management solutions for individuals, teams, and business organizations." \
	"$P/$APP"/icon="/univention-management-console/js/dijit/themes/umc/icons/50x50/bitwarden.png" \
	"$P/$APP"/label="Bitwarden" \
	"$P/$APP"/link="https://bitwarden.$hostname.$domainname/"

# setting up automatic backup
# installing sqlite3 if not already present
dpkg -s sqlite3 2>/dev/null >/dev/null || univention-install sqlite3

cat <<-EOF >"/etc/cron.daily/bitwarden_rs-backup"
#!/bin/sh

###################################################################
# generated by bitwarden_rs app join script, do not edit manually #
###################################################################

cd $data_dir
sqlite3 db.sqlite3 ".backup db-backup.sq3"

EOF

chmod +x /etc/cron.daily/bitwarden_rs-backup

