# Stack WordPress

Conteneurs : `wordpress` (CMS), `wordpress-db` (MariaDB), `wordpress-agent` (Zabbix Agent 2).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `wordpress-net` | 172.31.1.0/24 | wordpress, wordpress-db | Accès privé à la base |
| `services-net` (externe) | 172.30.0.0/24 | wordpress, wordpress-agent (+ n8n, Zabbix) | Webhook sortant, supervision |

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env 2>/dev/null || cat > .env <<EOF2
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 16)
MARIADB_DATABASE=wordpress
MARIADB_USER=wp
MARIADB_PASSWORD=$(openssl rand -hex 16)
EOF2

docker compose up -d
docker compose ps   # wordpress, wordpress-db doivent être "healthy" ; wordpress-agent "Up"
```

Interface : `http://IP:80`. Suivre l'installation (langue, titre du site, compte admin).

## Autoriser les mots de passe d'application (obligatoire pour n8n)

WordPress bloque par défaut les mots de passe d'application tant que le site n'est pas en HTTPS. Comme ce projet reste en HTTP, il faut déclarer l'environnement comme local directement dans le fichier déjà généré :

```bash
docker exec wordpress bash -c "sed -i \"/That's all, stop editing/i define('WP_ENVIRONMENT_TYPE', 'local');\" /var/www/html/wp-config.php"
```

Vérifier :

```bash
docker exec wordpress grep ENVIRONMENT_TYPE /var/www/html/wp-config.php
```

Rechargez ensuite **Utilisateurs > Profil** dans WordPress : la section « Mots de passe d'application » doit apparaître sans avertissement, tout en bas de page.

> Cette commande est à refaire à chaque fois que le volume `wordpress_data` est recréé (après un `docker compose down -v`), car `wp-config.php` est régénéré à neuf.

## Créer le mot de passe d'application pour n8n

1. **Utilisateurs > Profil**, section **Mots de passe d'application**
2. Nom : `n8n` → **Ajouter un nouveau mot de passe d'application**
3. Copier immédiatement le mot de passe affiché (format `aaaa bbbb cccc dddd eeee ffff`, avec les espaces) — il ne sera plus jamais affiché
4. Le transmettre au responsable n8n (en privé, jamais dans Git)

## Webhook automatique (publication -> n8n)

Le fichier `mu-plugins/n8n-webhook.php` envoie automatiquement un webhook à n8n dès qu'un article est **publié** (mu-plugin = chargé automatiquement, rien à activer). Il envoie `{"event":"post_published","title":"..."}` vers `http://n8n:5678/webhook/wordpress`.

### Tester

1. Se connecter à `wp-admin`, créer un article, cliquer sur **Publier**.
2. Vérifier dans n8n (*Executions*) qu'une exécution est arrivée avec le bon titre.

Test manuel sans passer par l'interface :

```bash
docker exec wordpress curl -s -X POST http://n8n:5678/webhook/wordpress \
  -H "Content-Type: application/json" \
  -d '{"event":"post_published","title":"Test depuis WordPress"}'
```

## Articles créés automatiquement par n8n (alertes Zabbix)

Une fois la chaîne Zabbix -> n8n -> WordPress configurée (voir `monitoring/README.md` et `n8n/README.md`), des articles apparaissent automatiquement dans **Articles > Tous les articles** :
- `Alerte : <hôte> a un problème (<problème>)` à l'ouverture d'un problème
- `Rétabli : <hôte> - <problème>` à sa résolution

**Limite connue à garder en tête pour la démo** : si vous testez la panne en arrêtant le conteneur `wordpress` lui-même, n8n ne pourra pas publier l'article d'alerte tant que WordPress est injoignable (dépendance circulaire). Zabbix retente automatiquement (« retries ») : l'article de panne apparaît en général après le redémarrage de WordPress, en retard. Pour une démo plus propre, testez plutôt la panne d'un service qui n'empêche pas n8n d'écrire sur WordPress (ex. `n8n-db`, ou charge simulée).

## Test de panne

```bash
docker compose stop wordpress
# Observer dans Zabbix : Monitoring > Problems
docker compose start wordpress
# Observer le retour à l'état normal + l'article "Rétabli" dans WordPress
```

## Informations pour le responsable Zabbix

- Un agent `wordpress-agent` (Zabbix Agent 2) est inclus dans ce compose, connecté à `services-net`.
- Créer dans Zabbix un hôte nommé **`wordpress`** (doit correspondre exactement à `ZBX_HOSTNAME`), interface **Agent**, **Connect to : DNS**, DNS name `wordpress-agent`, port `10050`.
- Lier les templates **Linux by Zabbix agent** et **Docker by Zabbix agent 2**.
- Scénario web complémentaire (optionnel) : URL `http://wordpress:80`, code attendu `200`.

## Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `network services-net declared as external, but could not be found` | Réseau pas encore créé | `docker network create --driver bridge --subnet 172.30.0.0/24 services-net` |
| Page d'installation en boucle | `wordpress-db` pas encore prêt | Attendre son état `healthy` (`docker compose ps`) |
| Erreur 500 sur toutes les pages | `wp-config.php` pointe vers un ancien mot de passe de base (volume recréé avec un nouveau `.env`) | `docker compose down -v && docker compose up -d` (recommence l'installation à zéro) |
| Section « Mots de passe d'application » absente ou grisée | HTTPS requis par défaut | Voir section dédiée plus haut (`docker exec ... WP_ENVIRONMENT_TYPE`) |
| Le webhook vers n8n ne part pas | `wordpress` pas sur `services-net`, ou mu-plugin non pris en compte | `docker network inspect services-net` ; `docker exec wordpress ls /var/www/html/wp-content/mu-plugins/` |
