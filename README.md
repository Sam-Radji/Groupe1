# Projet Docker : WordPress, n8n et Zabbix

Plateforme conteneurisée à trois stacks : WordPress (application), n8n (automatisation) et Zabbix (supervision par agents), reliées par un réseau Docker partagé. Chaque stack a sa propre base de données, isolée sur son réseau privé.

Détail de chaque stack : [`wordpress/README.md`](wordpress/README.md), [`n8n/README.md`](n8n/README.md), [`monitoring/README.md`](monitoring/README.md).
Fiche rôles : [`docs/roles.md`](docs/roles.md). Dashboard : [`dashboard/`](dashboard/).

## Architecture

![Architecture](docs/architecture.png)

```
services-net : 172.30.0.0/24

   WordPress <----- (1) publication -----> n8n <----- (3) alerte ----- Zabbix Server
       ^                                    |                              ^
       |                                    +---- (4) création article ----+
       |                                                                   |
   wordpress-agent <--------------------- agents interrogés (2) -----------+
   n8n-agent       <-------------------------------------------------------+
   zabbix-agent    <-------------------------------------------------------+ (surveille Zabbix lui-même)

wordpress-net        n8n-net            monitoring-net
172.31.1.0/24        172.31.2.0/24      172.31.3.0/24
    |                    |                   |
MariaDB            PostgreSQL          PostgreSQL (Zabbix)
```

| Stack | Services | Port(s) exposé(s) |
|---|---|---|
| `wordpress/` | wordpress, wordpress-db (MariaDB), wordpress-agent | 80 |
| `n8n/` | n8n, n8n-db (PostgreSQL), n8n-agent | 5678 |
| `monitoring/` | zabbix-server, zabbix-web, zabbix-db (PostgreSQL), zabbix-agent | 8080 |

## Scénario fonctionnel

Deux flux automatisés cohabitent :

1. **Publication -> automatisation** : un article publié sur WordPress déclenche un webhook vers n8n, qui exécute un workflow de traitement.
2. **Supervision -> alerte -> annonce** : des agents Zabbix (un par stack) surveillent en continu CPU/RAM/conteneurs. Quand Zabbix détecte un problème (ou sa résolution), il appelle n8n via un webhook, qui crée automatiquement un article sur WordPress annonçant l'incident.

## Prérequis sur la VM

- Ubuntu 22.04/24.04 avec accès SSH
- 4 à 6 Go de RAM minimum
- Ports **80, 5678, 8080** ouverts dans le NSG Azure (en plus du 22 pour SSH)

## Déploiement (objectif : moins de 15 minutes)

```bash
git clone <URL_DU_REPO> projet
cd projet
chmod +x scripts/up.sh
bash scripts/up.sh
```

Le script crée le réseau partagé `services-net`, puis démarre les trois stacks dans l'ordre (WordPress, n8n, Zabbix), en générant un `.env` à partir de `.env.example` si besoin.

**Si `.env.example` n'apparaît pas après un `git clone`** (fichier caché mal transféré), créez le `.env` à la main dans le dossier concerné — voir la section « Dépannage » de chaque README de stack, qui donne la commande exacte.

## Configuration post-déploiement (environ 10 minutes, manuelle)

Le déploiement des conteneurs est automatique, mais deux réglages applicatifs ne peuvent pas l'être et doivent être faits une fois, à la main, après le premier démarrage :

1. **WordPress** : terminer l'installation (langue, titre, compte admin), puis autoriser les mots de passe d'application et en créer un pour n8n — voir [`wordpress/README.md`](wordpress/README.md).
2. **n8n** : créer le compte propriétaire, importer les deux workflows, configurer le credential WordPress, activer les workflows — voir [`n8n/README.md`](n8n/README.md).
3. **Zabbix** : changer le mot de passe par défaut, créer les 3 hôtes (`wordpress`, `n8n`, `Zabbix server`) avec leur agent, configurer le media type webhook et l'action d'alerte vers n8n — voir [`monitoring/README.md`](monitoring/README.md).

Ces trois étapes sont documentées en détail, avec les erreurs les plus fréquentes et leur solution, dans le README de chaque stack.

## Vérification

1. **WordPress** : `http://IP` → publier un article → l'exécution apparaît dans n8n (*Executions*).
2. **Zabbix** : `http://IP:8080` → *Monitoring > Latest data* → CPU/RAM remontent pour les 3 hôtes.
3. **Alerte automatique** : arrêter un service (ex. `cd n8n && docker compose stop n8n-db`), attendre 1-2 minutes, vérifier *Monitoring > Problems* dans Zabbix, puis l'article créé dans WordPress.

## Scénario de démonstration

```bash
# Panne (éviter wordpress lui-même, voir la limite connue ci-dessous)
cd n8n && docker compose stop n8n-db

# Observer : Zabbix > Monitoring > Problems, puis Reports > Action log (statut "Sent")
# puis n8n > Executions, puis l'article "Alerte : ..." dans WordPress

# Rétablissement
docker compose start n8n-db
# Observer : le problème se résout dans Zabbix, article "Rétabli : ..." dans WordPress
```

**Limite connue** : si le service arrêté est WordPress lui-même, n8n ne peut pas y publier l'article tant qu'il est injoignable. Zabbix retente automatiquement (retries), donc l'article de panne finit par apparaître, mais en retard, après le redémarrage de WordPress. Pour une démonstration nette avec les deux articles (panne + rétablissement) dans l'ordre, tester la panne d'un autre composant.

## Arrêt

```bash
for d in wordpress n8n monitoring; do (cd "$d" && docker compose down); done
```

Ajoutez `-v` pour supprimer aussi les données (bases, workflows, configuration Zabbix) — utile pour repartir propre en cas de volumes incohérents avec un nouveau `.env`, voir le dépannage de chaque stack.

Pour la VM Azure : désallouer après chaque session (`az vm deallocate ...` ou bouton **Arrêter** dans le portail) pour préserver le crédit étudiant. Un simple arrêt depuis l'OS ne suffit pas.

## Sécurité

- Secrets uniquement dans les fichiers `.env` de chaque stack (ignorés par Git, jamais commités)
- Bases de données jamais exposées sur un port public
- Chaque conteneur n'est connecté qu'aux réseaux dont il a réellement besoin
- Mots de passe par défaut (Zabbix `Admin`/`zabbix`) changés dès le premier accès
- Les agents Zabbix et n8n/WordPress utilisent `user: root` et montent le socket Docker en lecture seule, nécessaire pour la supervision des conteneurs — accès large mais justifié techniquement, à mentionner dans le rapport

## Organisation du dépôt

```
projet/
├── README.md                 (ce fichier)
├── .gitignore
├── scripts/
│   └── up.sh                 (déploiement en une commande)
├── docs/
│   ├── roles.md
│   └── architecture.png
├── dashboard/                 (captures et description du dashboard Zabbix)
├── wordpress/                 (compose.yml, .env.example, mu-plugins/, README.md)
├── n8n/                       (compose.yml, .env.example, 2 workflows, README.md)
└── monitoring/                (compose.yml, .env.example, README.md)
```
