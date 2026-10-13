# Hermes Agent + WebUI on Railway

Run [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research on an always-on Railway server and use it from any browser through [Hermes WebUI](https://github.com/nesquena/hermes-webui).

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent-webui?utm_medium=integration&utm_source=template&utm_campaign=hermes-webui)

## What you get

- Hermes WebUI: chat with streaming, sessions, workspace file browser, memory, skills, scheduled tasks, profiles and settings, on desktop and phone.
- Hermes Agent running in the same service, built from the official Nous Research image.
- The Hermes gateway running alongside it, so scheduled tasks fire while you are away and Telegram, Discord, Slack and other messaging apps can reach the agent.
- A password-protected login. The password is generated for you.
- One volume for everything: config, sessions, memory, skills, cron jobs and your workspace survive redeploys.
- Automatic, tested version updates (see [Updates](#updates)).

## After deploying

1. Open the service's public URL.
2. Sign in with `HERMES_WEBUI_PASSWORD`. You'll find it in the service's **Variables** tab.
3. Connect a model provider. Either:
   - set one of the API key variables (for example `OPENROUTER_API_KEY`) in **Variables** and redeploy, or
   - open **Settings → Providers** in the WebUI and paste a key there.

   One OpenRouter key gives access to models from most providers. Until a provider is connected, chat replies with "No LLM provider configured".
4. Pick a model from the model menu in the composer and start chatting.

### Messaging apps (optional)

To talk to Hermes from Telegram, create a bot with [@BotFather](https://t.me/BotFather), then set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS` (your numeric Telegram user ID from [@userinfobot](https://t.me/userinfobot), comma-separated for several people) and redeploy. Hermes does not answer anyone who is not on the list.

Discord, Slack, Signal, email and the other platforms Hermes supports work the same way. See the [Hermes messaging docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/) for the variable names, and add them in **Variables**.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `HERMES_WEBUI_PASSWORD` | generated | Password for the WebUI login. Required. The service will not start without it. |
| `OPENROUTER_API_KEY` | none | Optional. OpenRouter key. One key for models from many providers. |
| `ANTHROPIC_API_KEY` | none | Optional. Anthropic API key for Claude models. |
| `OPENAI_API_KEY` | none | Optional. OpenAI API key. |
| `NOUS_API_KEY` | none | Optional. Nous Portal API key for Hermes models. |
| `TELEGRAM_BOT_TOKEN` | none | Optional. Bot token from @BotFather to chat with Hermes on Telegram. |
| `TELEGRAM_ALLOWED_USERS` | none | Optional. Telegram user IDs allowed to use the bot, comma-separated. |

Any other provider key Hermes understands (`GOOGLE_API_KEY`, `DEEPSEEK_API_KEY`, `XAI_API_KEY` and so on) can be added the same way. A key saved in **Settings → Providers** is stored on the volume and takes priority over a Railway variable with the same name.

Advanced: set `HERMES_GATEWAY=off` to run the WebUI without the gateway. Scheduled tasks then only run when you trigger them, and messaging apps are disabled.

Public networking should point at port `8080`, the port Railway gives the service by default.

## How it is put together

Everything runs in one Railway service with one volume:

- The image starts from the official `nousresearch/hermes-agent` image and adds Hermes WebUI on top.
- The WebUI is the only public process. It runs the agent in-process from the agent's own Python environment, the way Hermes WebUI's recommended single-container setup does.
- The Hermes gateway runs next to it under the image's own supervisor, which restarts it if it crashes. Its API listens on `127.0.0.1:8642` only. The WebUI uses it for scheduled tasks and gateway health, with a key that is generated on first boot.

Why not two services? Hermes WebUI reads the agent's home directory directly (sessions, memory, skills, cron jobs, config). Railway volumes can't be shared between services, so splitting the agent and the WebUI would leave one of them without the data.

## Security

- Hermes WebUI has no login unless a password is set, and the agent can run shell commands on the server. This template generates `HERMES_WEBUI_PASSWORD` and the service refuses to start if it is empty or shorter than 12 characters.
- Every page and API route except the login page, health check, static files and share links you create yourself requires signing in. Login cookies are HTTP-only, signed and marked Secure on Railway.
- The gateway API and the official Hermes dashboard are not exposed. Only the WebUI port is public.
- The WebUI and the gateway run as the unprivileged `hermes` user.
- Telegram and other messaging platforms only answer the users you allow.

To change the password, edit `HERMES_WEBUI_PASSWORD` and redeploy. The variable always wins over a password set in the WebUI.

## Storage

Mount the volume at `/opt/data`. That is `HERMES_HOME`, and also `HOME` for the agent:

| Path | Contents |
|---|---|
| `/opt/data/config.yaml`, `/opt/data/.env` | Hermes config and keys saved from the WebUI |
| `/opt/data/sessions`, `/opt/data/memories`, `/opt/data/skills`, `/opt/data/cron` | Agent state |
| `/opt/data/webui` | WebUI sessions, settings and login secrets |
| `/opt/data/workspace` | Default workspace shown in the file browser |
| `/opt/data/logs` | Gateway and agent logs |

## Updates

This template pins the Hermes Agent image (by tag and digest) and the Hermes WebUI release (by commit). A GitHub Action checks for new versions every day:

- Hermes Agent is bumped when Nous Research moves its `stable` image to a new release.
- Hermes WebUI publishes a release almost every day, so it is bumped weekly, or together with an agent release.
- Every bump is built and smoke-tested before it is merged. Failed bumps open an issue instead.

When a bump lands, Railway shows an **update available** notice in your project. Updates are opt-in: apply them when it suits you. Your volume is kept.

Hermes WebUI publishes stable (`v*`) and experimental (`exp-v*`) releases. The update script takes the newest release of either kind. At the moment the stable line is older than the current Hermes Agent and does not work fully with it, so the pinned WebUI release is from the experimental line. Each one still has to pass the smoke test.

The in-app update check of Hermes WebUI is turned off, because this install is updated by redeploying.

## Run it locally

```bash
HERMES_WEBUI_PASSWORD=$(openssl rand -hex 16) docker compose up --build
# open http://localhost:8080
```

`scripts/smoke-test.sh` builds the image and, starting from an empty root-owned volume like Railway's, checks that:

- the service refuses to start without a password
- only the login page is reachable without signing in
- the WebUI can import the agent and reach the gateway API with its key
- the gateway API listens on loopback only, and the WebUI can restart the gateway
- chat without a model key fails with a clear error and the server stays up
- sessions and the login survive a restart

## License

The files in this repository are MIT licensed. Hermes Agent and Hermes WebUI are MIT licensed by their authors and are installed unmodified.
