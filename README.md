# 5dive-laya

Runs [Laya](https://huggingface.co/convaiinnovations/laya), a small local typed-decision model,
as the provider behind `5dive reflex`. With it, reflex decides on your own box with no API key.

```bash
sudo 5dive plugin add 5dive-ai/5dive-laya
sudo 5dive laya setup
```

`plugin add` installs only the `5dive laya` command. 5dive never runs a plugin's code at install
time. `setup` does the host work, and you start it yourself:

- installs Laya **0.3.20** (pinned) with CPU torch into `/opt/5dive-laya/venv`
- fetches the one checkpoint reflex asks for (`typed-decisions`) into `/var/lib/5dive-laya`
- starts **one** shared `5dive-reflex-laya.service` per host, bound to **127.0.0.1:8767 only**,
  with **no checkpoint preloaded**, offline, as the `5dive-laya` system user
- points reflex at it: `5dive config reflex-endpoint=http://127.0.0.1:8767/v1/systemone reflex-model=typed-decisions`

If the live socket is ever anything other than loopback, setup stops the service and does not
point reflex at it. The unit also carries a systemd IP firewall (`IPAddressDeny=any`,
`IPAddressAllow=localhost`), so the port stays closed to the network even if a future Laya
ignored `LAYA_HOST`.

## Hardware

**Starter Plus (8 GB RAM) or larger is the minimum for a local Laya.** On **Starter (4 GB)**, keep
reflex on its remote provider. Setup refuses a host with under 7 GiB of RAM
(`--allow-small-host` overrides it at your own risk).

## Check it, and undo it

```bash
5dive laya                    # service, bind, health, whether reflex uses it, RAM and disk
5dive laya status --json
5dive reflex status --probe   # reflex's own view: endpoint, configured, health
5dive laya logs
sudo 5dive laya uninstall     # reflex back to its default endpoint, service and files gone, plugin removed
```

Uninstall resets reflex only if it still points at this Laya. A model you had set explicitly
before setup is restored.

## What this plugin is not

Laya is an engine behind `5dive reflex` and nothing more. This plugin has no decision API of its
own, no command an agent calls, no routing and no policy. Agents keep calling `5dive reflex`
exactly as before. Setup only changes which provider answers.

Setting up the provider does not let any policy act on Laya's answers. Reflex runs every provider
in shadow, and whether a policy may act is decided from the replay numbers.

## Tests

```bash
bash tests/laya.test.sh          # the lifecycle against a throwaway root, stubbed host
bash tests/negative-controls.sh  # each load-bearing line, broken, turns exactly its arms red
sudo bash tests/on-box-acceptance.sh  # on a throwaway 8 GB box: install, measure, uninstall
```
