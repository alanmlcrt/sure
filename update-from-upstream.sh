#!/usr/bin/env bash
# Met à jour ton fork avec les nouveautés de we-promise/sure (upstream),
# en conservant tes modifications (import Excel, workflow CI, etc.).
#
# Usage :  ./update-from-upstream.sh    (ou : bash update-from-upstream.sh)
set -euo pipefail

BRANCH="main"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"

info() { printf '\033[1;34m▶ %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$1"; }
err()  { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; }

# 1. Le remote upstream existe-t-il ?
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  err "Le remote '$UPSTREAM_REMOTE' n'existe pas. Ajoute-le avec :"
  echo "    git remote add $UPSTREAM_REMOTE https://github.com/we-promise/sure.git"
  exit 1
fi

# 2. Working tree propre ? (sinon une fusion écraserait/mélangerait ton travail)
if ! git diff --quiet || ! git diff --cached --quiet; then
  err "Tu as des changements non commités. Commit ou 'git stash' avant de mettre à jour."
  git status --short
  exit 1
fi

# 3. Se placer sur main
current="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current" != "$BRANCH" ]; then
  info "Bascule sur '$BRANCH' (tu étais sur '$current')."
  git checkout "$BRANCH"
fi

# 4. Récupérer les nouveautés upstream
info "Récupération depuis $UPSTREAM_REMOTE/$UPSTREAM_BRANCH..."
git fetch "$UPSTREAM_REMOTE"

# 5. Y a-t-il quelque chose à fusionner ?
count="$(git rev-list --count "${BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}")"
if [ "$count" -eq 0 ]; then
  ok "Déjà à jour — rien de nouveau côté upstream."
  exit 0
fi
info "$count nouveau(x) commit(s) à intégrer :"
git log --oneline --no-decorate "${BRANCH}..${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" | sed 's/^/    /'

# 6. Fusion (en gardant tes commits)
info "Fusion dans '$BRANCH'..."
if git merge --no-edit "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"; then
  ok "Fusion réussie, tes modifications sont conservées."
  echo
  info "Étapes suivantes :"
  echo "    git push origin $BRANCH                         # publie + déclenche le build de l'image"
  echo "    # puis sur le VPS : docker compose pull && docker compose up -d"
else
  echo
  err "Conflits de fusion. Fichiers concernés :"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  echo
  warn "Ouvre chaque fichier, garde À LA FOIS leurs changements et les tiens, puis :"
  echo "    git add <fichiers résolus>"
  echo "    git commit"
  echo "    git push origin $BRANCH"
  echo
  warn "Pour tout annuler et revenir à l'état d'avant la fusion : git merge --abort"
  exit 1
fi
