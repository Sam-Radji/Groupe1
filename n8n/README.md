# Stack n8n

Conteneurs : `n8n` (workflows et webhooks), `n8n-db` (PostgreSQL), `n8n-agent` (Zabbix Agent 2).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `n8n-net` | 172.31.2.0/24 | n8n, n8n-db | Accès privé à la base |
| `services-net` (externe) | 172.30.0.0/24 | n8n, n8n-agent (+ wordpress, Zabbix) | Webhooks entrants/sortants, supervision |

La base `n8n-db` n'est que sur `n8n-net` et n'expose aucun port : ni WordPress ni Zabbix ne peuvent l'atteindre.

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env 2>/dev/null || cat > .env <<EOF2
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=n8n
N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
PUBLIC_IP=METTRE_ICI_IP_PUBLIQUE_DE_LA_VM
TZ=Europe/Paris
EOF2
# Éditer ensuite .env pour remplacer PUBLIC_IP par la vraie IP si besoin

docker compose up -d
docker compose ps   # n8n et n8n-db doivent être "healthy" ; n8n-agent "Up"
```

Interface : `http://IP:5678`. Créer le compte propriétaire dès la première connexion.

## Workflow 1 : WordPress -> n8n (réception d'une publication)

Fichier : `workflow-wordpress-webhook.json`.

1. *Workflows > Import from file*, choisir ce fichier.
2. **Activer** le workflow (interrupteur en haut à droite) — sans cela, l'URL de production renvoie une 404.
3. URL : `/webhook/wordpress` (actif) — `/webhook-test/wordpress` seulement en mode écoute.

Test :

```bash
curl -X POST http://localhost:5678/webhook/wordpress \
  -H "Content-Type: application/json" \
  -d '{"event":"post_published","title":"Test"}'
```

Résultat attendu : `{"received":true,"valid":true,...}`.

## Workflow 2 : Zabbix -> n8n -> WordPress (alerte -> article)

Fichier : `workflow-zabbix-to-wordpress.json`. Reçoit une alerte Zabbix sur `/webhook/zabbix-alert`, construit un titre/contenu, puis crée un article WordPress via le nœud natif **WordPress**.

### Étape préalable côté WordPress

Le responsable WordPress doit avoir autorisé les mots de passe d'application et vous avoir transmis :
- l'identifiant `wp-admin` du compte
- un mot de passe d'application (format `aaaa bbbb cccc dddd eeee ffff`, avec les espaces)

Si ce n'est pas encore fait côté WordPress, voir `wordpress/README.md`, section « Autoriser les mots de passe d'application ».

### Configuration dans n8n

1. *Workflows > Import from file*, choisir `workflow-zabbix-to-wordpress.json`.
2. *Credentials > New > WordPress API* :
   - WordPress URL : `http://wordpress:80`
   - Username : l'identifiant `wp-admin` transmis
   - Password : le mot de passe d'application (avec les espaces, pas le mot de passe normal du compte)
3. Ouvrir le nœud **Créer l'article WordPress**, sélectionner ce credential dans le menu déroulant.
4. **Activer** le workflow.

### Tester sans attendre Zabbix

```bash
curl -X POST http://localhost:5678/webhook/zabbix-alert \
  -H "Content-Type: application/json" \
  -d '{"host":"n8n","problem":"Test manuel","severity":"Warning","status":"PROBLEM"}'
```

Vérifier qu'un article apparaît dans WordPress et qu'une exécution réussie apparaît dans *Executions*.

### URL à transmettre au responsable Zabbix

```
http://n8n:5678/webhook/zabbix-alert
```

Corps JSON attendu (POST) :

```json
{ "host": "n8n", "problem": "RAM élevée", "severity": "High", "status": "PROBLEM" }
```

Voir `monitoring/README.md` pour la configuration exacte du Media type webhook côté Zabbix (script JS, paramètres, message templates).

## Erreurs fréquentes et solutions

| Erreur rencontrée | Cause | Solution |
|---|---|---|
| `network services-net declared as external, but could not be found` | Réseau pas encore créé | `docker network create --driver bridge --subnet 172.30.0.0/24 services-net` |
| 404 sur `/webhook/...` | Le workflow correspondant n'est pas activé | Activer le toggle en haut à droite de l'éditeur |
| `Authorization failed` / 401 sur le nœud WordPress | Username incorrect, mot de passe d'application mal copié (espaces), ou mots de passe d'application pas encore autorisés côté WordPress (HTTPS requis) | Vérifier le credential ; voir `wordpress/README.md` |
| `rest_cannot_create` (401) | Le compte WordPress utilisé n'a pas les droits (doit être Administrateur ou Éditeur) | Utiliser un compte avec les bons droits |
| Erreur HTTP 500 sur le nœud WordPress pendant un test de panne | WordPress est justement le service arrêté : n8n ne peut pas lui écrire tant qu'il est down | Attendre le redémarrage de WordPress ; Zabbix retente automatiquement (retries) |
| n8n ne démarre pas | Mot de passe PostgreSQL du `.env` ne correspond plus au volume existant | `docker compose down -v` puis relancer (perte des workflows si pas exportés) |

## Test de panne (pour la démo)

```bash
docker compose stop n8n
docker compose start n8n
```

## Vérifications réseau utiles

```bash
# n8n joignable par son nom depuis services-net
docker run --rm --network services-net curlimages/curl -s http://n8n:5678/healthz

# Isolation de la base : seuls n8n et n8n-db doivent apparaître
docker network inspect n8n_n8n-net --format '{{range .Containers}}{{.Name}} {{end}}'
```

## Informations pour le responsable Zabbix

- Un agent `n8n-agent` (Zabbix Agent 2) est inclus dans ce compose, connecté à `services-net`.
- Créer dans Zabbix un hôte nommé **`n8n`**, interface **Agent**, **Connect to : DNS**, DNS name `n8n-agent`, port `10050`.
- Lier les templates **Linux by Zabbix agent** et **Docker by Zabbix agent 2**.
- Scénario web complémentaire (optionnel) : URL `http://n8n:5678/healthz`, code attendu `200`.
