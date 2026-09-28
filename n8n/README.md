# Stack n8n

Conteneurs : `n8n` (workflows et webhooks) et `n8n-db` (PostgreSQL).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `n8n-net` | 172.31.2.0/24 | n8n, n8n-db | Accès privé à la base |
| `services-net` (externe) | 172.30.0.0/24 | n8n (+ WordPress, Zabbix) | Webhooks entrants, supervision |

La base `n8n-db` n'est que sur `n8n-net` et n'expose aucun port : ni WordPress ni Zabbix ne peuvent l'atteindre.

## Démarrage

```bash
# 1. Réseau partagé (une seule fois par hôte Docker ; ignorer l'erreur s'il existe déjà)
docker network create --driver bridge --subnet 172.30.0.0/24 services-net

# 2. Configuration
cp .env.example .env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" .env
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)|" .env
# renseigner PUBLIC_IP dans .env

# 3. Lancement
docker compose up -d
docker compose ps        # n8n et n8n-db doivent être "healthy"
```

Interface : `http://IP:5678`. Créer le compte propriétaire dès la première connexion.

## Workflow de réception

1. Dans n8n : *Workflows > Import from file* et choisir `workflow-wordpress-webhook.json`.
2. **Activer** le workflow (interrupteur en haut à droite). Sans cela, l'URL de production ne répond pas.
3. URLs du webhook :
   - production : `/webhook/wordpress` (workflow actif)
   - test : `/webhook-test/wordpress` (uniquement après clic sur « Listen for test event »)

Le workflow attend un JSON avec `event` et `title`, indique s'il est valide et renvoie la réponse.

## URL à donner au responsable WordPress

```
http://n8n:5678/webhook/wordpress
```

Cette URL fonctionne depuis un conteneur rattaché à `services-net` (résolution DNS Docker). Ne pas utiliser l'IP publique pour les communications inter-stacks.

Corps attendu (POST, JSON) :

```json
{ "event": "post_published", "title": "Titre de l'article" }
```

## Tests

```bash
# Depuis l'hôte
curl -X POST http://localhost:5678/webhook/wordpress \
  -H "Content-Type: application/json" \
  -d '{"event":"post_published","title":"Test"}'

# Depuis services-net (simule WordPress)
docker run --rm --network services-net curlimages/curl \
  -s -X POST http://n8n:5678/webhook/wordpress \
  -H "Content-Type: application/json" \
  -d '{"event":"post_published","title":"Test"}'

# Santé (ce que Zabbix contrôlera)
docker run --rm --network services-net curlimages/curl -s http://n8n:5678/healthz
```

Résultat attendu : `{"received":true,"valid":true,...}` et une exécution visible dans *Executions*.

Vérifier l'isolation réseau :

```bash
docker network inspect n8n_n8n-net --format '{{range .Containers}}{{.Name}} {{end}}'      # n8n n8n-db
docker network inspect services-net --format '{{range .Containers}}{{.Name}} {{end}}'     # n8n + les autres
```

## Test de panne (pour la démo)

```bash
docker compose stop n8n      # Zabbix doit passer en PROBLEM
docker compose start n8n     # puis retour à la normale
```

## Informations pour le responsable Zabbix

- Cible à superviser : `http://n8n:5678/healthz` (code HTTP 200, via `services-net`)
- Conteneurs : `n8n` et `n8n-db`

## Dépannage

- **`network services-net declared as external, but could not be found`** : créer le réseau (étape 1).
- **404 sur `/webhook/wordpress`** : le workflow n'est pas activé.
- **n8n ne démarre pas** : `docker compose logs n8n` (souvent un mot de passe PostgreSQL modifié après la première création : `docker compose down -v` puis relancer).
- **WordPress n'atteint pas n8n** : vérifier que WordPress est bien sur `services-net`.
