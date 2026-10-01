#!/usr/bin/env bash
# Lance les trois stacks dans l'ordre, depuis la racine du repo.
# Usage : bash scripts/up.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> Réseau partagé services-net..."
docker network create --driver bridge --subnet 172.30.0.0/24 services-net 2>/dev/null \
  && echo "   créé" || echo "   déjà existant, on continue"

for stack in wordpress n8n monitoring; do
  echo
  echo ">> Stack : $stack"
  if [ ! -d "$stack" ]; then
    echo "   dossier '$stack' introuvable, ignoré"
    continue
  fi
  (
    cd "$stack"
    if [ ! -f .env ]; then
      if [ -f .env.example ]; then
        cp .env.example .env
        echo "   .env créé depuis .env.example : pensez à le compléter si besoin"
      else
        echo "   ATTENTION : ni .env ni .env.example trouvé dans $stack/"
      fi
    fi
    docker compose up -d
  )
done

echo
echo "Terminé. Vérifiez l'état avec :"
echo "  docker ps"
echo "  (cd wordpress && docker compose ps)"
echo "  (cd n8n && docker compose ps)"
echo "  (cd monitoring && docker compose ps)"
