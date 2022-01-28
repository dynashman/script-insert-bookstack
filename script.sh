#!/bin/sh
# This script will install a new BookStack instance on a fresh Ubuntu 20.04 server.
# This script is experimental and does not ensure any security.

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
DOMAIN=$1
if [ -z "$1" ]
then
echo ""
printf "Enter v5 the domain you want to host BookStack and press [ENTER]\nExamples: my-site.com or docs.my-site.com\n"
read -r DOMAIN
fi

# Ensure a domain was provided otherwise display
# an error message and stop the script
if [ -z "$DOMAIN" ]
then
  >&2 echo 'ERROR: A domain must be provided to run this script'
  exit 1
fi

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

# Set up database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
mysql -u root --execute="CREATE DATABASE $DOMAIN;"
mysql -u root --execute="CREATE USER '$DOMAIN'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';"
mysql -u root --execute="GRANT ALL ON $DOMAIN.* TO '$DOMAIN'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
cd /var/www || exit
printf "current directory"
mkdir $DOMAIN
ls
printf "end ls"
BOOKSTACK_DIR1="/var/www/$DOMAIN/"
cd $BOOKSTACK_DIR1 || exit
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="/var/www/$DOMAIN/bookstack"
cd $BOOKSTACK_DIR || exit

# Install composer
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
then
    >&2 echo 'ERROR: Invalid composer installer checksum'
    rm composer-setup.php
    exit 1
fi

php composer-setup.php --quiet
rm composer-setup.php

# Move composer to global installation
mv composer.phar /usr/local/bin/composer

# Install BookStack composer dependencies
export COMPOSER_ALLOW_SUPERUSER=1
php /usr/local/bin/composer install --no-dev --no-plugins

# Copy and update BookStack environment variables
cp .env.example .env
sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$DOMAIN.help.iscode.tech@" .env
sed -i.bak "s/DB_DATABASE=.*$/DB_DATABASE=$DOMAIN/" .env
sed -i.bak "s/DB_USERNAME=.*$/DB_USERNAME=$DOMAIN/" .env
sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env

# Generate the application key
php artisan key:generate --no-interaction --force
# Migrate the databases
php artisan migrate --no-interaction --force

# Set file and folder permissions
chown www-data:www-data -R bootstrap/cache public/uploads storage && chmod -R 755 bootstrap/cache public/uploads storage

# Set up apache
a2enmod rewrite
a2enmod php7.4
FILE = "/etc/apache2/sites-available/$DOMAIN-bookstack.conf"
cat > FILE <<EOL
<VirtualHost *:80>
	ServerName ${DOMAIN}.help.iscode.tech

	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/${DOMAIN}/bookstack/public/

    <Directory /var/www/bookstack/public/>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <IfModule mod_rewrite.c>
            <IfModule mod_negotiation.c>
                Options -MultiViews -Indexes
            </IfModule>

            RewriteEngine On

            # Handle Authorization Header
            RewriteCond %{HTTP:Authorization} .
            RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

            # Redirect Trailing Slashes If Not A Folder...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_URI} (.+)/$
            RewriteRule ^ %1 [L,R=301]

            # Handle Front Controller...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteRule ^ index.php [L]
        </IfModule>
    </Directory>

	ErrorLog \${APACHE_LOG_DIR}/error.log
	CustomLog \${APACHE_LOG_DIR}/access.log combined

</VirtualHost>
EOL
CON = "$DOMAIN-bookstack.conf"
a2ensite CON

# Restart apache to load new config
systemctl restart apache2

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo "MySQL was installed without a root password, It is recommended that you set a root MySQL password."
echo ""
echo "You can access your BookStack instance at: http://$CURRENT_IP/ or http://$DOMAIN.help.iscode.tech/"
