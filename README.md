# Odoo Tamara Dev

```bash
./scripts/setup-website.sh
./scripts/run-website.sh --ngrok
```

- Backend: `<public-or-local>/odoo`
- Enable Tamara: Apps → search Tamara → Activate
- Tamara settings: main menu → Tamara

Set `NGROK_URL` in `.env` if you already have a reserved ngrok domain. `NGROK_ENABLED=1` starts the tunnel on every `./scripts/run-website.sh`.

## Run the website
- <domain>/odoo
- Enable Tamara: <domain>/odoo/apps -> search for module Tamara -> Activate
- Go to Tamara settings: Main menu -> Tamara then input Tamara tokens to start