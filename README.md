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

## systemd service

There is a unit file included in the repository root as `HIDSoft.service`. The packaged unit already uses `After=mariadb.service` so systemd will start this service after the database unit, but depending on how you want system behavior to respond to the database, you may want to adjust the unit in one of these ways:

- Add `Requires=mariadb.service` to make systemd treat MariaDB as required (this unit will fail if MariaDB fails to start).
- Use `Wants=mariadb.service` if you want systemd to try to start MariaDB but not treat its failure as fatal.

Also ensure `ExecStart` uses absolute paths (both the ruby binary and the script) so systemd can execute the process reliably.

To use the packaged unit file:

1. Copy the service file to systemd's unit directory:

   sudo cp HIDSoft.service /etc/systemd/system/HIDSoft.service

2. Inspect the file and update paths or dependency behavior if needed. The repo's `HIDSoft.service` contains the following settings:

```ini name=HIDSoft.service url=https://github.com/nsayers/HIDSoft/blob/main/HIDSoft.service
[Unit]
Description=HID Card Reader Software
After=network.target mariadb.service

[Service]
User=cardreader
Group=cardreader
WorkingDirectory=/usr/local/sbin/HIDSoft
Restart=on-failure
ExecStart=/usr/bin/ruby rubyserv.rb debug

[Install]
WantedBy=multi-user.target
```

Suggested edits (optional) — copy into the unit file to make the DB dependency explicit and use absolute paths:

```ini
[Unit]
Description=HID Card Reader Software
Requires=mariadb.service
After=network.target mariadb.service

[Service]
User=cardreader
Group=cardreader
WorkingDirectory=/usr/local/sbin/HIDSoft
Restart=on-failure
ExecStart=/usr/bin/ruby /usr/local/sbin/HIDSoft/rubyserv.rb debug

[Install]
WantedBy=multi-user.target
```

Notes:
- On some systems the DB unit is named `mysql.service` instead of `mariadb.service`; adjust the Requires/After lines to match your distribution.
- If you prefer systemd not to fail the HIDSoft unit when DB fails to start, use `Wants=` instead of `Requires=`.

3. Reload systemd and enable/start the service:

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
