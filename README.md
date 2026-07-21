# HIDSoft

HIDSoft is the control server for HID card readers and related tooling. This README provides basic installation, configuration, and operational guidance to get the server running and to connect readers.

## Requirements

- Linux (tested on Debian, CentOS and AlmaLinux)
- MariaDB (I built with 10.3; other 10.x versions should work)
- Ruby and Perl runtimes (repo contains Ruby and Perl components)
- systemd (or other init system) to run the service
- TCP port 4070 open between readers and the server

## Installation

1. Create the install directory and copy the repository files:

   sudo mkdir -p /usr/local/sbin/HIDSoft
   sudo cp -r bin /usr/local/sbin/HIDSoft

2. Create a dedicated system user to run the service (no interactive login required):

   sudo useradd --system --no-create-home --shell /sbin/nologin cardreader
   sudo chown -R cardreader:cardreader /usr/local/sbin/HIDSoft

3. Install and configure MariaDB. Create a database and a user for HIDSoft and grant the appropriate privileges.

4. Open the reader TCP port (4070) on your firewall and restrict it to the networks where your readers live. Example with firewalld:

   sudo firewall-cmd --add-port=4070/tcp --permanent
   sudo firewall-cmd --reload

   If you use ufw/iptables, open the equivalent port there.

## systemd service (example)

Create `/etc/systemd/system/HIDSoft.service` and replace `<executable>` below with the actual server executable or start script in `/usr/local/sbin/HIDSoft/bin`.

```ini name=/etc/systemd/system/HIDSoft.service
[Unit]
Description=HIDSoft control server
After=network.target

[Service]
Type=simple
User=cardreader
Group=cardreader
WorkingDirectory=/usr/local/sbin/HIDSoft
ExecStart=/usr/local/sbin/HIDSoft/bin/<executable>
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then enable and start the service:

   sudo systemctl daemon-reload
   sudo systemctl enable --now HIDSoft.service

## Configuration

Place your configuration (database connection, ports, credentials, logging, etc.) where your deployment expects it. Common locations include `/etc/HIDSoft/` or a config file inside `/usr/local/sbin/HIDSoft`. If the project has example configuration files in the repo, copy and edit those.

## Pointing readers at the server

Configure each reader to connect to the server's IP address and port 4070. When the server is running and you monitor it, you should normally see a child process created for each connected reader.

## Build / performance notes

Depending on the number of readers and hardware, build times vary. In my environment with ~60 readers the access/ident build cycle took about 10 minutes per build. Adjust hardware and worker counts to suit your workload.

## Security

- Keep the reader network internal where possible — the protocol is not encrypted by default.
- Consider tunneling reader traffic over VPN or TLS if readers must be exposed across untrusted networks.
- Use firewall rules and network segmentation to limit access to port 4070.

## Troubleshooting

- Check `journalctl -u HIDSoft.service` for service logs.
- Verify the service user has access to the install and config files.
- Confirm MariaDB is running and that the HIDSoft DB user can connect from the server.

## Contributing / Support

If you want to improve the README or the installation experience, please open an issue or a pull request with proposed changes.
