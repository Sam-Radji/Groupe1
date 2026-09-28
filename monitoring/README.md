# Stack Monitoring (Zabbix)

Conteneurs : `zabbix-server` (moteur), `zabbix-web` (interface) et `zabbix-db` (PostgreSQL).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `monitoring-net` | 172.31.3.0/24 | zabbix-server, zabbix-web, zabbix-db | Communication interne Zabbix |
| `services-net` (externe) | 172.30.0.0/24 | zabbix-server (+ wordpress, n8n) | Contrôle HTTP des services |

Seul `zabbix-server` est sur `services-net` : c'est lui qui interroge WordPress et n8n. `zabbix-web` n'a pas besoin d'y être.

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" .env

docker compose up -d
docker compose ps   # les 3 services doivent démarrer ; zabbix-db "healthy"
```

Interface : `http://IP:8080`. Identifiants par défaut : `Admin` / `zabbix` — **à changer immédiatement**.

## Configurer la supervision de WordPress et n8n

Zabbix Server contacte directement les URLs en HTTP (scénarios web), sans agent à installer sur WordPress ou n8n.

1. *Data collection > Hosts > Create host*
   - Nom : `wordpress` — Groupe : `Services`
   - Interface : aucune nécessaire pour un scénario web seul
2. *Web scenarios > Create web scenario* sur l'hôte `wordpress` :
   - Nom : `Disponibilité WordPress`
   - Étape : Nom `Accueil`, URL `http://wordpress:80`, code de statut attendu `200`
3. Répéter pour l'hôte `n8n` avec l'URL `http://n8n:5678/healthz`
4. *Triggers* : un déclencheur est créé automatiquement en cas d'échec du scénario (statut ≠ 200) ; vérifier son niveau de sévérité (Warning ou High).
5. *Dashboards > Create dashboard* : ajouter les widgets « Problems » et l'état des deux scénarios web.

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
