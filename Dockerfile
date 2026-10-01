# Image officielle WordPress avec PHP et Apache
FROM wordpress:php8.3-apache

# Outils utiles au diagnostic et à l'administration de la base
RUN apt-get update && apt-get install -y \
    default-mysql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Définition du répertoire racine de l'application Web
WORKDIR /var/www/html
