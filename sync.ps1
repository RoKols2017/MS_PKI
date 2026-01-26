# Быстрая синхронизация репозитория
# Запускать: powershell -ExecutionPolicy Bypass -File sync.ps1

cd $PSScriptRoot
git config --global --add safe.directory $PWD
git add -A
git commit -m "Синхронизация: исправлен .gitignore, обновлен CHANGELOG, добавлен config/"
git fetch origin
git merge origin/main --no-edit 2>$null
git push origin main
