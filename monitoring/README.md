# Stack Monitoring (Zabbix)

Conteneurs : `zabbix-server` (moteur), `zabbix-web` (interface), `zabbix-db` (PostgreSQL), `zabbix-agent` (supervision de l'hôte Zabbix lui-même).

| Réseau | Sous-réseau | Membres | Rôle |
|---|---|---|---|
| `monitoring-net` | 172.31.3.0/24 | zabbix-server, zabbix-web, zabbix-db, zabbix-agent | Communication interne Zabbix |
| `services-net` (externe) | 172.30.0.0/24 | zabbix-server (+ wordpress-agent, n8n-agent, n8n) | Interroge les agents, envoie les webhooks |

Seul `zabbix-server` est sur `services-net` : c'est lui qui interroge les agents de WordPress et n8n, et qui appelle n8n pour les alertes. `zabbix-web` n'a pas besoin d'y être.

## Démarrage

```bash
docker network create --driver bridge --subnet 172.30.0.0/24 services-net   # si pas déjà fait

cp .env.example .env 2>/dev/null || cat > .env <<EOF2
POSTGRES_USER=zabbix
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=zabbix
TZ=Europe/Paris
EOF2

docker compose up -d
docker compose ps   # zabbix-db "healthy" ; zabbix-server, zabbix-web, zabbix-agent "Up" (zabbix-web peut prendre 1-2 min)
```

Interface : `http://IP:8080`. Identifiants par défaut : `Admin` / `zabbix` — **à changer immédiatement** (*User settings*, icône en haut à droite).

## 1. Créer les hôtes et lier les agents

Chaque stack (`wordpress/`, `n8n/`, et celle-ci) déploie un conteneur `*-agent` (Zabbix Agent 2) connecté à `services-net` (ou `monitoring-net` pour celui-ci). Pour chaque hôte :

| Hôte à créer (nom exact) | Adresse DNS de l'interface Agent | Port |
|---|---|---|
| `wordpress` | `wordpress-agent` | 10050 |
| `n8n` | `n8n-agent` | 10050 |
| `Zabbix server` (déjà présent par défaut) | `zabbix-agent` | 10050 |

Pour `wordpress` et `n8n` :
1. *Data collection > Hosts > Create host*, nom exact de la colonne, groupe `Services`
2. Onglet **Interfaces > Add > Agent**, **Connect to : DNS**, renseigner le DNS name, port `10050` (le champ IP peut rester à `127.0.0.1`, il est ignoré si « Connect to » est sur DNS)
3. Onglet **Templates > Add** : **Linux by Zabbix agent** et **Docker by Zabbix agent 2**

Pour **`Zabbix server`** (déjà créé par défaut à l'installation) :
1. Ouvrir cet hôte existant, onglet **Interfaces**
2. Ajouter ou modifier l'interface **Agent** de la même façon : DNS name `zabbix-agent`, port `10050`
3. Lier les mêmes templates

Vérifier ensuite dans **Monitoring > Latest data** (filtrer par hôte) que des données CPU/RAM/conteneurs remontent après 1-2 minutes.

### En cas d'erreur « Connection refused to 127.0.0.1 »

L'interface utilise encore l'IP au lieu du DNS. Rouvrir l'interface, vérifier que **Connect to** est bien sur **DNS** (pas IP) et que le champ DNS name contient le bon nom d'agent. Si le sélecteur ne change pas, supprimer l'interface et la recréer en choisissant DNS en premier.

## 2. Scénarios web (complémentaire, optionnel)

En plus des agents, un scénario web HTTP peut vérifier que l'application répond (pas seulement que l'agent est joignable) :
- Hôte `wordpress` : *Web scenarios > Create* → URL `http://wordpress:80`, code attendu `200`
- Hôte `n8n` : URL `http://n8n:5678/healthz`, code attendu `200`

## 3. Envoyer les alertes vers n8n (webhook sortant)

But : à chaque problème détecté (ou résolu) sur un hôte, Zabbix appelle n8n, qui crée un article sur WordPress.

### Créer le Media type

*Alerts > Media types > Create media type* :
- Nom : `Webhook n8n`
- Type : `Webhook`

**Onglet Parameters**, ajouter ces 5 lignes (noms exacts, sensibles à la casse) :

| Name | Value |
|---|---|
| `host` | `{HOST.NAME}` |
| `problem` | `{EVENT.NAME}` |
| `severity` | `{EVENT.SEVERITY}` |
| `status` | `{EVENT.STATUS}` |
| `URL` | `http://n8n:5678/webhook/zabbix-alert` |

**Onglet Script**, remplacer tout le contenu par :

```javascript
try {
    var params = JSON.parse(value);

    if (!params.URL) {
        throw 'Paramètre "URL" manquant ou vide. Contenu reçu : ' + value;
    }

    var req = new HttpRequest();
    req.addHeader('Content-Type: application/json');

    var body = JSON.stringify({
        host: params.host,
        problem: params.problem,
        severity: params.severity,
        status: params.status
    });

    var resp = req.post(params.URL, body);

    if (req.getStatus() >= 200 && req.getStatus() < 300) {
        return 'OK';
    } else {
        throw 'Erreur HTTP ' + req.getStatus() + ': ' + resp;
    }
} catch (error) {
    throw 'Échec de l\'envoi vers n8n : ' + error;
}
```

> Zabbix regroupe tous les paramètres de l'onglet *Parameters* dans une seule variable `value` (texte JSON) : d'où le `JSON.parse(value)`. Les noms de paramètres sont sensibles à la casse — Zabbix fournit en réalité une clé `URL` en majuscules même si vous en créez une en minuscules ailleurs (paramètre interne), d'où l'usage de `params.URL` ici.

**Onglet Message templates** (obligatoire, sinon erreur « No message defined ») :
- **Add**, type `Problem` : garder le modèle par défaut proposé par Zabbix (il n'est pas utilisé par le script, juste exigé par Zabbix)
- **Add**, type `Problem recovery` : idem, modèle par défaut

**Update** pour sauvegarder le media type.

### Activer le media type sur l'utilisateur

*Users > Users > Admin > onglet Media > Add* : Type `Webhook n8n`, **Add**, puis **Update** sur la fiche utilisateur.

### Créer l'action

*Alerts > Actions > Trigger actions > Create action* :
- Nom : `Notifier n8n`
- Onglet **Conditions** : laisser vide (tous les hôtes) ou filtrer par groupe `Services`
- Onglet **Operations > Add** : Send to users `Admin`, Send only to `Webhook n8n`
- Onglet **Recovery operations > Add** : même configuration, pour notifier aussi la résolution

### Vérifier l'envoi

*Reports > Action log* : chaque tentative apparaît avec un statut `Sent`, `In progress` (avec retries restants) ou l'erreur exacte si `Failed`.

## Test de bout en bout

```bash
cd ../wordpress   # ou ../n8n
docker compose stop wordpress   # ou stop n8n
```

Attendre 1-2 minutes, puis vérifier dans l'ordre :
1. *Monitoring > Problems* : le problème apparaît
2. *Reports > Action log* : statut `Sent`
3. n8n (*Executions*) : une exécution automatique
4. WordPress : un article « Alerte : ... »

```bash
docker compose start wordpress
```

Revérifier la résolution et l'article « Rétabli : ... ».

**Limite connue** : si le service testé est **WordPress lui-même**, n8n ne peut pas y écrire tant qu'il est down. Zabbix retente automatiquement (retries visibles dans *Action log*) ; l'article de panne apparaît généralement après le redémarrage, en léger retard. Pour une démo plus nette, tester plutôt la panne d'un composant qui n'empêche pas n8n d'écrire sur WordPress (ex. `n8n-db` ou un conteneur secondaire).

## Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `network services-net declared as external, but could not be found` | Réseau pas encore créé | `docker network create --driver bridge --subnet 172.30.0.0/24 services-net` |
| `zabbix-web` reste bloqué sur `health: starting` | Création du schéma PostgreSQL en cours (normal au premier démarrage) | Attendre 1-2 minutes ; sinon `docker compose logs zabbix-web` |
| `PostgreSQL server is not available` en boucle dans les logs `zabbix-web`/`zabbix-server` | Mot de passe du `.env` ne correspond plus au volume existant | `docker compose down -v && docker compose up -d` (perte de la configuration Zabbix) |
| `Connection refused to [127.0.0.1]:10050` | Interface agent configurée en IP au lieu de DNS | Voir section 1, sous-section dédiée |
| `No message defined for media type` | Onglet Message templates vide | Ajouter les modèles `Problem` et `Problem recovery` (section 3) |
| `Could not resolve host: undefined` dans le script webhook | Paramètre `URL` absent, mal nommé, ou `JSON.parse` sur la mauvaise variable | Vérifier l'onglet Parameters et le script exact fourni plus haut |
| Erreur HTTP 500 dans *Action log* | n8n a reçu l'alerte mais échoue à écrire sur WordPress (souvent parce que WordPress est le service en panne testé) | Voir « Limite connue » ci-dessus |
