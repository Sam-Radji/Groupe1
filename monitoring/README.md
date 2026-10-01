# Stack Monitoring (Zabbix)

Conteneurs : `zabbix-server` (moteur), `zabbix-web` (interface) et `zabbix-db` (PostgreSQL).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `monitoring-net` | 172.31.3.0/24 | zabbix-server, zabbix-web, zabbix-db | Communication interne Zabbix |
| `services-net` (externe) | 172.30.0.0/24 | zabbix-server (+ wordpress, n8n) | Contrôle HTTP des services |

Seul `zabbix-server` est sur `services-net` : c'est lui qui interroge les agents de WordPress et n8n. `zabbix-web` n'a pas besoin d'y être.

Un agent `zabbix-agent` est aussi inclus ici, pour surveiller l'hôte Zabbix lui-même (CPU/RAM/conteneurs), sur `monitoring-net` uniquement (`zabbix-server` y a déjà accès, pas besoin de `services-net`).

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" .env

docker compose up -d
docker compose ps   # les 3 services doivent démarrer ; zabbix-db "healthy"
```

Interface : `http://IP:8080`. Identifiants par défaut : `Admin` / `zabbix` — **à changer immédiatement**.

## Configurer la supervision par agents

Chaque stack (`wordpress/`, `n8n/`, et `monitoring/` lui-même) déploie désormais un conteneur `*-agent` (Zabbix Agent 2) connecté à `services-net` (ou `monitoring-net` pour le sien propre). Zabbix Server les interroge activement en plus des scénarios web HTTP.

| Hôte à créer | Nom exact (`ZBX_HOSTNAME`) | Adresse DNS de l'interface Agent | Port |
|---|---|---|---|
| WordPress | `wordpress` | `wordpress-agent` | 10050 |
| n8n | `n8n` | `n8n-agent` | 10050 |
| Zabbix (lui-même) | `Zabbix server` | `zabbix-agent` | 10050 |

Pour chaque ligne :

1. *Data collection > Hosts > Create host*
   - Nom : exactement la valeur de la colonne « Nom exact »
   - Groupe : `Services`
   - Interfaces : **Agent**, adresse DNS = colonne correspondante, port `10050`
2. Onglet **Templates** : lier **Docker by Zabbix agent 2** (surveillance des conteneurs) et **Linux by Zabbix agent 2** (CPU/RAM/disque de l'hôte).
3. (Optionnel, en complément) *Web scenarios > Create web scenario* :
   - Pour `wordpress` : URL `http://wordpress:80`, code attendu `200`
   - Pour `n8n` : URL `http://n8n:5678/healthz`, code attendu `200`
4. *Dashboards > Create dashboard* : ajouter les widgets « Problems », CPU/RAM par hôte, et l'état des scénarios web.

## Envoyer les alertes vers n8n (webhook sortant)

But : quand un problème est détecté (ou résolu), Zabbix doit appeler n8n, qui créera un article sur WordPress.

1. *Alerts > Media types > Create media type*
   - Nom : `Webhook n8n`
   - Type : `Webhook`
   - Paramètres : ajouter `host` = `{HOST.NAME}`, `problem` = `{EVENT.NAME}`, `severity` = `{EVENT.SEVERITY}`, `status` = `{EVENT.STATUS}`
   - Script JS (adapter le script par défaut fourni par Zabbix) : faire un `HttpRequest().post()` vers `http://n8n:5678/webhook/zabbix-alert` avec ces paramètres en corps JSON.
2. *Users > Admin > Media* : ajouter ce media type à l'utilisateur Admin (ou à un utilisateur dédié).
3. *Alerts > Actions > Trigger actions > Create action*
   - Nom : `Notifier n8n`
   - Conditions : par exemple tous les hôtes du groupe `Services`
   - Onglet **Operations** : envoyer via `Webhook n8n`
   - Onglet **Recovery operations** : cocher aussi l'envoi à la résolution, pour que WordPress reçoive l'article « Rétabli : ... »

## Test de panne (démonstration)

```bash
docker compose -f ../wordpress/compose.yml stop wordpress
# Attendre l'intervalle du scénario web (par défaut 1 min), observer le PROBLEM dans Zabbix
docker compose -f ../wordpress/compose.yml start wordpress
# Observer le retour à OK
```

Même chose avec `../n8n/compose.yml stop n8n`.

## Dépannage

- **`network services-net declared as external, but could not be found`** : créer le réseau (voir plus haut).
- **Zabbix Web affiche une erreur de base au premier lancement** : attendre 1 à 2 minutes (création du schéma), puis `docker compose restart zabbix-web`.
- **Scénario web toujours en erreur** : vérifier que `zabbix-server` est bien sur `services-net` (`docker network inspect services-net`), et que WordPress/n8n sont démarrés.
