# Publishing to your own GitHub repository

Run from the project directory (`pgbackrest_monitor/`).  Replace `<you>` with your GitHub user or
organisation.  The `gh` CLI must be logged in (`gh auth status`); without it, create the empty repository
in the GitHub web UI and skip the `gh repo create` line.

```bash
cd pgbackrest_monitor

# 1. identity for commits (once per machine, or drop --global to set it for this repo only)
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

# 2. initialise; test results and bytecode are already excluded by .gitignore
git init -b main
git add .
git status                                   # review: no tests/results/, no __pycache__, no secrets
git commit -m "pgbackrest_monitor 1.0: PostgreSQL extension and collector for pgBackRest monitoring"

# 3. create the GitHub repository and push
gh repo create <you>/pgbackrest_monitor --public --source=. --remote=origin --push \
   --description "Monitor pgBackRest backups, WAL archiving and repositories from SQL"
#   (use --private instead of --public for a private repository)

# 4. tag the release
git tag -a v1.0.0 -m "pgbackrest_monitor 1.0.0"
git push origin v1.0.0
gh release create v1.0.0 --title "pgbackrest_monitor 1.0.0" --notes-file docs/SAMPLE_HEALTH_REPORT.md
```

Afterwards: `README.md` references `https://github.com/<you>/pgbackrest_monitor` in the clone
instructions and the systemd unit's `Documentation=` line; adjust both to your URL.

## Day-to-day

```bash
git checkout -b fix/archive-threshold         # work on a branch
make unittest && make installcheck && make integration
git commit -am "Describe the change"
git push -u origin fix/archive-threshold
gh pr create --fill                           # open a pull request, merge from the web UI or `gh pr merge`
```

## Optional: continuous integration

A GitHub Actions workflow that runs the unit tests on every push (the SQL and integration tests need a
PostgreSQL server with the extension installed, which the `postgres` service container plus
`apt install postgresql-server-dev` can provide; start with the unit tests):

```yaml
# .github/workflows/ci.yml
name: ci
on: [push, pull_request]
jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y python3-psycopg2
      - run: make unittest
```
