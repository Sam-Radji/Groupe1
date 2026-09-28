# Stack WordPress

Conteneurs : `wordpress` (CMS) et `wordpress-db` (MariaDB).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `wordpress-net` | 172.31.1.0/24 | wordpress, wordpress-db | Accès privé à la base |
| `services-net` (externe) | 172.30.0.0/24 | wordpress (+ n8n, Zabbix) | Envoi du webhook, supervision |

## Webhook automatique

Le fichier `mu-plugins/n8n-webhook.php` envoie automatiquement un webhook à n8n dès qu'un article est **publié** (mu-plugin = chargé automatiquement, rien à activer dans wp-admin). Il envoie `{"event":"post_published","title":"..."}` vers `http://n8n:5678/webhook/wordpress`.

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env
sed -i "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=$(openssl rand -hex 16)|" .env
sed -i "s|^MARIADB_PASSWORD=.*|MARIADB_PASSWORD=$(openssl rand -hex 16)|" .env

docker compose up -d
docker compose ps   # wordpress et wordpress-db doivent être "healthy"
```

Interface : `http://IP:80`. Suivre l'installation (langue, titre du site, compte admin).

## Tester le webhook

1. Se connecter à `wp-admin`, créer un article, cliquer sur **Publier**.
2. Vérifier dans n8n (*Executions*) qu'une exécution est arrivée avec le bon titre.

Test manuel sans passer par l'interface :

```bash
docker exec wordpress curl -s -X POST http://n8n:5678/webhook/wordpress \
  -H "Content-Type: application/json" \
  -d '{"event":"post_published","title":"Test depuis WordPress"}'
```

## Test de panne

```bash
docker compose stop wordpress
docker compose start wordpress
```

## Informations pour le responsable Zabbix

- Cible à superviser : `http://wordpress:80` (code HTTP 200, via `services-net`)
- Conteneurs : `wordpress` et `wordpress-db`

## Dépannage

- **`network services-net declared as external, but could not be found`** : créer le réseau (voir plus haut).
- **Le webhook ne part pas** : vérifier que `wordpress` est bien sur `services-net` (`docker network inspect services-net`), et regarder `docker compose logs wordpress`.
- **Page d'installation qui boucle** : `wordpress-db` pas encore prêt, attendre son état `healthy`.
