# Wazuh on a Mac in one command

Set up [Wazuh](https://wazuh.com), the free and open-source security platform, on an Apple silicon Mac. The script runs the Wazuh server in Docker and connects your Mac's own Wazuh agent to it, so the Mac is monitored for misconfigurations, known vulnerabilities, file changes and suspicious activity.

Everything stays on your Mac: the server is reachable only from `127.0.0.1`, and every default password is replaced with a random one before the first start.

## Quick start

1. Install [Docker Desktop for Apple silicon](https://www.docker.com/products/docker-desktop/) and open it.
2. In Docker Desktop, set **Settings → Resources → Memory** to **8 GB** and click **Apply & restart**.
3. In **Settings → General**, turn on **Start Docker Desktop when you sign in**, so monitoring survives a reboot.
4. Run this in Terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/muhaiminShihab/wazuh-setup/main/setup-wazuh-docker-mac.sh)"
```

The first run takes 5–10 minutes because it downloads about 3 GB of Docker images. It asks for your Mac password once, to install the agent.

When it finishes, it prints:

- the dashboard address, usually `https://localhost`
- the username `admin`
- a generated password

Your browser will warn about the certificate. That's expected, because the certificate is self-signed. Save the password in your password manager.

### Prefer to read it first?

You should; it's a security tool. Download it, look through it, then run it:

```bash
curl -fsSL https://raw.githubusercontent.com/muhaiminShihab/wazuh-setup/main/setup-wazuh-docker-mac.sh -o setup-wazuh-docker-mac.sh
less setup-wazuh-docker-mac.sh
bash setup-wazuh-docker-mac.sh
```

## Requirements

| What | Needed |
| --- | --- |
| Mac | Apple silicon (M1 or later), macOS Big Sur or later |
| Docker Desktop | Installed and running, with at least 4 GB of memory (8 GB recommended) |
| Disk | About 3 GB for the images, plus room for data (Wazuh recommends 50 GB for 90 days) |
| Account | An admin account on the Mac, for installing the agent |
| Free ports | 1514, 1515, 514/udp, 9200 and 55000 on this Mac; the dashboard uses 443, or 8443/9443 if 443 is taken |

## What the script does

1. Checks that Docker Desktop is running and has enough memory.
2. Sets `vm.max_map_count` to 262144 inside Docker's VM if it's lower, which the Wazuh indexer needs.
3. Downloads Wazuh's official Docker setup, [wazuh-docker v4.14.9](https://github.com/wazuh/wazuh-docker), into `~/wazuh-docker`.
4. Hardens the configuration before the first start (see below).
5. Generates TLS certificates and starts the Wazuh manager, indexer and dashboard.
6. Downloads the Wazuh agent for macOS from `packages.wazuh.com`, checks that the package is signed by Wazuh, installs it and points it at `127.0.0.1`.
7. Confirms the new admin password works, the default one is rejected, and the agent shows as **Active**.

## Security choices

Wazuh's stock Docker files are built for a lab server: they publish every port to the network and ship with publicly known passwords. On a laptop that moves between networks, the script changes that before anything starts:

- **Local only.** Every published port is bound to `127.0.0.1`, so nothing on your Wi-Fi or office network can reach the server, the indexer API or the dashboard.
- **No default passwords.** `admin`, `kibanaserver` and the `wazuh-wui` API user get random 25-character passwords. The other built-in demo users (`kibanaro`, `logstash`, `readall`, `snapshotrestore`) get random passwords that are never saved, so their public defaults no longer work.
- **Verified agent package.** The script stops if the agent installer isn't signed by Wazuh.
- **Private credentials file.** Passwords are saved in `~/wazuh-docker/single-node/.wazuh-credentials`, readable only by your user.

## Day to day

| Task | Command |
| --- | --- |
| Open the dashboard | `https://localhost` (or the port the script printed) |
| See your passwords | `cat ~/wazuh-docker/single-node/.wazuh-credentials` |
| Stop the server | `cd ~/wazuh-docker/single-node && docker compose stop` |
| Start it again | `cd ~/wazuh-docker/single-node && docker compose start`, or re-run the script |
| Check the agent | `sudo /Library/Ossec/bin/wazuh-control status` |
| Read the agent log | `sudo tail -30 /Library/Ossec/logs/ossec.log` |

Re-running the script is safe. On an existing install it starts the server, re-checks the configuration and makes sure the agent is connected. While the server is stopped, the agent keeps watching the Mac and catches up when the server is back.

### Install somewhere other than `~/wazuh-docker`

```bash
export WAZUH_DIR=~/somewhere-else
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/muhaiminShihab/wazuh-setup/main/setup-wazuh-docker-mac.sh)"
```

Keep it inside your home folder so Docker Desktop can read the config files.

## Troubleshooting

**"Docker Desktop isn't running."** Open Docker Desktop, wait until it shows *Engine running*, then run the script again.

**"Docker Desktop only has … GB of memory."** Raise it under **Settings → Resources → Memory**, click **Apply & restart**, then run the script again.

**The dashboard stops loading after Docker Desktop restarts.** Docker Desktop can reset `vm.max_map_count`, which stops the indexer. Re-run the script; it sets the value again and restarts the server.

**"Data from an earlier Wazuh Docker install is still in Docker."** An old install's data would clash with the new passwords. If you don't need it, remove it and run the script again:

```bash
docker volume ls -q | grep '^single-node_' | xargs docker volume rm
```

**"Port is already allocated."** Another program is using 1514, 1515, 514, 9200 or 55000. Stop it, or find it with `lsof -nP -i :<port>`.

**The agent never shows as Active.** Check its log with `sudo tail -30 /Library/Ossec/logs/ossec.log`, and confirm the server is up with `cd ~/wazuh-docker/single-node && docker compose ps`.

## Uninstall

Remove the server and all of its data:

```bash
cd ~/wazuh-docker/single-node && docker compose down -v
rm -rf ~/wazuh-docker
```

Remove the agent (commands from [Wazuh's uninstall guide](https://documentation.wazuh.com/current/installation-guide/uninstalling-wazuh/agent.html)):

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.wazuh.agent.plist
sudo /bin/rm -r /Library/Ossec
sudo /bin/rm -f /Library/LaunchDaemons/com.wazuh.agent.plist
sudo /bin/rm -rf /Library/StartupItems/WAZUH
sudo /usr/bin/dscl . -delete "/Users/wazuh"
sudo /usr/bin/dscl . -delete "/Groups/wazuh"
sudo /usr/sbin/pkgutil --forget com.wazuh.pkg.wazuh-agent
```

## Limitations

- **One Mac.** The server only listens on this Mac, so other computers can't report to it. To monitor a team, run the Wazuh server on a separate Linux machine (see Wazuh's [Quickstart](https://documentation.wazuh.com/current/quickstart.html)) and point each laptop's agent at it.
- **Same machine.** The server runs on the Mac it watches. If that Mac were compromised, its logs couldn't be fully trusted. A separate server avoids that.
- **Apple silicon only.** Intel Macs need the `intel64` agent package; the script doesn't handle them yet.
- **Pinned version.** The script installs Wazuh 4.14.9. To move to a newer release, update `WAZUH_VERSION` at the top of the script and test it on a fresh install.

## Credits

[Wazuh](https://wazuh.com) is developed by Wazuh, Inc. and released under GPLv2 and Apache 2.0. This repository only automates installing it and isn't affiliated with Wazuh, Inc.
