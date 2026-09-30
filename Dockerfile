# Utilisation de l'image officielle WordPress
FROM wordpress:6.4-apache

# Mise à jour des paquets et installation du client MySQL et de cURL
RUN apt-get update && apt-get install -y \
    default-mysql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Définition du répertoire racine de l'application Web
WORKDIR /var/www/html
